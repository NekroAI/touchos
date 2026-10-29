import CoreGraphics
import Foundation

// 交互状态机（SRS 第 5 章）：纯函数式，`handle(event) -> [effect]`，副作用由外层按顺序执行。
// 时间统一为外层提供的单调时钟（秒）；触点帧的时间戳已由输入层换算到同一时钟。

/// 候选判定失败原因（FR-6.2）
public enum AnchorFailure: String, Equatable, Sendable {
    case moved, pressed, secondTouch, lifted, palm
}

/// 激活态结束原因（调试叠层与日志用）
public enum SessionEnd: Equatable, Sendable {
    case committed(SlotID)
    case anchorLifted, thirdFinger, escape, frameTimeout, maxDuration
    /// 常驻模式：在关闭上抬起或短按、无触摸超时、多指移动（手势交还系统）
    case cancelSlot, idleTimeout, handoff
    /// 按压执行过动作后在同一槽位抬起：关闭，不再执行（D18）
    case liftAfterPress
    /// 在映射区之外抬起：关闭，不执行（D21）
    case liftOutside
    /// 面板开着时再做一次已启用的多指轻点唤起手势：关闭（D22）
    case tapToggle
    /// 在关闭上按住进入编辑（D23），值为当前面板 ID
    case edit(String)
    case deviceRemoved, tapDisabled, forced(String)
}

/// 唤起方式（D19、D23）：每种可以绑定一个面板
public enum PanelTrigger: Hashable, Sendable {
    case hold(AnchorCorner)
    case cornerDoubleTap(AnchorCorner)
    case threeFingerTap
    case fourFingerTap
}

/// 外层随时维护的会话环境；进入激活态时取快照（SRS 5.4）。
public struct SessionEnvironment: Equatable, Sendable {
    /// 启用中的设备（FR-4.4、FR-4.6）
    public var devices: [TrackpadDeviceID: TrackpadDevice] = [:]
    /// 全部面板，按用户排列的顺序；第一个为默认面板（D23）。双指上下移动按这个顺序切换
    public var panels: [Layout] = []
    /// 唤起方式绑定的面板 ID；未绑定或 ID 不存在时打开默认面板
    public var bindings: [PanelTrigger: String] = [:]
    /// 滑杆槽位的当前值，进入激活时取快照用于显示
    public var sliderValues: [SliderTarget: Double] = [:]
    public var frontmostBundleID: String?
    /// 暂停、前台应用在黑名单、拦截或权限不可用时为 true：不接受新的锚定
    public var suspended = false
    /// 冻结光标所在屏幕的可见区域尺寸（pt），用于计算面板尺寸（FR-8.5、8.6）
    public var screenSize = CGSize(width: 1440, height: 900)

    public init() {}

    /// 唤起方式对应的面板序号；没有面板时为 nil
    public func panelIndex(for trigger: PanelTrigger) -> Int? {
        guard !panels.isEmpty else { return nil }
        guard let id = bindings[trigger] else { return 0 }
        return panels.firstIndex { $0.id == id } ?? 0
    }

    /// 可以按住唤起的角：默认锚定角与单独绑定了面板的角
    func holdCorners(default corner: AnchorCorner) -> [AnchorCorner] {
        AnchorCorner.allCases.filter { $0 == corner || bindings[.hold($0)] != nil }
    }

    func doubleTapCorners(default corner: AnchorCorner) -> [AnchorCorner] {
        AnchorCorner.allCases.filter { $0 == corner || bindings[.cornerDoubleTap($0)] != nil }
    }
}

/// 事件拦截策略的快照（SRS 7.2），由拦截回调无锁读取。
public struct TapPolicy: Equatable, Sendable {
    public enum Mode: UInt8, Sendable { case idle, armed, active, cooldown }

    public var mode: Mode
    /// 冷却截止时刻；冷却期内按冷却列处理
    public var cooldownUntil: TimeInterval = 0
    /// 此前一律丢弃带惯性阶段的滚动（`P.momentumSuppressMs`），在冷却结束后仍可能有效
    public var momentumUntil: TimeInterval = 0
    /// 因第三指取消进入的冷却：手势类事件放行（FR-7.5）
    public var passGestures = false

    public init(mode: Mode, cooldownUntil: TimeInterval = 0, momentumUntil: TimeInterval = 0, passGestures: Bool = false) {
        self.mode = mode
        self.cooldownUntil = cooldownUntil
        self.momentumUntil = momentumUntil
        self.passGestures = passGestures
    }
}

/// 光标控制命令（SRS 7.4），由 CursorLock 执行
public enum CursorCommand: Equatable, Sendable {
    /// 候选开始：记录冻结点，开始累计被丢弃的指针位移
    case arm
    /// 候选失败：光标移到"冻结点 + 累计位移"（FR-7.6）
    case compensate
    /// 进入激活：光标保持在冻结点，逐 tick 校验（FR-7.7）
    case lock
    /// 退出激活：光标精确回到冻结点（FR-7.8）
    case restore
}

