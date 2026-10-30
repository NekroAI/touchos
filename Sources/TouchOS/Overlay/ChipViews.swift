import SwiftUI
import TouchOSCore

/// 一枚按钮：动效（弹开、悬停、按压回弹、提交、收拢）与主题无关，外观交给各主题的 `Face`
struct ChipView: View {
    let slot: Slot
    let geometry: ChipGeometry
    let hovered: Bool
    let value: Double?
    /// 滑杆调整前的值：显示原位置与差值（D29）
    let base: Double?
    let pulse: Int
    let presses: Int
    let phase: OverlayModel.Phase
    /// 唤起位置与按钮组中心（按钮组 pt）
    let origin: CGPoint
    let groupCenter: CGPoint
    /// 弹开时的延迟
    let delay: TimeInterval
    @Environment(\.overlayStyle) private var style

    var body: some View {
        let g = geometry
        let face = FaceKind(slot: slot, geometry: g)
        Face(kind: face, slot: slot, size: g.frame.size, lit: hovered || chosen, value: value, base: base)
            .frame(width: g.frame.width, height: g.frame.height)
            // 波纹与连按计数贴着各主题实际画出来的按钮轮廓（`chipBody`），不按单元格估算
            .overlayPreferenceValue(ChipBodyKey.self) { body in
                if let body {
                    GeometryReader { proxy in
                        let r = proxy[body.bounds]
                        Ripple(trigger: pulse, shape: body.shape, size: r.size)
                            .position(x: r.midX, y: r.midY)
                        if presses >= 2 {
                            PressBadge(count: presses).position(body.shape.badgePoint(in: r))
                        }
                    }
                }
            }
            .keyframeAnimator(initialValue: CGFloat(1), trigger: pulse) { content, k in
                content.scaleEffect(k)
            } keyframes: { _ in
                // 不用时长为 0 的关键帧：其插值进度为 0/0，曾产生 NaN 导致崩溃（m0-report.md）
                CubicKeyframe(PanelMetrics.pressScale, duration: PanelMetrics.pressDown)
                SpringKeyframe(1, duration: PanelMetrics.pressRelease)
            }
            .scaleEffect(scale(face))
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

    private func scale(_ face: FaceKind) -> CGFloat {
        let size = geometry.frame.size
        if !phase.appeared { return PanelMetrics.enterScale }
        if chosen {
            return dissolving ? PanelMetrics.dissolveScale
                : PanelMetrics.scale(PanelMetrics.commitScale, for: size, maxGrow: PanelMetrics.commitGrowMax)
        }
        if phase.leaving { return PanelMetrics.collapseScale }
        // 只有液态光斑靠放大表现悬停；玻璃圆钮由圆钮变大变色、全息线框由角标展开表现
        guard hovered, style.theme == .lens, face == .tile || face == .round else { return 1 }
        return PanelMetrics.scale(PanelMetrics.hoverScale, for: size, maxGrow: PanelMetrics.hoverGrowMax)
    }

    private var opacity: Double {
        if !phase.appeared { return 0 }
        if chosen { return dissolving ? 0 : 1 }
        return phase.leaving ? 0 : 1
    }

    private var offset: CGSize {
        let c = CGPoint(x: geometry.frame.midX, y: geometry.frame.midY)
        if !phase.appeared {
            // 中心的关闭是整组的锚点，原地淡入，不随唤起位置偏移（负责人反馈：出场时中心会偏一下）
            if geometry.kind == .cancel { return .zero }
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

/// 按钮的种类决定画法
enum FaceKind: Equatable {
    case close, slider, widget, round, tile

    init(slot: Slot, geometry: ChipGeometry) {
        if geometry.kind == .cancel { self = .close }
        else if slot.widget != nil { self = .widget }
        else if slot.slider != nil { self = .slider }
        else if geometry.kind == .round { self = .round }
        else { self = .tile }
    }
}

private struct Face: View {
    let kind: FaceKind
    let slot: Slot
    let size: CGSize
    let lit: Bool
    let value: Double?
    let base: Double?
    @Environment(\.overlayStyle) private var style

    var body: some View {
        let slider = SliderReading(value: value ?? 0, base: base)
        switch style.theme {
        case .orb: OrbFace(kind: kind, slot: slot, size: size, lit: lit, slider: slider, accent: style.accent)
        case .lens: LensFace(kind: kind, slot: slot, size: size, lit: lit, slider: slider, accent: style.accent)
        case .holo: HoloFace(kind: kind, slot: slot, size: size, lit: lit, slider: slider, accent: style.accent)
        }
    }
}

// MARK: 公用小件


/// 按钮中间的图形：图标；没有图标时直接画名称（数字键、符号键，D30），名称越长字越小
private struct Glyph: View {
    let slot: Slot
    let size: CGFloat
    var weight: Font.Weight = .medium

    /// 没有图标：名称画在按钮中间，下方不再重复显示名称
    static func isText(_ slot: Slot) -> Bool { slot.symbol.isEmpty }

    var body: some View {
        if Self.isText(slot) {
            let n = slot.title.count
            Text(slot.title)
                .font(.system(size: n <= 1 ? size * 1.15 : n <= 3 ? size * 0.85 : size * 0.6, weight: weight, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.5)
        } else {
            Image(systemName: slot.symbol).font(.system(size: size, weight: weight))
        }
    }
}

/// 竖向滑杆的上下端与同几行里的按钮对齐，不凸出到格子边缘（负责人反馈）：
/// 按每行的高度与按钮实际画出的高度算出两端各收进多少。不是网格槽位时只留默认边距
private func verticalSliderInset(_ slot: Slot, height: CGFloat, tile: CGFloat, minimum: CGFloat) -> CGFloat {
    guard case .cell(let c) = slot.shape, c.rowSpan > 0 else { return minimum }
    let row = (height + 2 * PanelMetrics.chipInset) / CGFloat(c.rowSpan)
    return max((row - tile) / 2 - PanelMetrics.chipInset, minimum)
}

/// 滑杆的读数：当前值与调整前的值（D29）
struct SliderReading: Equatable {
    let value: Double
    let base: Double?

    var percent: Int { Int((value * 100).rounded()) }
    /// 与调整前相差的百分点；没有调整时为 nil
    var delta: Int? {
        guard let base else { return nil }
        let d = percent - Int((base * 100).rounded())
        return d == 0 ? nil : d
    }
    var deltaText: String { delta.map { $0 > 0 ? "+\($0)" : "\($0)" } ?? "" }
    var key: String { "\(percent)|\(deltaText)" }
}

/// 滑杆的读数文字：百分比，调整中在旁边（竖向在下方）用强调色标出差值
private struct SliderReadout: View {
    let reading: SliderReading
    let vertical: Bool
    let accent: Color
    var text: (String) -> Text = { Text($0).font(.system(size: 12).monospacedDigit()) }

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 5))
        layout {
            text("\(reading.percent)%")
            if reading.delta != nil { text(reading.deltaText).foregroundStyle(accent) }
        }
    }
}

/// 滑杆的填充：横向从左、纵向从下。调整中在原位置留一道参考线；调小时减掉的部分留淡影（D29）。
/// 调整生效（基准换成新值）时参考线滑到新位置再淡出，让人看到确实变了
private struct FillBar: View {
    let value: Double
    var base: Double?
    let color: Color

    static let tick: CGFloat = 2
    /// 参考线移到新位置的弹簧；到位后淡出的延迟与时长
    static let settle = Animation.spring(response: 0.38, dampingFraction: 0.78)
    static let fadeDelay = 0.35
    static let fadeDuration = 0.3

    var body: some View {
        GeometryReader { g in
            let vertical = g.size.height > g.size.width
            let length = vertical ? g.size.height : g.size.width
            let moved = base.map { abs($0 - value) >= 0.005 } ?? false
            let mark = base ?? value
            ZStack(alignment: vertical ? .bottom : .leading) {
                bar(max(mark, value), length, vertical, g.size, color.opacity(0.32))
                    .opacity(moved && mark > value ? 1 : 0)
                bar(value, length, vertical, g.size, color)
                    .animation(.easeOut(duration: 0.06), value: value)
                Rectangle().fill(Color.white.opacity(0.9))
                    .frame(width: vertical ? g.size.width : Self.tick, height: vertical ? Self.tick : g.size.height)
                    .offset(x: vertical ? 0 : mark * length - Self.tick / 2, y: vertical ? -(mark * length - Self.tick / 2) : 0)
                    .animation(Self.settle, value: mark)
                    .opacity(moved ? 1 : 0)
                    .animation(moved ? .easeOut(duration: 0.1) : .easeOut(duration: Self.fadeDuration).delay(Self.fadeDelay), value: moved)
            }
            .frame(width: g.size.width, height: g.size.height, alignment: vertical ? .bottom : .leading)
        }
    }

    private func bar(_ v: Double, _ length: CGFloat, _ vertical: Bool, _ size: CGSize, _ color: Color) -> some View {
        Rectangle().fill(color).frame(width: vertical ? size.width : v * length, height: vertical ? v * length : size.height)
    }
}

/// 文字衬底：深色字形的宽晕、贴边的晕与细阴影，第一次出现时离线渲染成图片并缓存，浮层里只贴图片。
/// 不在浮层里实时模糊：面板缩放、移动、淡入淡出时每个名称的模糊都要逐帧重做，是展开、收起、切换卡顿的主因；
/// 改成 `drawingGroup` 又会在透明的浮层窗口里丢掉衬底（性能实测与负责人反馈，D28）
private struct FloatingLabel<Glyphs: View>: ViewModifier {
    let key: String
    let glyphs: Glyphs

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { g in
                if let image = LabelGlow.image(key, size: g.size, glyphs: glyphs) {
                    let m = PanelMetrics.labelBitmapMargin
                    Image(nsImage: image)
                        .frame(width: g.size.width + 2 * m, height: g.size.height + 2 * m)
                        .offset(x: -m, y: -m)
                }
            }
        }
    }
}

