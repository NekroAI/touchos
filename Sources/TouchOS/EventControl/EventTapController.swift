import CoreGraphics
import Foundation
import OSLog
import TouchOSAtomics
import TouchOSCore

/// HID 层可修改的事件拦截（SRS 7.1、7.2）。回调运行在专用线程的 RunLoop 上，只读取无锁发布的 `TapPolicy` 快照查表决定放行或丢弃；
/// 物理按下与 Esc 通过回调异步上报给状态机。光标冻结只靠丢弃指针移动实现：进程退出后拦截随之消失，系统行为立即恢复（NFR-7）。
final class EventTapController: @unchecked Sendable {
    /// TouchOS 合成的事件在事件源用户数据字段写入该值，拦截见到一律放行（FR-7.3）
    static let syntheticMarker: Int64 = 0x546F_7563_684F_53  // "TouchOS"

    // AppKit 手势类事件的原始类型值（FR-7.1）：旋转 18、开始手势 19、结束手势 20、手势 29、捏合 30、轻扫 31、智能缩放 32、查询 33、压力 34
    private static let gestureTypes: Set<UInt32> = [18, 19, 20, 29, 30, 31, 32, 33, 34]
    private static let pointerMoveTypes: Set<CGEventType> = [.mouseMoved]
    private static let buttonTypes: Set<CGEventType> = [
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
    ]
    private static let escapeKeyCode: Int64 = 53

    private let log = Logger(subsystem: TouchOSCore.logSubsystem, category: "tap")

    // 无锁发布的策略快照：先写截止时刻，最后写模式
    private let mode = TOAtomicCreate()!            // TapPolicy.Mode 原始值 | passGestures << 8
    private let cooldownUntil = TOAtomicCreate()!
    private let momentumUntil = TOAtomicCreate()!
    // 候选期被丢弃的指针位移，由 CursorLock 取走（FR-7.6）
    private let deltaX = TOAtomicCreate()!
    private let deltaY = TOAtomicCreate()!

    private let onPhysicalPress: @Sendable () -> Void
    private let onEscape: @Sendable () -> Void
    private let onDisabled: @Sendable () -> Void

    private var tap: CFMachPort?
    private var thread: Thread?

    /// 三个回调在拦截线程上调用，实现方只能异步投递（FR-7.2）。
    init(onPhysicalPress: @escaping @Sendable () -> Void, onEscape: @escaping @Sendable () -> Void,
         onDisabled: @escaping @Sendable () -> Void) {
        self.onPhysicalPress = onPhysicalPress
        self.onEscape = onEscape
        self.onDisabled = onDisabled
    }

    var isRunning: Bool { tap != nil }

    var isEnabled: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    func publish(_ policy: TapPolicy) {
        TOAtomicStoreDouble(cooldownUntil, policy.cooldownUntil)
        TOAtomicStoreDouble(momentumUntil, policy.momentumUntil)
        TOAtomicStore(mode, UInt64(policy.mode.rawValue) | (policy.passGestures ? 1 << 8 : 0))
    }

    /// 取出候选期累计的指针位移并清零
    func takeCursorDelta() -> CGVector {
        CGVector(dx: TOAtomicExchangeDouble(deltaX, 0), dy: TOAtomicExchangeDouble(deltaY, 0))
    }

    /// 在专用线程上创建拦截。没有辅助功能权限时创建失败，返回 false。
    func start() -> Bool {
        guard tap == nil else { return true }
        var mask: CGEventMask = 0
        for type in Self.pointerMoveTypes.union(Self.buttonTypes).union([.scrollWheel, .keyDown]) {
            mask |= 1 << CGEventMask(type.rawValue)
        }
        for raw in Self.gestureTypes { mask |= 1 << CGEventMask(raw) }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: tapCallback, userInfo: refcon) else {
            log.error("CGEvent.tapCreate failed (accessibility permission missing?)")
            return false
        }
        tap = port
        let thread = Thread { [self] in
            guard let port = tap else { return }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
        }
        thread.name = "ai.nekro.touchos.tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
        log.info("event tap started")
        return true
    }

    /// 拦截回调：只查表，不加锁、不等待（FR-7.2）
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reenable()  // FR-7.10：立即重新启用，并让状态机取消会话
            onDisabled()
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker { return pass }

        let packed = TOAtomicLoad(mode)
        let mode = TapPolicy.Mode(rawValue: UInt8(packed & 0xFF)) ?? .idle
        let now = ProcessInfo.processInfo.systemUptime
        let inCooldown = mode == .cooldown && now < TOAtomicLoadDouble(cooldownUntil)

        if Self.pointerMoveTypes.contains(type) {
            switch mode {
            case .armed:
                // FR-7.6：候选期丢弃并累计位移
                TOAtomicAddDouble(deltaX, Double(event.getIntegerValueField(.mouseEventDeltaX)))
                TOAtomicAddDouble(deltaY, Double(event.getIntegerValueField(.mouseEventDeltaY)))
                return nil
            case .active:
                return nil  // FR-7.4：任何来源的指针移动一律丢弃
            default:
                return pass
            }
        }
        if Self.buttonTypes.contains(type) {
            switch mode {
            case .armed:
                if type == .leftMouseDown { onPhysicalPress() }  // T4：上报后放行
                return pass
            case .active:
                return nil
            case .cooldown:
                // SPEC-QUESTION: 策略表冷却列只丢弃"触控板来源"的按键，但拦截层无法可靠区分来源；目前冷却期内一律丢弃
                return inCooldown ? nil : pass
            case .idle:
                return pass
            }
        }
        if type == .scrollWheel {
            if mode == .active { return nil }
            // 退出后继续丢弃惯性阶段的滚动（SRS 7.2 冷却列，`P.momentumSuppressMs`）
            let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0
            return momentum && now < TOAtomicLoadDouble(momentumUntil) ? nil : pass
        }
        if Self.gestureTypes.contains(type.rawValue) {
            if mode == .active { return nil }
            let passGestures = packed & (1 << 8) != 0  // FR-7.5
            return inCooldown && !passGestures ? nil : pass
        }
        if type == .keyDown, mode == .active, event.getIntegerValueField(.keyboardEventKeycode) == Self.escapeKeyCode {
            onEscape()  // T16：上报并吞掉
            return nil
        }
        return pass
    }
}

private let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<EventTapController>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
}
