import SwiftUI
import TouchOSCore

/// 指示点与轨迹，按显示刷新率重绘并在触点帧之间插值（FR-8.9）。
/// 落在按钮上时也照常显示：用户靠它判断手指的真实位置、预判移动距离（负责人反馈，D20）
struct PointerLayer: View {
    let model: OverlayModel
    /// 用于跟随面板的水平位置（D41）
    let state: PanelState
    /// 按钮组在窗口中的位置；指示点坐标是按钮组 pt，绘制时加上偏移
    let groupRect: CGRect
    /// 指示点当前对应的范围（按钮组 pt）：当前面板，总览时为整个按钮组（D29）
    let area: CGRect
    let overCancel: Bool
    let showTrail: Bool
    @Environment(\.overlayStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 画布只覆盖指示点周围这么大的方块（轨迹、光晕、全息读数都在其内），跟着指示点移动。
    /// 不铺满整个窗口：画布每帧由 CPU 重新栅格化，面积决定开销（性能实测，D28）
    static let canvasSize: CGFloat = 320

    var body: some View {
        // 手指不在板上、轨迹也淡完时停下逐帧刷新
        let _ = model.wake
        let until = model.pointerDown ? .infinity : (model.samples.last?.t ?? 0) + model.trailDuration
        TimelineView(.animation(minimumInterval: nil, paused: ProcessInfo.processInfo.systemUptime > until)) { timeline in
            let _ = timeline.date
            let now = ProcessInfo.processInfo.systemUptime
            let p = model.displayedPointer(at: now)
            ZStack(alignment: .topLeading) {
                if let anchor = p ?? model.samples.last?.p {
                    let half = Self.canvasSize / 2
                    Canvas { ctx, _ in
                        ctx.translateBy(x: half - anchor.x, y: half - anchor.y)
                        draw(&ctx, pointer: p, now: now)
                    }
                    .frame(width: Self.canvasSize, height: Self.canvasSize)
                    .offset(x: groupRect.minX + model.placementShift(state, at: now, reduceMotion: reduceMotion) + anchor.x - half,
                            y: groupRect.minY + anchor.y - half)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .task(id: until) {
            let wait = until - ProcessInfo.processInfo.systemUptime
            guard wait > 0, wait.isFinite else { return }
            try? await Task.sleep(for: .seconds(wait + PanelMetrics.settleMargin))
            if !Task.isCancelled { model.wake &+= 1 }
        }
    }

    /// 坐标为按钮组 pt
    /// 指示点在面板之外时照常绘制：抬起即取消是自然的预期，只由按钮组轻微变淡提示（D39）
    private func draw(_ ctx: inout GraphicsContext, pointer: CGPoint?, now: TimeInterval) {
        let color = overCancel ? Color.gray : style.accent
        if showTrail { drawTrail(&ctx, now: now, color: color) }
        guard let p = pointer else { return }
        if style.theme == .holo {
            drawCrosshair(&ctx, at: p, color: color, area: area)
        } else {
            let halo = PanelMetrics.pointerHalo, core = PanelMetrics.pointerCore
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - halo / 2, y: p.y - halo / 2, width: halo, height: halo)),
                     with: .radialGradient(Gradient(colors: [color.opacity(0.5), color.opacity(0)]),
                                           center: p, startRadius: core / 2, endRadius: halo / 2))
            let coreRect = CGRect(x: p.x - core / 2, y: p.y - core / 2, width: core, height: core)
            var shadow = ctx
            shadow.addFilter(.shadow(color: .black.opacity(0.5), radius: 2, y: 1))
            shadow.fill(Path(ellipseIn: coreRect), with: .color(.white))
            ctx.stroke(Path(ellipseIn: coreRect.insetBy(dx: 1, dy: 1)), with: .color(color), lineWidth: 2)
        }
    }

    /// 全息主题：圆圈加十字准星，右下角显示面板内的归一化坐标
    private func drawCrosshair(_ ctx: inout GraphicsContext, at p: CGPoint, color: Color, area: CGRect) {
        let c = color.opacity(0.9)
        ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)), with: .color(c), lineWidth: 1.5)
        var cross = Path()
        cross.move(to: CGPoint(x: p.x - 16, y: p.y))
        cross.addLine(to: CGPoint(x: p.x - 9, y: p.y))
        cross.move(to: CGPoint(x: p.x + 9, y: p.y))
        cross.addLine(to: CGPoint(x: p.x + 16, y: p.y))
        cross.move(to: CGPoint(x: p.x, y: p.y - 16))
        cross.addLine(to: CGPoint(x: p.x, y: p.y - 9))
        cross.move(to: CGPoint(x: p.x, y: p.y + 9))
        cross.addLine(to: CGPoint(x: p.x, y: p.y + 16))
        ctx.stroke(cross, with: .color(c), lineWidth: 1)
        let readout = String(format: "X %.2f  Y %.2f", (p.x - area.minX) / max(area.width, 1), (p.y - area.minY) / max(area.height, 1))
        let text = ctx.resolve(Text(readout).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(color.opacity(0.85)))
        ctx.draw(text, at: CGPoint(x: p.x + 14, y: p.y + 12), anchor: .topLeading)
    }

    /// 最近 `P.trailMs`、最长 `trailMaxLength` 的路径：越旧、越远越细越透明
    private func drawTrail(_ ctx: inout GraphicsContext, now: TimeInterval, color: Color) {
        var points = model.samples.filter { now - $0.t <= model.trailDuration }.map { ($0.t, $0.p) }
        if let head = model.displayedPointer(at: now) {
            points.removeAll { $0.0 > now }
            points.append((now, head))
        }
        guard points.count >= 2 else { return }
        let maxLength = PanelMetrics.trailMaxLength
        var length: CGFloat = 0
        // 从指示点往回画，超出长度上限的部分截掉
        for i in stride(from: points.count - 1, to: 0, by: -1) {
            let a = points[i].1, b = points[i - 1].1
            let step = hypot(b.x - a.x, b.y - a.y)
            guard step > 0 else { continue }
            let kept = min(step, maxLength - length)
            let end = CGPoint(x: a.x + (b.x - a.x) * kept / step, y: a.y + (b.y - a.y) * kept / step)
            let age = (now - points[i].0) / model.trailDuration
            let k = max(0, 1 - max(age, length / maxLength))
            var seg = Path()
            seg.move(to: a)
            seg.addLine(to: end)
            ctx.stroke(seg, with: .color(color.opacity(PanelMetrics.trailMaxOpacity * k)),
                       style: StrokeStyle(lineWidth: max(1, PanelMetrics.trailMaxWidth * k), lineCap: .round))
            length += kept
            if length >= maxLength { break }
        }
    }
}
