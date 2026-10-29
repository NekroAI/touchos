import AppKit
import SwiftUI
import TouchOSCore

/// 浮层（SRS 8.1、8.2）：永不获得焦点、鼠标穿透、出现在所有桌面和全屏应用之上；只渲染视图模型，不处理输入。
/// 启动时创建并保持隐藏，激活时只切换可见性（FR-8.4）。
/// 唤起的是一组悬浮按钮而不是一个窗口（D20）：没有容器背景，窗口铺满整屏、完全透明。
final class OverlayPanel: NSPanel {
    init(model: OverlayModel) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                   styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // 出现在所有桌面并能叠加在全屏应用上；不进入窗口循环与 Mission Control（FR-8.2、8.3）
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .transient]
        contentView = NSHostingView(rootView: OverlayRoot(model: model))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 铺满鼠标（冻结光标）所在屏幕：按钮组居中于整块屏幕（修订 FR-8.5 的"可见区域中心"，负责人反馈：
    /// 中心的取消要在屏幕正中），指示点可以越出按钮组（D15），背景压暗铺满整屏。
    /// 返回按钮组左上角在窗口内容坐标（原点左上）中的位置
    func show(groupSize: CGSize) -> CGPoint {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else {
            orderFrontRegardless()
            return .zero
        }
        let f = screen.frame
        setFrame(f, display: false)
        orderFrontRegardless()
        return CGPoint(x: (f.width - groupSize.width) / 2, y: (f.height - groupSize.height) / 2)
    }

    func hide() {
        orderOut(nil)
    }
}

/// 指示点的位置样本（按钮组 pt），用于帧间插值与轨迹（FR-8.9、SRS 8.3）
struct PointerSample {
    let t: TimeInterval
    let p: CGPoint
}

@MainActor
@Observable
final class OverlayModel {
    /// 按钮组的生命周期（D20）：弹开 → 显示 → 提交（选中的留下）→ 消散，或整体收拢
    enum Phase: Equatable {
        case entering, shown, committing(SlotID), dissolving(SlotID), collapsing

        var appeared: Bool { self != .entering }
        var chosen: SlotID? {
            switch self {
            case .committing(let id), .dissolving(let id): id
            default: nil
            }
        }
        var leaving: Bool { chosen != nil || self == .collapsing }
    }

    private(set) var state: PanelState?
    var phase = Phase.shown
    /// 按钮组左上角在窗口中的位置
    var groupOrigin = CGPoint.zero
    /// 背景压暗（调试菜单开关）
    var dim = false
    var slotGap = 0.0
    /// `P.trailMs`（秒）
    var trailDuration = 0.3
    /// 各槽位的波纹与按下回弹的触发计数，每加一播放一次
    private(set) var pulses: [SlotID: Int] = [:]
    /// 当前悬停期间各槽位按压执行的次数，悬停变化时清零
    private(set) var presses: [SlotID: Int] = [:]
    /// 最近的指示点样本；指点指抬起后保留到轨迹淡出
    private(set) var samples: [PointerSample] = []
    private(set) var pointerDown = false

    func pulse(_ id: SlotID) { pulses[id, default: 0] += 1 }

    /// 按压执行一次：计数加一；`animate` 为假（减少动态效果）时不播放回弹与波纹
    func press(_ id: SlotID, animate: Bool) {
        presses[id, default: 0] += 1
        if animate { pulse(id) }
    }

    /// 指示点每帧都变，单独存在 `samples` 里；`state` 去掉指示点后只在槽位、悬停、页码等变化时更新，
    /// 避免每一帧都让全部按钮重新计算视图
    func apply(_ new: PanelState?) {
        let now = ProcessInfo.processInfo.systemUptime
        var stripped = new
        stripped?.pointer = nil
        if stripped?.hovered != state?.hovered { presses.removeAll() }
        if stripped != state { state = stripped }
        if new == nil { pulses.removeAll() }
        if let p = new?.pointer {
            if !pointerDown { samples.removeAll() }  // 新的指点指不接上一条轨迹
            samples.append(PointerSample(t: now, p: p))
            pointerDown = true
        } else {
            pointerDown = false
        }
        samples.removeAll { now - $0.t > max(trailDuration, PanelMetrics.maxSampleInterval) * 2 }
    }

