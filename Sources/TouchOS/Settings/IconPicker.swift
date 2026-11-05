import AppKit
import SwiftUI
import TouchOSCore
import UniformTypeIdentifiers

// 按钮图标的编辑（D58）：SF 符号（完整符号库，分类与搜索）或应用图标；以及选应用的菜单（D59）

/// 属性栏标题处的图标：应用图标用原色，便于认出是哪个应用
struct SlotIconPreview: View {
    let slot: Slot

    var body: some View {
        if let id = slot.appIcon, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: SymbolCatalog.valid(slot.symbol))
        }
    }
}

/// 图标：符号或应用
struct IconField: View {
    @Binding var symbol: String
    @Binding var appIcon: String?
    /// 动作打开的应用，切到「应用」时默认用它
    let actionApp: String?
    @State private var browsing = false

    var body: some View {
        Picker("图标", selection: makeBinding(get: { appIcon != nil }, set: { useApp in
            if !useApp { appIcon = nil } else if let id = actionApp ?? AppChooser.pick() { appIcon = id }
        })) {
            Text("符号").tag(false)
            Text("应用图标").tag(true)
        }
        .pickerStyle(.segmented)
        if let id = appIcon {
            LabeledContent("应用") {
                HStack {
                    AppLabel(bundleID: id)
                    Button("选择…") { if let picked = AppChooser.pick() { appIcon = picked } }
                }
            }
        } else {
            LabeledContent("符号") {
                HStack {
                    Image(systemName: SymbolCatalog.valid(symbol)).frame(width: 22)
                    TextField("SF Symbols 名称", text: $symbol).labelsHidden()
                    Button { browsing = true } label: { Image(systemName: "square.grid.3x3") }
                        .help("浏览符号")
                        .popover(isPresented: $browsing) { SymbolBrowser { symbol = $0; browsing = false } }
                }
            }
        }
    }
}

/// 符号库：常用在前，其余按系统的分类，可按名称与关键词搜索
private struct SymbolBrowser: View {
    let pick: (String) -> Void
    @State private var query = ""
    @State private var category = SymbolCatalog.common

    static let columns = 9
    static let cell: CGFloat = 34

    var body: some View {
        let names = SymbolCatalog.shared.names(category: category, query: query)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("搜索（英文名称或关键词）", text: $query).textFieldStyle(.roundedBorder)
                Picker("分类", selection: $category) {
                    ForEach(SymbolCatalog.shared.categories, id: \.key) { c in
                        Label(c.title, systemImage: c.icon).tag(c.key)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!query.isEmpty)
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cell), spacing: 4), count: Self.columns), spacing: 4) {
                    ForEach(names, id: \.self) { name in
                        Button { pick(name) } label: {
                            Image(systemName: name).font(.system(size: 16)).frame(width: Self.cell, height: Self.cell)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .help(name)
                    }
                }
            }
            .frame(height: 300)
            Text(names.isEmpty ? String(localized: "没有找到") : String(localized: "\(names.count) 个符号"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(width: CGFloat(Self.columns) * (Self.cell + 4) + 20)
    }
}

/// SF 符号的名称、分类与搜索关键词。
/// 来源：系统 CoreGlyphs 资源包里的 symbol_order / symbol_categories / symbol_search（未公开的数据文件，
/// 与 SF Symbols 应用读的是同一份）。读不到时只提供手选的常用符号，搜索只匹配名称
@MainActor
final class SymbolCatalog {
    static let shared = SymbolCatalog()
    static let common = "common"
    static let all = "all"

    static let resources = URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources")

    /// 常用：按钮最常见的用途
    static let commonNames = [
        "star", "heart", "bolt", "flame", "plus.square", "xmark.square", "arrow.clockwise", "arrow.uturn.backward",
        "arrow.uturn.forward", "magnifyingglass", "chevron.backward", "chevron.forward", "doc.on.doc", "doc.on.clipboard",
        "scissors", "square.and.arrow.down", "square.and.arrow.up", "trash", "folder", "terminal", "gearshape", "camera.viewfinder",
        "lock", "moon", "sun.max", "speaker.wave.2", "speaker.slash", "play.fill", "pause.fill", "forward.fill", "backward.fill",
        "music.note", "mic", "video", "message", "envelope", "calendar", "note.text", "globe", "safari", "link", "bookmark",
        "rectangle.lefthalf.filled", "rectangle.righthalf.filled", "rectangle.inset.filled", "macwindow", "display.2", "keyboard",
        "command", "option", "eye.slash", "minus.rectangle", "photo", "paintbrush", "pencil", "wand.and.stars", "sparkles",
        "app", "app.badge", "square.grid.2x2", "doc.text", "list.bullet", "checklist", "clock", "timer", "alarm", "bell",
        "house", "person", "person.2", "cart", "creditcard", "map", "location", "airplane", "car", "cloud", "wifi", "printer",
        "externaldrive", "server.rack", "cpu", "hammer", "wrench.and.screwdriver", "ladybug", "chevron.left.forwardslash.chevron.right",
        "text.bubble", "phone", "translate", "character.book.closed", "book", "graduationcap", "lightbulb", "flag", "tag", "pin",
    ]

    /// 系统分类里不适合挑按钮图标的（新增、可变、多色、可绘制）
    static let skippedCategories: Set<String> = ["whatsnew", "variable", "multicolor", "draw"]
    /// 各语言文字的变体（如 `.ar`、`.zh`）与从右到左的变体，列表里只留基础的一个
    static let variantSuffixes: Set<String> = [
        "ar", "hi", "rtl", "he", "ja", "th", "zh", "bn", "gu", "kn", "ko", "ml", "mni", "mr", "or", "pa", "sat", "te", "si", "ta", "el", "ru",
    ]