@MainActor
private enum LabelGlow {
    /// 缓存上限：超出时清空重来（名称、点亮状态、滑杆数值的组合）
    static let limit = 400
    private static var cache: [String: NSImage] = [:]

    static func image<V: View>(_ key: String, size: CGSize, glyphs: V) -> NSImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let full = "\(key)|\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
        if let hit = cache[full] { return hit }
        let glyph = glyphs.colorMultiply(.black)
        let layers = ZStack {
            // 外层宽而淡的晕压住背景的纹理，内层贴着笔画勾出轮廓，最后一层细阴影
            glyph.blur(radius: PanelMetrics.labelHaloRadius).opacity(PanelMetrics.labelHaloOpacity)
            glyph.blur(radius: PanelMetrics.labelGlowRadius).opacity(PanelMetrics.labelGlowOpacity)
            glyph.blur(radius: PanelMetrics.labelShadowRadius).offset(y: PanelMetrics.labelShadowDrop).opacity(PanelMetrics.labelShadowOpacity)
        }
        .frame(width: size.width, height: size.height)
        .padding(PanelMetrics.labelBitmapMargin)
        let renderer = ImageRenderer(content: layers)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        renderer.scale = scale
        guard let cg = renderer.cgImage else { return nil }
        let image = NSImage(cgImage: cg, size: CGSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))
        if cache.count >= limit { cache.removeAll() }
        cache[full] = image
        return image
    }
}