    /// 某一时刻的显示位置：在最后两个样本之间按经过的时间线性插值（FR-8.9）
    func displayedPointer(at now: TimeInterval) -> CGPoint? {
        guard pointerDown, let b = samples.last else { return nil }
        guard samples.count >= 2 else { return b.p }
        let a = samples[samples.count - 2]
        let interval = min(max(b.t - a.t, PanelMetrics.minSampleInterval), PanelMetrics.maxSampleInterval)
        let k = min((now - b.t) / interval, 1)
        return CGPoint(x: a.p.x + (b.p.x - a.p.x) * k, y: a.p.y + (b.p.y - a.p.y) * k)
    }
}

/// 按钮组视觉尺寸与动效参数（SRS 8.3，修订见 decisions.md D20）
enum PanelMetrics {
    /// 按钮在槽位可见区域（已扣掉 `P.slotGap`）基础上每边再小的量：按钮铺满各自的格子，之间留出等宽的缝
    static let chipInset: CGFloat = 2
    static let chipCornerRadius: CGFloat = 18
    /// 环形布局的圆形按钮：直径取环宽与弦长中较小者的该比例，再限制在上下限之间
    static let roundChipFill: CGFloat = 0.7
    static let roundChipMin: CGFloat = 40
    static let roundChipMax: CGFloat = 76
    /// 取消按钮：中心一个小圆
    static let cancelChipSize: CGFloat = 40
    static let iconSize: CGFloat = 26
    static let roundIconSize: CGFloat = 24
    static let cancelIconSize: CGFloat = 15
    static let titleSize: CGFloat = 12.5
    static let captionSize: CGFloat = 10.5

    /// 悬停：浮起放大，每边外扩不超过 `hoverGrowMax`（大按钮不至于放大过多）
    static let hoverScale: CGFloat = 1.06
    static let hoverGrowMax: CGFloat = 8
    /// 提交：选中的按钮放大、停留，然后放大淡出
    static let commitScale: CGFloat = 1.1
    static let commitGrowMax: CGFloat = 12
    static let dissolveScale: CGFloat = 1.18
    /// 按压：缩小后回弹
    static let pressScale: CGFloat = 0.93
    static let pressDown: TimeInterval = 0.06
    static let pressRelease: TimeInterval = 0.24

    /// 弹开：从唤起位置方向拉近 `enterPull` 倍距离、缩小，按离唤起位置的距离依次出现，最晚延迟 `enterStagger`。
    /// 不做模糊：对玻璃做模糊动画代价很高，弹开会卡顿
    static let enterScale: CGFloat = 0.85
    static let enterPull: CGFloat = 0.35
    static let enterStagger: TimeInterval = 0.08
    static let enterResponse = 0.3
    static let enterDamping = 0.78
    /// 收拢：向按钮组中心拉近、缩小、淡出。幅度要大，否则看起来是一格一格原地消失（负责人反馈"栅格感"）
    static let collapseScale: CGFloat = 0.6
    static let collapsePull: CGFloat = 0.6

    /// 使用系统液态玻璃（`defaults write ai.nekro.touchos systemGlass -bool true`）。默认关闭：
    /// 实测 macOS 27 上液态玻璃不跟随透明度动画，弹开第一帧就整块出现、退场时残留，改用毛玻璃材质（D20）
    static var systemGlass: Bool { UserDefaults.standard.bool(forKey: "systemGlass") }

    /// 未点亮按钮的底色：窗口背景色半透明，深色模式偏暗、浅色模式偏亮
    static let chipBase = Color(nsColor: .windowBackgroundColor).opacity(0.22)
    /// 毛玻璃强度、顶部高光与文字阴影（半透明按钮的可读性）
    static let materialOpacity = 0.55
    static let sheenOpacity = 0.08
    static let labelShadowOpacity = 0.35

    /// 悬停光：在按钮下方流动的强调色光晕（透过玻璃）
    static let glowBlur: CGFloat = 14
    static let glowOpacity = 0.55