public struct PanelState: Equatable, Sendable {
    /// 当前面板（导航停稳后的目标面板）
    public let layout: Layout
    public let size: CGSize
    /// 指示点（面板 pt，原点左上）；没有指点指时为 nil。不钳制：映射区以外落在面板之外（D15），命中仍按钳制后的坐标
    public var pointer: CGPoint?
    /// 整块触控板对应的显示范围相对面板每边多出的宽度（pt），浮层窗口据此留出指示点越界的空间
    public var overscan: CGSize = .zero
    public var hovered: SlotID?
    /// 全部面板与当前序号（D23）
    public var panels: [Layout] = []
    public var panelIndex = 0
    /// 面板位置（0 为第一个面板，可为小数）与总览进度（0 为单个面板，1 为总览），按同一时钟求值
    public var nav = Motion.at(0)
    public var overview = Motion.at(0)
    /// 总览中指向的面板
    public var overviewHover: Int?
    /// 在关闭上按住的开始时刻与进入编辑所需时长（圆环充满动画）
    public var holdStartedAt: TimeInterval?
    public var holdDuration: TimeInterval = 0
    /// 常驻模式下锚指已抬起
    public var sticky = false
    /// 唤起位置（面板 pt，不钳制）：轻点的中心或锚指落点。按钮从这里弹开（D20）
    public var origin: CGPoint?
    /// 滑杆槽位当前显示的值：指点指在滑杆上时为预览值，否则为进入激活时的实际值
    public var sliderValues: [SlotID: Double] = [:]
}

public struct ActionRequest: Equatable, Sendable {
    public let action: Action
    public let title: String
    /// 会话开始时的前台应用（FR-9.3）
    public let frontmostBundleID: String?
    /// 不早于该时刻执行（面板隐藏后 `P.actionDelayMs`，SRS 5.5）
    public let notBefore: TimeInterval
}

public enum SessionEffect: Equatable, Sendable {
    case policy(TapPolicy)
    case cursor(CursorCommand)
    /// 候选开始：外层应在此时刷新 `screenSize`（冻结光标所在屏幕），在进入激活前送回
    case armed(TrackpadDeviceID)
    case showPanel(PanelState)
    case updatePanel(PanelState)
    case hidePanel
    /// 按压执行后槽位回弹一次（D18）
    case flashSlot(SlotID)
    /// 滑杆确定的值，外层据此设置音量等；移动过程只预览，不产生该副作用
    case slider(SliderTarget, Double)
    /// 槽位或面板变化时的触觉反馈（FR-6.14、6.15）
    case haptic
    case action(ActionRequest)
    /// 打开编辑窗口并定位到该面板（D23），在会话结束、光标恢复之后执行
    case openEditor(String)
    case armFailed(AnchorFailure)
    case sessionEnded(SessionEnd)
}

public enum SessionEvent: Equatable, Sendable {
    case frame(TouchFrame)
    case physicalPress
    /// 物理按压松开（用于在关闭上按住进入编辑，D23）
    case physicalRelease
    case escapeKey
    case tick(TimeInterval)
    case deviceRemoved(TrackpadDeviceID)
    case tapDisabled
    case forceCancel(String)
    case environment(SessionEnvironment)
    /// 可调参数变更；会话进行中收到时延到回到空闲后生效
    case tuning(Tuning)
}

public struct ArmedContext: Equatable, Sendable {
    public let device: TrackpadDeviceID
    public let corner: AnchorCorner
    public let anchorID: Int
    public let anchorOrigin: CGPoint
    public let startedAt: TimeInterval
}

/// 常驻状态下的一次多指接触（D22、D23）：判定为轻点、切换面板、捏合总览、水平移动或系统手势
public struct MultiGesture: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case undecided
        /// 双指上下：`base` 为判定时的面板位置
        case navigate(base: Double)
        /// 双指捏合：`base` 为判定时的总览进度
        case pinch(base: Double)
        /// 双指水平移动或已结算：不再处理，等全部抬起
        case ignored
    }

    struct Sample: Equatable, Sendable {
        let t: TimeInterval
        let value: Double
    }

    public let startedAt: TimeInterval
    public var kind = Kind.undecided
    /// 最多同时几指
    public var fingers = 0
    /// 有手指移动超过轻点限度
    public var moved = false
    var origins: [Int: CGPoint] = [:]
    /// 双指的编号与起始重心、间距（毫米）
    var pair: [Int] = []
    var startCentroid = CGPoint.zero
    var startSpread = 0.0
    /// 最近的位置样本，松手时估算速度
    var samples: [Sample] = []

    init(startedAt: TimeInterval) {
        self.startedAt = startedAt
    }
}

public struct ActiveContext: Equatable, Sendable {
    public let device: TrackpadDeviceID
    public let anchorID: Int
    public let enteredAt: TimeInterval
    public let corner: AnchorCorner
    /// 唤起位置（触控板归一化坐标）：轻点的中心或锚指落点
    public var entryPoint: CGPoint?
    public let panels: [Layout]
    public var panelIndex = 0
    public var layout: Layout { panels[panelIndex] }
    /// 面板位置与总览进度（D23）
    public var nav = Motion.at(0)
    public var overview = Motion.at(0)
    public var overviewHover: Int?
    public let panelSize: CGSize
    public let frontmostBundleID: String?
    public var pointer: PointerTrack?
    public var hovered: SlotID?
    public var panelVisible = false
    public var lastFrameAt: TimeInterval
    /// 当前指点指已在所在槽位按压执行过：抬起时关闭但不再执行，移到别的槽位后恢复（D18）
    public var pressConsumed = false
    /// 在关闭上按住的开始时刻（D23）
    public var holdStartedAt: TimeInterval?
    /// 进入激活时各滑杆的实际值；离开滑杆时预览恢复为该值
    public var sliderBase: [SlotID: Double] = [:]
    public var sliderValues: [SlotID: Double] = [:]
    /// 常驻模式：锚指已抬起，面板保留，单指操作
    public var anchorLifted = false
    /// 最近一次板上有手指的时刻（常驻模式的无触摸超时）
    public var lastTouchAt: TimeInterval = 0
    /// 常驻模式下板上出现多指，到全部抬起为止
    public var gesture: MultiGesture?
}

