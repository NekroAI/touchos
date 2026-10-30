import SwiftUI
import TouchOSCore

/// 一枚按钮：动效（弹开、悬停、按压回弹、提交、收拢）与主题无关，外观交给各主题的 `Face`
struct ChipView: View {
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
    @Environment(\.overlayStyle) private var style

    var body: some View {
        let g = geometry
        let face = FaceKind(slot: slot, geometry: g)
        Face(kind: face, slot: slot, size: g.frame.size, lit: hovered || chosen, value: value)
            .frame(width: g.frame.width, height: g.frame.height)
            .background { FocusHalo(kind: face, size: g.frame.size) }
            .overlay { Ripple(trigger: pulse, size: g.frame.size, wide: face == .slider || face == .widget) }
            .overlay(alignment: .topTrailing) {
                if presses >= 2 { PressBadge(count: presses).offset(x: face == .tile ? -6 : 6, y: face == .tile ? 4 : -6) }
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
    @Environment(\.overlayStyle) private var style

    var body: some View {
        switch style.theme {
        case .orb: OrbFace(kind: kind, slot: slot, size: size, lit: lit, value: value ?? 0, accent: style.accent)
        case .lens: LensFace(kind: kind, slot: slot, size: size, lit: lit, value: value ?? 0, accent: style.accent)
        case .holo: HoloFace(kind: kind, slot: slot, size: size, lit: lit, value: value ?? 0, accent: style.accent)
        }
    }
}

// MARK: 公用小件

/// 按钮身后的柔焦（见 `PanelMetrics.haloPad`）：范围按按钮种类估算可见部分，材质用羽化的形状做遮罩，没有硬边
private struct FocusHalo: View {
    let kind: FaceKind
    let size: CGSize

    var body: some View {
        let (w, h, dy, corner) = extent
        let pad = PanelMetrics.haloPad, feather = PanelMetrics.haloFeather
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill(Color.black.opacity(PanelMetrics.haloTint))
        }
        .environment(\.colorScheme, .dark)
        .mask {
            RoundedRectangle(cornerRadius: corner + pad, style: .continuous)
                .frame(width: w + pad * 2, height: h + pad * 2)
                .blur(radius: feather / 2)
        }
        .frame(width: w + (pad + feather) * 2, height: h + (pad + feather) * 2)
        .offset(y: dy)
        .allowsHitTesting(false)
    }

    /// 可见部分的宽、高、相对按钮中心的竖直偏移、圆角
    private var extent: (CGFloat, CGFloat, CGFloat, CGFloat) {
        switch kind {
        case .tile:
            let w = min(size.width, PanelMetrics.haloTile), h = min(size.height, PanelMetrics.haloTile)
            return (w, h, 0, min(w, h) * 0.35)
        case .round:
            // 圆钮加下方的名称
            let d = min(size.width, size.height), label = PanelMetrics.haloLabelHeight
            return (max(d, PanelMetrics.haloLabelWidth), d + label, label / 2, d / 2)
        case .close:
            let d = PanelMetrics.cancelChipSize
            return (d, d, 0, d / 2)
        case .slider, .widget:
            return (size.width, size.height, 0, min(size.width, size.height) * 0.45)
        }
    }
}

private func percent(_ v: Double) -> Int { Int((v * 100).rounded()) }

/// 滑杆的填充：横向从左、纵向从下
private struct FillBar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { g in
            let vertical = g.size.height > g.size.width
            Rectangle().fill(color)
                .frame(width: vertical ? g.size.width : g.size.width * value, height: vertical ? g.size.height * value : g.size.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: vertical ? .bottom : .leading)
        }
        .animation(.easeOut(duration: 0.06), value: value)
    }
}

