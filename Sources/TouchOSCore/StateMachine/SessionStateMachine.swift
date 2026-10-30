import CoreGraphics
import Foundation

// 交互状态机（SRS 第 5 章）：纯函数式，`handle(event) -> [effect]`，副作用由外层按顺序执行。
// 时间统一为外层提供的单调时钟（秒）；触点帧的时间戳已由输入层换算到同一时钟。

/// 轻点后按住的确认期失败原因（D38）：第二下没有停留满 `P.tapHoldDelayMs` 就抬起、移动、按压或又落下一指
public enum ArmFailure: String, Equatable, Sendable {
    case moved, pressed, secondTouch, lifted, palm
}

/// 激活态结束原因（调试叠层与日志用）
public enum SessionEnd: Equatable, Sendable {
    case committed(SlotID)
    case escape, frameTimeout, maxDuration
    /// 在关闭或空白处抬起、短按关闭；板上没有手指超时；多指移动（手势交还系统）
    case cancelSlot, idleTimeout, handoff
    /// 按压执行过动作后在同一槽位抬起：关闭，不再执行（D18）
    case liftAfterPress
    /// 在映射区之外抬起：关闭，不执行（D21）
    case liftOutside
    /// 手指落下后很快抬起且基本没动：关闭，不执行（D53）
    case quickLift
    /// 面板开着时再做一次已启用的多指轻点唤起手势：关闭（D22）
    case tapToggle
    /// 在关闭上按住进入编辑（D23），值为当前面板 ID
    case edit(String)
    case deviceRemoved, tapDisabled, forced(String)
}

/// 唤起方式（D19、D23、D25、D38）：每种可以绑定一个面板
public enum PanelTrigger: Hashable, Sendable {
    /// 单指轻点一下，紧接着在附近再按住：停留 `P.tapHoldDelayMs` 后打开，这根手指就是指点指（D25、D38）
    case tapHold
    /// 同上，第一下落在触控板边上的某个方位分区（D38）
    case zoneTapHold(TriggerZone)
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
    /// 暂停、前台应用在黑名单、拦截或权限不可用时为 true：不接受新的唤起
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
    /// 确认期开始：记录冻结点，开始累计被丢弃的指针位移
    case arm
    /// 确认失败：光标移到"冻结点 + 累计位移"（FR-7.6）
    case compensate
    /// 进入激活：光标保持在冻结点，逐 tick 校验（FR-7.7）
    case lock
    /// 退出激活：光标精确回到冻结点（FR-7.8）
    case restore
}

public struct PanelState: Equatable, Sendable {
    /// 当前面板（导航停稳后的目标面板）
    public let layout: Layout
    /// 参考大小（pt）：面板堆栈、总览与以下坐标的基准（D29）
    public let size: CGSize
    /// 各面板在参考坐标里的位置（随网格伸缩，中心重合，D29）
    public var frames: [CGRect] = []
    /// 指示点当前对应的范围（参考坐标）：当前面板，总览时为整个参考大小。越出即"松手取消"
    public var area: CGRect = .zero
    /// 指示点（参考坐标 pt，原点左上）；没有指点指时为 nil。不钳制：映射区以外落在面板之外（D15），命中仍按钳制后的坐标
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
    /// 唤起位置（参考坐标 pt，不钳制）：轻点的中心。按钮从这里弹开（D20）
    public var origin: CGPoint?
    /// 滑杆槽位当前显示的值：指点指在滑杆上时为预览值，否则为基准值
    public var sliderValues: [SlotID: Double] = [:]
    /// 滑杆的基准值：显示调整前的位置与差值（D29）
    public var sliderBase: [SlotID: Double] = [:]
}

public struct ActionRequest: Equatable, Sendable {
    public let action: Action
    public let title: String
    /// 会话开始时的前台应用（FR-9.3）
    public let frontmostBundleID: String?
    /// 不早于该时刻执行（面板隐藏后 `P.actionDelayMs`，SRS 5.5）
    public let notBefore: TimeInterval

    public init(action: Action, title: String, frontmostBundleID: String?, notBefore: TimeInterval) {
        self.action = action
        self.title = title
        self.frontmostBundleID = frontmostBundleID
        self.notBefore = notBefore
    }
}