/// 毛玻璃底：只保留一部分强度，叠一层底色
private struct Glass<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color
    let edge: Double
    let glow: Color?
    @Environment(\.backdropGlass) private var backdrop

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    if backdrop {
                        shape.fill(.ultraThinMaterial).opacity(PanelMetrics.materialOpacity)
                    } else {
                        shape.fill(PanelMetrics.flatGlass)
                    }
                    shape.fill(tint)
                }
            }
            .overlay(shape.strokeBorder(Color.white.opacity(edge), lineWidth: 0.5))
            .shadow(color: glow?.opacity(0.45) ?? .black.opacity(0.25), radius: glow == nil ? 9 : 15, y: glow == nil ? 3 : 5)
    }
}

private extension View {
    func glass<S: InsettableShape>(_ shape: S, tint: Color, edge: Double, glow: Color? = nil) -> some View {
        modifier(Glass(shape: shape, tint: tint, edge: edge, glow: glow))
    }
}

extension View {
    /// 直接浮在桌面上的文字：身后衬一层模糊的深色字形，只贴着笔画，没有底框（负责人反馈：被桌面干扰，但不要框）。
    /// `key` 标识这段文字的内容与状态（名称、点亮与否、数值），预渲染的衬底按它缓存
    func floatingLabel(_ key: String) -> some View {
        modifier(FloatingLabel(key: key, glyphs: self))
    }
}