    static let pointerCore: CGFloat = 9
    static let pointerHalo: CGFloat = 26
    static let trailMaxWidth: CGFloat = 5
    static let trailMaxOpacity = 0.5
    /// 指示点在映射区之外（此时抬起即取消，D21、D22）：按钮组整体变淡，显示按钮组范围的轮廓，
    /// 指示点换成不带强调色的 × 并标注"松手取消"，与悬停在按钮上的样子区分开
    static let outsideGroupOpacity = 0.45
    static let boundsOpacity = 0.3
    static let cancelPointerSize: CGFloat = 22
    static let cancelPointerFill = 0.75
    static let cancelHintSize: CGFloat = 11
    static let cancelHintOffset: CGFloat = 24
    static let dimOpacity = 0.14

    /// 面板名与页码：按钮组上方的小标签，显示这么久后淡出；滑杆数值、圆形按钮名称也按这个距离摆放
    static let pageLabelDuration: TimeInterval = 1.2
    static let pageLabelOffset: CGFloat = 30

    /// 波纹从按钮轮廓向外扩散的距离与时长
    static let rippleDistance: CGFloat = 16
    static let rippleDuration = 0.4
    /// 波纹从透明亮起的时长
    static let rippleAttack = 0.04

    /// 按比例放大，但每边外扩不超过 `maxGrow`
    static func scale(_ factor: CGFloat, for size: CGSize, maxGrow: CGFloat) -> CGFloat {
        let longest = max(size.width, size.height)
        return longest > 0 ? min(factor, 1 + maxGrow * 2 / longest) : factor
    }
    /// 插值用的样本间隔上下限：触点约 66 Hz，超过上限视为停顿后的新移动
    static let minSampleInterval: TimeInterval = 0.004
    static let maxSampleInterval: TimeInterval = 0.05
}

/// 一个按钮画在哪里、画成什么样。命中区域仍由 `HitTester` 按槽位形状判定，与这里无关
struct ChipGeometry: Equatable {
    enum Kind { case tile, round, cancel }

    var frame: CGRect
    var kind: Kind

    var cornerRadius: CGFloat {
        let half = min(frame.width, frame.height) / 2
        return kind == .tile ? min(PanelMetrics.chipCornerRadius, half) : half
    }

    func scaled(_ k: CGFloat) -> ChipGeometry {
        let w = frame.width * k, h = frame.height * k
        return ChipGeometry(frame: CGRect(x: frame.midX - w / 2, y: frame.midY - h / 2, width: w, height: h), kind: kind)
    }

    static func of(_ slot: Slot, tester: HitTester) -> ChipGeometry? {
        switch slot.shape {
        case .cell, .rect:
            guard let r = tester.visualRect(of: slot) else { return nil }
            if slot.isCancel { return round(at: CGPoint(x: r.midX, y: r.midY), diameter: PanelMetrics.cancelChipSize, kind: .cancel) }
            return ChipGeometry(frame: r.insetBy(dx: PanelMetrics.chipInset, dy: PanelMetrics.chipInset), kind: .tile)
        case .sector(let s):
            if slot.isCancel || (s.innerRadius == 0 && s.isFullCircle) {
                return round(at: tester.center, diameter: PanelMetrics.cancelChipSize, kind: slot.isCancel ? .cancel : .round)
            }
            // 环形布局画成沿环排列的圆形按钮，不画扇形
            let unit = tester.unitRadius
            let outer = min(s.outerRadius ?? Self.openOuterRadius, Self.openOuterRadius)
            let r = (s.innerRadius + outer) / 2 * unit
            let ring = (outer - s.innerRadius) * unit
            let width = min(s.endAngle - s.startAngle, 180) * .pi / 180
            let chord = 2 * r * sin(width / 2)
            let d = min(max(min(ring, chord) * PanelMetrics.roundChipFill, PanelMetrics.roundChipMin), PanelMetrics.roundChipMax)
            let a = (s.startAngle + s.endAngle) / 2 * .pi / 180
            return round(at: CGPoint(x: tester.center.x + r * sin(a), y: tester.center.y - r * cos(a)), diameter: d, kind: .round)
        }
    }

    /// 向外无限延伸的扇区按这个外半径摆放按钮（单位半径的比例）
    private static let openOuterRadius = 0.98

    private static func round(at c: CGPoint, diameter d: CGFloat, kind: Kind) -> ChipGeometry {
        ChipGeometry(frame: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d), kind: kind)
    }
}

