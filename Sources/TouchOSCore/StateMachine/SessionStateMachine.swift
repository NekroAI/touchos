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
    /// 轻点后按住唤起、未满 `P.tapHoldMinMs` 就抬起：关闭，不执行（D25）
    case earlyLift
    /// 面板开着时再做一次已启用的多指轻点唤起手势：关闭（D22）
    case tapToggle
    /// 在关闭上按住进入编辑（D23），值为当前面板 ID
    case edit(String)
    case deviceRemoved, tapDisabled, forced(String)
}

/// 唤起方式（D19、D23、D25）：每种可以绑定一个面板
public enum PanelTrigger: Hashable, Sendable {
    /// 单指轻点一下，紧接着在附近再按住：第二次落下即打开，这根手指就是指点指（D25）
    case tapHold
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
    /// 常驻模式下锚指已抬起
    public var sticky = false
    /// 唤起位置（参考坐标 pt，不钳制）：轻点的中心或锚指落点。按钮从这里弹开（D20）
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
    /// 各面板的大小与映射区（D29）
    public let geometry: PanelGeometry
    /// 当前面板的大小（pt）
    public var panelSize: CGSize { geometry.size(of: layout) }
    public let frontmostBundleID: String?
    public var pointer: PointerTrack?
    public var hovered: SlotID?
    public var panelVisible = false
    public var lastFrameAt: TimeInterval
    /// 当前指点指已在所在槽位按压执行过：抬起时关闭但不再执行，移到别的槽位后恢复（D18）
    public var pressConsumed = false
    /// 在关闭上按住的开始时刻（D23）
    public var holdStartedAt: TimeInterval?
    /// 按住按钮连续触发（D33）：哪个按钮、下一次触发的时刻。松开、移出这个按钮即停止
    public var repeatSlot: SlotID?
    public var repeatAt: TimeInterval?
    /// 各滑杆的基准值：进入激活时的实际值，接受调整后换成新值；离开滑杆时恢复为该值（D29）
    public var sliderBase: [SlotID: Double] = [:]
    public var sliderValues: [SlotID: Double] = [:]
    /// 已经送给系统的值：滑杆随手指实时生效（D29）
    public var sliderApplied: [SliderTarget: Double] = [:]
    /// 常驻模式：锚指已抬起，面板保留，单指操作
    public var anchorLifted = false
    /// 轻点后按住唤起时，早于该时刻抬起只关闭（D25，`P.tapHoldMinMs`）
    public var releaseAfter: TimeInterval?
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
    /// 轻点后按住的第一下：设备、位置、抬起时刻（D25）
    private var pendingTapHold: (device: TrackpadDeviceID, position: CGPoint, endedAt: TimeInterval)?
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
                pendingCornerTap = nil
                pendingTapHold = nil
            }
        }
        return effects
    }

    // MARK: 轻点唤起（D19）

    private mutating func tapTrigger(_ frame: TouchFrame) -> [SessionEffect] {
        guard tuning.threeFingerTap || tuning.fourFingerTap || tuning.tapHold || !tuning.doubleTapCorners.isEmpty,
              let device = environment.devices[frame.device],
              let tap = taps.feed(frame, surfaceMM: device.surfaceSizeMM, maxDuration: tuning.tapMaxMs / 1000,
                                  maxMoveMM: tuning.tapMaxMoveMM),
              state == .idle, !environment.suspended
        else { return [] }
        switch tap.fingers {
        case 3 where tuning.threeFingerTap, 4 where tuning.fourFingerTap:
            pendingCornerTap = nil
            pendingTapHold = nil
            guard let index = environment.panelIndex(for: tap.fingers == 3 ? .threeFingerTap : .fourFingerTap) else { return [] }
            return enterActive(device: tap.device, corner: Self.tapCorner, anchorID: nil, entry: tap.centroid, panel: index,
                               now: frame.timestamp)
        case 1:
            pendingTapHold = nil
            // 触摸期间有物理按压：这是一次单击，不是轻点
            if let pressed = lastPressAt, pressed >= tap.startedAt && pressed < tap.endedAt {
                pendingCornerTap = nil
                return []
            }
            // 第一下落在启用了"轻点两下"的角落：让给角落轻点两下（D26）
            if let corner = tuning.doubleTapCorners.first(where: {
                closedContains(anchorZone($0, width: tuning.anchorZoneW, height: tuning.anchorZoneH), tap.centroid)
            }) {
                if let first = pendingCornerTap, first.device == tap.device, first.corner == corner,
                   tap.startedAt - first.endedAt <= tuning.doubleTapGapMs / 1000 {
                    pendingCornerTap = nil
                    guard let index = environment.panelIndex(for: .cornerDoubleTap(corner)) else { return [] }
                    return enterActive(device: tap.device, corner: corner, anchorID: nil, entry: tap.centroid, panel: index,
                                       now: frame.timestamp)
                }
                pendingCornerTap = (tap.device, corner, tap.endedAt)
                return []
            }
            pendingCornerTap = nil
            if tuning.tapHold { pendingTapHold = (tap.device, tap.centroid, tap.endedAt) }
            return []
        default:
            pendingCornerTap = nil
            pendingTapHold = nil
            return []
        }
    }

    /// 轻点后按住（D25）：第一下轻点之后 `P.doubleTapGapMs` 内、`P.tapHoldReachMM` 以内落下一根新手指，
    /// 落下即打开面板，这根手指成为指点指。不满足时返回 nil
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
        guard touching.count == 1, reach <= tuning.tapHoldReachMM, let index = environment.panelIndex(for: .tapHold) else {
            return nil
        }
        return enterActive(device: frame.device, corner: Self.tapCorner, anchorID: nil, entry: first.position, panel: index,
                           now: frame.timestamp, pointer: c)
    }

    /// 轻点唤起没有锚指，会话的锚定角只是占位，不参与判定（`anchorLifted` 为 true）
    private static let tapCorner = AnchorCorner.bottomLeft

    // MARK: 空闲

    private mutating func idle(_ event: SessionEvent) -> [SessionEffect] {
        guard case .frame(let frame) = event, !environment.suspended, !environment.panels.isEmpty,
              environment.devices[frame.device] != nil else { return [] }
        let touching = frame.contacts.filter(\.isTouching)
        if let effects = tapHold(frame, touching) { return effects }
        // T1
        guard touching.count == 1, let c = touching.first, c.phase == .began,
              let corner = tuning.holdCorners.first(where: {
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
    /// 光标在此刻冻结（不经过候选期）。`pointer` 为轻点后按住的第二根手指，直接作为指点指（D25）。条件不满足时返回空
    private mutating func enterActive(device id: TrackpadDeviceID, corner: AnchorCorner, anchorID: Int?, entry: CGPoint,
                                      panel: Int, now: TimeInterval, pointer: Contact? = nil) -> [SessionEffect] {
        let panels = environment.panels
        guard panels.indices.contains(panel), let device = environment.devices[id] else { return [] }
        let geometry = PanelGeometry(screen: environment.screenSize, deviceMM: device.surfaceSizeMM, tuning: tuning)
        var active = ActiveContext(device: id, anchorID: anchorID ?? -1, enteredAt: now, corner: corner, panels: panels,
                                   geometry: geometry, frontmostBundleID: environment.frontmostBundleID, lastFrameAt: now)
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
        var effects: [SessionEffect] = [setPolicy(TapPolicy(mode: .active, momentumUntil: policy.momentumUntil))]
        if anchorID == nil {
            active.anchorLifted = true
            active.lastTouchAt = now
            effects.append(.cursor(.arm))
        }
        effects.append(.cursor(.lock))
        if let c = pointer {
            active.pointer = PointerTrack(id: c.id, t: now, p: c.position)
            active.releaseAfter = now + tuning.tapHoldMinMs / 1000
            let h = hover(active, c.position, now: now)
            active.hovered = h.slot
            active.overviewHover = h.overview
            updateSliderPreview(&active, point: mapper(active).panelPoint(c.position, panelSize: active.panelSize))
            effects += syncSliders(&active)
        }
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
            if let id = ctx.repeatSlot, let at = ctx.repeatAt {
                if ctx.hovered != id {
                    ctx.repeatSlot = nil  // 移出按钮：停止连续触发
                    ctx.repeatAt = nil
                    state = .active(ctx)
                } else if now >= at, let slot = ctx.layout.slot(id) {
                    // 落后太多（例如 tick 卡顿）不补发，从现在起按间隔继续
                    ctx.repeatAt = max(at + tuning.repeatIntervalMs / 1000, now)
                    state = .active(ctx)
                    var effects: [SessionEffect] = [.action(ActionRequest(action: slot.action, title: slot.title,
                                                                          frontmostBundleID: ctx.frontmostBundleID, notBefore: now))]
                    if ctx.panelVisible { effects += [.flashSlot(id), .updatePanel(panelState(ctx))] }
                    return effects
                }
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
        updateSliderPreview(&ctx, point: mapper(ctx).panelPoint(pointer.latest, panelSize: ctx.panelSize))
        return [.haptic] + syncSliders(&ctx) + (ctx.panelVisible ? [.updatePanel(panelState(ctx))] : [])
    }

    private mutating func pointerFrame(_ ctx: inout ActiveContext, _ frame: TouchFrame) -> [SessionEffect] {
        let mapper = mapper(ctx)
        var effects: [SessionEffect] = []

        if var pointer = ctx.pointer {
            guard let c = frame.contacts.first(where: { $0.id == pointer.id }), c.phase != .cancelled else {
                clearPointer(&ctx)  // 指点指异常消失：不提交，允许重新选择
                let reverted = syncSliders(&ctx)
                state = .active(ctx)
                return reverted + (ctx.panelVisible ? [.updatePanel(panelState(ctx))] : [])
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
        effects += syncSliders(&ctx)
        state = .active(ctx)
        if ctx.panelVisible { effects.append(.updatePanel(panelState(ctx))) }
        return effects
    }

    private mutating func commit(_ ctx: inout ActiveContext, _ pointer: PointerTrack, liftAt: TimeInterval) -> [SessionEffect] {
        if ctx.pressConsumed {
            return exit(ctx, now: liftAt, end: .liftAfterPress)  // D18：按压已执行过，抬起只关闭
        }
        if let after = ctx.releaseAfter, liftAt < after {
            return exit(ctx, now: liftAt, end: .earlyLift)  // D25：停留不足
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
        let tester = tester(ctx)
        if let id = ctx.hovered, let slot = ctx.layout.slot(id), let target = slot.slider {
            // 滑杆：在滑杆上抬起即接受，按提交坐标确定最终数值（抬起去抖同 FR-6.10）
            if let raw = tester.sliderValue(of: slot, at: panelPoint) { accept(&ctx, target, Self.quantize(raw)) }
            // 先送一次新基准：提交动效里参考线滑到生效的位置（D29）
            let accepted: [SessionEffect] = ctx.panelVisible ? [.updatePanel(panelState(ctx))] : []
            return accepted + exit(ctx, now: liftAt, end: .committed(id))
        }
        // 高亮的就是会执行的：抬起时与悬停同一套滞回规则（D31，修订 FR-6.11 的不带滞回）
        let hit = tester.hit(panelPoint, current: ctx.hovered)
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
        ctx.releaseAfter = nil
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
        if ctx.panelVisible { effects += [.flashSlot(id), .updatePanel(panelState(ctx))] }
        return effects
    }

    /// 滑杆数值按 1% 取整
    static func quantize(_ v: Double) -> Double { (v * 100).rounded() / 100 }

    /// 滑杆实时生效（D29）：指点指所在滑杆的预览值立即送给系统，其余滑杆回到基准值。
    /// 不知道实际值（读取失败）的滑杆没有可恢复的基准，只预览，接受后才送出
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

    /// 5.5 退出激活（T11、T14–T18）：隐藏面板 → 光标回到冻结点 → 冷却策略 → 动作
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
        s.sticky = ctx.anchorLifted
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
