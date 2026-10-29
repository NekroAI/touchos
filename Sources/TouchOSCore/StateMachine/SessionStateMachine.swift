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
    case deviceRemoved, tapDisabled, forced(String)
}

/// 外层随时维护的会话环境；进入激活态时取快照（SRS 5.4）。
public struct SessionEnvironment: Equatable, Sendable {
    /// 启用中的设备（FR-4.4、FR-4.6）
    public var devices: [TrackpadDeviceID: TrackpadDevice] = [:]
    /// 按前台应用解析出的布局（FR-10.7）
    public var layout: Layout?
    public var frontmostBundleID: String?
    /// 暂停、前台应用在黑名单、拦截或权限不可用时为 true：不接受新的锚定
    public var suspended = false
    /// 冻结光标所在屏幕的可见区域尺寸（pt），用于计算面板尺寸（FR-8.5、8.6）
    public var screenSize = CGSize(width: 1440, height: 900)

    public init() {}
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
    public let layout: Layout
    public let size: CGSize
    /// 指示点（面板 pt，原点左上）；没有指点指时为 nil
    public var pointer: CGPoint?
    public var hovered: SlotID?
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
    /// 连续触发提交时槽位闪烁一次（T12）
    case flashSlot(SlotID)
    /// 槽位变化或连续触发提交时的触觉反馈（FR-6.14、6.15）
    case haptic
    case action(ActionRequest)
    case armFailed(AnchorFailure)
    case sessionEnded(SessionEnd)
}

public enum SessionEvent: Equatable, Sendable {
    case frame(TouchFrame)
    case physicalPress
    case escapeKey
    case tick(TimeInterval)
    case deviceRemoved(TrackpadDeviceID)
    case tapDisabled
    case forceCancel(String)
    case environment(SessionEnvironment)
}

public struct ArmedContext: Equatable, Sendable {
    public let device: TrackpadDeviceID
    public let anchorID: Int
    public let anchorOrigin: CGPoint
    public let startedAt: TimeInterval
}

public struct ActiveContext: Equatable, Sendable {
    public let device: TrackpadDeviceID
    public let anchorID: Int
    public let enteredAt: TimeInterval
    public let layout: Layout
    public let panelSize: CGSize
    public let frontmostBundleID: String?
    public var pointer: PointerTrack?
    public var hovered: SlotID?
    public var panelVisible = false
    public var lastFrameAt: TimeInterval
}

public enum SessionState: Equatable, Sendable {
    case idle
    case armed(ArmedContext)
    case active(ActiveContext)
    case cooldown(until: TimeInterval)
}