/// 浮层根视图：可选的背景压暗、按钮组、面板名标签、指示点
private struct OverlayRoot: View {
    let model: OverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let state = model.state {
                let tester = HitTester(layout: state.layout, panelSize: state.size, slotGap: model.slotGap, hysteresis: 0)
                let groupRect = CGRect(origin: model.groupOrigin, size: state.size)
                if model.dim {
                    Color.black.opacity(model.phase.appeared && !model.phase.leaving ? PanelMetrics.dimOpacity : 0)
                        .animation(.easeOut(duration: 0.2), value: model.phase)
                }
                let outside = state.pointer.map { !CGRect(origin: .zero, size: state.size).contains($0) } ?? false
                ChipGroup(model: model, state: state, tester: tester)
                    .frame(width: state.size.width, height: state.size.height, alignment: .topLeading)
                    .opacity(outside && !model.phase.leaving ? PanelMetrics.outsideGroupOpacity : 1)
                    .animation(.easeOut(duration: 0.15), value: outside)
                    .offset(x: groupRect.minX, y: groupRect.minY)
                    .id(state.layout.id)  // 翻页时整组替换
                PageLabel(name: state.layout.name, pageIndex: state.pageIndex, pageCount: state.pageCount)
                    .opacity(model.phase.leaving ? 0 : 1)
                    .position(x: groupRect.midX, y: groupRect.minY - PanelMetrics.pageLabelOffset)
                if !model.phase.leaving {
                    PointerLayer(model: model, groupRect: groupRect,
                                 overCancel: state.hovered.flatMap { state.layout.slot($0) }?.isCancel ?? false,
                                 showTrail: !reduceMotion)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 一组悬浮按钮与在按钮之间流动的悬停光
private struct ChipGroup: View {
    let model: OverlayModel
    let state: PanelState
    let tester: HitTester

    var body: some View {
        let chips = state.layout.slots.compactMap { slot in ChipGeometry.of(slot, tester: tester).map { (slot: slot, geometry: $0) } }
        let origin = state.origin ?? tester.center
        let farthest = chips.map { distance($0.geometry, origin) }.max() ?? 1
        let lit = chips.first { $0.slot.id == (model.phase.chosen ?? state.hovered) && !$0.slot.isCancel }
        // 收拢与消散时光晕随按钮一起淡出，不在原地残留
        let fading: Bool = { if case .dissolving = model.phase { true } else { model.phase == .collapsing } }()
        ZStack(alignment: .topLeading) {
            HoverGlow(target: fading ? nil : lit.map {
                $0.geometry.scaled(PanelMetrics.scale(PanelMetrics.hoverScale, for: $0.geometry.frame.size, maxGrow: PanelMetrics.hoverGrowMax))
            })
            GlassGroup {
                ZStack(alignment: .topLeading) {
                    ForEach(chips, id: \.slot.id) { chip in
                        ChipView(slot: chip.slot, geometry: chip.geometry, hovered: state.hovered == chip.slot.id,
                                 value: state.sliderValues[chip.slot.id], pulse: model.pulses[chip.slot.id] ?? 0,
                                 presses: model.presses[chip.slot.id] ?? 0, phase: model.phase,
                                 origin: origin, groupCenter: tester.center,
                                 delay: PanelMetrics.enterStagger * distance(chip.geometry, origin) / max(farthest, 1))
                    }
                }
                .frame(width: state.size.width, height: state.size.height, alignment: .topLeading)
            }
        }
    }

    private func distance(_ g: ChipGeometry, _ p: CGPoint) -> CGFloat {
        hypot(g.frame.midX - p.x, g.frame.midY - p.y)
    }
}

/// macOS 26 起把所有玻璃按钮放进同一个玻璃容器，一次合成；更早的系统直接渲染
private struct GlassGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26, *), PanelMetrics.systemGlass {
            GlassEffectContainer(spacing: 0) { content }
        } else {
            content
        }
    }
}

/// 一枚悬浮按钮
private struct ChipView: View {
    let slot: Slot
    let geometry: ChipGeometry
    let hovered: Bool
    let value: Double?
    let pulse: Int
    let presses: Int
    let phase: OverlayModel.Phase
    /// 唤起位置与按钮组中心（按钮组 pt）
    let origin: CGPoint
    let groupCenter: CGPoint
    /// 弹开时的延迟
    let delay: TimeInterval

