// DMG 安装窗口背景（D46，品牌规范见 docs/brand.md）。用浅色底：访达图标文字是深色，改不了。
// 用法：swiftc -O tools/dmg/render-background.swift -o /tmp/render-dmg && /tmp/render-dmg Resources/dmg/.background
import AppKit

let size = CGSize(width: 660, height: 400)
let outDir = CommandLine.arguments[1]

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}

func render(scale: Int, to name: String) {
    let w = Int(size.width) * scale, h = Int(size.height) * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    ctx.setFillColor(color(0xF6F5F8))
    ctx.fill(CGRect(origin: .zero, size: size))
    // 品牌色的两团柔光
    for (center, radius, hex) in [(CGPoint(x: 90, y: 40), 300.0, 0xFFC27A as UInt32), (CGPoint(x: 590, y: 370), 320.0, 0x9A4DFF)] {
        let g = CGGradient(colorsSpace: space, colors: [color(hex, 0.22), color(hex, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    // 箭头：从应用图标指向 Applications（两图标位于 x = 170 和 490，y = 190，原点在左下时 y = 210）
    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: 268, y: 218))
    arrow.addQuadCurve(to: CGPoint(x: 388, y: 218), control: CGPoint(x: 328, y: 248))
    let head = CGMutablePath()
    head.move(to: CGPoint(x: 376, y: 234))
    head.addLine(to: CGPoint(x: 392, y: 216))
    head.addLine(to: CGPoint(x: 368, y: 212))
    let outline = CGMutablePath()
    outline.addPath(arrow)
    outline.addPath(head)
    ctx.saveGState()
    ctx.addPath(outline.copy(strokingWithWidth: 5, lineCap: .round, lineJoin: .round, miterLimit: 2))
    ctx.clip()
    let stroke = CGGradient(colorsSpace: space, colors: [color(0xE8743A), color(0x7A35E0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(stroke, start: CGPoint(x: 268, y: 0), end: CGPoint(x: 392, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    // 说明同时写两种语言：这一步还没有语言可选
    let hint = NSAttributedString(string: "拖到 Applications 完成安装  ·  Drag to Applications to install", attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor(srgbRed: 0.33, green: 0.33, blue: 0.37, alpha: 1),
    ])
    let line = hint.size()
    hint.draw(at: CGPoint(x: (size.width - line.width) / 2, y: 62))

    NSGraphicsContext.current = nil
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
}

render(scale: 1, to: "bg.png")
render(scale: 2, to: "bg@2x.png")
