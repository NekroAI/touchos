import AppKit
import OSLog
import TouchOSCore

/// 在 input.queue 上运行 `SessionStateMachine`，按顺序执行它产生的副作用（SRS 2.3、第 3 章）。
/// 时间统一为 `ProcessInfo.systemUptime`：触点帧由输入层换算，tick 与事件拦截直接读取。
final class SessionDriver: @unchecked Sendable {
    /// SRS 5.2：非空闲状态每 16 ms 一次 tick
    static let tickInterval: DispatchTimeInterval = .milliseconds(16)
    /// FR-6.14：两次触觉反馈间隔不少于 40 ms
    static let hapticMinInterval: TimeInterval = 0.04
    /// 临时调节开关（K12 设置界面之前）：`defaults write ai.nekro.touchos mappingScale -float 0.5`
    static let mappingScaleKey = "mappingScale"

    let queue: DispatchQueue
    private let log = Logger(subsystem: TouchOSCore.logSubsystem, category: "session")
    private var machine: SessionStateMachine
    private let baseTuning: Tuning
    private var environment: SessionEnvironment
    private let tap: EventTapController
    private let cursor: CursorLock
    private let executor: ActionExecutor
    private let overlay: OverlayController
    private var timer: DispatchSourceTimer?
    private var lastHaptic: TimeInterval = 0
    // 延迟打点（调试叠层）：当前处理的触点帧时间戳、本次候选的锚指落下时刻
    private var frameTimestamp: TimeInterval?
    private var armStartedAt: TimeInterval?

    /// 调试信息（状态、候选失败原因、会话结束原因），在 input.queue 上调用
    var onDebug: (@Sendable (String) -> Void)?
    /// 延迟样本，在主线程、浮层更新之后调用；为 nil 时不打点
    var onLatency: (@MainActor @Sendable (LatencySample) -> Void)?

    init(queue: DispatchQueue, tuning: Tuning, tap: EventTapController, cursor: CursorLock,
         executor: ActionExecutor, overlay: OverlayController) {
        self.queue = queue
        self.tap = tap
        self.cursor = cursor
        self.executor = executor
        self.overlay = overlay
        environment = SessionEnvironment()
        baseTuning = tuning
        machine = SessionStateMachine(tuning: tuning, environment: environment)
    }

    /// 在任意线程调用，异步投递到 input.queue
    func send(_ event: SessionEvent) {
        queue.async { self.handle(event) }
    }

    /// 修改会话环境（设备、布局、前台应用、暂停状态），只影响下一次会话（SRS 5.4）
    func updateEnvironment(_ change: @escaping @Sendable (inout SessionEnvironment) -> Void) {
        queue.async {
            change(&self.environment)
            self.handle(.environment(self.environment))
        }
    }

    /// 同步取消会话（应用退出时用，保证光标与拦截先恢复）
    func cancelNow(_ reason: String) {
        queue.sync { self.handle(.forceCancel(reason)) }
    }

    /// 只在 input.queue 上调用
    func handle(_ event: SessionEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        if case .frame(let f) = event, machine.state == .idle, f.contacts.contains(where: { $0.phase == .began }) {
            applyOverrides()
        }
        if case .frame(let f) = event { frameTimestamp = f.timestamp } else { frameTimestamp = nil }
        for effect in machine.handle(event) { apply(effect) }
        updateTimer()
    }