    var body: some View {
        let g = geometry
        let shape = RoundedRectangle(cornerRadius: g.cornerRadius, style: .continuous)
        let lit = hovered || chosen
        ZStack {
            if slot.slider != nil { SliderFill(shape: shape, vertical: g.frame.height > g.frame.width, value: value ?? 0) }
            ChipLabel(slot: slot, kind: g.kind, lit: lit, value: value)
        }
        .frame(width: g.frame.width, height: g.frame.height)
        // 内容必须是玻璃本身的内容：作为兄弟视图叠在玻璃上时，玻璃容器会把它压到玻璃下面一起模糊
        .modifier(ChipSurface(shape: shape, lit: lit, cancel: g.kind == .cancel))
        .overlay { Ripple(shape: shape, trigger: pulse) }
        .overlay(alignment: .topTrailing) {
            if presses >= 2 { PressBadge(count: presses).offset(x: 6, y: -6) }
        }
        .overlay(alignment: .top) {
            if slot.slider != nil, hovered, let value { ValueBubble(value: value).offset(y: -PanelMetrics.pageLabelOffset) }
        }
        .overlay(alignment: .bottom) {
            if g.kind == .round { RoundTitle(title: slot.title, lit: lit).offset(y: PanelMetrics.pageLabelOffset - 6) }
        }
        .keyframeAnimator(initialValue: CGFloat(1), trigger: pulse) { content, k in
            content.scaleEffect(k)
        } keyframes: { _ in
            // 不用时长为 0 的关键帧：其插值进度为 0/0，曾产生 NaN 导致崩溃（m0-report.md）
            CubicKeyframe(PanelMetrics.pressScale, duration: PanelMetrics.pressDown)
            SpringKeyframe(1, duration: PanelMetrics.pressRelease)
        }
        .scaleEffect(scale)
        .opacity(opacity)
        .offset(offset)
        .position(x: g.frame.midX, y: g.frame.midY)
        .animation(.spring(response: 0.22, dampingFraction: 0.72), value: hovered)
        .animation(phaseAnimation, value: phase)
    }

    private var chosen: Bool { phase.chosen == slot.id }

    private var dissolving: Bool {
        if case .dissolving = phase { true } else { false }
    }

    private var scale: CGFloat {
        let size = geometry.frame.size
        if !phase.appeared { return PanelMetrics.enterScale }
        if chosen {
            return dissolving ? PanelMetrics.dissolveScale
                : PanelMetrics.scale(PanelMetrics.commitScale, for: size, maxGrow: PanelMetrics.commitGrowMax)
        }
        if phase.leaving { return PanelMetrics.collapseScale }
        return hovered ? PanelMetrics.scale(PanelMetrics.hoverScale, for: size, maxGrow: PanelMetrics.hoverGrowMax) : 1
    }

    private var opacity: Double {
        if !phase.appeared { return 0 }
        if chosen { return dissolving ? 0 : 1 }
        return phase.leaving ? 0 : 1
    }

    private var offset: CGSize {
        let c = CGPoint(x: geometry.frame.midX, y: geometry.frame.midY)
        if !phase.appeared {
            return CGSize(width: (origin.x - c.x) * PanelMetrics.enterPull, height: (origin.y - c.y) * PanelMetrics.enterPull)
        }
        if phase == .collapsing {
            return CGSize(width: (groupCenter.x - c.x) * PanelMetrics.collapsePull,
                          height: (groupCenter.y - c.y) * PanelMetrics.collapsePull)
        }
        return .zero
    }

    private var phaseAnimation: Animation {
        switch phase {
        case .shown: .spring(response: PanelMetrics.enterResponse, dampingFraction: PanelMetrics.enterDamping).delay(delay)
        case .dissolving: .easeOut(duration: OverlayController.dissolveDuration)
        case .collapsing: .easeIn(duration: OverlayController.leaveDuration)  // 加速收进中心
        default: .easeOut(duration: OverlayController.leaveDuration)
        }
    }
}

