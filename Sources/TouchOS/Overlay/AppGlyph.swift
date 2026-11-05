import AppKit
import SwiftUI
import TouchOSCore

/// 应用图标的单色版（D58）：和 SF 符号一样只有形状，颜色跟随各主题的前景色（圆钮、光斑为白，全息为强调色）。
/// 做法：取图标的亮度，按图标底色的亮度决定正反（浅底图标反过来），与底色差得越多越不透明，
/// 于是标志本身是实的，圆角方底只剩一层淡淡的轮廓。生成一次按 bundle ID 缓存，浮层里只贴图
@MainActor
enum AppGlyph {
    /// 生成的位图边长（px），浮层里最大约 40 pt，2 倍屏足够
    static let pixels = 128
    /// 图标底板的最低不透明度：保留圆角方底的轮廓，看得出这是应用
    static let plateOpacity = 0.07
    /// 与底色的亮度差乘上它再截到 1，再过一道平滑曲线：标志实、过渡区收窄，接近符号的干净边缘
    static let contrastGain = 2.2
    /// 判断为浅底的阈值（底板一圈的平均亮度）
    static let lightPlate = 0.55
    /// 统计底色时只看离中心这么远之外的一圈（以半边长为 1）
    static let plateRing = 0.62
    /// 亮度拉伸时两端各舍去的比例，个别极亮极暗的像素不影响整体
    static let clip = 0.03
    /// 图标画布四周有留白，显示尺寸比符号的字号大这么多倍，看上去才一样大
    static let scale: CGFloat = 1.5
    /// 参与排版的边长与字号之比：与符号占的高度相当，画得比它大的部分溢出，不把下方的名称挤低
    static let layoutScale: CGFloat = 1.2

    private static var cache: [String: NSImage] = [:]

    /// 应用未安装时为 nil（不缓存，装上后即可显示）
    static func image(_ bundleID: String) -> NSImage? {
        if let hit = cache[bundleID] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let image = make(NSWorkspace.shared.icon(forFile: url.path)) else { return nil }
        cache[bundleID] = image
        return image
    }

    private static func smoothstep(_ x: Double) -> Double { x * x * (3 - 2 * x) }

    private static func make(_ icon: NSImage) -> NSImage? {
        let n = pixels, count = n * n
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var rgba = [UInt8](repeating: 0, count: count * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            icon.draw(in: NSRect(x: 0, y: 0, width: n, height: n))
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        guard drawn else { return nil }

        var alpha = [Double](repeating: 0, count: count), luma = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let a = Double(rgba[i * 4 + 3]) / 255
            alpha[i] = a
            guard a > 0 else { continue }
            let r = Double(rgba[i * 4]) / 255 / a, g = Double(rgba[i * 4 + 1]) / 255 / a, b = Double(rgba[i * 4 + 2]) / 255 / a
            luma[i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        let solid = (0..<count).filter { alpha[$0] > 0.5 }.map { luma[$0] }.sorted()
        guard !solid.isEmpty else { return nil }
        let lo = solid[Int(Double(solid.count - 1) * clip)], hi = solid[Int(Double(solid.count - 1) * (1 - clip))]
        let range = max(hi - lo, 0.001)

        // 底色：外圈不透明像素的平均亮度
        var plate = 0.0, plateCount = 0
        let half = Double(n) / 2
        for y in 0..<n {
            for x in 0..<n where alpha[y * n + x] > 0.9 {
                if max(abs(Double(x) + 0.5 - half), abs(Double(y) + 0.5 - half)) / half > plateRing {
                    plate += luma[y * n + x]
                    plateCount += 1
                }
            }
        }
        let base = min(max(((plateCount > 0 ? plate / Double(plateCount) : solid[solid.count / 2]) - lo) / range, 0), 1)

        // 输出：白色，透明度为形状；作为模板图，前景色决定颜色
        var out = [UInt8](repeating: 0, count: count * 4)
        for i in 0..<count where alpha[i] > 0 {
            let t = min(max((luma[i] - lo) / range, 0), 1)
            let a = alpha[i] * (plateOpacity + (1 - plateOpacity) * smoothstep(min(abs(t - base) * contrastGain, 1)))
            let v = UInt8((a * 255).rounded())
            out[i * 4] = v; out[i * 4 + 1] = v; out[i * 4 + 2] = v; out[i * 4 + 3] = v
        }
        let cg: CGImage? = out.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        guard let cg else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: n, height: n))
        image.isTemplate = true
        return image
    }
}

extension Slot {
    /// 图标的身份，预渲染的衬底按它缓存
    var iconKey: String { appIcon.map { "app:" + $0 } ?? symbol }

    /// 按钮中间画名称而不是图标（D30）
    var showsTitleAsGlyph: Bool { symbol.isEmpty && appIcon == nil }
}

/// 按钮图标：应用图标的单色版（D58）或 SF 符号，颜色都跟随前景色。应用未安装时退回符号
struct SlotSymbol: View {
    let slot: Slot
    let size: CGFloat
    var weight: Font.Weight = .regular

    var body: some View {
        if let id = slot.appIcon, let image = AppGlyph.image(id) {
            Image(nsImage: image).renderingMode(.template).resizable().interpolation(.high)
                .frame(width: size * AppGlyph.scale, height: size * AppGlyph.scale)
                .frame(width: size * AppGlyph.layoutScale, height: size * AppGlyph.layoutScale)
        } else {
            Image(systemName: slot.symbol.isEmpty ? "app.dashed" : slot.symbol).font(.system(size: size, weight: weight))
        }
    }
}