/// 毛玻璃底：只保留一部分强度，叠一层底色
private struct Glass<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color
    let edge: Double
    let glow: Color?

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial).opacity(PanelMetrics.materialOpacity)
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

    /// 直接浮在桌面上的文字：加阴影保证可读
    func floatingLabel() -> some View {
        shadow(color: .black.opacity(PanelMetrics.labelShadowOpacity), radius: 4, y: 1)
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
    let value: Double
    let accent: Color

    static let orb: CGFloat = 58
    static let orbLit: CGFloat = 66
    static let sliderHeight: CGFloat = 60

    var body: some View {
        switch kind {
        case .close:
            Circle().fill(Color.black.opacity(lit ? 0.55 : 0.38))
                .overlay(Circle().strokeBorder(Color.white.opacity(lit ? 0.6 : 0.3), lineWidth: 0.5))
                .overlay(Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white))
                .frame(width: PanelMetrics.cancelChipSize, height: PanelMetrics.cancelChipSize)
                .overlay(alignment: .bottom) { EditHint(visible: lit).offset(y: 24) }
        case .tile:
            let room = min(size.width, size.height - 30)
            let d = min(lit ? Self.orbLit : Self.orb, room)
            VStack(spacing: 8) {
                orb(d)
                Text(slot.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(lit ? 0.98 : 0.68))
                    .lineLimit(1)
                    .floatingLabel()
            }
        case .round:
            orb(min(size.width, size.height) * (lit ? 1.1 : 1))
                .overlay(alignment: .bottom) {
                    Text(slot.title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(lit ? 0.98 : 0.68))
                        .fixedSize().floatingLabel().offset(y: PanelMetrics.roundTitleOffset)
                }
        case .slider:
            let shape = Capsule()
            ZStack {
                FillBar(value: value, color: lit ? accent.opacity(0.6) : Color.white.opacity(0.16)).clipShape(shape)
                HStack(spacing: 10) {
                    Image(systemName: slot.symbol).font(.system(size: 18, weight: .medium))
                    Text(slot.title).font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 4)
                    Text("\(percent(value))%").font(.system(size: 12).monospacedDigit()).opacity(0.75)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
            }
            .glass(shape, tint: Color.white.opacity(0.09), edge: lit ? 0.45 : 0.2, glow: lit ? accent : nil)
            .frame(width: max(size.width - 16, 0), height: min(Self.sliderHeight, max(size.height - 16, 0)))
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
            .padding(6)
        }
    }

    private func orb(_ d: CGFloat) -> some View {
        Circle().fill(lit ? accent.opacity(0.62) : Color.white.opacity(0.09))
            .overlay(Image(systemName: slot.symbol).font(.system(size: 22, weight: .medium)).foregroundStyle(.white))
            .glass(Circle(), tint: .clear, edge: lit ? 0.5 : 0.2, glow: lit ? accent : nil)
            .frame(width: d, height: d)
    }
}

// MARK: A · 液态光斑

private struct LensFace: View {
    let kind: FaceKind
    let slot: Slot
    let size: CGSize
    let lit: Bool
    let value: Double
    let accent: Color

    var body: some View {
        switch kind {
        case .close:
            Circle().strokeBorder(Color.white.opacity(lit ? 0.8 : 0.3), lineWidth: 1)
                .background(Circle().fill(Color.black.opacity(lit ? 0.3 : 0.15)))
                .overlay(Image(systemName: "xmark").font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.9)))
                .frame(width: 38, height: 38)
                .overlay(alignment: .bottom) { EditHint(visible: lit).offset(y: 24) }
        case .tile:
            VStack(spacing: 9) {
                Image(systemName: slot.symbol).font(.system(size: 28, weight: .regular)).foregroundStyle(.white.opacity(lit ? 1 : 0.86))
                Text(slot.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(lit ? 0.96 : 0.55))
                    .lineLimit(1)
            }
            .floatingLabel()
        case .round:
            Image(systemName: slot.symbol).font(.system(size: 26)).foregroundStyle(.white.opacity(lit ? 1 : 0.86))
                .frame(width: size.width, height: size.height)
                .overlay(alignment: .bottom) {
                    Text(slot.title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(lit ? 0.96 : 0.6))
                        .fixedSize().offset(y: PanelMetrics.roundTitleOffset - 4)
                }
                .floatingLabel()
        case .slider:
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: slot.symbol).font(.system(size: 20))
                    Text(slot.title).font(.system(size: 13, weight: .medium)).opacity(lit ? 0.96 : 0.6)
                    Spacer(minLength: 4)
                    Text("\(percent(value))%").font(.system(size: 12).monospacedDigit()).opacity(lit ? 0.9 : 0.45)
                }
                .foregroundStyle(.white)
                Spacer(minLength: 8)
                Capsule().fill(Color.white.opacity(0.14))
                    .overlay(FillBar(value: value, color: lit ? accent : Color.white.opacity(0.78)).clipShape(Capsule()))
                    .frame(height: lit ? 6 : 4)
            }
            .padding(.horizontal, 20).padding(.vertical, 22)
            .floatingLabel()
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
            .floatingLabel()
        }
    }
}

// MARK: C · 全息线框