    struct Category {
        let key: String
        let title: String
        let icon: String
    }

    private(set) var categories: [Category] = []
    private var ordered: [String] = []
    private var byCategory: [String: [String]] = [:]
    private var keywords: [String: [String]] = [:]

    private init() {
        categories = [Category(key: Self.common, title: String(localized: "常用"), icon: "star")]
        guard let order = Self.plist("symbol_order") as? [String] else { return }
        let restricted = Set((Self.plist("symbol_restrictions", ext: "strings") as? [String: String])?.keys.map { $0 } ?? [])
        let all = Set(order)
        ordered = order.filter { name in
            guard !restricted.contains(name) else { return false }
            let parts = name.split(separator: ".")
            guard parts.count > 1, let last = parts.last, Self.variantSuffixes.contains(String(last)) else { return true }
            return !all.contains(parts.dropLast().joined(separator: "."))
        }
        let kept = Set(ordered)
        if let map = Self.plist("symbol_categories") as? [String: [String]] {
            var groups: [String: [String]] = [:]
            for name in ordered { for key in map[name] ?? [] { groups[key, default: []].append(name) } }
            byCategory = groups
        }
        keywords = (Self.plist("symbol_search") as? [String: [String]])?.filter { kept.contains($0.key) } ?? [:]
        let listed = (Self.plist("categories") as? [[String: String]]) ?? []
        categories.append(Category(key: Self.all, title: String(localized: "全部"), icon: "square.grid.2x2"))
        for c in listed {
            guard let key = c["key"], key != Self.all, !Self.skippedCategories.contains(key), byCategory[key] != nil else { continue }
            categories.append(Category(key: key, title: Self.title(key), icon: c["icon"] ?? "square"))
        }
    }

    func names(category: String, query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.isEmpty else {
            let pool = ordered.isEmpty ? Self.commonNames : ordered
            return pool.filter { name in name.contains(q) || (keywords[name]?.contains { $0.hasPrefix(q) } ?? false) }
        }
        switch category {
        case Self.common: return Self.commonNames
        case Self.all: return ordered
        default: return byCategory[category] ?? []
        }
    }

    /// 图标名无效时显示占位
    static func valid(_ name: String) -> String {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil ? "questionmark.square.dashed" : name
    }

    private static func plist(_ name: String, ext: String = "plist") -> Any? {
        guard let data = try? Data(contentsOf: resources.appendingPathComponent("\(name).\(ext)")) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }

    private static func title(_ key: String) -> String {
        switch key {
        case "communication": String(localized: "通讯")
        case "weather": String(localized: "天气")
        case "maps": String(localized: "地图")
        case "objectsandtools": String(localized: "物品与工具")
        case "devices": String(localized: "设备")
        case "cameraandphotos": String(localized: "相机与照片")
        case "gaming": String(localized: "游戏")
        case "connectivity": String(localized: "连接")
        case "transportation": String(localized: "交通")
        case "automotive": String(localized: "汽车")
        case "accessibility": String(localized: "辅助功能")
        case "privacyandsecurity": String(localized: "隐私与安全")
        case "human": String(localized: "人物")
        case "home": String(localized: "家居")
        case "fitness": String(localized: "健身")
        case "nature": String(localized: "自然")
        case "editing": String(localized: "编辑")
        case "textformatting": String(localized: "文本格式")
        case "media": String(localized: "媒体")
        case "keyboard": String(localized: "键盘")
        case "commerce": String(localized: "商务")
        case "time": String(localized: "时间")
        case "health": String(localized: "健康")
        case "shapes": String(localized: "形状")
        case "arrows": String(localized: "箭头")
        case "indices": String(localized: "编号")
        case "math": String(localized: "数学")
        default: key.capitalized
        }
    }
}

/// 选应用的菜单：能打开网页的应用（浏览器）列在前面，「其他应用…」打开文件选择（D59）
struct AppMenu: View {
    /// nil 为默认浏览器
    let bundleID: String?
    let allowsDefault: Bool
    let set: (String?) -> Void

    var body: some View {
        Menu {
            if allowsDefault {
                Button("默认浏览器") { set(nil) }
                Divider()
            }
            ForEach(AppChooser.browsers, id: \.self) { id in
                Button { set(id) } label: {
                    Label { Text(AppLabel.name(id)) } icon: { Image(nsImage: AppChooser.menuIcon(id)) }
                }
            }
            Divider()
            Button("其他应用…") { if let picked = AppChooser.pick() { set(picked) } }
        } label: {
            if let bundleID { AppLabel(bundleID: bundleID) } else { Text("默认浏览器") }
        }
        .fixedSize()
    }
}

enum AppChooser {
    /// 菜单里的应用图标边长
    static let menuIconSize: CGFloat = 16

    /// 能打开 https 链接的应用（去重，按名称排序）。只取装在应用目录里的：系统还会列出其他应用数据目录里的
    /// 副本（更新器下载的、测试工具缓存的），读它们会触发系统的「访问其他应用的数据」拦截提示
    static var browsers: [String] {
        guard let probe = URL(string: "https://example.com") else { return [] }
        let ids = NSWorkspace.shared.urlsForApplications(toOpen: probe).filter { !$0.path.contains("/Library/") }
            .compactMap { Bundle(url: $0)?.bundleIdentifier }
        return Array(Set(ids)).sorted { AppLabel.name($0).localizedStandardCompare(AppLabel.name($1)) == .orderedAscending }
    }

    static var defaultBrowser: String? {
        guard let probe = URL(string: "https://example.com"), let url = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }

    @MainActor static func menuIcon(_ bundleID: String) -> NSImage {
        let image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage()
        image.size = NSSize(width: menuIconSize, height: menuIconSize)
        return image
    }

    @MainActor static func pick() -> String? {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }
}