/// 按钮底：玻璃（macOS 26 起为液态玻璃，更早为毛玻璃），点亮时带强调色。内容画在玻璃之上
private struct ChipSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let lit: Bool
    let cancel: Bool

    func body(content: Content) -> some View {
        let tint = cancel ? Color.white : Color.accentColor
        Group {
            if #available(macOS 26, *), PanelMetrics.systemGlass {
                // 未点亮时也带一层随深浅色变化的底色：清透的玻璃压在文字上时，背后的文字会干扰阅读
                content.glassEffect(.regular.tint(lit ? tint.opacity(cancel ? 0.2 : 0.35) : PanelMetrics.chipBase), in: shape)
            } else {
                // 半透明（负责人反馈：不要实心）：毛玻璃只保留一部分强度，叠一层很淡的底色与顶部高光；文字加阴影保证可读
                content
                    .shadow(color: .black.opacity(PanelMetrics.labelShadowOpacity), radius: 2, y: 1)
                    .background {
                        ZStack {
                            shape.fill(.ultraThinMaterial).opacity(PanelMetrics.materialOpacity)
                            shape.fill(lit ? tint.opacity(0.3) : PanelMetrics.chipBase)
                            shape.fill(LinearGradient(colors: [.white.opacity(PanelMetrics.sheenOpacity), .clear],
                                                      startPoint: .top, endPoint: .center))
                        }
                    }
                    .shadow(color: .black.opacity(lit ? 0.25 : 0.1), radius: lit ? 12 : 6, y: lit ? 6 : 2)
            }
        }
        .overlay(shape.strokeBorder(lit ? tint.opacity(0.9) : Color.white.opacity(0.2), lineWidth: lit ? 1.5 : 1))
    }
}

/// 在按钮下方流动的强调色光晕：悬停从一枚按钮滑到下一枚，透过玻璃看到的是一块移动的光
private struct HoverGlow: View {
    let target: ChipGeometry?
    @State private var last: ChipGeometry?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let g = target ?? last {
                RoundedRectangle(cornerRadius: g.cornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(PanelMetrics.glowOpacity))
                    .frame(width: g.frame.width, height: g.frame.height)
                    .blur(radius: PanelMetrics.glowBlur)
                    .position(x: g.frame.midX, y: g.frame.midY)
                    .opacity(target == nil ? 0 : 1)
            }
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.8), value: target)
        .onChange(of: target) { _, new in
            if let new { last = new }
        }
        .allowsHitTesting(false)
    }
}

private struct SliderFill<S: InsettableShape>: View {
    let shape: S
    let vertical: Bool
    let value: Double

    var body: some View {
        GeometryReader { g in
            let w = vertical ? g.size.width : g.size.width * value
            let h = vertical ? g.size.height * value : g.size.height
            Rectangle()
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.55), Color.accentColor.opacity(0.3)],
                                     startPoint: vertical ? .top : .trailing, endPoint: vertical ? .bottom : .leading))
                .frame(width: w, height: h)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: vertical ? .bottom : .leading)
        }
        .clipShape(shape)
        .animation(.easeOut(duration: 0.06), value: value)
    }
}

/// 按钮内容：方形按钮为图标 + 名称（说明文字只在点亮时显示）；圆形按钮只放图标，名称在下方；取消只有一个 ×
private struct ChipLabel: View {
    let slot: Slot
    let kind: ChipGeometry.Kind
    let lit: Bool
    let value: Double?

    var body: some View {
        switch kind {
        case .cancel:
            Image(systemName: "xmark")
                .font(.system(size: PanelMetrics.cancelIconSize, weight: .semibold))
                .foregroundStyle(lit ? .primary : .secondary)
        case .round:
            icon(PanelMetrics.roundIconSize)
        case .tile:
            VStack(spacing: 5) {
                icon(PanelMetrics.iconSize)
                Text(slot.title).font(.system(size: PanelMetrics.titleSize, weight: .medium))
                    .lineLimit(2).multilineTextAlignment(.center)
                if let caption {
                    // 始终占位，点亮时才显示：避免图标和名称随悬停上下跳动
                    Text(caption).font(.system(size: PanelMetrics.captionSize)).foregroundStyle(.secondary).lineLimit(1)
                        .opacity(lit || slot.slider != nil ? 1 : 0)
                }
            }
            .padding(6)
        }
    }