public enum SessionEffect: Equatable, Sendable {
    case policy(TapPolicy)
    case cursor(CursorCommand)
    /// 确认期开始：外层应在此时刷新 `screenSize`（冻结光标所在屏幕），在进入激活前送回
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
    case armFailed(ArmFailure)
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

/// 轻点后按住的确认期（D38）：第二下已落下，停留满 `P.tapHoldDelayMs` 才打开面板
public struct ArmedContext: Equatable, Sendable {
    public let device: TrackpadDeviceID
    public let trigger: PanelTrigger
    /// 第二下的接触编号与落点
    public let contactID: Int
    public let origin: CGPoint
    /// 第一下轻点的位置：面板从这里弹开
    public let entry: CGPoint
    public let startedAt: TimeInterval
    /// 第二下的最新位置，进入激活时作为指点指的起点
    public var latest: CGPoint
}

/// 面板开着时的一次多指接触（D22、D23）：判定为轻点、切换面板、捏合总览、水平移动或系统手势
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
    public let enteredAt: TimeInterval
    /// 唤起位置（触控板归一化坐标）：轻点的中心
    public var entryPoint: CGPoint?
    public let panels: [Layout]
    public var panelIndex = 0
    public var layout: Layout { panels[panelIndex] }
    /// 面板位置与总览进度（D23）
    public var nav = Motion.at(0)
    public var overview = Motion.at(0)
    public var overviewHover: Int?
    /// 各面板的大小与映射区（D29）
    public let geometry: PanelGeometry
    /// 当前面板的大小（pt）
    public var panelSize: CGSize { geometry.size(of: layout) }
    public let frontmostBundleID: String?
    public var pointer: PointerTrack?
    public var hovered: SlotID?
    public var lastFrameAt: TimeInterval
    /// 当前指点指已在所在槽位按压执行过：抬起时关闭但不再执行，移到别的槽位后恢复（D18）
    public var pressConsumed = false
    /// 在关闭上按住的开始时刻（D23）
    public var holdStartedAt: TimeInterval?
    /// 指点指刚抬起、还在宽限期内（D36）：抬起前的轨迹与抬起时刻。宽限期过后按它提交
    public var pendingLift: PendingLift?
    /// 按住按钮连续触发（D33）：哪个按钮、下一次触发的时刻。松开、移出这个按钮即停止
    public var repeatSlot: SlotID?
    public var repeatAt: TimeInterval?
    /// 各滑杆的基准值：进入激活时的实际值，接受调整后换成新值；离开滑杆时恢复为该值（D29）
    public var sliderBase: [SlotID: Double] = [:]
    public var sliderValues: [SlotID: Double] = [:]
    /// 已经送给系统的值：滑杆随手指实时生效（D29）
    public var sliderApplied: [SliderTarget: Double] = [:]
    /// 最近一次板上有手指的时刻（无触摸超时）
    public var lastTouchAt: TimeInterval = 0
    /// 板上手指上一次明显移动（超过 `P.stillThresholdMM`）、按压或连续触发的时刻；`P.maxSessionSec` 从这里算起（D42）
    public var lastActivityAt: TimeInterval = 0
    /// 判断"明显移动"的参照点：板上手指的平均位置（触控板归一化坐标）
    public var activityPoint: CGPoint?
    /// 板上出现多指，到全部抬起为止
    public var gesture: MultiGesture?
}