public enum SessionState: Equatable, Sendable {
    case idle
    case armed(ArmedContext)
    case active(ActiveContext)
    case cooldown(until: TimeInterval)
}

public struct SessionStateMachine: Sendable {
    public private(set) var tuning: Tuning
    /// 会话进行中收到的参数变更，回到空闲时生效（FR-10.3：配置变更只影响下一次会话）
    private var pendingTuning: Tuning?
    public private(set) var environment: SessionEnvironment
    public private(set) var state: SessionState = .idle
    /// 最近一次发布的拦截策略（冷却结束后仍保留惯性滚动截止时刻）
    public private(set) var policy = TapPolicy(mode: .idle)
    /// 轻点唤起（D19）：空闲与候选期间观察所有触点帧
    private var taps = TapDetector()
    /// 角落双击的第一下：设备、角落、抬起时刻
    private var pendingCornerTap: (device: TrackpadDeviceID, corner: AnchorCorner, endedAt: TimeInterval)?
    /// 最近一次帧或 tick 的时刻：按压等不带时间的事件用它
    private var clock: TimeInterval = 0

    public init(tuning: Tuning, environment: SessionEnvironment = SessionEnvironment()) {
        self.tuning = tuning
        self.environment = environment
    }

    /// 非空闲状态需要每 16 ms 一次 `tick`（SRS 5.2）
    public var needsTicks: Bool { state != .idle }

    public mutating func handle(_ event: SessionEvent) -> [SessionEffect] {
        if case .environment(let env) = event {
            environment = env
            return []
        }
        if case .tuning(let t) = event {
            if state == .idle { tuning = t } else { pendingTuning = t }
            return []
        }
        if state == .idle, let t = pendingTuning {
            tuning = t
            pendingTuning = nil
        }
        if case .frame(let f) = event { clock = max(clock, f.timestamp) }
        if case .tick(let t) = event { clock = max(clock, t) }
        let observing = state == .idle || { if case .armed = state { true } else { false } }()
        var effects: [SessionEffect]
        switch state {
        case .idle: effects = idle(event)
        case .armed(let ctx): effects = armed(ctx, event)
        case .active(let ctx): effects = active(ctx, event)
        case .cooldown(let until): effects = cooldown(until, event)
        }
        if case .frame(let frame) = event {
            if observing {
                effects += tapTrigger(frame)
            } else {
                taps.reset()
                pendingCornerTap = nil
            }
        }
        return effects
    }

    // MARK: 轻点唤起（D19）

    private mutating func tapTrigger(_ frame: TouchFrame) -> [SessionEffect] {
        guard tuning.threeFingerTap || tuning.fourFingerTap || tuning.cornerDoubleTap,
              let device = environment.devices[frame.device],
              let tap = taps.feed(frame, surfaceMM: device.surfaceSizeMM, maxDuration: tuning.tapMaxMs / 1000,
                                  maxMoveMM: tuning.tapMaxMoveMM),
              state == .idle, !environment.suspended
        else { return [] }
        switch tap.fingers {
        case 3 where tuning.threeFingerTap, 4 where tuning.fourFingerTap:
            pendingCornerTap = nil
            guard let index = environment.panelIndex(for: tap.fingers == 3 ? .threeFingerTap : .fourFingerTap) else { return [] }
            return enterActive(device: tap.device, corner: tuning.anchorCorner, anchorID: nil, entry: tap.centroid, panel: index,
                               now: frame.timestamp)
        case 1 where tuning.cornerDoubleTap:
            guard let corner = environment.doubleTapCorners(default: tuning.anchorCorner).first(where: {
                closedContains(anchorZone($0, width: tuning.anchorZoneW, height: tuning.anchorZoneH), tap.centroid)
            }) else {
                pendingCornerTap = nil
                return []
            }
            if let first = pendingCornerTap, first.device == tap.device, first.corner == corner,
               tap.startedAt - first.endedAt <= tuning.doubleTapGapMs / 1000 {
                pendingCornerTap = nil
                guard let index = environment.panelIndex(for: .cornerDoubleTap(corner)) else { return [] }
                return enterActive(device: tap.device, corner: corner, anchorID: nil, entry: tap.centroid, panel: index,
                                   now: frame.timestamp)
            }
            pendingCornerTap = (tap.device, corner, tap.endedAt)
            return []
        default:
            pendingCornerTap = nil
            return []
        }
    }

    // MARK: 空闲

    private mutating func idle(_ event: SessionEvent) -> [SessionEffect] {
        // T1
        guard case .frame(let frame) = event, tuning.holdTrigger, !environment.suspended, !environment.panels.isEmpty,
              environment.devices[frame.device] != nil else { return [] }
        let touching = frame.contacts.filter(\.isTouching)
        guard touching.count == 1, let c = touching.first, c.phase == .began,
              let corner = environment.holdCorners(default: tuning.anchorCorner).first(where: {
                  closedContains(anchorZone($0, width: tuning.anchorZoneW, height: tuning.anchorZoneH), c.position)
              })
        else { return [] }
        state = .armed(ArmedContext(device: frame.device, corner: corner, anchorID: c.id, anchorOrigin: c.position,
                                    startedAt: frame.timestamp))
        return [setPolicy(TapPolicy(mode: .armed, momentumUntil: policy.momentumUntil)), .cursor(.arm), .armed(frame.device)]
    }

