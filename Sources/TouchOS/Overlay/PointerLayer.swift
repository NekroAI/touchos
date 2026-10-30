import SwiftUI

/// 指示点与轨迹，按显示刷新率重绘并在触点帧之间插值（FR-8.9）。
/// 落在按钮上时也照常显示：用户靠它判断手指的真实位置、预判移动距离（负责人反馈，D20）
struct PointerLayer: View {
    let model: OverlayModel
    /// 按钮组在窗口中的位置；指示点坐标是按钮组 pt，绘制时加上偏移
    let groupRect: CGRect
    /// 指示点当前对应的范围（按钮组 pt）：当前面板，总览时为整个按钮组（D29）
    let area: CGRect
    let overCancel: Bool
    let showTrail: Bool
    @Environment(\.overlayStyle) private var style

    /// 画布只覆盖指示点周围这么大的方块（轨迹、光晕、全息读数、"松手取消"都在其内），跟着指示点移动。
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
            let local = area
            ZStack(alignment: .topLeading) {
                // 指示点在映射区之外：抬起即取消。显示按钮组范围的轮廓（提示要移回多远，D15）
                if let p, !local.contains(p) {
                    RoundedRectangle(cornerRadius: style.theme == .holo ? 6 : 26)
                        .stroke(.white.opacity(PanelMetrics.boundsOpacity), style: StrokeStyle(lineWidth: 1.5, dash: [6, 6]))
                        .frame(width: local.width + 20, height: local.height + 20)
                        .offset(x: groupRect.minX + local.minX - 10, y: groupRect.minY + local.minY - 10)
                }
                if let anchor = p ?? model.samples.last?.p {
                    let half = Self.canvasSize / 2
                    Canvas { ctx, _ in
                        ctx.translateBy(x: half - anchor.x, y: half - anchor.y)
                        draw(&ctx, pointer: p, now: now, inside: p.map { local.contains($0) } ?? true)
                    }
                    .frame(width: Self.canvasSize, height: Self.canvasSize)
                    .offset(x: groupRect.minX + anchor.x - half, y: groupRect.minY + anchor.y - half)
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
    private func draw(_ ctx: inout GraphicsContext, pointer: CGPoint?, now: TimeInterval, inside: Bool) {
        let color = overCancel ? Color.gray : style.accent
        if showTrail { drawTrail(&ctx, now: now, color: color) }
        guard let p = pointer else { return }
        guard inside else {
            drawCancelPointer(&ctx, at: p)
            return
        }
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
        let capsule = CGRect(x: at.x - size.width / 2 - 8, y: at.y - size.height / 2 - 3, width: size.width + 16, height: size.height + 6)
        ctx.fill(Path(roundedRect: capsule, cornerRadius: capsule.height / 2), with: .color(.black.opacity(PanelMetrics.cancelPointerFill)))
        ctx.draw(hint, at: at)
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