/// 正在播放卡片的占位内容（K9 接入系统正在播放信息之前）
private enum NowPlaying {
    static let title = "正在播放"
    static let subtitle = "按下播放 / 暂停"
}

// MARK: B · 玻璃圆钮

private struct OrbFace: View {
    let kind: FaceKind
    let slot: Slot
    let size: CGSize
    let lit: Bool
    let slider: SliderReading
    let accent: Color

    static let orb: CGFloat = 58
    static let orbLit: CGFloat = 66
    /// 卡片里圆钮下方留给名称的高度（间距加一行字）
    static let labelSpacing: CGFloat = 8
    static let labelRoom: CGFloat = 30
    static let sliderHeight: CGFloat = 60
    /// 卡片里圆钮加名称实际画出的高度（竖向滑杆按它对齐）
    static let tileHeight: CGFloat = orb + labelSpacing + 14

    var body: some View {
        switch kind {
        case .close:
            Circle().fill(Color.black.opacity(lit ? 0.55 : 0.38))
                .overlay(Circle().strokeBorder(Color.white.opacity(lit ? 0.6 : 0.3), lineWidth: 0.5))
                .overlay(Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white))
                .frame(width: PanelMetrics.cancelChipSize, height: PanelMetrics.cancelChipSize)
                .chipBody(.circle)
                .overlay(alignment: .bottom) { EditHint(visible: lit).offset(y: 24) }
        case .tile:
            let room = min(size.width, size.height - Self.labelRoom)
            let d = min(lit ? Self.orbLit : Self.orb, room)
            VStack(spacing: Self.labelSpacing) {
                orb(d)
                Text(slot.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(lit ? 0.98 : 0.68))
                    .lineLimit(1)
                    .floatingLabel("orb.tile|\(slot.title)|\(lit)")
                    .opacity(Glyph.isText(slot) ? 0 : 1)  // 占位：与同一行的按钮对齐
            }
        case .round:
            orb(min(size.width, size.height) * (lit ? 1.1 : 1))
                .overlay(alignment: .bottom) {
                    Text(slot.title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(lit ? 0.98 : 0.68))
                        .fixedSize().floatingLabel("orb.round|\(slot.title)|\(lit)").offset(y: PanelMetrics.roundTitleOffset)
                        .opacity(Glyph.isText(slot) ? 0 : 1)
                }
        case .slider:
            let shape = Capsule()
            let vertical = size.height > size.width
            let long = vertical
                ? max(size.height - 2 * verticalSliderInset(slot, height: size.height, tile: Self.tileHeight, minimum: 8), 0)
                : max(size.width - 16, 0)
            let thick = min(Self.sliderHeight, max((vertical ? size.width : size.height) - 16, 0))
            ZStack {
                FillBar(value: slider.value, base: slider.base, color: lit ? accent.opacity(0.6) : Color.white.opacity(0.16)).clipShape(shape)
                if vertical {
                    VStack(spacing: 6) {
                        SliderReadout(reading: slider, vertical: true, accent: .white).opacity(0.75)
                        Spacer(minLength: 4)
                        Image(systemName: slot.symbol).font(.system(size: 18, weight: .medium))
                        Text(slot.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .padding(.vertical, 20)
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: slot.symbol).font(.system(size: 18, weight: .medium))
                        Text(slot.title).font(.system(size: 13, weight: .medium))
                        Spacer(minLength: 4)
                        SliderReadout(reading: slider, vertical: false, accent: .white).opacity(0.75)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                }
            }
            .glass(shape, tint: Color.white.opacity(0.09), edge: lit ? 0.45 : 0.2, glow: lit ? accent : nil)
            .frame(width: vertical ? thick : long, height: vertical ? long : thick)
            .chipBody(.capsule)
        case .widget:
            let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
            let art = min(92, max(size.height * 0.36, 40))
            VStack(alignment: .leading, spacing: 14) {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(0.1))
                    .overlay(Image(systemName: slot.symbol).font(.system(size: art * 0.37)).foregroundStyle(.white.opacity(0.75)))
                    .frame(width: art, height: art)
                VStack(alignment: .leading, spacing: 4) {
                    Text(NowPlaying.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.95))
                    Text(NowPlaying.subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .glass(shape, tint: Color.white.opacity(0.08), edge: lit ? 0.45 : 0.18, glow: lit ? accent : nil)
            .chipBody(.rounded(30))
            .padding(6)
        }
    }

    private func orb(_ d: CGFloat) -> some View {
        Circle().fill(lit ? accent.opacity(0.62) : Color.white.opacity(0.09))
            .overlay(Glyph(slot: slot, size: 22).foregroundStyle(.white))
            .glass(Circle(), tint: .clear, edge: lit ? 0.5 : 0.2, glow: lit ? accent : nil)
            .frame(width: d, height: d)
            .chipBody(.circle)
    }
}

// MARK: A · 液态光斑

private struct LensFace: View {
    let kind: FaceKind
    let slot: Slot
    let size: CGSize
    let lit: Bool
    let slider: SliderReading
    let accent: Color

