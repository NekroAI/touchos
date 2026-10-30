import AppKit
import CoreGraphics
import Foundation
import TouchOSAtomics
import TouchOSCore

/// 光标冻结与校正（SRS 7.4）。除 `mode` 外只在 input.queue 上使用。
/// 丢弃指针移动只能冻结系统记录的位置，有的 Mac 上屏幕光标仍会跟手（D47），所以默认在激活态隐藏光标（D52）。
/// "断开鼠标与光标关联"接口只在应用位于前台时有效，后台调用返回成功却不起作用，不使用（D52）。
final class CursorLock: @unchecked Sendable {
    /// FR-7.7：偏离冻结点超过该距离（pt）时移回
    static let tolerance: CGFloat = 0.5
    /// 看门狗的检查间隔
    private static let watchdogInterval: DispatchTimeInterval = .milliseconds(250)

    private let tap: EventTapController
    private let stallLimit: TimeInterval
    /// input.queue 卡住时在看门狗队列上调用（光标已恢复），用来放开拦截并结束会话。启动前设置一次
    var onStall: (@Sendable () -> Void)?
    /// 保护 `currentMode`、`applied` 与 `watchdog`：撤销可能来自 input.queue，也可能来自看门狗
    private let freezeLock = NSLock()
    private var currentMode = CursorFreeze.hide
    /// 这次会话实际施加的方式，退出时撤销
    private var applied: CursorFreeze?
    private var watchdog: DispatchSourceTimer?
    // 诊断日志：冻结时的计数，退出时算出这次会话的增量
    private var sessionMovesAtLock: UInt64 = 0
    private var sessionCorrectionsAtLock: UInt64 = 0
    private let watchdogQueue = DispatchQueue(label: "ai.nekro.touchos.cursor-watchdog", qos: .userInteractive)
    /// input.queue 最后一次校验的时刻
    private let heartbeat = TOAtomicCreate()!
    /// 冻结点（Quartz 全局坐标，原点为主屏左上角）
    private var freezePoint: CGPoint?

    /// 调试叠层的指针诊断。偏离量以 0.01 pt 为单位记录
    struct Diagnostics {
        var checks: UInt64
        var corrections: UInt64
        var maxEventDeviation: Double
        var maxScreenDeviation: Double
    }
    private let checks = TOAtomicCreate()!
    private let corrections = TOAtomicCreate()!
    private let maxEventDeviation = TOAtomicCreate()!
    private let maxScreenDeviation = TOAtomicCreate()!

    init(tap: EventTapController, stallLimit: TimeInterval) {
        self.tap = tap
        self.stallLimit = stallLimit
    }

    /// 通用设置「面板打开时的光标」，下一次会话生效
    var mode: CursorFreeze {
        get { freezeLock.withLock { currentMode } }
        set { freezeLock.withLock { currentMode = newValue } }
    }

    func apply(_ command: CursorCommand) {
        switch command {
        case .arm:
            freezePoint = Self.location
            _ = tap.takeCursorDelta()
        case .compensate:
            // FR-7.6：光标移到"冻结点 + 累计位移"（钳制在屏幕内），看起来只是晚一点开始移动
            let d = tap.takeCursorDelta()
            if let p = freezePoint, d != .zero {
                Self.warp(Self.clampToDisplays(CGPoint(x: p.x + d.dx, y: p.y + d.dy), fallback: p))
            }
            freezePoint = nil
        case .lock:
            _ = tap.takeCursorDelta()
            applyFreeze()
        case .restore:
            // FR-7.8：精确回到冻结点，之后才切换策略（由效果顺序保证）
            if let p = freezePoint { Self.warp(p) }
            freezePoint = nil
            releaseFreeze()
        }
    }

    private func applyFreeze() {
        freezeLock.lock()
        defer { freezeLock.unlock() }
        guard applied == nil else { return }
        var freeze = currentMode
        var result = "-"
        if freeze == .hide {
            Self.allowHidingInBackground()
            let error = CGDisplayHideCursor(CGMainDisplayID())
            result = "\(error.rawValue)"
            if error != .success { freeze = .keep }  // 隐藏失败：退回只靠拦截，恢复时也不用显示
        }
        applied = freeze
        startWatchdog()
        sessionMovesAtLock = tap.droppedActiveMoves
        sessionCorrectionsAtLock = TOAtomicLoad(corrections)
        DiagnosticLog.shared.record("光标冻结：设置 \(currentMode.rawValue) 实际 \(freeze.rawValue) 返回 \(result) · \(Self.systemState)")  // l10n-ignore
    }

    /// 撤销这次会话施加的方式，可重复调用。所有退出路径（含退出应用时的取消）都经过 `.restore`，
    /// input.queue 卡住时由看门狗调用
    private func releaseFreeze() {
        freezeLock.lock()
        defer { freezeLock.unlock() }
        if let applied {
            DiagnosticLog.shared.record("光标恢复：\(applied.rawValue) · 本次丢弃指针事件 \(self.tap.droppedActiveMoves &- self.sessionMovesAtLock) · 校正 \(TOAtomicLoad(self.corrections) &- self.sessionCorrectionsAtLock) · \(Self.systemState)")  // l10n-ignore
        }
        if applied == .hide { CGDisplayShowCursor(CGMainDisplayID()) }
        applied = nil
        watchdog?.cancel()
        watchdog = nil
    }

