import SwiftUI
import TouchOSCore

/// 一个面板在堆栈中的摆放
struct PanelTransform: Equatable {
    var scale = 1.0
    var offset = CGSize.zero
    var opacity = 1.0
    var blur = 0.0
    /// 绕水平轴的翻转角（度，立体滚筒）
    var tilt = 0.0
    var z = 0.0
}

/// 全部面板（D23）：当前面板在前，其余按切换动画摆放；捏合时排成总览网格。
/// 位置来自核心给出的弹簧（`PanelState.nav`、`.overview`），每帧用同一时钟求值，跟手、打断、回弹都与核心的判定一致
struct PanelStack: View {
    let model: OverlayModel
    let state: PanelState
    let now: TimeInterval
    let reduceMotion: Bool
    @Environment(\.overlayStyle) private var style

    /// 深度堆叠：每深一层缩小、上移、模糊的量；翻过去的面板放大、下移、快速淡出
    static let depthShrink = 0.1
    static let depthRise: CGFloat = 36
    static let depthBlur = 4.0
    static let passedGrow = 0.2
    static let passedDrop: CGFloat = 30
    static let passedFade = 1.7
    /// 立体滚筒：相邻面板之间的角度、滚筒半径（面板高度的倍数）
    static let drumAngle = 40.0
    static let drumRadius = 0.95
    /// 立体滚筒：离开正面每一格的淡出量
    static let drumFade = 0.9
    /// 深度刻度：在面板右侧的距离与行距
    static let indicatorGap: CGFloat = 36
    static let indicatorRow: CGFloat = 28
    /// 唤起后过这么久才创建邻近面板：首帧只建当前面板的玻璃，弹开不卡
    static let neighborDelay: TimeInterval = 0.3
    static let neighborFadeIn: TimeInterval = 0.25

    var body: some View {
        let f = frame
        ZStack(alignment: .topLeading) {
            ForEach(Array(state.panels.enumerated()), id: \.element.id) { k, layout in
                if f.mounted(k) {
                    let t = f.transform(k, nav: style.nav)
                    let current = k == state.panelIndex
                    PanelView(layout: layout, size: state.size, slotGap: model.slotGap, current: current,
                              hovered: current && f.overview < 0.5 ? state.hovered : nil,
                              phase: current ? model.phase : .shown,
                              sliderValues: state.sliderValues, sliderBase: state.sliderBase,
                              pulses: current ? model.pulses : [:], presses: current ? model.presses : [:],
                              origin: nil, outside: current && f.outside)
                        .equatable()
                        // 后面的面板本来就模糊、半透明：不用毛玻璃（每块毛玻璃都要系统逐帧模糊背后的内容）
                        .environment(\.backdropGlass, current)
                        .scaleEffect(t.scale)
                        .rotation3DEffect(.degrees(t.tilt), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
                        .blur(radius: t.blur)
                        .offset(t.offset)
                        .opacity(t.opacity)
                        .zIndex(t.z)
                }
            }
            if f.overview > 0.05 {
                OverviewMarks(panels: state.panels, size: state.size, hovered: state.overviewHover)
                    .opacity(min(f.overview, 1) * f.stay)
                    .zIndex(50)
            }
            if let started = state.holdStartedAt, !model.phase.leaving, let center = holdCenter {
                HoldRing(progress: min(max((now - started) / max(state.holdDuration, 0.001), 0), 1))
                    .position(center)
                    .zIndex(60)
            }
            if state.panels.count > 1 {
                DepthIndicator(panels: state.panels, nav: f.nav, names: f.peek)
                    .opacity(f.chrome * (0.4 + 0.6 * f.peek))
                    .offset(x: state.size.width + Self.indicatorGap,
                            y: state.size.height / 2 - Double(state.panels.count) * Self.indicatorRow / 2)
                    .zIndex(70)
            }
            PanelTitle(name: state.layout.name, index: state.panelIndex, count: state.panels.count)
                .opacity(f.chrome * max(f.peek, f.titleFresh))
                .position(x: state.size.width / 2, y: -PanelMetrics.titleOffset)
                .zIndex(70)
        }
        .frame(width: state.size.width, height: state.size.height, alignment: .topLeading)
    }

    private var frame: StackFrame {
        StackFrame(state: state, now: now, reduceMotion: reduceMotion, phase: model.phase, phaseAt: model.phaseAt,
                   shownAt: model.shownAt)
    }

    /// 在关闭上按住时圆环的位置（当前面板，此时导航已停稳）
    private var holdCenter: CGPoint? {
        guard let id = state.hovered, let slot = state.layout.slot(id) else { return nil }
        let tester = HitTester(layout: state.layout, panelSize: state.size, slotGap: model.slotGap, hysteresis: 0)
        return ChipGeometry.of(slot, tester: tester).map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }
    }
}