    private func icon(_ size: CGFloat) -> some View {
        Image(systemName: slot.symbol)
            .font(.system(size: size, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .symbolEffect(.bounce, value: lit)
    }

    private var caption: String? {
        if slot.slider != nil { return value.map { "\(Int(($0 * 100).rounded()))%" } }
        return slot.action.shortLabel
    }
}

/// 圆形按钮下方的名称：直接浮在桌面上，用一层毛玻璃保证可读
private struct RoundTitle: View {
    let title: String
    let lit: Bool

    var body: some View {
        Text(title)
            .font(.system(size: PanelMetrics.captionSize + 1, weight: lit ? .semibold : .medium))
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(.ultraThinMaterial, in: Capsule())
            .fixedSize()
    }
}

/// 连按计数：同一按钮按压执行两次起显示 ×N
private struct PressBadge: View {
    let count: Int

    var body: some View {
        Text("×\(count)")
            .font(.system(size: 11, weight: .bold).monospacedDigit())
            .contentTransition(.numericText(value: Double(count)))
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.accentColor, in: Capsule())
            .animation(.snappy, value: count)
    }
}

/// 滑杆悬停时在上方放大显示的数值
private struct ValueBubble: View {
    let value: Double

    var body: some View {
        Text("\(Int((value * 100).rounded()))%")
            .font(.system(size: 15, weight: .semibold).monospacedDigit())
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .fixedSize()
    }
}

/// 按钮组上方的面板名与页码：出现或翻页时显示一会儿后淡出
private struct PageLabel: View {
    let name: String
    let pageIndex: Int
    let pageCount: Int
    @State private var visible = false