public struct SessionStateMachine: Sendable {
    public let tuning: Tuning
    public private(set) var environment: SessionEnvironment
    public private(set) var state: SessionState = .idle
    /// 最近一次发布的拦截策略（冷却结束后仍保留惯性滚动截止时刻）
    public private(set) var policy = TapPolicy(mode: .idle)

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
        switch state {
        case .idle: return idle(event)
        case .armed(let ctx): return armed(ctx, event)
        case .active(let ctx): return active(ctx, event)
        case .cooldown(let until): return cooldown(until, event)
        }
    }

    // MARK: 空闲

    private mutating func idle(_ event: SessionEvent) -> [SessionEffect] {
        // T1
        guard case .frame(let frame) = event, !environment.suspended, environment.layout != nil,
              environment.devices[frame.device] != nil else { return [] }
        let touching = frame.contacts.filter(\.isTouching)
        guard touching.count == 1, let c = touching.first, c.phase == .began,
              closedContains(anchorZone(tuning.anchorCorner, width: tuning.anchorZoneW, height: tuning.anchorZoneH), c.position)
        else { return [] }
        state = .armed(ArmedContext(device: frame.device, anchorID: c.id, anchorOrigin: c.position, startedAt: frame.timestamp))
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
        guard let layout = environment.layout, let device = environment.devices[ctx.device] else { return abortArmed() }
        let size = panelSize(screen: environment.screenSize, deviceMM: device.surfaceSizeMM, scale: tuning.panelScale)
        var active = ActiveContext(device: ctx.device, anchorID: ctx.anchorID, enteredAt: now, layout: layout, panelSize: size,
                                   frontmostBundleID: environment.frontmostBundleID, lastFrameAt: now)
        var effects: [SessionEffect] = [setPolicy(TapPolicy(mode: .active, momentumUntil: policy.momentumUntil)), .cursor(.lock)]
        if tuning.panelDelayMs <= 0 {
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
            if frame.contacts.filter(\.isTouching).count >= 3 {
                return exit(ctx, now: frame.timestamp, end: .thirdFinger, thirdFinger: true)  // T15
            }
            guard frame.contacts.contains(where: { $0.id == ctx.anchorID && $0.isTouching }) else {
                return exit(ctx, now: frame.timestamp, end: .anchorLifted)  // T14
            }
            return pointerFrame(&ctx, frame)
        case .tick(let now):
            if now - ctx.lastFrameAt > tuning.frameTimeoutMs / 1000 { return exit(ctx, now: now, end: .frameTimeout) }  // T17
            if now - ctx.enteredAt > tuning.maxSessionSec { return exit(ctx, now: now, end: .maxDuration) }  // T18
            if !ctx.panelVisible && now - ctx.enteredAt >= tuning.panelDelayMs / 1000 {  // T10
                ctx.panelVisible = true
                state = .active(ctx)
                return [.showPanel(panelState(ctx))]
            }
            return []
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

    private mutating func pointerFrame(_ ctx: inout ActiveContext, _ frame: TouchFrame) -> [SessionEffect] {
        let mapper = Mapper(margin: tuning.mappingMargin)
        let tester = HitTester(layout: ctx.layout, panelSize: ctx.panelSize, slotGap: tuning.slotGap, hysteresis: tuning.hysteresis)
        var effects: [SessionEffect] = []

        if var pointer = ctx.pointer {
            guard let c = frame.contacts.first(where: { $0.id == pointer.id }), c.phase != .cancelled else {
                clearPointer(&ctx)  // 指点指异常消失：不提交，允许重新选择
                state = .active(ctx)
                return ctx.panelVisible ? [.updatePanel(panelState(ctx))] : []
            }
            if c.phase == .ended {
                return commit(&ctx, pointer, liftAt: frame.timestamp, mapper: mapper, tester: tester)  // T11–T13
            }
            pointer.append(t: frame.timestamp, p: c.position)  // T9
            ctx.pointer = pointer
            let hovered = tester.hit(mapper.panelPoint(c.position, panelSize: ctx.panelSize), current: ctx.hovered)
            if hovered != ctx.hovered {
                ctx.hovered = hovered
                effects.append(.haptic)
            }
        } else if let c = frame.contacts.first(where: { candidate in
            candidate.id != ctx.anchorID && candidate.phase == .began && mapper.isInMappingZone(candidate.position)
                && !closedContains(anchorZone(tuning.anchorCorner, width: tuning.anchorZoneW, height: tuning.anchorZoneH), candidate.position)
        }) {
            // T8：新接触落在映射区且不在锚定区（FR-6.5）
            ctx.pointer = PointerTrack(id: c.id, t: frame.timestamp, p: c.position)
            let hovered = tester.hit(mapper.panelPoint(c.position, panelSize: ctx.panelSize))
            if hovered != ctx.hovered {
                ctx.hovered = hovered
                effects.append(.haptic)
            }
        } else {
            state = .active(ctx)
            return []
        }
        state = .active(ctx)
        if ctx.panelVisible { effects.append(.updatePanel(panelState(ctx))) }
        return effects
    }

    private mutating func commit(_ ctx: inout ActiveContext, _ pointer: PointerTrack, liftAt: TimeInterval,
                                 mapper: Mapper, tester: HitTester) -> [SessionEffect] {
        let point = pointer.commitPoint(liftAt: liftAt, lookback: tuning.liftLookbackMs / 1000)
        // FR-6.11：按提交坐标做一次不带滞回的命中
        guard let id = tester.hit(mapper.panelPoint(point, panelSize: ctx.panelSize)), let slot = ctx.layout.slot(id),
              slot.action != .none else {
            clearPointer(&ctx)  // T13：安全区或空隙，不退出
            state = .active(ctx)
            return ctx.panelVisible ? [.updatePanel(panelState(ctx))] : []
        }
        let request = ActionRequest(action: slot.action, title: slot.title, frontmostBundleID: ctx.frontmostBundleID,
                                    notBefore: liftAt + tuning.actionDelayMs / 1000)
        if slot.repeats {
            // T12：执行动作但不退出
            clearPointer(&ctx)
            state = .active(ctx)
            var effects: [SessionEffect] = [.action(request), .haptic]
            if ctx.panelVisible { effects += [.flashSlot(id), .updatePanel(panelState(ctx))] }
            return effects
        }
        return exit(ctx, now: liftAt, end: .committed(id), action: request)  // T11
    }

    private func clearPointer(_ ctx: inout ActiveContext) {
        ctx.pointer = nil
        ctx.hovered = nil
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
        let mapper = Mapper(margin: tuning.mappingMargin)
        return PanelState(layout: ctx.layout, size: ctx.panelSize,
                          pointer: ctx.pointer.map { mapper.panelPoint($0.latest, panelSize: ctx.panelSize) },
                          hovered: ctx.hovered)
    }
}

extension Contact {
    /// 仍在板上（ended / cancelled 表示这一帧已离开）
    public var isTouching: Bool { phase != .ended && phase != .cancelled }
}