    private func apply(_ effect: SessionEffect) {
        switch effect {
        case .policy(let p):
            tap.publish(p)
            onDebug?("状态：\(p.mode)")
        case .cursor(let c):
            cursor.apply(c)
        case .armed:
            // 冻结光标所在屏幕决定面板尺寸（FR-8.5、8.6）；在进入激活前送回状态机
            environment.screenSize = Self.cursorScreenSize()
            _ = machine.handle(.environment(environment))
            if case .armed(let ctx) = machine.state { armStartedAt = ctx.startedAt }
        case .showPanel(let s):
            let sample = panelShownSample()
            DispatchQueue.main.async {
                self.overlay.show(s)
                if let sample { self.onLatency?(sample(ProcessInfo.processInfo.systemUptime)) }
            }
        case .updatePanel(let s):
            let frameAt = onLatency == nil ? nil : frameTimestamp
            DispatchQueue.main.async {
                self.overlay.update(s)
                if let frameAt { self.onLatency?(.pointer(ProcessInfo.processInfo.systemUptime - frameAt)) }
            }
        case .hidePanel:
            DispatchQueue.main.async { self.overlay.hide() }
        case .flashSlot(let id):
            DispatchQueue.main.async { self.overlay.flash(id) }
        case .haptic:
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastHaptic >= Self.hapticMinInterval {
                lastHaptic = now
                DispatchQueue.main.async {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
            }
        case .action(let request):
            executor.enqueue(request)
        case .armFailed(let reason):
            log.info("arm failed: \(reason.rawValue, privacy: .public)")
            onDebug?("候选失败：\(reason.rawValue)")
        case .sessionEnded(let end):
            log.info("session ended: \(String(describing: end), privacy: .public)")
            onDebug?("会话结束：\(end)")
        }
    }

    /// AC-1：锚指落下 → 进入激活 → 面板在主线程显示，后一段在主线程上补全
    private func panelShownSample() -> (@Sendable (TimeInterval) -> LatencySample)? {
        guard onLatency != nil, let armedAt = armStartedAt, case .active(let ctx) = machine.state else { return nil }
        let entered = ctx.enteredAt
        return { now in .panelShown(anchorToActive: entered - armedAt, activeToShown: now - entered) }
    }

    /// 空闲时有新手指落下才读取一次，改动在下一次唤起生效
    private func applyOverrides() {
        var t = baseTuning
        let scale = UserDefaults.standard.double(forKey: Self.mappingScaleKey)
        if scale > 0 {
            t.mappingScale = min(max(scale, Tuning.mappingScaleRange.lowerBound), Tuning.mappingScaleRange.upperBound)
        }
        guard t != machine.tuning else { return }
        _ = machine.handle(.tuning(t))
        onDebug?("映射区 \(t.mappingScale)")
    }

    private func updateTimer() {
        if machine.needsTicks, timer == nil {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        } else if !machine.needsTicks, let t = timer {
            t.cancel()
            timer = nil
        }
    }

    private func tick() {
        if case .active = machine.state { cursor.verify() }  // FR-7.7
        handle(.tick(ProcessInfo.processInfo.systemUptime))
    }

    /// 光标所在屏幕的可见区域尺寸。NSScreen 的属性在后台线程只读访问是安全的。
    private static func cursorScreenSize() -> CGSize {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.screens.first
        return screen?.visibleFrame.size ?? SessionEnvironment().screenSize
    }
}

/// 调试叠层显示的延迟样本（NFR-1、AC-1）。只到主线程应用浮层状态为止，不含 SwiftUI 渲染、窗口合成与屏幕扫描。
enum LatencySample: Sendable {
    /// 触点帧时间戳 → 主线程更新指示点
    case pointer(TimeInterval)
    case panelShown(anchorToActive: TimeInterval, activeToShown: TimeInterval)
}

/// 主线程上的浮层控制
@MainActor
final class OverlayController {
    /// 连续触发提交时槽位闪烁的时长（SRS 8.3）
    static let flashDuration: TimeInterval = 0.15

    let model = OverlayModel()
    private lazy var panel = OverlayPanel(model: model)

    init(slotGap: Double) {
        model.slotGap = slotGap
        _ = panel  // FR-8.4：启动时创建并保持隐藏
    }

    func show(_ state: PanelState) {
        model.state = state
        panel.show(size: state.size)
    }

    func update(_ state: PanelState) {
        model.state = state
    }

    func hide() {
        panel.hide()
        model.state = nil
        model.flashing = nil
    }

    func flash(_ id: SlotID) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }  // FR-8.10
        model.flashing = id
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flashDuration) { [weak self] in
            if self?.model.flashing == id { self?.model.flashing = nil }
        }
    }
}