    var body: some View {
        HStack(spacing: 8) {
            Text(name).font(.system(size: 12, weight: .semibold))
            if pageCount > 1 {
                HStack(spacing: 4) {
                    ForEach(0..<pageCount, id: \.self) { i in
                        Circle().fill(i == pageIndex ? Color.primary : Color.secondary.opacity(0.4)).frame(width: 5, height: 5)
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .fixedSize()
        .opacity(visible ? 1 : 0)
        .task(id: "\(name)#\(pageIndex)") {
            withAnimation(.easeOut(duration: 0.15)) { visible = true }
            try? await Task.sleep(for: .seconds(PanelMetrics.pageLabelDuration))
            withAnimation(.easeIn(duration: 0.3)) { visible = false }
        }
    }
}

/// 提交与按压执行的波纹：强调色描边从按钮轮廓向外扩散并淡出
private struct Ripple<S: InsettableShape>: View {
    struct Value {
        var spread: CGFloat = 0
        var opacity = 0.0
    }

    let shape: S
    let trigger: Int

    var body: some View {
        // 外扩固定距离而不是按比例缩放：大小按钮的波纹看起来一样
        Color.clear
            .keyframeAnimator(initialValue: Value(), trigger: trigger) { _, v in
                shape.inset(by: -v.spread).stroke(Color.accentColor, lineWidth: 3).opacity(v.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.spread) {
                    CubicKeyframe(PanelMetrics.rippleDistance, duration: PanelMetrics.rippleDuration)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(0.9, duration: PanelMetrics.rippleAttack)
                    CubicKeyframe(0, duration: PanelMetrics.rippleDuration - PanelMetrics.rippleAttack)
                }
            }
            .allowsHitTesting(false)
    }
}

/// 指示点与轨迹，按显示刷新率重绘并在触点帧之间插值（FR-8.9）。
/// 落在按钮上时也照常显示：用户靠它判断手指的真实位置、预判移动距离（负责人反馈，D20）
private struct PointerLayer: View {
    let model: OverlayModel
    /// 按钮组在窗口中的位置；指示点坐标是按钮组 pt，绘制时加上偏移
    let groupRect: CGRect
    let overCancel: Bool
    let showTrail: Bool

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, _ in
                let now = ProcessInfo.processInfo.systemUptime
                let _ = timeline.date
                let color = overCancel ? Color.gray : Color.accentColor
                ctx.translateBy(x: groupRect.minX, y: groupRect.minY)
                if showTrail { drawTrail(&ctx, now: now, color: color) }
                guard let p = model.displayedPointer(at: now) else { return }
                // 指示点在映射区之外：抬起即取消。显示按钮组范围的轮廓（提示要移回多远，D15），指示点换成取消样式
                let local = CGRect(origin: .zero, size: groupRect.size)
                if !local.contains(p) {
                    ctx.stroke(Path(roundedRect: local, cornerRadius: PanelMetrics.chipCornerRadius),
                               with: .color(.white.opacity(PanelMetrics.boundsOpacity)), style: StrokeStyle(lineWidth: 1.5, dash: [6, 6]))
                    drawCancelPointer(&ctx, at: p)
                    return
                }
                let halo = PanelMetrics.pointerHalo, core = PanelMetrics.pointerCore
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - halo / 2, y: p.y - halo / 2, width: halo, height: halo)),
                         with: .radialGradient(Gradient(colors: [color.opacity(0.55), color.opacity(0)]),
                                               center: p, startRadius: core / 2, endRadius: halo / 2))
                let coreRect = CGRect(x: p.x - core / 2, y: p.y - core / 2, width: core, height: core)
                ctx.fill(Path(ellipseIn: coreRect), with: .color(.white))
                ctx.stroke(Path(ellipseIn: coreRect), with: .color(color), lineWidth: 2)
            }
        }
        .allowsHitTesting(false)
    }

    /// 取消样式的指示点：深色圆底上一个白色 ×，下方深色胶囊里一行"松手取消"（浅色背景上也看得清）
    private func drawCancelPointer(_ ctx: inout GraphicsContext, at p: CGPoint) {
        let d = PanelMetrics.cancelPointerSize
        let disc = CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)
        ctx.fill(Path(ellipseIn: disc), with: .color(.black.opacity(PanelMetrics.cancelPointerFill)))
        ctx.stroke(Path(ellipseIn: disc), with: .color(.white.opacity(0.9)), lineWidth: 1.5)
        let k = d * 0.2
        var cross = Path()
        cross.move(to: CGPoint(x: p.x - k, y: p.y - k))
        cross.addLine(to: CGPoint(x: p.x + k, y: p.y + k))
        cross.move(to: CGPoint(x: p.x + k, y: p.y - k))
        cross.addLine(to: CGPoint(x: p.x - k, y: p.y + k))
        ctx.stroke(cross, with: .color(.white), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        let hint = ctx.resolve(Text("松手取消").font(.system(size: PanelMetrics.cancelHintSize, weight: .medium)).foregroundStyle(.white))
        let size = hint.measure(in: CGSize(width: 200, height: 40))
        let at = CGPoint(x: p.x, y: p.y + PanelMetrics.cancelHintOffset)
        let capsule = CGRect(x: at.x - size.width / 2 - 7, y: at.y - size.height / 2 - 3, width: size.width + 14, height: size.height + 6)
        ctx.fill(Path(roundedRect: capsule, cornerRadius: capsule.height / 2), with: .color(.black.opacity(PanelMetrics.cancelPointerFill)))
        ctx.draw(hint, at: at)
    }

    /// 最近 `P.trailMs` 的路径：越旧越细、越透明
    private func drawTrail(_ ctx: inout GraphicsContext, now: TimeInterval, color: Color) {
        var points = model.samples.filter { now - $0.t <= model.trailDuration }.map { ($0.t, $0.p) }
        if let head = model.displayedPointer(at: now) {
            points.removeAll { $0.0 > now }
            points.append((now, head))
        }
        guard points.count >= 2 else { return }
        for i in 1..<points.count {
            let age = (now - points[i].0) / model.trailDuration
            let k = max(0, 1 - age)
            var seg = Path()
            seg.move(to: points[i - 1].1)
            seg.addLine(to: points[i].1)
            ctx.stroke(seg, with: .color(color.opacity(PanelMetrics.trailMaxOpacity * k)),
                       style: StrokeStyle(lineWidth: max(1, PanelMetrics.trailMaxWidth * k), lineCap: .round))
        }
    }
}

extension Action {
    /// 按钮点亮时显示的小字说明
    var shortLabel: String? {
        switch self {
        case .none: nil
        case .keyboardShortcut(let k): k.displayLabel
        case .openApp: "打开应用"
        case .openURL(let url, _): url.host ?? "打开链接"
        case .openFile: "打开文件"
        case .shell: "Shell"
        case .appleScript: "脚本"
        case .shortcut(let name): name
        case .system: nil
        }
    }
}