private struct HoloFace: View {
    let kind: FaceKind
    let slot: Slot
    let size: CGSize
    let lit: Bool
    let value: Double
    let accent: Color

    /// 全息主题的文字色：偏青的白
    static let ink = Color(.sRGB, red: 220 / 255, green: 250 / 255, blue: 1)

    var body: some View {
        switch kind {
        case .close:
            Circle().strokeBorder(accent.opacity(lit ? 1 : 0.55), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .overlay(Image(systemName: "xmark").font(.system(size: 14, weight: .light)).foregroundStyle(accent))
                .frame(width: 40, height: 40)
                .overlay(alignment: .bottom) { EditHint(visible: lit, mono: true).offset(y: 24) }
        case .round:
            Circle().fill(accent.opacity(lit ? 0.1 : 0)).strokeBorder(accent.opacity(lit ? 0.9 : 0.35), lineWidth: lit ? 1 : 0.5)
                .overlay(Image(systemName: slot.symbol).font(.system(size: 22, weight: .light)).foregroundStyle(accent.opacity(lit ? 1 : 0.85)))
                .overlay(alignment: .bottom) { label.fixedSize().offset(y: PanelMetrics.roundTitleOffset) }
        case .tile, .slider, .widget:
            ZStack(alignment: .topLeading) {
                plate
                if let code = slot.action.shortLabel, kind != .widget {
                    Text(code).font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(0.7)
                        .foregroundStyle(accent.opacity(lit ? 0.9 : 0.4))
                        .padding(.leading, 12).padding(.top, 10)
                }
                content
            }
        }
    }

    private var plate: some View {
        let shape = RoundedRectangle(cornerRadius: 2)
        return shape.fill(accent.opacity(lit ? 0.08 : 0))
            .overlay(shape.strokeBorder(accent.opacity(lit ? 0 : 0.12), lineWidth: 0.5))
            .overlay(shape.stroke(accent.opacity(lit ? 0.35 : 0), lineWidth: 10).blur(radius: 10).clipShape(shape))
            .overlay(CornerBrackets(length: 12, inset: lit ? 0 : 6).stroke(accent.opacity(lit ? 1 : 0.42), lineWidth: 1.5))
            .padding(4)
    }

    private var label: some View {
        Text(slot.title.uppercased()).font(.system(size: 11, design: .monospaced)).tracking(1.3)
            .foregroundStyle(Self.ink.opacity(lit ? 1 : 0.62)).lineLimit(1)
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .slider:
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: slot.symbol).font(.system(size: 18, weight: .light)).foregroundStyle(accent.opacity(lit ? 1 : 0.85))
                    label
                    Spacer(minLength: 4)
                    Text(String(format: "%03d", percent(value))).font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(accent.opacity(lit ? 1 : 0.7))
                }
                Spacer(minLength: 8)
                Rectangle().fill(accent.opacity(0.2))
                    .overlay(FillBar(value: value, color: accent).shadow(color: accent.opacity(0.8), radius: 4))
                    .frame(height: 2)
            }
            .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 26)
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
                Image(systemName: slot.symbol).font(.system(size: 26, weight: .light)).foregroundStyle(accent.opacity(lit ? 1 : 0.85))
                label
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
            .floatingLabel()
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

/// 提交与按压执行的波纹：强调色描边从按钮中心向外扩散并淡出
private struct Ripple: View {
    let trigger: Int
    let size: CGSize
    /// 滑杆、卡片用圆角矩形，其余用圆
    let wide: Bool
    @Environment(\.overlayStyle) private var style

    var body: some View {
        let d = min(size.width, size.height) * 0.92
        let accent = style.accent, size = size, wide = wide
        Color.clear
            .keyframeAnimator(initialValue: 1.0, trigger: trigger) { _, p in
                Group {
                    if wide {
                        RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(accent, lineWidth: 2)
                            .frame(width: size.width * 0.92, height: size.height * 0.92)
                    } else {
                        Circle().stroke(accent, lineWidth: 2).frame(width: d, height: d)
                    }
                }
                .scaleEffect(0.6 + p * 0.75)
                .opacity(p < 1 ? (1 - p) * 0.85 : 0)
            } keyframes: { _ in
                // 从 0 走到 1；初值为 1 表示没有在播放
                LinearKeyframe(0.0, duration: 0.001)
                CubicKeyframe(1.0, duration: PanelMetrics.rippleDuration)
            }
            .allowsHitTesting(false)
    }
}
