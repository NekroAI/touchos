import AppKit
import CoreGraphics
import Foundation
import OSLog
import TouchOSAtomics
import TouchOSCore

/// HID 层可修改的事件拦截（SRS 7.1、7.2）。回调运行在专用线程的 RunLoop 上，只读取无锁发布的 `TapPolicy` 快照查表决定放行或丢弃；
/// 物理按下与 Esc 通过回调异步上报给状态机。进程退出后拦截随之消失（NFR-7）；光标冻结另见 `CursorLock`（D50）。
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
    private static let buttonDownTypes: Set<CGEventType> = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    /// NSEvent 压力事件的原始类型值（力度触控板的轻按 / 深按阶段）
    private static let pressureType: UInt32 = 34
    /// 按下事件与压力阶段进入 1 的事件相隔不超过该值，才算同一次物理按压（D18）。两者到达顺序不固定
    static let pressPairingWindow: TimeInterval = 0.08

    /// NFR-2 打点：1 µs 一个桶，统计到 2 ms，超出计入溢出桶
    static let timingBucketWidth: TimeInterval = 0.000_001
    static let timingBuckets = 2000
    /// AC-17 调试开关：在回调里阻塞这么久，超过系统对拦截回调的超时，触发系统停用拦截
    static let debugStallDuration: TimeInterval = 2

    private let log = Logger(subsystem: TouchOSCore.logSubsystem, category: "tap")

    // 无锁发布的策略快照：先写截止时刻，最后写模式
    private let mode = TOAtomicCreate()!            // TapPolicy.Mode 原始值 | passGestures << 8
    private let cooldownUntil = TOAtomicCreate()!
    private let momentumUntil = TOAtomicCreate()!
    // 确认期被丢弃的指针位移，由 CursorLock 取走（FR-7.6）
    private let deltaX = TOAtomicCreate()!
    private let deltaY = TOAtomicCreate()!
    // NFR-2 回调耗时（调试叠层可用时才统计）：每桶一个计数器，最大值以纳秒记
    private let measure: Bool
    private let timing: [OpaquePointer]
    private let timingMaxNs = TOAtomicCreate()!
    // 调试叠层的指针诊断：激活态收到（并丢弃）的指针移动事件数
    private let activeMoves = TOAtomicCreate()!
    // AC-17：到达该时刻（systemUptime）后的第一个事件在回调里阻塞，0 表示未预约
    private let stallAt = TOAtomicCreate()!
    private let ticksToNs: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    private let onPhysicalPress: @Sendable () -> Void
    /// 激活态松开按键（D23：长按关闭进入编辑，未到时长松开即取消）。在 `start()` 之前设置
    var onPhysicalRelease: (@Sendable () -> Void)?
    private let onEscape: @Sendable () -> Void
    private let onDisabled: @Sendable () -> Void

    /// 调试叠层：力度触控板的按压阶段与力度（在拦截线程上调用，须异步投递）。在 `start()` 之前设置
    var onPressureDebug: (@Sendable (_ stage: Int, _ pressure: Float) -> Void)?

    private var tap: CFMachPort?
    private var thread: Thread?

    // 激活态按压配对（D18）：物理按压同时产生按下事件与压力阶段 1；"轻点来点按"只产生按下事件。
    // 只在拦截线程上读写。从未见过压力事件的设备（没有力度触控）退回"任何按下都算"。
    private var sawPressure = false
    private var pressureStage = 0
    private var stageUpAt: TimeInterval = 0
    private var pendingDownAt: TimeInterval = 0

    /// 三个回调在拦截线程上调用，实现方只能异步投递（FR-7.2）。
    /// `measure` 为真时统计回调耗时（NFR-2），供调试叠层显示。
    init(measure: Bool, onPhysicalPress: @escaping @Sendable () -> Void, onEscape: @escaping @Sendable () -> Void,
         onDisabled: @escaping @Sendable () -> Void) {
        self.measure = measure
        timing = measure ? (0...Self.timingBuckets).map { _ in TOAtomicCreate()! } : []
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

    /// 取出确认期累计的指针位移并清零
    func takeCursorDelta() -> CGVector {
        CGVector(dx: TOAtomicExchangeDouble(deltaX, 0), dy: TOAtomicExchangeDouble(deltaY, 0))
    }

    /// 回调耗时快照（NFR-2）；未开启统计时为 nil
    func timingSnapshot() -> LatencyHistogram? {
        guard measure else { return nil }
        return LatencyHistogram(bucketWidth: Self.timingBucketWidth, counts: timing.map { TOAtomicLoad($0) },
                                max: Double(TOAtomicLoad(timingMaxNs)) / 1e9)
    }

    /// 取出激活态丢弃的指针移动事件数（调试叠层）
    var droppedActiveMoves: UInt64 { TOAtomicLoad(activeMoves) }

    func resetTiming() {
        TOAtomicStore(activeMoves, 0)
        for t in timing { TOAtomicStore(t, 0) }
        TOAtomicStore(timingMaxNs, 0)
    }

    /// AC-17 调试：`delay` 秒后的第一个事件在回调里阻塞 `debugStallDuration`，让系统以超时停用拦截
    func scheduleDebugStall(after delay: TimeInterval) {
        TOAtomicStoreDouble(stallAt, ProcessInfo.processInfo.systemUptime + delay)
    }

    /// 回调入口：AC-17 的人为阻塞不计入耗时统计
    fileprivate func callback(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let at = TOAtomicLoadDouble(stallAt)
        if at > 0, ProcessInfo.processInfo.systemUptime >= at, TOAtomicExchangeDouble(stallAt, 0) > 0 {
            log.info("debug stall in tap callback (AC-17)")
            Thread.sleep(forTimeInterval: Self.debugStallDuration)
        }
        guard measure else { return handle(type, event) }
        let start = mach_absolute_time()
        let result = handle(type, event)
        let ns = Double(mach_absolute_time() - start) * ticksToNs
        let bucket = Swift.min(Int(ns / 1e9 / Self.timingBucketWidth), Self.timingBuckets)
        TOAtomicIncrement(timing[bucket])
        TOAtomicMax(timingMaxNs, UInt64(ns))
        return result
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
                // FR-7.6：确认期丢弃并累计位移
                TOAtomicAddDouble(deltaX, Double(event.getIntegerValueField(.mouseEventDeltaX)))
                TOAtomicAddDouble(deltaY, Double(event.getIntegerValueField(.mouseEventDeltaY)))
                return nil
            case .active:
                TOAtomicIncrement(activeMoves)
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
                // 激活态的物理按压（D18：执行并保留）；按键事件一律吞掉
                if Self.buttonDownTypes.contains(type) {
                    if !sawPressure || now - stageUpAt <= Self.pressPairingWindow {
                        stageUpAt = 0
                        onPhysicalPress()
                    } else {
                        pendingDownAt = now  // 等压力事件确认；等不到就是轻点，忽略
                    }
                } else {
                    onPhysicalRelease?()
                }
                return nil
            case .cooldown where inCooldown:
                // SPEC-QUESTION: 策略表冷却列只丢弃"触控板来源"的按键，但拦截层无法可靠区分来源；目前冷却期内一律丢弃
                return nil
            case .idle, .cooldown:
                // 上报后放行：状态机据此把触摸期间按下过的单指触摸排除在轻点之外（D25，物理双击不会被当成轻点后按住）
                if type == .leftMouseDown { onPhysicalPress() }
                return pass
            }
        }
        if type == .scrollWheel {
            if mode == .active { return nil }
            // 退出后继续丢弃惯性阶段的滚动（SRS 7.2 冷却列，`P.momentumSuppressMs`）
            let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0
            return momentum && now < TOAtomicLoadDouble(momentumUntil) ? nil : pass
        }
        if type.rawValue == Self.pressureType, let e = NSEvent(cgEvent: event) {
            sawPressure = true
            if e.stage >= 1 && pressureStage == 0 {
                if mode == .active && now - pendingDownAt <= Self.pressPairingWindow {
                    pendingDownAt = 0
                    onPhysicalPress()
                } else {
                    stageUpAt = now
                }
            }
            pressureStage = e.stage
            onPressureDebug?(e.stage, e.pressure)
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
    return Unmanaged<EventTapController>.fromOpaque(refcon).takeUnretainedValue().callback(type, event)
}
