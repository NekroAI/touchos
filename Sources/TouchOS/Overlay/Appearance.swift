import AppKit
import SwiftUI
import TouchOSCore

/// 浮层主题（D23）：只决定画法，交互、命中与动效时序都与主题无关；主题、切换动画、强调色可以自由组合
enum OverlayTheme: String, CaseIterable, Sendable {
    /// B：玻璃圆钮（默认）
    case orb
    /// A：液态光斑——按钮没有底板，一块共享的玻璃跟着悬停在按钮之间流动
    case lens
    /// C：全息线框——细线、角标、等宽字、点阵底
    case holo

    var title: String {
        switch self {
        case .orb: "玻璃圆钮"
        case .lens: "液态光斑"
        case .holo: "全息线框"
        }
    }
}

/// 面板之间的切换动画（D23）
enum NavStyle: String, CaseIterable, Sendable {
    /// 深度堆叠：后面的面板缩小、上移、模糊，翻过去的面板放大淡出
    case depth
    /// 立体滚筒：面板排在一个水平轴的滚筒上翻转
    case drum

    var title: String {
        switch self {
        case .depth: "深度堆叠"
        case .drum: "立体滚筒"
        }
    }
}

/// 外观设置（K8 配置的 `appearance` 段），下一次唤起生效
struct Appearance: Equatable, Sendable {
    /// 强调色预设（名称、RRGGBB）
    static let presets: [(name: String, hex: String)] = [
        ("蓝", "0A84FF"), ("紫", "BF5AF2"), ("粉", "FF375F"), ("橙", "FF9F0A"), ("绿", "30D158"), ("青", "5BE7FF"),
    ]
    /// 全息主题在"自动"强调色下用青色
    static let holoAccent = "5BE7FF"

    var theme = OverlayTheme.orb
    var nav = NavStyle.depth
    /// 强调色 RRGGBB；nil 为自动（跟随系统强调色）
    var accentHex: String?

    init() {}

    init(_ c: AppConfig.Appearance) {
        theme = OverlayTheme(rawValue: c.theme) ?? .orb
        nav = NavStyle(rawValue: c.nav) ?? .depth
        accentHex = c.accent.flatMap { Self.rgb($0) == nil ? nil : $0 }
    }

    var config: AppConfig.Appearance {
        var c = AppConfig.Appearance()
        c.theme = theme.rawValue
        c.nav = nav.rawValue
        c.accent = accentHex
        return c
    }

    var accent: Color {
        if let c = (accentHex ?? (theme == .holo ? Self.holoAccent : nil)).flatMap(Self.rgb) {
            return Color(.sRGB, red: c.r, green: c.g, blue: c.b)
        }
        return .accentColor
    }

    static func rgb(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double(v >> 16 & 0xFF) / 255, Double(v >> 8 & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    static func hex(of color: NSColor) -> String? {
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }
}

/// 视图树里传递的外观
struct OverlayStyle {
    var theme = OverlayTheme.orb
    var nav = NavStyle.depth
    var accent = Color.accentColor

    init() {}

    init(_ appearance: Appearance) {
        theme = appearance.theme
        nav = appearance.nav
        accent = appearance.accent
    }
}

extension EnvironmentValues {
    @Entry var overlayStyle = OverlayStyle()
}

/// 菜单栏"外观"子菜单：主题、切换动画、强调色（含系统取色器）
@MainActor
final class AppearanceMenu: NSObject {
    let item = NSMenuItem(title: "外观", action: nil, keyEquivalent: "")
    private let read: () -> Appearance
    private let write: (Appearance) -> Void

    init(read: @escaping () -> Appearance, write: @escaping (Appearance) -> Void) {
        self.read = read
        self.write = write
        super.init()
        rebuild()
    }

    func rebuild() {
        let current = read()
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: "主题"))
        for (i, theme) in OverlayTheme.allCases.enumerated() {
            let title = theme == .orb ? "\(theme.title)（默认）" : theme.title
            menu.addItem(entry(title, #selector(pickTheme(_:)), tag: i, on: current.theme == theme))
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "切换动画"))
        for (i, nav) in NavStyle.allCases.enumerated() {
            menu.addItem(entry(nav.title, #selector(pickNav(_:)), tag: i, on: current.nav == nav))
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "强调色"))
        menu.addItem(entry("自动", #selector(pickAccent(_:)), tag: -1, on: current.accentHex == nil))
        for (i, preset) in Appearance.presets.enumerated() {
            let item = entry(preset.name, #selector(pickAccent(_:)), tag: i, on: current.accentHex == preset.hex)
            item.image = Self.swatch(preset.hex)
            menu.addItem(item)
        }
        let custom = current.accentHex.flatMap { hex in Appearance.presets.contains { $0.hex == hex } ? nil : hex }
        let item = entry("自定义…", #selector(pickCustomAccent), tag: 0, on: custom != nil)
        item.image = custom.flatMap { Self.swatch($0) }
        menu.addItem(item)
        self.item.submenu = menu
    }

    private func entry(_ title: String, _ action: Selector, tag: Int, on: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag = tag
        item.state = on ? .on : .off
        return item
    }

    private func update(_ change: (inout Appearance) -> Void) {
        var a = read()
        change(&a)
        write(a)
        rebuild()
    }

    @objc private func pickTheme(_ item: NSMenuItem) {
        update { $0.theme = OverlayTheme.allCases[item.tag] }
    }

    @objc private func pickNav(_ item: NSMenuItem) {
        update { $0.nav = NavStyle.allCases[item.tag] }
    }

    @objc private func pickAccent(_ item: NSMenuItem) {
        update { $0.accentHex = item.tag < 0 ? nil : Appearance.presets[item.tag].hex }
    }

    @objc private func pickCustomAccent() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        if let c = read().accentHex.flatMap(Appearance.rgb) {
            panel.color = NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
        }
        panel.setTarget(self)
        panel.setAction(#selector(colorPicked(_:)))
        NSApp.activate()
        panel.orderFrontRegardless()
    }

    @objc private func colorPicked(_ panel: NSColorPanel) {
        guard let hex = Appearance.hex(of: panel.color) else { return }
        update { $0.accentHex = hex }
    }

    private static func swatch(_ hex: String) -> NSImage? {
        guard let c = Appearance.rgb(hex) else { return nil }
        return NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}