/// 某一帧的堆栈参数：面板位置、总览进度、各种淡入淡出
@MainActor
struct StackFrame {
    let state: PanelState
    let now: TimeInterval
    let nav: Double
    let overview: Double
    /// 切换中（0–1）：显示邻近面板与各面板名
    let peek: Double
    /// 非当前面板与刻度、标题的整体可见度：唤起后淡入，退场时淡出
    let stay: Double
    let enter: Double
    /// 刻度与标题：总览时隐藏
    var chrome: Double { stay * enter * (1 - min(max(overview, 0), 1)) }
    /// 唤起后面板名先显示一会儿
    let titleFresh: Double
    let outside: Bool

    init(state: PanelState, now: TimeInterval, reduceMotion: Bool, phase: OverlayModel.Phase, phaseAt: TimeInterval,
         shownAt: TimeInterval) {
        self.state = state
        self.now = now
        // 减少动态效果：直接取弹簧终点（FR-8.10）
        nav = reduceMotion ? state.nav.target : state.nav.value(at: now)
        overview = reduceMotion ? state.overview.target : state.overview.value(at: now)
        let away = abs(nav - Double(state.panelIndex)) * 5 + abs(reduceMotion ? 0 : state.nav.velocity(at: now)) * 0.5
        peek = min(away, 1)
        let leave = phase.leaving ? min(max((now - phaseAt) / OverlayController.leaveDuration, 0), 1) : 0
        stay = 1 - leave * leave
        enter = min(max((now - shownAt - PanelStack.neighborDelay) / PanelStack.neighborFadeIn, 0), 1)
        titleFresh = min(max(PanelMetrics.titleDuration - (now - shownAt), 0), 1)
        outside = state.pointer.map { !CGRect(origin: .zero, size: state.size).contains($0) } ?? false
    }

    /// 只创建看得见的面板：当前面板一直在；邻近面板唤起一会儿后才创建；总览时全部创建
    func mounted(_ k: Int) -> Bool {
        if k == state.panelIndex || overview > 0.001 { return true }
        return enter > 0 && abs(Double(k) - nav) < 1.6
    }

