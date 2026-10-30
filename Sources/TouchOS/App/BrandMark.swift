import AppKit

/// 品牌标志「笔触」（D43）：书法 T，笔锋落在触点上。与 tools/icon/render-brand.swift 同一条路径（1024 画布，y 向下）
enum BrandMark {
    /// 菜单栏图标边长（pt）
    static let menuBarSize: CGFloat = 18
    /// 暂停时菜单栏图标的不透明度
    static let pausedAlpha: CGFloat = 0.4

    private static var path: CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 228, y: 384))
        p.addCurve(to: CGPoint(x: 806, y: 258), control1: CGPoint(x: 340, y: 306), control2: CGPoint(x: 566, y: 296))
        p.addCurve(to: CGPoint(x: 590, y: 382), control1: CGPoint(x: 772, y: 336), control2: CGPoint(x: 602, y: 374))
        p.addCurve(to: CGPoint(x: 456, y: 790), control1: CGPoint(x: 594, y: 510), control2: CGPoint(x: 540, y: 660))
        p.addCurve(to: CGPoint(x: 408, y: 770), control1: CGPoint(x: 438, y: 816), control2: CGPoint(x: 396, y: 800))
        p.addCurve(to: CGPoint(x: 462, y: 396), control1: CGPoint(x: 476, y: 640), control2: CGPoint(x: 490, y: 500))
        p.addCurve(to: CGPoint(x: 228, y: 384), control1: CGPoint(x: 380, y: 408), control2: CGPoint(x: 280, y: 416))
        p.closeSubpath()
        p.addEllipse(in: CGRect(x: 426 - 54, y: 792 - 54, width: 108, height: 108))
        return p
    }

    /// 单色模板图：系统按菜单栏深浅自动着色
    static func menuBarImage(description: String, alpha: CGFloat = 1) -> NSImage {
        let side = menuBarSize
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.scaleBy(x: side / 1024, y: side / 1024)
            ctx.translateBy(x: 512, y: 500)
            ctx.scaleBy(x: 1.24, y: 1.24)
            ctx.translateBy(x: -512, y: -530)
            ctx.addPath(path)
            ctx.setFillColor(NSColor.black.withAlphaComponent(alpha).cgColor)
            ctx.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }
}
