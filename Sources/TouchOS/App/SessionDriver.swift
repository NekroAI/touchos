import AppKit
import SwiftUI
import OSLog
import TouchOSCore

/// 在 input.queue 上运行 `SessionStateMachine`，按顺序执行它产生的副作用（SRS 2.3、第 3 章）。
/// 时间统一为 `ProcessInfo.systemUptime`：触点帧由输入层换算，tick 与事件拦截直接读取。
final class SessionDriver: @unchecked Sendable {
    /// SRS 5.2：非空闲状态每 16 ms 一次 tick
    static let tickInterval: DispatchTimeInterval = .milliseconds(16)
    /// FR-6.14：两次触觉反馈间隔不少于 40 ms
    static let hapticMinInterval: TimeInterval = 0.04
    let queue: DispatchQueue
    private let log = Logger(subsystem: TouchOSCore.logSubsystem, category: "session")
    private var machine: SessionStateMachine
    private let baseTuning: Tuning
    /// 用户配置快照（K8）：参数、面板、绑定；改动在下一次会话生效（FR-10.3）
    private var config = AppConfig.default
    private var environment: SessionEnvironment
    /// 调试预演（TouchSimulator）用的当前会话环境与参数快照；不在 input.queue 上调用
    var environmentSnapshot: SessionEnvironment { queue.sync { environment } }
    var tuningSnapshot: Tuning { queue.sync { machine.tuning } }
    private let tap: EventTapController
    private let cursor: CursorLock
    private let executor: ActionExecutor
    private let overlay: OverlayController
    private var timer: DispatchSourceTimer?
    private var lastHaptic: TimeInterval = 0
    private let haptics = TrackpadHaptics()
    /// 当前（或刚结束的）会话所在的设备，触觉反馈震这台设备
    private var sessionDevice: TrackpadDeviceID?
    // 延迟打点（调试叠层）：当前处理的触点帧时间戳、本次候选的锚指落下时刻
    private var frameTimestamp: TimeInterval?
    private var armStartedAt: TimeInterval?

    /// 调试信息（状态、候选失败原因、会话结束原因），在 input.queue 上调用
    var onDebug: (@Sendable (String) -> Void)?
    /// 在关闭上按住后打开编辑窗口（D23），在主线程调用
    var onOpenEditor: (@MainActor @Sendable (String) -> Void)?
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