    func transform(_ k: Int, nav style: NavStyle) -> PanelTransform {
        let d = Double(k) - nav
        var t = PanelTransform()
        // 越接近下一个面板的位置越依赖"切换中"：静止时后面的面板不显示
        let far = min(max((abs(d) - 0.5) * 2, 0), 1)
        let reveal = 1 - far * (1 - peek)
        switch style {
        case .drum:
            let a = d * PanelStack.drumAngle * .pi / 180
            t.tilt = -d * PanelStack.drumAngle
            t.offset.height = -sin(a) * state.size.height * PanelStack.drumRadius
            t.scale = 1 - (1 - cos(a)) * 0.6
            t.opacity = min(max(1 - abs(d) * PanelStack.drumFade, 0), 1) * reveal
        case .depth:
            if d >= 0 {
                t.scale = 1 - PanelStack.depthShrink * d
                t.offset.height = -PanelStack.depthRise * d
                t.blur = PanelStack.depthBlur * d
                t.opacity = (d < 1 ? 1 - 0.55 * d : max(0, 0.45 - 0.3 * (d - 1))) * reveal
            } else {
                t.scale = 1 + PanelStack.passedGrow * -d
                t.offset.height = PanelStack.passedDrop * -d
                t.blur = 3 * -d
                t.opacity = max(0, 1 + d * PanelStack.passedFade)
            }
        }
        t.z = 20 - abs(d) * 4 + (d < 0 ? 2 : 0)
        // 总览：从当前摆放过渡到网格，超出 1 时继续略微缩小（捏过头的阻力反馈）；张开超出 0 时略微放大
        let o = min(max(overview, 0), 1)
        if overview > 0 {
            let grid = OverviewGrid(count: state.panels.count, panelSize: state.size)
            let c = grid.center(of: k)
            let gx = c.x - state.size.width / 2, gy = c.y - state.size.height / 2
            t.offset = CGSize(width: t.offset.width * (1 - o) + gx * o, height: t.offset.height * (1 - o) + gy * o)
            t.scale = t.scale * (1 - o) + grid.scale * o - max(overview - 1, 0) * 0.1
            t.opacity = t.opacity * (1 - o) + o
            t.blur *= 1 - o
            t.tilt *= 1 - o
        } else if overview < 0 {
            t.scale *= 1 - overview * 0.08
        }
        if k != state.panelIndex { t.opacity *= max(enter, o) * stay }
        if t.opacity < 0.002 { t.opacity = 0 }
        return t
    }
}

/// 一个面板的全部按钮与主题装饰。可比较：堆栈逐帧只改外层的摆放，输入没变时不重算面板内部（性能实测，D28）
struct PanelView: View, Equatable {
    let layout: PanelLayout
    let size: CGSize
    let slotGap: Double
    let current: Bool
    let hovered: SlotID?
    let phase: OverlayModel.Phase
    let sliderValues: [SlotID: Double]
    let sliderBase: [SlotID: Double]
    let pulses: [SlotID: Int]
    let presses: [SlotID: Int]
    let origin: CGPoint?
    let outside: Bool
    @Environment(\.overlayStyle) private var style

    nonisolated static func == (a: PanelView, b: PanelView) -> Bool {
        a.layout == b.layout && a.size == b.size && a.slotGap == b.slotGap && a.current == b.current && a.hovered == b.hovered
            && a.phase == b.phase && a.sliderValues == b.sliderValues && a.sliderBase == b.sliderBase && a.pulses == b.pulses && a.presses == b.presses
            && a.origin == b.origin && a.outside == b.outside
    }