    // MARK: 候选

    private mutating func armed(_ ctx: ArmedContext, _ event: SessionEvent) -> [SessionEffect] {
        switch event {
        case .frame(let frame):
            guard frame.device == ctx.device else { return [] }
            if let failure = anchorFailure(ctx, frame) { return abandon(failure) }
            return frame.timestamp - ctx.startedAt >= tuning.dwellMs / 1000 ? enterActive(ctx, now: frame.timestamp) : []
        case .tick(let now):
            return now - ctx.startedAt >= tuning.dwellMs / 1000 ? enterActive(ctx, now: now) : []
        case .physicalPress:
            return abandon(.pressed)  // T4：按压由拦截按候选策略放行
        case .deviceRemoved(let id) where id == ctx.device:
            return abortArmed()
        case .tapDisabled, .forceCancel:
            return abortArmed()
        default:
            return []
        }
    }

    /// FR-6.1 的逐帧条件；nil 表示仍然成立
    private func anchorFailure(_ ctx: ArmedContext, _ frame: TouchFrame) -> AnchorFailure? {
        guard let anchor = frame.contacts.first(where: { $0.id == ctx.anchorID }), anchor.isTouching else {
            return .lifted  // T6
        }
        if frame.contacts.contains(where: { $0.id != ctx.anchorID && $0.isTouching }) { return .secondTouch }  // T5
        if anchor.size >= tuning.effectivePalmSize { return .palm }  // T7
        let mm = environment.devices[ctx.device]?.surfaceSizeMM ?? .zero
        let dx = (anchor.position.x - ctx.anchorOrigin.x) * mm.width
        let dy = (anchor.position.y - ctx.anchorOrigin.y) * mm.height
        if hypot(dx, dy) >= tuning.stillThresholdMM { return .moved }  // T3
        return nil
    }

    /// T3–T7：补位光标，恢复放行
    private mutating func abandon(_ failure: AnchorFailure) -> [SessionEffect] {
        state = .idle
        return [.cursor(.compensate), setPolicy(TapPolicy(mode: .idle, momentumUntil: policy.momentumUntil)), .armFailed(failure)]
    }

    /// T19（候选）：立即退出，光标校正，停止所有拦截
    private mutating func abortArmed() -> [SessionEffect] {
        state = .idle
        return [.cursor(.compensate), setPolicy(TapPolicy(mode: .idle))]
    }

    /// T2 与 5.4 进入激活
    private mutating func enterActive(_ ctx: ArmedContext, now: TimeInterval) -> [SessionEffect] {
        let index = environment.panelIndex(for: .hold(ctx.corner)) ?? 0
        let effects = enterActive(device: ctx.device, corner: ctx.corner, anchorID: ctx.anchorID, entry: ctx.anchorOrigin,
                                  panel: index, now: now)
        return effects.isEmpty ? abortArmed() : effects
    }

    /// 进入激活。`anchorID` 为 nil 表示轻点唤起（D19）：没有锚指，直接进入常驻状态，面板立即显示，
    /// 光标在此刻冻结（不经过候选期）。条件不满足时返回空
    private mutating func enterActive(device id: TrackpadDeviceID, corner: AnchorCorner, anchorID: Int?, entry: CGPoint,
                                      panel: Int, now: TimeInterval) -> [SessionEffect] {
        let panels = environment.panels
        guard panels.indices.contains(panel), let device = environment.devices[id] else { return [] }
        let size = panelSize(screen: environment.screenSize, deviceMM: device.surfaceSizeMM, scale: tuning.panelScale)
        var active = ActiveContext(device: id, anchorID: anchorID ?? -1, enteredAt: now, corner: corner, panels: panels,
                                   panelSize: size, frontmostBundleID: environment.frontmostBundleID, lastFrameAt: now)
        active.panelIndex = panel
        active.nav = .at(Double(panel))
        for page in panels {
            for slot in page.slots {
                if let target = slot.slider, let v = environment.sliderValues[target] { active.sliderBase[slot.id] = v }
            }
        }
        active.sliderValues = active.sliderBase
        active.entryPoint = entry
        var effects: [SessionEffect] = [setPolicy(TapPolicy(mode: .active, momentumUntil: policy.momentumUntil))]
        if anchorID == nil {
            active.anchorLifted = true
            active.lastTouchAt = now
            effects.append(.cursor(.arm))
        }
        effects.append(.cursor(.lock))
        if tuning.panelDelayMs <= 0 || anchorID == nil {
            active.panelVisible = true
            effects.append(.showPanel(panelState(active)))
        }
        state = .active(active)
        return effects
    }

    // MARK: 激活