/// 抬起防抖（D36）
public struct PendingLift: Equatable, Sendable {
    public let pointer: PointerTrack
    public let liftAt: TimeInterval
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
    /// 轻点唤起（D19）：空闲与确认期间观察所有触点帧
    private var taps = TapDetector()
    /// 轻点后按住的第一下：设备、位置、抬起时刻、对应的唤起方式（D25、D38）
    private var pendingTapHold: (device: TrackpadDeviceID, position: CGPoint, endedAt: TimeInterval, trigger: PanelTrigger)?
    /// 最近一次物理按压的时刻：触摸期间按下过的不算轻点（触控板上的物理单击、双击）
    private var lastPressAt: TimeInterval?
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
        if case .physicalPress = event { lastPressAt = clock }
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
                pendingTapHold = nil
            }
        }
        return effects
    }

    // MARK: 轻点唤起（D19）

    private mutating func tapTrigger(_ frame: TouchFrame) -> [SessionEffect] {
        guard tuning.threeFingerTap || tuning.fourFingerTap || tuning.tapHold || !tuning.zoneTapHold.isEmpty,
              let device = environment.devices[frame.device],
              let tap = taps.feed(frame, surfaceMM: device.surfaceSizeMM, maxDuration: tuning.tapMaxMs / 1000,
                                  maxMoveMM: tuning.tapMaxMoveMM),
              state == .idle, !environment.suspended
        else { return [] }
        pendingTapHold = nil
        switch tap.fingers {
        case 3 where tuning.threeFingerTap, 4 where tuning.fourFingerTap:
            guard let index = environment.panelIndex(for: tap.fingers == 3 ? .threeFingerTap : .fourFingerTap) else { return [] }
            return enterActive(device: tap.device, entry: tap.centroid, panel: index, now: frame.timestamp)
        case 1:
            // 触摸期间有物理按压：这是一次单击，不是轻点
            if let pressed = lastPressAt, pressed >= tap.startedAt && pressed < tap.endedAt { return [] }
            // 第一下落在开启的方位分区里：按住后打开该分区的面板，否则是普通的轻点后按住（D38）
            let zone = tuning.zoneTapHold.first {
                closedContains(triggerZone($0, width: tuning.zoneW, height: tuning.zoneH), tap.centroid)
            }
            if let zone {
                pendingTapHold = (tap.device, tap.centroid, tap.endedAt, .zoneTapHold(zone))
            } else if tuning.tapHold {
                pendingTapHold = (tap.device, tap.centroid, tap.endedAt, .tapHold)
            }
            return []
        default:
            return []
        }
    }

    /// 轻点后按住（D25、D38）：第一下轻点之后 `P.doubleTapGapMs` 内、`P.tapHoldReachMM` 以内落下一根新手指，
    /// 且板上只有这一根，进入确认期；停留满 `P.tapHoldDelayMs` 打开面板，这根手指成为指点指。不满足时返回 nil
    private mutating func tapHold(_ frame: TouchFrame, _ touching: [Contact]) -> [SessionEffect]? {
        guard let first = pendingTapHold, first.device == frame.device, let device = environment.devices[frame.device] else {
            return nil
        }
        if frame.timestamp - first.endedAt > tuning.doubleTapGapMs / 1000 {
            pendingTapHold = nil
            return nil
        }
        guard let c = touching.first(where: { $0.phase == .began }) else { return nil }
        pendingTapHold = nil
        let mm = device.surfaceSizeMM
        let reach = hypot((c.position.x - first.position.x) * mm.width, (c.position.y - first.position.y) * mm.height)
        guard touching.count == 1, reach <= tuning.tapHoldReachMM, environment.panelIndex(for: first.trigger) != nil else {
            return nil
        }
        let ctx = ArmedContext(device: frame.device, trigger: first.trigger, contactID: c.id, origin: c.position,
                               entry: first.position, startedAt: frame.timestamp, latest: c.position)
        guard tuning.tapHoldDelayMs > 0 else { return enterActive(ctx, now: frame.timestamp, armed: false) }
        state = .armed(ctx)
        return [setPolicy(TapPolicy(mode: .armed, momentumUntil: policy.momentumUntil)), .cursor(.arm), .armed(frame.device)]
    }

    // MARK: 空闲

    private mutating func idle(_ event: SessionEvent) -> [SessionEffect] {
        guard case .frame(let frame) = event, !environment.suspended, !environment.panels.isEmpty,
              environment.devices[frame.device] != nil else { return [] }
        return tapHold(frame, frame.contacts.filter(\.isTouching)) ?? []
    }

    // MARK: 确认期（D38）

    private mutating func armed(_ ctx: ArmedContext, _ event: SessionEvent) -> [SessionEffect] {
        switch event {
        case .frame(let frame):
            guard frame.device == ctx.device else { return [] }
            var ctx = ctx
            if let failure = armFailure(&ctx, frame) { return abandon(failure) }
            if frame.timestamp - ctx.startedAt >= tuning.tapHoldDelayMs / 1000 { return enterActive(ctx, now: frame.timestamp) }
            state = .armed(ctx)
            return []
        case .tick(let now):
            return now - ctx.startedAt >= tuning.tapHoldDelayMs / 1000 ? enterActive(ctx, now: now) : []
        case .physicalPress:
            return abandon(.pressed)  // 按压由拦截按确认期策略放行
        case .deviceRemoved(let id) where id == ctx.device:
            return abortArmed()
        case .tapDisabled, .forceCancel:
            return abortArmed()
        default:
            return []
        }
    }

    /// 确认期的逐帧条件：第二下仍在、板上只有它、没有移动；nil 表示仍然成立
    private func armFailure(_ ctx: inout ArmedContext, _ frame: TouchFrame) -> ArmFailure? {
        guard let c = frame.contacts.first(where: { $0.id == ctx.contactID }), c.isTouching else {
            return .lifted  // 连续轻点：两下都只是轻点
        }
        if frame.contacts.contains(where: { $0.id != ctx.contactID && $0.isTouching }) { return .secondTouch }
        if c.size >= tuning.effectivePalmSize { return .palm }
        let mm = environment.devices[ctx.device]?.surfaceSizeMM ?? .zero
        let dx = (c.position.x - ctx.origin.x) * mm.width
        let dy = (c.position.y - ctx.origin.y) * mm.height
        if hypot(dx, dy) >= tuning.stillThresholdMM { return .moved }
        ctx.latest = c.position
        return nil
    }

    /// 确认失败：补位光标，恢复放行
    private mutating func abandon(_ failure: ArmFailure) -> [SessionEffect] {
        state = .idle
        return [.cursor(.compensate), setPolicy(TapPolicy(mode: .idle, momentumUntil: policy.momentumUntil)), .armFailed(failure)]
    }

    /// T19（确认期）：立即退出，光标校正，停止所有拦截
    private mutating func abortArmed() -> [SessionEffect] {
        state = .idle
        return [.cursor(.compensate), setPolicy(TapPolicy(mode: .idle))]
    }

    /// 确认期满，进入激活（5.4）：第二下成为指点指。`armed` 为 false 表示没有经过确认期，光标在此刻冻结
    private mutating func enterActive(_ ctx: ArmedContext, now: TimeInterval, armed: Bool = true) -> [SessionEffect] {
        let index = environment.panelIndex(for: ctx.trigger) ?? 0
        let effects = enterActive(device: ctx.device, entry: ctx.entry, panel: index, now: now,
                                  pointer: (ctx.contactID, ctx.latest), cursorArmed: armed)
        return effects.isEmpty && armed ? abortArmed() : effects
    }

    /// 进入激活：面板立即显示（D19）。`pointer` 为轻点后按住的第二下，直接作为指点指（D25）；
    /// `cursorArmed` 表示确认期已记录冻结点。条件不满足时返回空
    private mutating func enterActive(device id: TrackpadDeviceID, entry: CGPoint, panel: Int, now: TimeInterval,
                                      pointer: (id: Int, position: CGPoint)? = nil, cursorArmed: Bool = false) -> [SessionEffect] {
        let panels = environment.panels
        guard panels.indices.contains(panel), let device = environment.devices[id] else { return [] }
        let geometry = PanelGeometry(screen: environment.screenSize, deviceMM: device.surfaceSizeMM, tuning: tuning)
        var active = ActiveContext(device: id, enteredAt: now, panels: panels, geometry: geometry,
                                   frontmostBundleID: environment.frontmostBundleID, lastFrameAt: now)
        active.panelIndex = panel
        active.nav = .at(Double(panel))
        for page in panels {
            for slot in page.slots {
                if let target = slot.slider, let v = environment.sliderValues[target] { active.sliderBase[slot.id] = v }
            }
        }
        active.sliderValues = active.sliderBase
        active.sliderApplied = environment.sliderValues
        active.entryPoint = entry
        active.lastTouchAt = now
        active.lastActivityAt = now
        var effects: [SessionEffect] = [setPolicy(TapPolicy(mode: .active, momentumUntil: policy.momentumUntil))]
        if !cursorArmed { effects.append(.cursor(.arm)) }
        effects.append(.cursor(.lock))
        if let c = pointer {
            active.pointer = PointerTrack(id: c.id, t: now, p: c.position)
            let h = hover(active, c.position, now: now)
            active.hovered = h.slot
            active.overviewHover = h.overview
            updateSliderPreview(&active, point: mapper(active).panelPoint(c.position, panelSize: active.panelSize))
            effects += syncSliders(&active)
        }
        effects.append(.showPanel(panelState(active)))
        state = .active(active)
        return effects
    }

    // MARK: 激活

    private mutating func active(_ ctx: ActiveContext, _ event: SessionEvent) -> [SessionEffect] {
        var ctx = ctx
        switch event {
        case .frame(let frame):
            guard frame.device == ctx.device else { return [] }  // FR-4.4：只跟随唤起的设备
            ctx.lastFrameAt = frame.timestamp
            let touching = frame.contacts.filter(\.isTouching)
            if !touching.isEmpty { ctx.lastTouchAt = frame.timestamp }
            noteActivity(&ctx, touching, at: frame.timestamp)
            if let effects = multiFinger(&ctx, frame, touching) { return effects }
            return pointerFrame(&ctx, frame)
        case .tick(let now):
            if let pending = ctx.pendingLift, now - pending.liftAt >= tuning.liftGraceMs / 1000 {
                ctx.pendingLift = nil
                return commit(&ctx, pending.pointer, liftAt: pending.liftAt)  // 宽限期过了，手指没回来（D36）
            }
            if let hold = ctx.holdStartedAt, now - hold >= tuning.editHoldMs / 1000 {
                var effects = exit(ctx, now: now, end: .edit(ctx.layout.id))  // D23：按住关闭进入编辑
                effects.insert(.openEditor(ctx.layout.id), at: effects.count - 1)
                return effects
            }
            if let id = ctx.repeatSlot, let at = ctx.repeatAt {
                if ctx.hovered != id {
                    ctx.repeatSlot = nil  // 移出按钮：停止连续触发
                    ctx.repeatAt = nil
                    state = .active(ctx)
                } else if now >= at, let slot = ctx.layout.slot(id) {
                    // 落后太多（例如 tick 卡顿）不补发，从现在起按间隔继续
                    ctx.repeatAt = max(at + tuning.repeatIntervalMs / 1000, now)
                    ctx.lastActivityAt = now
                    state = .active(ctx)
                    return [.action(ActionRequest(action: slot.action, title: slot.title, frontmostBundleID: ctx.frontmostBundleID,
                                                  notBefore: now)), .flashSlot(id), .updatePanel(panelState(ctx))]
                }
            }
            if ctx.pointer == nil && ctx.gesture == nil {
                // 板上没有手指时本来就没有帧，改用无触摸超时（D14）
                if now - ctx.lastTouchAt > tuning.stickyIdleMs / 1000 { return exit(ctx, now: now, end: .idleTimeout) }
            } else if now - ctx.lastFrameAt > tuning.frameTimeoutMs / 1000 {
                return exit(ctx, now: now, end: .frameTimeout)  // T17
            }
            // T18：只兜住输入卡住的情况，手指一直在动、按压或连续触发时不关（D42，修订 T18 的"激活总时长"）
            if now - ctx.lastActivityAt > tuning.maxSessionSec { return exit(ctx, now: now, end: .maxDuration) }
            // 切换或总览过渡停稳后，手指没动也要按当前位置重新命中
            if ctx.pointer != nil && ctx.hovered == nil && ctx.overviewHover == nil && settled(ctx, at: now) {
                let effects = rehover(&ctx)
                state = .active(ctx)
                return effects
            }
            return []
        case .physicalPress:
            ctx.lastActivityAt = clock
            state = .active(ctx)  // 按压没有命中任何按钮时 press 不写回状态
            return press(&ctx)
        case .physicalRelease:
            if ctx.repeatSlot != nil {
                ctx.repeatSlot = nil
                ctx.repeatAt = nil
                state = .active(ctx)
            }
            guard ctx.holdStartedAt != nil else { return [] }
            return exit(ctx, now: clock, end: .cancelSlot)  // 未满时长松开：关闭（D23）
        case .escapeKey:
            return exit(ctx, now: ctx.lastFrameAt, end: .escape)  // T16：拦截按激活策略吞掉该按键
        case .deviceRemoved(let id) where id == ctx.device:
            return abortActive(.deviceRemoved, ctx)
        case .tapDisabled:
            return abortActive(.tapDisabled, ctx)
        case .forceCancel(let reason):
            return abortActive(.forced(reason), ctx)
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

    /// 面板开着时的多指。多指期间不选择槽位，指点指作废。
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
        return effects + [.updatePanel(panelState(ctx))]
    }

    /// 跟手：面板位置或总览进度随双指移动
    private func track(_ ctx: inout ActiveContext, _ g: inout MultiGesture, dy: Double, ds: Double, now: TimeInterval) {
        let value: Double
        switch g.kind {
        case .navigate(let base):
            // 双指上推切到下一个面板；下一个面板排在下方，上推时整摞面板跟着手指上移（自然滚动，D32）
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

    /// 当前面板的映射区（D29：随网格伸缩）；总览时为参考映射区，对应整个参考大小
    private func mapper(_ ctx: ActiveContext) -> Mapper {
        let size = showingOverview(ctx) ? CGSize(width: tuning.mappingScale, height: tuning.mappingScale)
            : ctx.geometry.mapping(of: ctx.layout)
        return Mapper(margin: tuning.mappingMargin, size: size)
    }

    /// 映射区对应的显示范围：当前面板，总览时为参考大小
    private func space(_ ctx: ActiveContext) -> CGSize { showingOverview(ctx) ? ctx.geometry.group : ctx.panelSize }

    private func tester(_ ctx: ActiveContext) -> HitTester {
        // 判定区之间留不触发的空隙，按触控板毫米换算，面板外沿同样留一圈（D31，修订 D9、D23）
        let gap = tuning.hitGapMM / 2 * ctx.geometry.pointsPerMM(of: ctx.layout)
        return HitTester(layout: ctx.layout, panelSize: ctx.panelSize, slotGap: gap, hysteresis: tuning.hysteresis, extendsEdges: false)
    }

    private func showingOverview(_ ctx: ActiveContext) -> Bool { ctx.overview.target == 1 }

    /// 指点指当前位置对应的悬停（停稳之前一律不命中）
    private func hover(_ ctx: ActiveContext, _ p: CGPoint, now: TimeInterval) -> (slot: SlotID?, overview: Int?) {
        let m = mapper(ctx)
        guard m.contains(p), settled(ctx, at: now) else { return (nil, nil) }
        let point = m.panelPoint(p, panelSize: space(ctx))
        if showingOverview(ctx) { return (nil, OverviewGrid(count: ctx.panels.count, panelSize: ctx.geometry.group).index(at: point)) }
        let id = tester(ctx).hit(point, current: ctx.hovered)
        // 读不到实际值的滑杆（如外接屏不支持调亮度）不可用：不悬停，抬起按空白处理（D41，修订 D29 的"只预览，接受后才送出"）
        if let id, ctx.layout.slot(id)?.slider != nil, ctx.sliderBase[id] == nil { return (nil, nil) }
        return (id, nil)
    }

    /// 停稳后按指点指当前位置重新命中
    private func rehover(_ ctx: inout ActiveContext) -> [SessionEffect] {
        guard let pointer = ctx.pointer else { return [] }
        let h = hover(ctx, pointer.latest, now: clock)
        guard h.slot != ctx.hovered || h.overview != ctx.overviewHover else { return [] }
        ctx.hovered = h.slot
        ctx.overviewHover = h.overview
        ctx.pressConsumed = false
        updateSliderPreview(&ctx, point: mapper(ctx).panelPoint(pointer.latest, panelSize: ctx.panelSize))
        return [.haptic] + syncSliders(&ctx) + [.updatePanel(panelState(ctx))]
    }

    /// 手指落下，或板上手指的平均位置离参照点超过 `P.stillThresholdMM`，算一次活动并把参照点移过来（D42）
    private func noteActivity(_ ctx: inout ActiveContext, _ touching: [Contact], at t: TimeInterval) {
        guard !touching.isEmpty else {
            ctx.activityPoint = nil
            return
        }
        let n = Double(touching.count)
        let p = CGPoint(x: touching.map(\.position.x).reduce(0, +) / n, y: touching.map(\.position.y).reduce(0, +) / n)
        let mm = environment.devices[ctx.device]?.surfaceSizeMM ?? .zero
        if let last = ctx.activityPoint,
           hypot((p.x - last.x) * mm.width, (p.y - last.y) * mm.height) <= tuning.stillThresholdMM { return }
        ctx.lastActivityAt = t
        ctx.activityPoint = p
    }

    private mutating func pointerFrame(_ ctx: inout ActiveContext, _ frame: TouchFrame) -> [SessionEffect] {
        let mapper = mapper(ctx)
        var effects: [SessionEffect] = []

        if let pending = ctx.pendingLift {
            guard let c = frame.contacts.first(where: { $0.phase == .began }) else {
                state = .active(ctx)
                return []
            }
            ctx.pendingLift = nil
            let mm = environment.devices[ctx.device]?.surfaceSizeMM ?? .zero
            let p = pending.pointer.latest
            guard hypot((c.position.x - p.x) * mm.width, (c.position.y - p.y) * mm.height) <= tuning.liftReturnMM else {
                // 落得远：是新的一次触摸。原来的抬起照常提交，面板还在就接着处理这一帧（新手指可以成为指点指）
                var effects = commit(&ctx, pending.pointer, liftAt: pending.liftAt)
                if case .active(var after) = state { effects += pointerFrame(&after, frame) }
                return effects
            }
            // 手指回来了：当作没抬起过，从落点接着移动，悬停与按压状态都保留
            ctx.pointer = PointerTrack(id: c.id, t: frame.timestamp, p: c.position, continuing: pending.pointer)
        } else if var pointer = ctx.pointer {
            guard let c = frame.contacts.first(where: { $0.id == pointer.id }), c.phase != .cancelled else {
                clearPointer(&ctx)  // 指点指异常消失：不提交，允许重新选择
                let reverted = syncSliders(&ctx)
                state = .active(ctx)
                return reverted + [.updatePanel(panelState(ctx))]
            }
            if c.phase == .ended {
                guard tuning.liftGraceMs > 0 else { return commit(&ctx, pointer, liftAt: frame.timestamp) }  // T11–T13
                // 抬起防抖：先等一小段时间，手指回来就接着移动（D36）
                ctx.pendingLift = PendingLift(pointer: pointer, liftAt: frame.timestamp)
                state = .active(ctx)
                return []
            }
            pointer.append(t: frame.timestamp, p: c.position)  // T9
            ctx.pointer = pointer
        } else if let c = frame.contacts.first(where: { $0.phase == .began && mapper.acceptsPointerStart($0.position) }) {
            // T8：新接触落在边缘以内（FR-6.5；映射区修订见 decisions.md D9）
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
        effects += syncSliders(&ctx)
        state = .active(ctx)
        return effects + [.updatePanel(panelState(ctx))]
    }

    private mutating func commit(_ ctx: inout ActiveContext, _ pointer: PointerTrack, liftAt: TimeInterval) -> [SessionEffect] {
        if ctx.pressConsumed {
            return exit(ctx, now: liftAt, end: .liftAfterPress)  // D18：按压已执行过，抬起只关闭
        }
        let mapper = mapper(ctx)
        let point = pointer.commitPoint(liftAt: liftAt, lookback: tuning.liftLookbackMs / 1000)
        guard mapper.contains(point) else { return exit(ctx, now: liftAt, end: .liftOutside) }  // D21
        let panelPoint = mapper.panelPoint(point, panelSize: space(ctx))
        if showingOverview(ctx) {
            if settled(ctx, at: liftAt), let index = OverviewGrid(count: ctx.panels.count, panelSize: ctx.geometry.group).index(at: panelPoint) {
                return selectPanel(&ctx, index, now: liftAt)
            }
            return stay(&ctx)
        }
        guard settled(ctx, at: liftAt) else { return stay(&ctx) }
        // 误开面板后抬手不能直接触发（D53）；滑杆同样不接受
        let mm = environment.devices[ctx.device]?.surfaceSizeMM ?? .zero
        if liftAt - pointer.startedAt < tuning.commitGuardMs / 1000,
           hypot(pointer.spanX * mm.width, pointer.spanY * mm.height) < tuning.stillThresholdMM {
            return exit(ctx, now: liftAt, end: .quickLift)
        }
        let tester = tester(ctx)
        if let id = ctx.hovered, let slot = ctx.layout.slot(id), let target = slot.slider {
            // 滑杆：在滑杆上抬起即接受，按提交坐标确定最终数值（抬起去抖同 FR-6.10）
            if let raw = tester.sliderValue(of: slot, at: panelPoint) { accept(&ctx, target, Self.quantize(raw)) }
            // 先送一次新基准：提交动效里参考线滑到生效的位置（D29）
            return [.updatePanel(panelState(ctx))] + exit(ctx, now: liftAt, end: .committed(id))
        }
        // 高亮的就是会执行的：抬起时与悬停同一套滞回规则（D31，修订 FR-6.11 的不带滞回）
        let hit = tester.hit(panelPoint, current: ctx.hovered)
        if let id = hit, ctx.layout.slot(id)?.isCancel == true {
            return exit(ctx, now: liftAt, end: .cancelSlot)  // 在关闭上抬起即关闭（D17，修订 T13）
        }
        guard let id = hit, let slot = ctx.layout.slot(id), slot.action != .none else {
            // 在空白处（按钮间隙、空格子、无动作的按钮）抬起：与取消相同，关闭不执行（D37，修订 T13 与 D17 的"空隙保留"）
            return exit(ctx, now: liftAt, end: .cancelSlot)
        }
        let request = ActionRequest(action: slot.action, title: slot.title, frontmostBundleID: ctx.frontmostBundleID,
                                    notBefore: liftAt + tuning.actionDelayMs / 1000)
        return exit(ctx, now: liftAt, end: .committed(id), action: request)  // T11
    }

    /// 抬起但不退出：清掉指点指，面板保留
    private mutating func stay(_ ctx: inout ActiveContext) -> [SessionEffect] {
        clearPointer(&ctx)
        state = .active(ctx)
        return [.updatePanel(panelState(ctx))]
    }

    /// 总览中选中一个面板：退出总览，该面板放到前面
    private mutating func selectPanel(_ ctx: inout ActiveContext, _ index: Int, now: TimeInterval) -> [SessionEffect] {
        clearPointer(&ctx)
        ctx.panelIndex = index
        ctx.nav = .at(Double(index))
        ctx.overview = Motion(from: ctx.overview.value(at: now), to: 0, start: now,
                              response: tuning.overviewResponse, damping: tuning.overviewDamping)
        state = .active(ctx)
        return [.haptic] + [.updatePanel(panelState(ctx))]
    }

    private func clearPointer(_ ctx: inout ActiveContext) {
        ctx.pointer = nil
        ctx.pendingLift = nil
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
            return [.updatePanel(panelState(ctx))]
        }
        // 物理按压本身有机械或力反馈，这里不再追加触觉
        var effects: [SessionEffect] = []
        if let target = slot.slider {
            guard let value = ctx.sliderValues[id] else { return [] }
            // 按下即接受：设定后的值成为新的基准，移出滑杆不再恢复旧值
            accept(&ctx, target, value)
            effects += syncSliders(&ctx)
        } else {
            effects.append(.action(ActionRequest(action: slot.action, title: slot.title, frontmostBundleID: ctx.frontmostBundleID,
                                                 notBefore: ctx.lastFrameAt + tuning.actionDelayMs / 1000)))
            if slot.action.repeatsWhileHeld {
                ctx.repeatSlot = id  // 按住不放：延迟后开始连续触发（D33）
                ctx.repeatAt = clock + tuning.repeatDelayMs / 1000
            }
        }
        ctx.pressConsumed = true
        state = .active(ctx)
        return effects + [.flashSlot(id), .updatePanel(panelState(ctx))]
    }

    /// 滑杆数值按 1% 取整
    static func quantize(_ v: Double) -> Double { (v * 100).rounded() / 100 }

    /// 滑杆实时生效（D29）：指点指所在滑杆的预览值立即送给系统，其余滑杆回到基准值。
    /// 不知道实际值（读取失败）的滑杆不可用，不会悬停（D41）
    private func syncSliders(_ ctx: inout ActiveContext) -> [SessionEffect] {
        var desired: [SliderTarget: Double] = [:]
        for page in ctx.panels {
            for s in page.slots { if let t = s.slider, let v = ctx.sliderBase[s.id] { desired[t] = v } }
        }
        if let id = ctx.hovered, let t = ctx.layout.slot(id)?.slider, desired[t] != nil, let v = ctx.sliderValues[id] {
            desired[t] = v
        }
        var effects: [SessionEffect] = []
        for (t, v) in desired.sorted(by: { $0.key.rawValue < $1.key.rawValue }) where ctx.sliderApplied[t] != v {
            ctx.sliderApplied[t] = v
            effects.append(.slider(t, v))
        }
        return effects
    }

    /// 接受滑杆的调整：成为同一目标所有滑杆的新基准
    private func accept(_ ctx: inout ActiveContext, _ target: SliderTarget, _ value: Double) {
        for page in ctx.panels {
            for s in page.slots where s.slider == target {
                ctx.sliderBase[s.id] = value
                ctx.sliderValues[s.id] = value
            }
        }
    }

    /// 更新滑杆预览：指点指所在滑杆显示预览值，其余滑杆显示基准值
    private func updateSliderPreview(_ ctx: inout ActiveContext, point: CGPoint) {
        var values = ctx.sliderBase
        if let id = ctx.hovered, let slot = ctx.layout.slot(id), let raw = tester(ctx).sliderValue(of: slot, at: point) {
            values[id] = Self.quantize(raw)
        }
        ctx.sliderValues = values
    }

    /// 5.5 退出激活（T11、T16–T18）：隐藏面板 → 光标回到冻结点 → 冷却策略 → 动作
    private mutating func exit(_ ctx: ActiveContext, now: TimeInterval, end: SessionEnd,
                               thirdFinger: Bool = false, action: ActionRequest? = nil) -> [SessionEffect] {
        let until = now + tuning.cooldownMs / 1000
        var reverted = ctx
        reverted.hovered = nil
        let sliders = syncSliders(&reverted)  // 没有接受的调整恢复为基准值（D29）
        state = .cooldown(until: until)
        var effects: [SessionEffect] = [
            .hidePanel, .cursor(.restore),
            setPolicy(TapPolicy(mode: .cooldown, cooldownUntil: until,
                                momentumUntil: now + tuning.momentumSuppressMs / 1000, passGestures: thirdFinger)),
        ]
        effects += sliders
        if let action { effects.append(.action(action)) }
        effects.append(.sessionEnded(end))
        return effects
    }

    /// T19（激活）：立即退出，光标校正，停止所有拦截
    private mutating func abortActive(_ end: SessionEnd, _ ctx: ActiveContext) -> [SessionEffect] {
        var reverted = ctx
        reverted.hovered = nil
        let sliders = syncSliders(&reverted)
        state = .idle
        return [.hidePanel, .cursor(.restore), setPolicy(TapPolicy(mode: .idle))] + sliders + [.sessionEnded(end)]
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
        // 坐标统一换成参考坐标（各面板中心重合，D29）
        let mapper = mapper(ctx)
        let area = showingOverview(ctx) ? CGRect(origin: .zero, size: ctx.geometry.group) : ctx.geometry.frame(of: ctx.layout)
        func shown(_ p: CGPoint) -> CGPoint {
            let q = mapper.unclampedPanelPoint(p, panelSize: area.size)
            return CGPoint(x: q.x + area.minX, y: q.y + area.minY)
        }
        var s = PanelState(layout: ctx.layout, size: ctx.geometry.group, pointer: ctx.pointer.map { shown($0.latest) },
                           overscan: mapper.overscan(panelSize: area.size), hovered: ctx.hovered)
        s.frames = ctx.panels.map(ctx.geometry.frame(of:))
        s.area = area
        s.panels = ctx.panels
        s.panelIndex = ctx.panelIndex
        s.nav = ctx.nav
        s.overview = ctx.overview
        s.overviewHover = ctx.overviewHover
        s.holdStartedAt = ctx.holdStartedAt
        s.holdDuration = tuning.editHoldMs / 1000
        s.origin = ctx.entryPoint.map(shown)
        s.sliderValues = ctx.sliderValues
        s.sliderBase = ctx.sliderBase
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