    /// NFR-7：进程还活着时系统不会替我们恢复，所以 input.queue 超过 `stallLimit` 没有校验就直接恢复。
    /// 调用方持有 `freezeLock`
    private func startWatchdog() {
        TOAtomicStoreDouble(heartbeat, ProcessInfo.processInfo.systemUptime)
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + Self.watchdogInterval, repeating: Self.watchdogInterval)
        timer.setEventHandler { [weak self] in
            guard let self, ProcessInfo.processInfo.systemUptime - TOAtomicLoadDouble(self.heartbeat) > self.stallLimit else { return }
            DiagnosticLog.shared.record("看门狗：输入队列无响应，恢复光标")  // l10n-ignore
            self.releaseFreeze()
            self.onStall?()
        }
        timer.resume()
        watchdog = timer
    }

    /// 诊断日志用：前台应用、TouchOS 是否在前台、系统报告的光标状态
    private static var systemState: String {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        return "前台 \(front) · TouchOS 在前台 \(NSRunningApplication.current.isActive) · 光标可见 \(cursorFlag("CGCursorIsVisible")) · 软件光标 \(cursorFlag("CGCursorIsDrawnInFramebuffer"))"  // l10n-ignore
    }

    /// 这两个函数在 SDK 中已标为不可用，运行时查找；取不到时显示问号（只用于诊断日志）
    private static func cursorFlag(_ name: String) -> String {
        typealias Flag = @convention(c) () -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return "?" }
        return "\(unsafeBitCast(symbol, to: Flag.self)())"
    }

    /// 后台应用默认不能隐藏光标，要先设置连接属性 `SetsCursorInBackground`。
    /// 符号来自 CoreGraphics 的未公开接口，运行时查找；取不到时不设置，隐藏可能不生效，退回只靠拦截的效果（屏幕光标可能跟手）
    private static func allowHidingInBackground() {
        typealias Connection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        let handle = UnsafeMutableRawPointer(bitPattern: -2)
        guard let main = dlsym(handle, "CGSMainConnectionID"), let set = dlsym(handle, "CGSSetConnectionProperty") else { return }
        let connection = unsafeBitCast(main, to: Connection.self)()
        _ = unsafeBitCast(set, to: SetProperty.self)(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }

    /// FR-7.7：激活态每个 tick 校验一次
    func verify() {
        TOAtomicStoreDouble(heartbeat, ProcessInfo.processInfo.systemUptime)
        guard let p = freezePoint else { return }
        // 两个来源都看：只读事件位置时，有的构建上光标在动它却不变（0.1.0 发布版，D47）
        let event = Self.location, screen = Self.screenLocation
        let eventOff = hypot(event.x - p.x, event.y - p.y), screenOff = hypot(screen.x - p.x, screen.y - p.y)
        TOAtomicIncrement(checks)
        TOAtomicMax(maxEventDeviation, UInt64(eventOff * 100))
        TOAtomicMax(maxScreenDeviation, UInt64(screenOff * 100))
        if max(eventOff, screenOff) > Self.tolerance {
            TOAtomicIncrement(corrections)
            Self.warp(p)
        }
    }

    var diagnostics: Diagnostics {
        Diagnostics(checks: TOAtomicLoad(checks), corrections: TOAtomicLoad(corrections),
                    maxEventDeviation: Double(TOAtomicLoad(maxEventDeviation)) / 100,
                    maxScreenDeviation: Double(TOAtomicLoad(maxScreenDeviation)) / 100)
    }

    func resetDiagnostics() {
        for a in [checks, corrections, maxEventDeviation, maxScreenDeviation] { TOAtomicStore(a, 0) }
    }

    private static var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    /// 屏幕坐标系的光标位置，换算到 Quartz 全局坐标（主屏高度减 y）
    private static var screenLocation: CGPoint {
        let p = NSEvent.mouseLocation
        return CGPoint(x: p.x, y: CGDisplayBounds(CGMainDisplayID()).height - p.y)
    }

    private static func warp(_ p: CGPoint) {
        // 把本地事件抑制间隔设为 0，避免移动光标后约 0.25 秒的输入冻结（FR-7.7）
        CGEventSource(stateID: .combinedSessionState)?.localEventsSuppressionInterval = 0
        CGWarpMouseCursorPosition(p)
    }

    private static func clampToDisplays(_ p: CGPoint, fallback: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        var display: CGDirectDisplayID = 0
        if CGGetDisplaysWithPoint(p, 1, &display, &count) == .success, count > 0 { return p }
        guard CGGetDisplaysWithPoint(fallback, 1, &display, &count) == .success, count > 0 else { return fallback }
        let b = CGDisplayBounds(display)
        return CGPoint(x: min(max(p.x, b.minX), b.maxX - 1), y: min(max(p.y, b.minY), b.maxY - 1))
    }
}