    var body: some View {
        let tester = HitTester(layout: layout, panelSize: size, slotGap: slotGap, hysteresis: 0)
        let chips = layout.slots.compactMap { slot in ChipGeometry.of(slot, tester: tester).map { (slot: slot, geometry: $0) } }
        let origin = origin ?? tester.center
        let farthest = chips.map { hypot($0.geometry.frame.midX - origin.x, $0.geometry.frame.midY - origin.y) }.max() ?? 1
        let lit = chips.first { $0.slot.id == (phase.chosen ?? hovered) && !$0.slot.isCancel }
        let fading: Bool = { if case .dissolving = phase { true } else { phase == .collapsing } }()
        ZStack(alignment: .topLeading) {
            if style.theme == .holo {
                HoloDecor(size: size, ring: layout.isRing, accent: style.accent)
                    .opacity(phase.appeared && !phase.leaving ? 1 : 0)
                    .animation(.easeOut(duration: 0.25), value: phase)
            }
            if style.theme == .lens {
                LensGlass(target: fading ? nil : lit?.geometry, slider: lit.map { $0.slot.slider != nil || $0.slot.widget != nil } ?? false,
                          accent: style.accent)
            }
            ForEach(chips, id: \.slot.id) { chip in
                ChipView(slot: chip.slot, geometry: chip.geometry, hovered: hovered == chip.slot.id,
                         value: sliderValues[chip.slot.id], base: sliderBase[chip.slot.id], pulse: pulses[chip.slot.id] ?? 0,
                         presses: presses[chip.slot.id] ?? 0, phase: phase, origin: origin, groupCenter: tester.center,
                         delay: PanelMetrics.enterStagger * hypot(chip.geometry.frame.midX - origin.x,
                                                                  chip.geometry.frame.midY - origin.y) / max(farthest, 1))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .opacity(outside && !phase.leaving ? PanelMetrics.outsideGroupOpacity : 1)
        .animation(.easeOut(duration: 0.15), value: outside)
    }
}

/// 液态光斑主题：一块共享的玻璃跟着悬停在按钮之间流动（弹簧略欠阻尼，移动时带一点拉伸感）
private struct LensGlass: View {
    let target: ChipGeometry?
    let slider: Bool
    let accent: Color
    @State private var last: ChipGeometry?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let g = target ?? last {
                let round = g.kind != .tile
                let rect = round ? g.scaled(1.25).frame : g.frame.insetBy(dx: 4, dy: 4)
                let shape = RoundedRectangle(cornerRadius: round ? rect.width / 2 : (slider ? 26 : 24), style: .continuous)
                shape.fill(Color.white.opacity(0.11))
                    .background(shape.fill(.ultraThinMaterial).opacity(PanelMetrics.materialOpacity + 0.2))
                    .overlay(shape.strokeBorder(Color.white.opacity(0.32), lineWidth: 0.5))
                    .overlay(alignment: .top) {
                        // 顶部一道高光
                        shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center),
                                           lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 7)
                    .shadow(color: accent.opacity(0.3), radius: 22)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .opacity(target == nil ? 0 : 1)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: target)
        .onChange(of: target) { _, new in
            if let new { last = new }
        }
        .allowsHitTesting(false)
    }
}

/// 全息主题的面板装饰：点阵底与四角取景框
private struct HoloDecor: View {
    let size: CGSize
    let ring: Bool
    let accent: Color

    static let margin: CGFloat = 18
    static let spacing: CGFloat = 14
    static let bracket: CGFloat = 22

    var body: some View {
        let m = Self.margin
        let rect = CGRect(x: -m, y: -m, width: size.width + 2 * m, height: size.height + 2 * m)
        Canvas { ctx, _ in
            let clip = ring ? Path(ellipseIn: rect.offsetBy(dx: m, dy: m)) : Path(roundedRect: rect.offsetBy(dx: m, dy: m), cornerRadius: 6)
            ctx.clip(to: clip)
            var dots = Path()
            var y = Self.spacing / 2
            while y < rect.height {
                var x = Self.spacing / 2
                while x < rect.width {
                    dots.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                    x += Self.spacing
                }
                y += Self.spacing
            }
            ctx.fill(dots, with: .color(accent.opacity(0.16)))
        }
        .frame(width: rect.width, height: rect.height)
        .overlay {
            CornerBrackets(length: Self.bracket, inset: 0).stroke(accent.opacity(0.6), lineWidth: 1)
        }
        .offset(x: -m, y: -m)
        .allowsHitTesting(false)
    }
}

/// 四角的 L 形角标
struct CornerBrackets: Shape {
    var length: CGFloat
    var inset: CGFloat

    var animatableData: CGFloat {
        get { inset }
        set { inset = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset), l = min(length, r.width / 2, r.height / 2)
        var p = Path()
        for (corner, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                                 (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0)] {
            p.move(to: CGPoint(x: corner.x, y: corner.y + dy * l))
            p.addLine(to: corner)
            p.addLine(to: CGPoint(x: corner.x + dx * l, y: corner.y))
        }
        return p
    }
}

/// 总览：每个缩略图外的选择框与面板名
private struct OverviewMarks: View {
    let panels: [PanelLayout]
    let size: CGSize
    let hovered: Int?
    @Environment(\.overlayStyle) private var style

