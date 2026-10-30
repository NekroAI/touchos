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

    /// 深度堆叠：每深一层缩小、下移、模糊的量；翻过去的面板放大、上移、快速淡出。
    /// 后面的面板排在下方，与右侧刻度从上到下的顺序一致；双指上推时整摞面板跟着手指上移（D32）
    static let depthShrink = 0.1
    static let depthDrop: CGFloat = 36
    static let depthBlur = 4.0
    static let passedGrow = 0.2
    static let passedRise: CGFloat = 30
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
                    // 各面板按自己的网格大小画（D29），与参考大小同中心
                    PanelView(layout: layout, size: f.frame(k).size, slotGap: model.slotGap, current: current,
                              hovered: current && f.overview < 0.5 ? state.hovered : nil,
                              phase: current ? model.phase : .shown,
                              sliderValues: state.sliderValues, sliderBase: state.sliderBase,
                              pulses: current ? model.pulses : [:], presses: current ? model.presses : [:],
                              origin: nil, outside: current && f.outside)
                        .equatable()
                        // 后面的面板本来就模糊、半透明：不用毛玻璃（每块毛玻璃都要系统逐帧模糊背后的内容）
                        .environment(\.backdropGlass, current)
                        .frame(width: state.size.width, height: state.size.height)
                        .scaleEffect(t.scale)
                        .rotation3DEffect(.degrees(t.tilt), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
                        .blur(radius: t.blur)
                        .offset(t.offset)
                        .opacity(t.opacity)
                        .zIndex(t.z)
                }
            }
            if f.overview > 0.05 {
                OverviewMarks(panels: state.panels, frames: state.panels.indices.map(f.frame), size: state.size,
                              hovered: state.overviewHover)
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
                    .offset(x: (state.frames.map(\.maxX).max() ?? state.size.width) + Self.indicatorGap,
                            y: state.size.height / 2 - Double(state.panels.count) * Self.indicatorRow / 2)
                    .zIndex(70)
            }
            PanelTitle(name: state.layout.name, index: state.panelIndex, count: state.panels.count)
                .opacity(f.chrome * max(f.peek, f.titleFresh))
                .position(x: state.size.width / 2, y: frame.frame(state.panelIndex).minY - PanelMetrics.titleOffset)
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
        let panel = frame.frame(state.panelIndex)
        let tester = HitTester(layout: state.layout, panelSize: panel.size, slotGap: model.slotGap, hysteresis: 0)
        return ChipGeometry.of(slot, tester: tester).map { CGPoint(x: panel.minX + $0.frame.midX, y: panel.minY + $0.frame.midY) }
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
        outside = state.pointer.map { !state.area.contains($0) } ?? false
    }

    /// 第 `k` 个面板在参考坐标里的位置（D29）
    func frame(_ k: Int) -> CGRect {
        state.frames.indices.contains(k) ? state.frames[k] : CGRect(origin: .zero, size: state.size)
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
            // 后面的面板在滚筒下方（D32）
            t.tilt = d * PanelStack.drumAngle
            t.offset.height = sin(a) * state.size.height * PanelStack.drumRadius
            t.scale = 1 - (1 - cos(a)) * 0.6
            t.opacity = min(max(1 - abs(d) * PanelStack.drumFade, 0), 1) * reveal
        case .depth:
            if d >= 0 {
                t.scale = 1 - PanelStack.depthShrink * d
                t.offset.height = PanelStack.depthDrop * d
                t.blur = PanelStack.depthBlur * d
                t.opacity = (d < 1 ? 1 - 0.55 * d : max(0, 0.45 - 0.3 * (d - 1))) * reveal
            } else {
                t.scale = 1 + PanelStack.passedGrow * -d
                t.offset.height = -PanelStack.passedRise * -d
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
            // 比参考大小大的面板在格子里再缩小，不压到相邻的缩略图
            let own = frame(k).size
            let fit = min(1, state.size.width / max(own.width, 1), state.size.height / max(own.height, 1))
            t.scale = t.scale * (1 - o) + grid.scale * fit * o - max(overview - 1, 0) * 0.1
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
                Group {
                    if layout.isRing {
                        HoloRadar(size: size, layout: layout, hovered: phase.chosen ?? hovered, accent: style.accent)
                    } else {
                        HoloDecor(size: size, accent: style.accent)
                    }
                }
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

/// 液态光斑主题：一团强调色的柔光跟着悬停在按钮之间流动（弹簧略欠阻尼，移动时带一点拉伸感）。
/// 原来是一块灰色玻璃，负责人反馈不好看，改为从中心向外渐隐的光（D34）；只用渐变，不做实时模糊与阴影
private struct LensGlass: View {
    let target: ChipGeometry?
    let slider: Bool
    let accent: Color
    @State private var last: ChipGeometry?

    /// 光斑直径：图标外圈（`LensFace.glyphRing` 54）的两倍；圆形按钮为按钮直径的两倍。中心亮度
    static let spot: CGFloat = 108
    static let roundSpread: CGFloat = 2
    static let core = 0.8
    /// 格子里图标的中心在格子中心之上：图标加名称高 62，图标 28 → 上移 (62 − 28) / 2
    static let glyphLift: CGFloat = 17

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let g = target ?? last {
                let round = g.kind != .tile
                // 落在图标后面；滑杆铺满整条
                let d = round ? min(g.frame.width, g.frame.height) * Self.roundSpread : Self.spot
                let rect = slider ? g.frame.insetBy(dx: -10, dy: -10)
                    : CGRect(x: g.frame.midX - d / 2, y: g.frame.midY - d / 2 - (round ? 0 : Self.glyphLift), width: d, height: d)
                EllipticalGradient(stops: [.init(color: accent.opacity(Self.core), location: 0),
                                           .init(color: accent.opacity(Self.core * 0.5), location: 0.3),
                                           .init(color: accent.opacity(0), location: 1)],
                                   center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
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
    let accent: Color

    static let margin: CGFloat = 18
    static let spacing: CGFloat = 14
    static let bracket: CGFloat = 22
    /// 深色"显示屏"底板：透明线框压不住身后的窗口文字（负责人反馈可读性差，D34）
    static let screen = Color(.sRGB, red: 0.02, green: 0.05, blue: 0.07)
    static let screenOpacity = 0.8

    var body: some View {
        let m = Self.margin
        let rect = CGRect(x: -m, y: -m, width: size.width + 2 * m, height: size.height + 2 * m)
        Canvas { ctx, _ in
            let clip = Path(roundedRect: rect.offsetBy(dx: m, dy: m), cornerRadius: 6)
            ctx.clip(to: clip)
            ctx.fill(clip, with: .color(Self.screen.opacity(Self.screenOpacity)))
            ctx.stroke(clip, with: .color(accent.opacity(0.22)), lineWidth: 1)
            ctx.fill(Self.dots(in: rect.size), with: .color(accent.opacity(0.12)))
        }
        .frame(width: rect.width, height: rect.height)
        .overlay {
            CornerBrackets(length: Self.bracket, inset: 0).stroke(accent.opacity(0.6), lineWidth: 1)
        }
        .offset(x: -m, y: -m)
        .allowsHitTesting(false)
    }

    /// 点阵底：间距 `spacing`，直径 2 pt
    static func dots(in size: CGSize) -> Path {
        var dots = Path()
        var y = spacing / 2
        while y < size.height {
            var x = spacing / 2
            while x < size.width {
                dots.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                x += spacing
            }
            y += spacing
        }
        return dots
    }
}

/// 全息主题的环形面板：雷达表盘。环形按离圆心的距离与角度判定，是正圆，不随面板宽高比压成椭圆（D42）。
/// 外圈刻度环，各方向的分界画长刻度；内圈虚线表示中心区；悬停时外圈对应方向的那段弧点亮
private struct HoloRadar: View {
    let size: CGSize
    let layout: PanelLayout
    let hovered: SlotID?
    let accent: Color

    /// 底板比判定圆向外多出的宽度；刻度长短；悬停弧线宽
    static let margin: CGFloat = 18
    static let minorTick: CGFloat = 4
    static let majorTick: CGFloat = 12
    static let tickStep = 5.0
    static let arcWidth: CGFloat = 3

    var body: some View {
        let unit = min(size.width, size.height) / 2
        let radius = unit + Self.margin
        let center = CGPoint(x: radius, y: radius)
        let sectors = layout.slots.compactMap { slot -> (id: SlotID, sector: Sector)? in
            if case .sector(let s) = slot.shape { (slot.id, s) } else { nil }
        }
        let items = sectors.filter { !$0.sector.isFullCircle }
        let inner = items.first?.sector.innerRadius ?? 0
        let centerID = sectors.first { $0.sector.isFullCircle }?.id
        ZStack {
            RadarDial(radius: radius, inner: inner * unit, bounds: items.map(\.sector.startAngle), accent: accent)
            ForEach(items, id: \.id) { item in
                Path { p in
                    p.addArc(center: center, radius: radius - Self.arcWidth, startAngle: .degrees(item.sector.startAngle - 90),
                             endAngle: .degrees(item.sector.endAngle - 90), clockwise: false)
                }
                .stroke(accent, style: StrokeStyle(lineWidth: Self.arcWidth, lineCap: .round))
                .opacity(hovered == item.id ? 0.9 : 0)
            }
            Circle()
                .stroke(accent, lineWidth: 1.5)
                .frame(width: 2 * inner * unit, height: 2 * inner * unit)
                .opacity(centerID != nil && hovered == centerID ? 0.8 : 0)
        }
        .animation(.easeOut(duration: 0.15), value: hovered)
        .frame(width: 2 * radius, height: 2 * radius)
        .overlay {
            CornerBrackets(length: HoloDecor.bracket, inset: 0).stroke(accent.opacity(0.6), lineWidth: 1)
        }
        .position(x: size.width / 2, y: size.height / 2)
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}

/// 雷达表盘的静态部分：输入不变时不重画（悬停只改上层的弧）
private struct RadarDial: View, Equatable {
    let radius: CGFloat
    let inner: CGFloat
    /// 各方向扇区的起始角（0 为正上方，顺时针）
    let bounds: [Double]
    let accent: Color

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let disk = Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: 2 * radius, height: 2 * radius))
            ctx.fill(disk, with: .color(HoloDecor.screen.opacity(HoloDecor.screenOpacity)))
            var dots = ctx
            dots.clip(to: disk)
            dots.fill(HoloDecor.dots(in: size), with: .color(accent.opacity(0.12)))
            ctx.stroke(disk, with: .color(accent.opacity(0.3)), lineWidth: 1)
            func tick(_ deg: Double, _ length: CGFloat) -> Path {
                let a = (deg - 90) * .pi / 180
                var p = Path()
                p.move(to: CGPoint(x: c.x + cos(a) * radius, y: c.y + sin(a) * radius))
                p.addLine(to: CGPoint(x: c.x + cos(a) * (radius - length), y: c.y + sin(a) * (radius - length)))
                return p
            }
            var minor = Path()
            for deg in stride(from: 0.0, to: 360, by: HoloRadar.tickStep) { minor.addPath(tick(deg, HoloRadar.minorTick)) }
            ctx.stroke(minor, with: .color(accent.opacity(0.22)), lineWidth: 1)
            var major = Path()
            for deg in bounds { major.addPath(tick(deg, HoloRadar.majorTick)) }
            ctx.stroke(major, with: .color(accent.opacity(0.55)), lineWidth: 1)
            if inner > 0 {
                let ring = Path(ellipseIn: CGRect(x: c.x - inner, y: c.y - inner, width: 2 * inner, height: 2 * inner))
                ctx.stroke(ring, with: .color(accent.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            }
        }
        .frame(width: 2 * radius, height: 2 * radius)
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
    /// 各面板的实际大小（D29）：框按面板本身的大小画，与缩略图一致
    let frames: [CGRect]
    let size: CGSize
    let hovered: Int?
    @Environment(\.overlayStyle) private var style

    var body: some View {
        let grid = OverviewGrid(count: panels.count, panelSize: size)
        let h = size.height * grid.scale
        ZStack(alignment: .topLeading) {
            ForEach(Array(panels.enumerated()), id: \.element.id) { k, layout in
                let c = grid.center(of: k), lit = hovered == k
                let own = frames[k].size
                let fit = min(1, size.width / max(own.width, 1), size.height / max(own.height, 1)) * grid.scale
                let shape = RoundedRectangle(cornerRadius: style.theme == .holo ? 4 : 16, style: .continuous)
                shape.strokeBorder(lit ? style.accent : Color.white.opacity(0.18), lineWidth: lit ? 2 : 1)
                    .frame(width: own.width * fit + 20, height: own.height * fit + 20)
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
                    // 与按钮名称同样的预渲染深色衬底（D28），不用实时阴影
                    Text(layout.name)
                        .font(style.theme == .holo ? .system(size: 11.5, design: .monospaced) : .system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .floatingLabel("indicator|\(style.theme == .holo)|\(layout.name)")
                        .opacity(0.6 + 0.4 * near)
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