    private mutating func active(_ ctx: ActiveContext, _ event: SessionEvent) -> [SessionEffect] {
        var ctx = ctx
        switch event {
        case .frame(let frame):
            guard frame.device == ctx.device else { return [] }  // FR-4.4：锚指与指点指须在同一设备
            ctx.lastFrameAt = frame.timestamp
            let touching = frame.contacts.filter(\.isTouching)
            if touching.count >= 3 && !ctx.anchorLifted {
                return exit(ctx, now: frame.timestamp, end: .thirdFinger, thirdFinger: true)  // T15
            }
            let anchorDown = !ctx.anchorLifted && touching.contains { $0.id == ctx.anchorID }
            if !anchorDown && !ctx.anchorLifted {
                guard tuning.stickyPanel else { return exit(ctx, now: frame.timestamp, end: .anchorLifted) }  // T14
                ctx.anchorLifted = true  // 常驻模式：面板保留（D14）
                ctx.lastTouchAt = frame.timestamp
            }
            if ctx.anchorLifted {
                if !touching.isEmpty { ctx.lastTouchAt = frame.timestamp }
                if let effects = multiFinger(&ctx, frame, touching) { return effects }
            }
            return pointerFrame(&ctx, frame)
        case .tick(let now):
            if let hold = ctx.holdStartedAt, now - hold >= tuning.editHoldMs / 1000 {
                var effects = exit(ctx, now: now, end: .edit(ctx.layout.id))  // D23：按住关闭进入编辑
                effects.insert(.openEditor(ctx.layout.id), at: effects.count - 1)
                return effects
            }
            if ctx.anchorLifted && ctx.pointer == nil && ctx.gesture == nil {
                // 常驻模式下板上没有手指时本来就没有帧，改用无触摸超时（D14）
                if now - ctx.lastTouchAt > tuning.stickyIdleMs / 1000 { return exit(ctx, now: now, end: .idleTimeout) }
            } else if now - ctx.lastFrameAt > tuning.frameTimeoutMs / 1000 {
                return exit(ctx, now: now, end: .frameTimeout)  // T17
            }
            if now - ctx.enteredAt > tuning.maxSessionSec { return exit(ctx, now: now, end: .maxDuration) }  // T18
            if !ctx.panelVisible && now - ctx.enteredAt >= tuning.panelDelayMs / 1000 {  // T10
                ctx.panelVisible = true
                state = .active(ctx)
                return [.showPanel(panelState(ctx))]
            }
            // 切换或总览过渡停稳后，手指没动也要按当前位置重新命中
            if ctx.pointer != nil && ctx.hovered == nil && ctx.overviewHover == nil && settled(ctx, at: now) {
                let effects = rehover(&ctx)
                state = .active(ctx)
                return effects
            }
            return []
        case .physicalPress:
            return press(&ctx)
        case .physicalRelease:
            guard ctx.holdStartedAt != nil else { return [] }
            return exit(ctx, now: clock, end: .cancelSlot)  // 未满时长松开：关闭（D23）
        case .escapeKey:
            return exit(ctx, now: ctx.lastFrameAt, end: .escape)  // T16：拦截按激活策略吞掉该按键
        case .deviceRemoved(let id) where id == ctx.device:
            return abortActive(.deviceRemoved)
        case .tapDisabled:
            return abortActive(.tapDisabled)
        case .forceCancel(let reason):
            return abortActive(.forced(reason))
        default:
            return []
        }
    }

    /// 面板切换与总览都已停稳，可以命中槽位
    private func settled(_ ctx: ActiveContext, at t: TimeInterval) -> Bool {
        ctx.gesture == nil && ctx.nav.isSettled(at: t) && ctx.overview.isSettled(at: t)
    }

    private func navRange(_ ctx: ActiveContext) -> ClosedRange<Double> {
        0...Double(max(ctx.panels.count - 1, 0))
    }

    // MARK: 多指（D22、D23）

    /// 常驻模式下的多指。多指期间不选择槽位，指点指作废。
    /// - 双指上下移动：切换面板，跟手；双指捏合：总览；双指水平移动：不处理。
    /// - 三指以上移动或停留超过 `P.tapMaxMs`：系统手势，关闭并交还。
    /// - 全部抬起时若是已启用的轻点唤起手势（三指 / 四指）：关闭面板。
    /// 返回 nil 表示没有多指，照常处理指点指
    private mutating func multiFinger(_ ctx: inout ActiveContext, _ frame: TouchFrame, _ touching: [Contact]) -> [SessionEffect]? {
        let now = frame.timestamp
        if ctx.gesture == nil {
            guard touching.count >= 2 else { return nil }
            ctx.gesture = MultiGesture(startedAt: now)
            clearPointer(&ctx)
        }
        guard var g = ctx.gesture else { return nil }
        let mm = environment.devices[ctx.device]?.surfaceSizeMM ?? .zero
        func millimeters(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * mm.width, y: p.y * mm.height) }
        for c in touching {
            let origin = g.origins[c.id] ?? c.position
            g.origins[c.id] = origin
            let d = millimeters(CGPoint(x: c.position.x - origin.x, y: c.position.y - origin.y))
            if hypot(d.x, d.y) > tuning.tapMaxMoveMM { g.moved = true }
        }
        g.fingers = max(g.fingers, touching.count)
        var effects: [SessionEffect] = []