    var body: some View {
        let grid = OverviewGrid(count: panels.count, panelSize: size)
        let w = size.width * grid.scale, h = size.height * grid.scale
        ZStack(alignment: .topLeading) {
            ForEach(Array(panels.enumerated()), id: \.element.id) { k, layout in
                let c = grid.center(of: k), lit = hovered == k
                let shape = RoundedRectangle(cornerRadius: style.theme == .holo ? 4 : 16, style: .continuous)
                shape.strokeBorder(lit ? style.accent : Color.white.opacity(0.18), lineWidth: lit ? 2 : 1)
                    .frame(width: w + 20, height: h + 20)
                    .position(c)
                    .animation(.easeOut(duration: 0.15), value: lit)
                Text(style.theme == .holo ? layout.name.uppercased() : layout.name)
                    .font(style.theme == .holo ? .system(size: 11.5, design: .monospaced) : .system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(lit ? 0.95 : 0.6))
                    .shadow(color: .black.opacity(PanelMetrics.labelShadowOpacity), radius: 4)
                    .fixedSize()
                    .position(x: c.x, y: c.y + h / 2 + 22)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// 在关闭上按住：强调色圆环逐渐充满，满了进入编辑（D23）
private struct HoldRing: View {
    let progress: Double
    @Environment(\.overlayStyle) private var style

    static let diameter: CGFloat = 64

    var body: some View {
        Circle()
            .trim(from: 0, to: progress)
            .stroke(style.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .shadow(color: style.accent.opacity(0.7), radius: 6)
            .frame(width: Self.diameter, height: Self.diameter)
            .allowsHitTesting(false)
    }
}

/// 面板右侧的深度刻度：静止时只有淡淡的点，切换中显示各面板名
private struct DepthIndicator: View {
    let panels: [PanelLayout]
    let nav: Double
    /// 各面板名的可见度：切换中才显示
    let names: Double
    @Environment(\.overlayStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(panels.enumerated()), id: \.element.id) { k, layout in
                let near = min(max(1 - abs(Double(k) - nav), 0), 1)
                HStack(spacing: 10) {
                    let d = 5 + 3 * near
                    Group {
                        if style.theme == .holo {
                            Rectangle().fill(style.accent.opacity(0.4 + 0.6 * near))
                        } else {
                            Circle().fill(near > 0.5 ? style.accent : Color.white.opacity(0.5))
                        }
                    }
                    .frame(width: d, height: d)
                    .frame(width: 8)
                    Text(layout.name)
                        .font(style.theme == .holo ? .system(size: 11.5, design: .monospaced) : .system(size: 12))
                        .foregroundStyle(.white.opacity(0.5 + 0.45 * near))
                        .shadow(color: .black.opacity(PanelMetrics.labelShadowOpacity), radius: 4)
                        .opacity(names)
                        .fixedSize()
                }
                .frame(height: PanelStack.indicatorRow)
            }
        }
        .fixedSize()
        .allowsHitTesting(false)
    }
}

/// 面板上方的面板名
private struct PanelTitle: View {
    let name: String
    let index: Int
    let count: Int
    @Environment(\.overlayStyle) private var style

    var body: some View {
        Group {
            if style.theme == .holo {
                Text("// \(name.uppercased())  \(String(format: "%02d/%02d", index + 1, count))")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(style.accent.opacity(0.85))
            } else {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .tracking(0.5)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .shadow(color: .black.opacity(PanelMetrics.labelShadowOpacity), radius: 6)
        .fixedSize()
        .allowsHitTesting(false)
    }
}

extension Motion {
    /// 停稳的时刻：从起点按显示帧往后找；周期很长的弹簧最多找 `settleSearch` 秒
    static let settleStep: TimeInterval = 1.0 / 120
    static let settleSearch: TimeInterval = 4

    var settledAt: TimeInterval {
        var t = start
        while !isSettled(at: t) && t - start < Self.settleSearch { t += Self.settleStep }
        return t
    }
}