    /// 液态光斑只画图标，波纹与连按计数围着图标这么大的圆
    static let glyphRing: CGFloat = 54
    /// 图标加名称实际画出的高度（竖向滑杆按它对齐）
    static let tileHeight: CGFloat = 62

    var body: some View {
        switch kind {
        case .close:
            Circle().strokeBorder(Color.white.opacity(lit ? 0.8 : 0.3), lineWidth: 1)
                .background(Circle().fill(Color.black.opacity(lit ? 0.3 : 0.15)))
                .overlay(Image(systemName: "xmark").font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.9)))
                .frame(width: 38, height: 38)
                .chipBody(.circle)
                .overlay(alignment: .bottom) { EditHint(visible: lit).offset(y: 24) }
        case .tile:
            VStack(spacing: 9) {
                Glyph(slot: slot, size: 28, weight: .regular).foregroundStyle(.white.opacity(lit ? 1 : 0.86))
                    .background { Color.clear.frame(width: Self.glyphRing, height: Self.glyphRing).chipBody(.circle) }
                Text(slot.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(lit ? 0.96 : 0.55))
                    .lineLimit(1)
                    .opacity(Glyph.isText(slot) ? 0 : 1)
            }
            .floatingLabel("lens.tile|\(slot.symbol)|\(slot.title)|\(lit)")
        case .round:
            Glyph(slot: slot, size: 26, weight: .regular).foregroundStyle(.white.opacity(lit ? 1 : 0.86))
                .frame(width: size.width, height: size.height)
                .background { Color.clear.frame(width: Self.glyphRing, height: Self.glyphRing).chipBody(.circle) }
                .overlay(alignment: .bottom) {
                    Text(slot.title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(lit ? 0.96 : 0.6))
                        .fixedSize().offset(y: PanelMetrics.roundTitleOffset - 4)
                        .opacity(Glyph.isText(slot) ? 0 : 1)
                }
                .floatingLabel("lens.round|\(slot.symbol)|\(slot.title)|\(lit)")
        case .slider:
            let vertical = size.height > size.width
            let track = Capsule().fill(Color.white.opacity(0.14))
                .overlay(FillBar(value: slider.value, base: slider.base, color: lit ? accent : Color.white.opacity(0.78)).clipShape(Capsule()))
            Group {
                if vertical {
                    VStack(spacing: 10) {
                        SliderReadout(reading: slider, vertical: true, accent: accent).opacity(lit ? 0.9 : 0.45)
                        track.frame(width: lit ? 6 : 4).frame(maxHeight: .infinity)
                        Image(systemName: slot.symbol).font(.system(size: 20))
                        Text(slot.title).font(.system(size: 12, weight: .medium)).opacity(lit ? 0.96 : 0.6).lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, verticalSliderInset(slot, height: size.height, tile: Self.tileHeight, minimum: 22))
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 10) {
                            Image(systemName: slot.symbol).font(.system(size: 20))
                            Text(slot.title).font(.system(size: 13, weight: .medium)).opacity(lit ? 0.96 : 0.6)
                            Spacer(minLength: 4)
                            SliderReadout(reading: slider, vertical: false, accent: accent).opacity(lit ? 0.9 : 0.45)
                        }
                        .foregroundStyle(.white)
                        Spacer(minLength: 8)
                        track.frame(height: lit ? 6 : 4)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 22)
                }
            }
            .chipBody(.rounded(20))
            .floatingLabel("lens.slider|\(slot.symbol)|\(slot.title)|\(lit)|\(vertical)|\(slider.key)")
        case .widget:
            let art = min(96, max(size.height * 0.38, 40))
            VStack(alignment: .leading, spacing: 14) {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
                    .overlay(Image(systemName: slot.symbol).font(.system(size: art * 0.37)).foregroundStyle(.white.opacity(0.7)))
                    .frame(width: art, height: art)
                VStack(alignment: .leading, spacing: 4) {
                    Text(NowPlaying.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.95))
                    Text(NowPlaying.subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .chipBody(.rounded(20))
            .floatingLabel("lens.widget|\(slot.symbol)|\(NowPlaying.title)|\(NowPlaying.subtitle)")
        }
    }
}