        if g.fingers >= 3 {
            if g.moved || now - g.startedAt > tuning.tapMaxMs / 1000 {
                return exit(ctx, now: now, end: .handoff, thirdFinger: true)
            }
        } else if touching.count == 2 {
            let pair = touching.map(\.id).sorted()
            let a = millimeters(touching[0].position), b = millimeters(touching[1].position)
            let centroid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), spread = hypot(a.x - b.x, a.y - b.y)
            if pair != g.pair {
                g.pair = pair
                g.startCentroid = centroid
                g.startSpread = spread
            }
            let dx = centroid.x - g.startCentroid.x, dy = centroid.y - g.startCentroid.y, ds = spread - g.startSpread
            let multiple = ctx.panels.count > 1
            if case .undecided = g.kind {
                let classify = tuning.navClassifyMM
                if abs(ds) >= classify && abs(ds) > hypot(dx, dy) {
                    g.kind = multiple ? .pinch(base: ctx.overview.value(at: now)) : .ignored
                } else if abs(dy) >= classify && abs(dy) >= abs(dx) {
                    g.kind = multiple && ctx.overview.target == 0 ? .navigate(base: ctx.nav.value(at: now)) : .ignored
                } else if abs(dx) >= classify {
                    g.kind = .ignored
                }
            }
            track(&ctx, &g, dy: dy, ds: ds, now: now)
        } else {
            effects += releaseGesture(&ctx, &g, now: now)
        }

        if touching.isEmpty {
            ctx.gesture = nil
            let tapped = !g.moved && now - g.startedAt <= tuning.tapMaxMs / 1000
                && (g.fingers == 3 && tuning.threeFingerTap || g.fingers == 4 && tuning.fourFingerTap)
            if tapped, case .undecided = g.kind { return exit(ctx, now: now, end: .tapToggle) }  // D22
        } else {
            ctx.gesture = g
        }
        state = .active(ctx)
        return effects + (ctx.panelVisible ? [.updatePanel(panelState(ctx))] : [])
    }

    /// 跟手：面板位置或总览进度随双指移动
    private func track(_ ctx: inout ActiveContext, _ g: inout MultiGesture, dy: Double, ds: Double, now: TimeInterval) {
        let value: Double
        switch g.kind {
        case .navigate(let base):
            value = rubberBand(base + dy / tuning.navDistanceMM, in: navRange(ctx))
            ctx.nav = .at(value)
        case .pinch(let base):
            value = rubberBand(base - ds / tuning.pinchDistanceMM, in: 0...1)
            ctx.overview = .at(value)
        default:
            return
        }
        g.samples.append(.init(t: now, value: value))
        g.samples.removeAll { now - $0.t > Self.velocityWindow }
    }

    /// 松手速度按最近这段时间的位置变化估算
    static let velocityWindow: TimeInterval = 0.1

    /// 双指离开：按速度推算落点，弹簧过渡到那里
    private func releaseGesture(_ ctx: inout ActiveContext, _ g: inout MultiGesture, now: TimeInterval) -> [SessionEffect] {
        var velocity = 0.0
        if let first = g.samples.first, let last = g.samples.last, last.t - first.t > 0.005 {
            velocity = (last.value - first.value) / (last.t - first.t)
        }
        var effects: [SessionEffect] = []
        switch g.kind {
        case .navigate(let base):
            let current = ctx.nav.value(at: now), range = navRange(ctx)
            let start = base.rounded()
            var target = (current + velocity * tuning.navProjection).rounded()
            target = min(max(target, start - 1, range.lowerBound), start + 1, range.upperBound)
            ctx.nav = Motion(from: current, velocity: range.contains(current) ? velocity : 0, to: target, start: now,
                             response: tuning.navResponse, damping: tuning.navDamping)
            if Int(target) != ctx.panelIndex {
                ctx.panelIndex = Int(target)
                effects.append(.haptic)
            }
        case .pinch:
            let current = ctx.overview.value(at: now)
            let target: Double = current + velocity * tuning.navProjection > 0.5 ? 1 : 0
            ctx.overview = Motion(from: current, velocity: velocity, to: target, start: now,
                                  response: tuning.overviewResponse, damping: tuning.overviewDamping)
            ctx.overviewHover = nil
        default:
            return []
        }
        g.kind = .ignored
        return effects
    }

    // MARK: 指点指

    private func mapper() -> Mapper { Mapper(margin: tuning.mappingMargin, scale: tuning.mappingScale) }

    /// 命中不留空隙：网格单元之间的缝只是视觉（D23）
    private func tester(_ ctx: ActiveContext) -> HitTester {
        HitTester(layout: ctx.layout, panelSize: ctx.panelSize, slotGap: 0, hysteresis: tuning.hysteresis)
    }

    private func showingOverview(_ ctx: ActiveContext) -> Bool { ctx.overview.target == 1 }

    /// 指点指当前位置对应的悬停（停稳之前一律不命中）
    private func hover(_ ctx: ActiveContext, _ p: CGPoint, now: TimeInterval) -> (slot: SlotID?, overview: Int?) {
        let m = mapper()
        guard m.contains(p), settled(ctx, at: now) else { return (nil, nil) }
        let point = m.panelPoint(p, panelSize: ctx.panelSize)
        if showingOverview(ctx) { return (nil, OverviewGrid(count: ctx.panels.count, panelSize: ctx.panelSize).index(at: point)) }
        return (tester(ctx).hit(point, current: ctx.hovered), nil)
    }

    /// 停稳后按指点指当前位置重新命中
    private func rehover(_ ctx: inout ActiveContext) -> [SessionEffect] {
        guard let pointer = ctx.pointer else { return [] }
        let h = hover(ctx, pointer.latest, now: clock)
        guard h.slot != ctx.hovered || h.overview != ctx.overviewHover else { return [] }
        ctx.hovered = h.slot
        ctx.overviewHover = h.overview
        ctx.pressConsumed = false
        updateSliderPreview(&ctx, point: mapper().panelPoint(pointer.latest, panelSize: ctx.panelSize))
        return [.haptic] + (ctx.panelVisible ? [.updatePanel(panelState(ctx))] : [])
    }

    private mutating func pointerFrame(_ ctx: inout ActiveContext, _ frame: TouchFrame) -> [SessionEffect] {
        let mapper = mapper()
        var effects: [SessionEffect] = []

        if var pointer = ctx.pointer {
            guard let c = frame.contacts.first(where: { $0.id == pointer.id }), c.phase != .cancelled else {
                clearPointer(&ctx)  // 指点指异常消失：不提交，允许重新选择
                state = .active(ctx)
                return ctx.panelVisible ? [.updatePanel(panelState(ctx))] : []
            }
            if c.phase == .ended {
                return commit(&ctx, pointer, liftAt: frame.timestamp)  // T11–T13
            }
            pointer.append(t: frame.timestamp, p: c.position)  // T9
            ctx.pointer = pointer
        } else if let c = frame.contacts.first(where: { candidate in
            (candidate.id != ctx.anchorID || ctx.anchorLifted) && candidate.phase == .began
                && mapper.acceptsPointerStart(candidate.position)
                && (ctx.anchorLifted || !closedContains(anchorZone(ctx.corner, width: tuning.anchorZoneW, height: tuning.anchorZoneH), candidate.position))
        }) {
            // T8：新接触落在边缘以内且不在锚定区（FR-6.5；映射区修订见 decisions.md D9）
            ctx.pointer = PointerTrack(id: c.id, t: frame.timestamp, p: c.position)
        } else {
            state = .active(ctx)
            return []
        }
        // 映射区之外不悬停任何槽位（D21）
        guard let latest = ctx.pointer?.latest else { return [] }
        let h = hover(ctx, latest, now: frame.timestamp)
        if h.slot != ctx.hovered || h.overview != ctx.overviewHover {
            ctx.hovered = h.slot
            ctx.overviewHover = h.overview
            ctx.pressConsumed = false
            ctx.holdStartedAt = nil
            effects.append(.haptic)
        }
        updateSliderPreview(&ctx, point: mapper.panelPoint(latest, panelSize: ctx.panelSize))
        state = .active(ctx)
        if ctx.panelVisible { effects.append(.updatePanel(panelState(ctx))) }
        return effects
    }

    private mutating func commit(_ ctx: inout ActiveContext, _ pointer: PointerTrack, liftAt: TimeInterval) -> [SessionEffect] {
        if ctx.pressConsumed {
            return exit(ctx, now: liftAt, end: .liftAfterPress)  // D18：按压已执行过，抬起只关闭
        }
        let mapper = mapper()
        let point = pointer.commitPoint(liftAt: liftAt, lookback: tuning.liftLookbackMs / 1000)
        guard mapper.contains(point) else { return exit(ctx, now: liftAt, end: .liftOutside) }  // D21
        let panelPoint = mapper.panelPoint(point, panelSize: ctx.panelSize)
        if showingOverview(ctx) {
            if settled(ctx, at: liftAt), let index = OverviewGrid(count: ctx.panels.count, panelSize: ctx.panelSize).index(at: panelPoint) {
                return selectPanel(&ctx, index, now: liftAt)
            }
            return stay(&ctx)
        }
        guard settled(ctx, at: liftAt) else { return stay(&ctx) }
        let tester = tester(ctx)
        if let id = ctx.hovered, let slot = ctx.layout.slot(id), let target = slot.slider {
            // 滑杆：移动时只预览，抬起才按提交坐标确定数值（抬起去抖同 FR-6.10）
            var effects = exit(ctx, now: liftAt, end: .committed(id))
            if let raw = tester.sliderValue(of: slot, at: panelPoint) {
                effects.insert(.slider(target, Self.quantize(raw)), at: effects.count - 1)
            }
            return effects
        }
        // FR-6.11：按提交坐标做一次不带滞回的命中
        let hit = tester.hit(panelPoint)
        if let id = hit, ctx.layout.slot(id)?.isCancel == true {
            return exit(ctx, now: liftAt, end: .cancelSlot)  // 在关闭上抬起即关闭（D17，修订 T13）
        }
        guard let id = hit, let slot = ctx.layout.slot(id), slot.action != .none else {
            return stay(&ctx)  // T13：空隙，不退出
        }
        let request = ActionRequest(action: slot.action, title: slot.title, frontmostBundleID: ctx.frontmostBundleID,
                                    notBefore: liftAt + tuning.actionDelayMs / 1000)
        return exit(ctx, now: liftAt, end: .committed(id), action: request)  // T11
    }

    /// 抬起但不退出：清掉指点指，面板保留
    private mutating func stay(_ ctx: inout ActiveContext) -> [SessionEffect] {
        clearPointer(&ctx)
        state = .active(ctx)
        return ctx.panelVisible ? [.updatePanel(panelState(ctx))] : []
    }

    /// 总览中选中一个面板：退出总览，该面板放到前面
    private mutating func selectPanel(_ ctx: inout ActiveContext, _ index: Int, now: TimeInterval) -> [SessionEffect] {
        clearPointer(&ctx)
        ctx.panelIndex = index
        ctx.nav = .at(Double(index))
        ctx.overview = Motion(from: ctx.overview.value(at: now), to: 0, start: now,
                              response: tuning.overviewResponse, damping: tuning.overviewDamping)
        state = .active(ctx)
        return [.haptic] + (ctx.panelVisible ? [.updatePanel(panelState(ctx))] : [])
    }

    private func clearPointer(_ ctx: inout ActiveContext) {
        ctx.pointer = nil
        ctx.hovered = nil
        ctx.overviewHover = nil
        ctx.pressConsumed = false
        ctx.holdStartedAt = nil
        ctx.sliderValues = ctx.sliderBase
    }

    /// 激活态的物理按压（D18、D23）：指点指所在槽位执行一次，面板保留，可以连按；滑杆按当前预览值设定。
    /// 之后在同一槽位抬起只关闭不再执行。在关闭上按下开始计时，按住满 `P.editHoldMs` 进入编辑；
    /// 总览中按压选中面板；空隙上按压不做任何事
    private mutating func press(_ ctx: inout ActiveContext) -> [SessionEffect] {
        if showingOverview(ctx) {
            guard let index = ctx.overviewHover else { return [] }
            return selectPanel(&ctx, index, now: clock)
        }
        guard ctx.pointer != nil, let id = ctx.hovered, let slot = ctx.layout.slot(id) else { return [] }
        if slot.isCancel {
            ctx.holdStartedAt = clock
            state = .active(ctx)
            return ctx.panelVisible ? [.updatePanel(panelState(ctx))] : []
        }
        // 物理按压本身有机械或力反馈，这里不再追加触觉
        var effects: [SessionEffect] = []
        if let target = slot.slider {
            guard let value = ctx.sliderValues[id] else { return [] }
            effects.append(.slider(target, value))
            // 设定后的值成为新的基准：移出滑杆不再恢复旧值
            for page in ctx.panels {
                for s in page.slots where s.slider == target { ctx.sliderBase[s.id] = value }
            }
        } else {
            effects.append(.action(ActionRequest(action: slot.action, title: slot.title, frontmostBundleID: ctx.frontmostBundleID,
                                                 notBefore: ctx.lastFrameAt + tuning.actionDelayMs / 1000)))
        }
        ctx.pressConsumed = true
        state = .active(ctx)
        if ctx.panelVisible { effects += [.flashSlot(id), .updatePanel(panelState(ctx))] }
        return effects
    }

    /// 滑杆数值按 1% 取整
    static func quantize(_ v: Double) -> Double { (v * 100).rounded() / 100 }

    /// 更新滑杆预览：指点指所在滑杆显示预览值，其余滑杆恢复实际值。只改显示，不产生副作用
    private func updateSliderPreview(_ ctx: inout ActiveContext, point: CGPoint) {
        var values = ctx.sliderBase
        if let id = ctx.hovered, let slot = ctx.layout.slot(id), let raw = tester(ctx).sliderValue(of: slot, at: point) {
            values[id] = Self.quantize(raw)
        }
        ctx.sliderValues = values
    }

    /// 5.5 退出激活（T11、T14–T18）：隐藏面板 → 光标回到冻结点 → 冷却策略 → 动作
    private mutating func exit(_ ctx: ActiveContext, now: TimeInterval, end: SessionEnd,
                               thirdFinger: Bool = false, action: ActionRequest? = nil) -> [SessionEffect] {
        let until = now + tuning.cooldownMs / 1000
        state = .cooldown(until: until)
        var effects: [SessionEffect] = [
            .hidePanel, .cursor(.restore),
            setPolicy(TapPolicy(mode: .cooldown, cooldownUntil: until,
                                momentumUntil: now + tuning.momentumSuppressMs / 1000, passGestures: thirdFinger)),
        ]
        if let action { effects.append(.action(action)) }
        effects.append(.sessionEnded(end))
        return effects
    }

    /// T19（激活）：立即退出，光标校正，停止所有拦截
    private mutating func abortActive(_ end: SessionEnd) -> [SessionEffect] {
        state = .idle
        return [.hidePanel, .cursor(.restore), setPolicy(TapPolicy(mode: .idle)), .sessionEnded(end)]
    }

    // MARK: 冷却

    private mutating func cooldown(_ until: TimeInterval, _ event: SessionEvent) -> [SessionEffect] {
        // T20；T21：冷却期内的新接触一律忽略
        guard case .tick(let now) = event, now >= until else { return [] }
        state = .idle
        return [setPolicy(TapPolicy(mode: .idle, momentumUntil: policy.momentumUntil))]
    }

    // MARK: 工具

    private mutating func setPolicy(_ p: TapPolicy) -> SessionEffect {
        policy = p
        return .policy(p)
    }

    private func panelState(_ ctx: ActiveContext) -> PanelState {
        let mapper = mapper()
        var s = PanelState(layout: ctx.layout, size: ctx.panelSize,
                           pointer: ctx.pointer.map { mapper.unclampedPanelPoint($0.latest, panelSize: ctx.panelSize) },
                           overscan: mapper.overscan(panelSize: ctx.panelSize), hovered: ctx.hovered)
        s.panels = ctx.panels
        s.panelIndex = ctx.panelIndex
        s.nav = ctx.nav
        s.overview = ctx.overview
        s.overviewHover = ctx.overviewHover
        s.holdStartedAt = ctx.holdStartedAt
        s.holdDuration = tuning.editHoldMs / 1000
        s.sticky = ctx.anchorLifted
        s.origin = ctx.entryPoint.map { mapper.unclampedPanelPoint($0, panelSize: ctx.panelSize) }
        s.sliderValues = ctx.sliderValues
        return s
    }
}

extension Slot {
    /// 关闭（安全区）：抬起不执行任何动作，按住进入编辑（D23）
    public var isCancel: Bool { action == .none && slider == nil && widget == nil }
}

extension Contact {
    /// 仍在板上（ended / cancelled 表示这一帧已离开）
    public var isTouching: Bool { phase != .ended && phase != .cancelled }
}