    /// 配置变更：面板与绑定立即进入会话环境，参数在下一次有手指落下时生效
    func apply(_ config: AppConfig) {
        queue.async {
            self.config = config
            self.environment.panels = config.activePanels  // 停用的面板不参与（D37）
            self.environment.bindings = config.bindingMap
            self.handle(.environment(self.environment))
            self.applyTuning()
        }
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
            applyTuning()
            refreshEnvironment()
        }
        if case .frame(let f) = event { frameTimestamp = f.timestamp } else { frameTimestamp = nil }
        let effects = machine.handle(event)
        if case .active(let ctx) = machine.state { sessionDevice = ctx.device }
        // 面板的退场方式取决于同一批副作用里的会话结束原因（D16）
        let end = effects.lazy.compactMap { if case .sessionEnded(let e) = $0 { e } else { nil } }.first
        for effect in effects { apply(effect, end: end) }
        updateTimer()
    }

    private func apply(_ effect: SessionEffect, end: SessionEnd?) {
        switch effect {
        case .policy(let p):
            tap.publish(p)
            onDebug?("状态：\(p.mode)")
        case .cursor(let c):
            cursor.apply(c)
        case .armed:
            if case .armed(let ctx) = machine.state { armStartedAt = ctx.startedAt }
        case .showPanel(let s):
            log.info("panel shown: \(s.layout.id, privacy: .public)")
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
            let style = Self.dismissal(for: end)
            if case .commit = style { performHaptic(.strong, force: true) }
            DispatchQueue.main.async { self.overlay.dismiss(style) }
        case .flashSlot(let id):
            DispatchQueue.main.async { self.overlay.flash(id) }
        case .haptic:
            performHaptic(.light)
        case .slider(let target, let value):
            switch target {
            case .volume: SystemVolume.set(value)
            case .brightness: DisplayBrightness.set(value)
            case .demo: break
            }
        case .action(let request):
            executor.enqueue(request)
        case .openEditor(let panelID):
            DispatchQueue.main.async { self.onOpenEditor?(panelID) }
        case .armFailed(let reason):
            log.info("arm failed: \(reason.rawValue, privacy: .public)")
            onDebug?("候选失败：\(reason.rawValue)")
        case .sessionEnded(let end):
            log.info("session ended: \(String(describing: end), privacy: .public)")
            onDebug?("会话结束：\(end)")
        }
    }

    /// FR-6.14：两次间隔不少于 40 ms；提交时的确认震动（D16）不受间隔限制
    private func performHaptic(_ strength: TrackpadHaptics.Strength, force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard config.general.haptics, force || now - lastHaptic >= Self.hapticMinInterval else { return }
        lastHaptic = now
        haptics.perform(strength, on: sessionDevice)
    }

    /// 面板退场方式（D16）：提交时留下选中的槽位，用户主动取消时淡出，异常时立即隐藏
    static func dismissal(for end: SessionEnd?) -> OverlayController.Dismissal {
        switch end {
        case .committed(let id): .commit(id)
        case .anchorLifted, .escape, .cancelSlot, .idleTimeout, .thirdFinger, .handoff, .liftAfterPress, .liftOutside, .tapToggle, .edit: .fade
        default: .immediate
        }
    }

    /// AC-1：锚指落下 → 进入激活 → 面板在主线程显示，后一段在主线程上补全
    private func panelShownSample() -> (@Sendable (TimeInterval) -> LatencySample)? {
        guard onLatency != nil, let armedAt = armStartedAt, case .active(let ctx) = machine.state else { return nil }
        let entered = ctx.enteredAt
        return { now in .panelShown(anchorToActive: entered - armedAt, activeToShown: now - entered) }
    }

    /// 空闲时有新手指落下才读取一次，改动在下一次唤起生效
    /// 空闲时每次有手指落下：冻结光标所在屏幕决定面板尺寸（FR-8.5、8.6），并读取滑杆的实际值。
    /// 在进入激活之前送回状态机；轻点唤起（D19）不经过候选期，所以不能等到候选开始再刷新
    private func refreshEnvironment() {
        environment.screenSize = Self.cursorScreenSize()
        environment.sliderValues[.volume] = SystemVolume.get()
        environment.sliderValues[.brightness] = DisplayBrightness.get()
        _ = machine.handle(.environment(environment))
    }

    private func applyTuning() {
        var t = baseTuning
        config.apply(to: &t)
        // 连续触发跟随系统键盘的「重复前延迟」与「按键重复速度」（D33）
        t.repeatDelayMs = NSEvent.keyRepeatDelay * 1000
        t.repeatIntervalMs = NSEvent.keyRepeatInterval * 1000
        guard t != machine.tuning else { return }
        _ = machine.handle(.tuning(t))
        onDebug?("面板 \(t.panelScale) · 映射区 \(t.mappingScale) · 常驻 \(t.stickyPanel ? "开" : "关")")
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
    /// 面板退场方式（D16，视觉修订见 D20）
    enum Dismissal: Equatable {
        /// 立即隐藏（异常退出，NFR-7 的故障安全优先）
        case immediate
        /// 整体收拢淡出（用户主动取消）
        case fade
        /// 其余按钮淡出，选中的按钮留下并扩散一圈波纹，随后消散
        case commit(SlotID)
    }

    /// 提交后选中按钮停留的时长
    static let commitHold: TimeInterval = 0.24
    /// 其余按钮淡出、整体收拢的时长
    static let leaveDuration: TimeInterval = 0.2
    /// 选中按钮最后消散的时长
    static let dissolveDuration: TimeInterval = 0.16
    /// 先以"未弹开"渲染，等首帧完成再切到"显示"开始弹开动画：首帧要创建玻璃，实测约 50 ms，
    /// 动画若同时开始，前几帧会被吃掉，看起来一跳一跳的
    static let enterKick: TimeInterval = 0.05

    let model = OverlayModel()
    /// 外观（K8 配置），下一次显示生效
    var appearance = Appearance()
    var dim = false
    var showTrail = true
    private lazy var panel = OverlayPanel(model: model)
    /// 每次显示加一；延迟执行的动画步骤据此判断面板是否已被新的会话重新显示
    private var generation = 0

    init(slotGap: Double, trailMs: Double) {
        model.slotGap = slotGap
        model.trailDuration = trailMs / 1000
        _ = panel  // FR-8.4：启动时创建并保持隐藏
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }  // FR-8.10

    func show(_ state: PanelState) {
        generation += 1
        model.dim = dim
        model.appearance = appearance
        model.showTrail = showTrail
        model.shownAt = ProcessInfo.processInfo.systemUptime
        // 落到"未弹开"不能带动画：否则上一次留下的状态（已显示、正在收拢）会先倒放回起点，再弹开，看起来抖一下
        Self.withoutAnimation {
            model.phase = reduceMotion ? .shown : .entering
            model.apply(state)
        }
        model.groupOrigin = panel.show(groupSize: state.size)
        guard !reduceMotion else { return }
        after(Self.enterKick) { $0.model.phase = .shown }
    }

    func update(_ state: PanelState) {
        model.apply(state)
    }

    func dismiss(_ style: Dismissal) {
        guard panel.isVisible else { return hide() }
        switch style {
        case .immediate:
            hide()
        case _ where reduceMotion:
            hide()
        case .fade:
            model.phase = .collapsing
            after(Self.leaveDuration) { $0.hide() }
        case .commit(let id):
            model.pulse(id)
            model.phase = .committing(id)
            after(Self.commitHold) {
                $0.model.phase = .dissolving(id)
                $0.after(Self.dissolveDuration) { $0.hide() }
            }
        }
    }

    /// 延迟执行动画的下一步；期间面板被重新显示则放弃
    private func after(_ delay: TimeInterval, _ step: @escaping @MainActor (OverlayController) -> Void) {
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == current else { return }
            step(self)
        }
    }

    func hide() {
        panel.hide()
        Self.withoutAnimation {
            model.apply(nil)
            model.phase = .entering
        }
    }

    private static func withoutAnimation(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }

    /// 按压执行（D18）：计数、回弹与波纹
    func flash(_ id: SlotID) {
        model.press(id, animate: !reduceMotion)
    }
}