// MARK: C · 全息线框

private struct HoloFace: View {
    let kind: FaceKind
    let slot: Slot
    let size: CGSize
    let lit: Bool
    let slider: SliderReading
    let accent: Color

    /// 全息主题的文字色：偏青的白
    static let ink = Color(.sRGB, red: 220 / 255, green: 250 / 255, blue: 1)

    var body: some View {
        switch kind {
        case .close:
            Circle().strokeBorder(accent.opacity(lit ? 1 : 0.55), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .overlay(Image(systemName: "xmark").font(.system(size: 14, weight: .light)).foregroundStyle(accent))
                .frame(width: 40, height: 40)
                .chipBody(.circle)
                .overlay(alignment: .bottom) { EditHint(visible: lit, mono: true).offset(y: 24) }
        case .round:
            Circle().fill(accent.opacity(lit ? 0.1 : 0)).strokeBorder(accent.opacity(lit ? 0.9 : 0.35), lineWidth: lit ? 1 : 0.5)
                .overlay(Glyph(slot: slot, size: 22, weight: .light).foregroundStyle(accent.opacity(lit ? 1 : 0.85)))
                .chipBody(.circle)
                .overlay(alignment: .bottom) {
                    label.fixedSize().offset(y: PanelMetrics.roundTitleOffset).opacity(Glyph.isText(slot) ? 0 : 1)
                }
        case .tile, .slider, .widget:
            ZStack(alignment: .topLeading) {
                plate
                if let code = slot.action.shortLabel, kind != .widget {
                    Text(code).font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(0.7)
                        .foregroundStyle(accent.opacity(lit ? 0.95 : 0.6))
                        .padding(.leading, 12).padding(.top, 10)
                }
                content
            }
        }
    }

    private var plate: some View {
        let shape = RoundedRectangle(cornerRadius: 2)
        return shape.fill(accent.opacity(lit ? 0.08 : 0))
            .overlay(shape.strokeBorder(accent.opacity(lit ? 0 : 0.2), lineWidth: 0.5))
            .overlay(shape.stroke(accent.opacity(lit ? 0.35 : 0), lineWidth: 10).blur(radius: 10).clipShape(shape))
            .overlay(CornerBrackets(length: 12, inset: lit ? 0 : 6).stroke(accent.opacity(lit ? 1 : 0.6), lineWidth: 1.5))
            .chipBody(.rounded(2))
            .padding(4)
    }

    private var label: some View {
        Text(slot.title.uppercased()).font(.system(size: 11, weight: .medium, design: .monospaced)).tracking(1.3)
            .foregroundStyle(Self.ink.opacity(lit ? 1 : 0.8)).lineLimit(1)
            .floatingLabel("holo|\(slot.title)|\(lit)")
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .slider:
            let vertical = size.height > size.width
            let readout = SliderReadout(reading: slider, vertical: vertical, accent: Self.ink) {
                Text($0).font(.system(size: 13, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(accent.opacity(lit ? 1 : 0.7))
            let bar = Rectangle().fill(accent.opacity(0.2))
                .overlay(FillBar(value: slider.value, base: slider.base, color: accent).shadow(color: accent.opacity(0.8), radius: 4))
            if vertical {
                VStack(spacing: 10) {
                    readout
                    bar.frame(width: 2).frame(maxHeight: .infinity)
                    Image(systemName: slot.symbol).font(.system(size: 18, weight: .light)).foregroundStyle(accent.opacity(lit ? 1 : 0.85))
                    label
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 26).padding(.bottom, 24)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: slot.symbol).font(.system(size: 18, weight: .light)).foregroundStyle(accent.opacity(lit ? 1 : 0.85))
                        label
                        Spacer(minLength: 4)
                        readout
                    }
                    Spacer(minLength: 8)
                    bar.frame(height: 2)
                }
                .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 26)
            }
        case .widget:
            let art = min(90, max(size.height * 0.36, 40))
            VStack(alignment: .leading, spacing: 14) {
                Rectangle().strokeBorder(accent.opacity(0.35), lineWidth: 1)
                    .overlay(Image(systemName: slot.symbol).font(.system(size: art * 0.35, weight: .light)).foregroundStyle(accent.opacity(0.85)))
                    .frame(width: art, height: art)
                VStack(alignment: .leading, spacing: 5) {
                    Text(NowPlaying.title.uppercased()).font(.system(size: 12, design: .monospaced)).tracking(1.3).foregroundStyle(Self.ink)
                    Text(NowPlaying.subtitle).font(.system(size: 11, design: .monospaced)).foregroundStyle(accent.opacity(0.55))
                }
            }
            .padding(22)
        default:
            VStack(spacing: 10) {
                Glyph(slot: slot, size: 26, weight: .light).foregroundStyle(lit ? Self.ink : accent)
                    .floatingLabel("holo.glyph|\(slot.symbol)|\(slot.title)|\(lit)")
                label.opacity(Glyph.isText(slot) ? 0 : 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 关闭按钮点亮时下方的提示：按住进入编辑（D23）
private struct EditHint: View {
    let visible: Bool
    var mono = false

    var body: some View {
        Text("按住进入编辑")
            .font(mono ? .system(size: 10, design: .monospaced) : .system(size: 10.5))
            .foregroundStyle(.white.opacity(0.65))
            .fixedSize()
            .floatingLabel("hint|\(mono)")
            .opacity(visible ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: visible)
    }
}

/// 连按计数：同一按钮按压执行两次起显示 ×N
private struct PressBadge: View {
    let count: Int
    @Environment(\.overlayStyle) private var style

    var body: some View {
        Text("×\(count)")
            .font(.system(size: 11, weight: .bold).monospacedDigit())
            .contentTransition(.numericText(value: Double(count)))
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(style.accent, in: Capsule())
            .animation(.snappy, value: count)
    }
}

/// 按钮看得见的轮廓（波纹与连按计数据此定位）
enum ChipBodyShape: Equatable {
    case circle, capsule
    case rounded(CGFloat)

    /// 连按计数的位置：圆形在右上 45° 的边上，其余在右上角内侧
    func badgePoint(in r: CGRect) -> CGPoint {
        switch self {
        case .circle:
            let k = 0.5.squareRoot() * r.width / 2
            return CGPoint(x: r.midX + k, y: r.midY - k)
        case .capsule:
            return CGPoint(x: r.maxX - r.height * 0.2, y: r.minY + r.height * 0.1)
        case .rounded(let c):
            return CGPoint(x: r.maxX - c * 0.3, y: r.minY + c * 0.3)
        }
    }
}

struct ChipBody {
    let bounds: Anchor<CGRect>
    let shape: ChipBodyShape
}

struct ChipBodyKey: PreferenceKey {
    static var defaultValue: ChipBody? { nil }
    static func reduce(value: inout ChipBody?, nextValue: () -> ChipBody?) { value = value ?? nextValue() }
}

extension View {
    /// 标出按钮看得见的部分：每种主题、每类按钮各标一处
    func chipBody(_ shape: ChipBodyShape) -> some View {
        anchorPreference(key: ChipBodyKey.self, value: .bounds) { ChipBody(bounds: $0, shape: shape) }
    }
}

/// 提交与按压执行的波纹：强调色描边从按钮轮廓向外扩散并淡出
private struct Ripple: View {
    let trigger: Int
    let shape: ChipBodyShape
    let size: CGSize
    @Environment(\.overlayStyle) private var style

    /// 轮廓向外扩出的距离（pt）：从略小于按钮到按钮外一圈，宽的滑杆不会被放大成巨大的框
    static let outsetStart: CGFloat = -2
    static let outsetEnd: CGFloat = 14

    var body: some View {
        let accent = style.accent, shape = shape, size = size, start = Self.outsetStart, end = Self.outsetEnd
        Color.clear
            .frame(width: size.width, height: size.height)
            .keyframeAnimator(initialValue: 1.0, trigger: trigger) { content, raw in
                let p = min(max(raw, 0), 1)
                let o = start + p * (end - start)
                content.overlay {
                    Group {
                        switch shape {
                        case .circle: Circle().stroke(accent, lineWidth: 2)
                        case .capsule: Capsule().stroke(accent, lineWidth: 2)
                        case .rounded(let c): RoundedRectangle(cornerRadius: c + o, style: .continuous).stroke(accent, lineWidth: 2)
                        }
                    }
                    .frame(width: size.width + 2 * o, height: size.height + 2 * o)
                    .opacity(p < 1 ? (1 - p) * 0.85 : 0)
                }
            } keyframes: { _ in
                // 从 0 走到 1；初值为 1 表示没有在播放。第二段不能用 CubicKeyframe：它沿用上一段的速度，
                // 1 ms 内从 1 跳到 0 的速度会把进度甩到约 -25，波纹被翻转放大成满屏的粗圆环（负责人反馈的"大圈"）
                LinearKeyframe(0.0, duration: 0.001)
                LinearKeyframe(1.0, duration: PanelMetrics.rippleDuration, timingCurve: .easeOut)
            }
            .allowsHitTesting(false)
    }
}
