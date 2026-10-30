// 品牌资产生成脚本（方案「笔触」，docs/decisions.md D43，规范见 docs/brand.md）。
//
// 字标依赖 Inter 变量字体（Google Fonts，SIL OFL 1.1），字体不进仓库：
//   curl -LO "https://raw.githubusercontent.com/google/fonts/main/ofl/inter/Inter%5Bopsz,wght%5D.ttf"
// 用法：
//   swiftc -O tools/icon/render-brand.swift -o /tmp/render-brand
//   /tmp/render-brand <Inter 字体路径> <输出目录>
// 输出：AppIcon-1024.png、icon-128.png、logo-dark.png、logo-light.png。再按 tools/icon/README.md 生成 AppIcon.icns。
import AppKit
import CoreText

let fontPath = CommandLine.arguments[1], outDir = CommandLine.arguments[2]
CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: fontPath) as CFURL, .process, nil)

func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
func gradient(_ stops: [(CGFloat, UInt32)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map { c($0.1) } as CFArray, locations: stops.map(\.0))!
}

/// 书法 T：横笔左细右粗上扬，竖笔收成笔锋（1024 画布，y 向下）。与 Sources/TouchOS/App/BrandMark.swift 同一条路径
func strokeT() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 228, y: 384))
    p.addCurve(to: CGPoint(x: 806, y: 258), control1: CGPoint(x: 340, y: 306), control2: CGPoint(x: 566, y: 296))
    p.addCurve(to: CGPoint(x: 590, y: 382), control1: CGPoint(x: 772, y: 336), control2: CGPoint(x: 602, y: 374))
    p.addCurve(to: CGPoint(x: 456, y: 790), control1: CGPoint(x: 594, y: 510), control2: CGPoint(x: 540, y: 660))
    p.addCurve(to: CGPoint(x: 408, y: 770), control1: CGPoint(x: 438, y: 816), control2: CGPoint(x: 396, y: 800))
    p.addCurve(to: CGPoint(x: 462, y: 396), control1: CGPoint(x: 476, y: 640), control2: CGPoint(x: 490, y: 500))
    p.addCurve(to: CGPoint(x: 228, y: 384), control1: CGPoint(x: 380, y: 408), control2: CGPoint(x: 280, y: 416))
    p.closeSubpath()
    return p
}
/// 触点：笔锋直接落进去，不留空隙（分开时整个图形读作感叹号）
let dotCenter = CGPoint(x: 426, y: 792)

func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil) }

/// 位图，坐标原点左上、y 向下
func render(_ w: Int, _ h: Int, to name: String, _ draw: (CGContext) -> Void) {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    draw(ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outDir + "/" + name))
}

func fill(_ ctx: CGContext, _ path: CGPath, _ g: CGGradient, from a: CGPoint, to b: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

let ink = gradient([(0, 0xFFC27A), (0.45, 0xFF5C7A), (1, 0x9A4DFF)])
let inkOnLight = gradient([(0, 0xE8743A), (0.45, 0xE0305F), (1, 0x7A35E0)])

/// 应用图标（1024 画布）。macOS 图标网格：主体 824 × 824，圆角 185
func drawIcon(_ ctx: CGContext) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, 0x2A1638), (1, 0x0B0812)]), start: CGPoint(x: 220, y: 100), end: CGPoint(x: 720, y: 924),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // 笔画的光晕
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 70, color: c(0xFF5C7A, 0.55))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    fill(ctx, strokeT(), ink, from: CGPoint(x: 220, y: 260), to: CGPoint(x: 780, y: 760))
    ctx.endTransparencyLayer()
    ctx.restoreGState()
    // 触点与一圈涟漪
    ctx.addPath(circle(dotCenter, 84))
    ctx.setStrokeColor(c(0xFF8FA8, 0.4))
    ctx.setLineWidth(5)
    ctx.strokePath()
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 50, color: c(0xFF5C7A, 0.95))
    ctx.addPath(circle(dotCenter, 44))
    ctx.setFillColor(c(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.restoreGState()
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 183, cornerHeight: 183, transform: nil))
    ctx.setStrokeColor(c(0xFFFFFF, 0.12))
    ctx.setLineWidth(4)
    ctx.strokePath()
}

/// 无底的标志，画进 `rect`（方形）
func drawMark(_ ctx: CGContext, in rect: CGRect, gradient g: CGGradient) {
    ctx.saveGState()
    ctx.translateBy(x: rect.minX, y: rect.minY)
    ctx.scaleBy(x: rect.width / 1024, y: rect.width / 1024)
    ctx.translateBy(x: 512, y: 500)
    ctx.scaleBy(x: 1.24, y: 1.24)
    ctx.translateBy(x: -512, y: -530)
    let path = CGMutablePath()
    path.addPath(strokeT())
    path.addPath(circle(dotCenter, 54))
    fill(ctx, path, g, from: CGPoint(x: 220, y: 260), to: CGPoint(x: 780, y: 860))
    ctx.restoreGState()
}

func font(_ size: CGFloat, weight: CGFloat) -> CTFont {
    let base = CTFontCreateWithName("Inter" as CFString, size, nil)
    let tag = "wght".unicodeScalars.reduce(0) { ($0 << 8) | Int($1.value) }
    return CTFontCreateCopyWithAttributes(base, size, nil, CTFontDescriptorCreateWithAttributes([kCTFontVariationAttribute: [tag: weight]] as CFDictionary))
}

func text(_ ctx: CGContext, _ s: String, _ f: CTFont, _ color: CGColor, x: CGFloat, baseline y: CGFloat, kern: CGFloat) {
    let a = NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): f,
                                                       NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                                                       NSAttributedString.Key(kCTKernAttributeName as String): kern])
    ctx.saveGState()
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)  // 画布 y 向下
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(CTLineCreateWithAttributedString(a), ctx)
    ctx.restoreGState()
}

/// 横排 logo：标志 + NEKRO 小字 + TouchOS，透明底
func drawLogo(_ ctx: CGContext, gradient g: CGGradient, title: CGColor, sub: CGColor) {
    drawMark(ctx, in: CGRect(x: 8, y: 10, width: 220, height: 220), gradient: g)
    text(ctx, "NEKRO", font(30, weight: 600), sub, x: 244, baseline: 88, kern: 7)
    text(ctx, "TouchOS", font(112, weight: 600), title, x: 240, baseline: 190, kern: -3)
}

render(1024, 1024, to: "AppIcon-1024.png", drawIcon)
render(256, 256, to: "icon-128.png") { ctx in
    ctx.scaleBy(x: 0.25, y: 0.25)
    drawIcon(ctx)
}
render(760, 240, to: "logo-dark.png") { drawLogo($0, gradient: ink, title: c(0xFFFFFF), sub: c(0xA3A5AD)) }
render(760, 240, to: "logo-light.png") { drawLogo($0, gradient: inkOnLight, title: c(0x16171A), sub: c(0x55575E)) }
