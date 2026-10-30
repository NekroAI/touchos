import AppKit
import ServiceManagement
import SwiftUI
import TouchOSCore

/// 设置窗口（K12、SRS 第 11 章）：面板、唤起与手感、外观、通用、关于。所有修改立即生效并防抖写盘
@MainActor
final class SettingsWindowController {
    private let configs: ConfigController
    private let executor: ActionExecutor
    private let cloud: CloudSyncController
    private let navigation = SettingsNavigation()
    private var window: NSWindow?

    init(configs: ConfigController, executor: ActionExecutor, cloud: CloudSyncController) {
        self.configs = configs
        self.executor = executor
        self.cloud = cloud
    }

    func show(page: SettingsPage? = nil) {
        if let page { navigation.page = page }
        let window = self.window ?? makeWindow()
        self.window = window
        // 从触控板手势打开时本应用不在前台，系统可以拒绝激活（macOS 14 起为协作式激活），
        // 只 makeKeyAndOrderFront 窗口会落在当前应用后面；orderFrontRegardless 保证它出现在最前
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// 在关闭上按住后打开：直接进入该面板的编辑（D23）
    func show(editing panelID: String) {
        navigation.open(panel: panelID)
        show()
    }

    private func makeWindow() -> NSWindow {
        let root = SettingsRoot(configs: configs, executor: executor, cloud: cloud, navigation: navigation)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = String(localized: "TouchOS 设置")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 1120, height: 720))
        window.minSize = NSSize(width: 980, height: 620)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("TouchOSSettings")
        return window
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case panels, triggers, appearance, general, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .panels: String(localized: "面板")
        case .triggers: String(localized: "唤起与手感")
        case .appearance: String(localized: "外观")
        case .general: String(localized: "通用")
        case .about: String(localized: "关于")
        }
    }

    var symbol: String {
        switch self {
        case .panels: "square.grid.3x2"
        case .triggers: "hand.tap"
        case .appearance: "paintpalette"
        case .general: "gearshape"
        case .about: "info.circle"
        }
    }
}

/// 当前页与编辑器的选中项
@MainActor
@Observable
final class SettingsNavigation {
    var page = SettingsPage.panels
    var selectedPanel: String?
    var selectedSlot: SlotID?

    func open(panel id: String?) {
        page = .panels
        selectedPanel = id
        selectedSlot = nil
    }
}

/// 侧栏选中项：某个面板，或某个设置页
private enum SidebarItem: Hashable {
    case panel(String)
    case page(SettingsPage)
}

private struct SettingsRoot: View {
    let configs: ConfigController
    let executor: ActionExecutor
    let cloud: CloudSyncController
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            Sidebar(configs: configs, navigation: navigation)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            VStack(spacing: 0) {
                if let problem = configs.problem {
                    ProblemBanner(text: problem) { navigation.page = .general }
                }
                switch navigation.page {
                case .panels:
                    let panels = configs.config.panels
                    if let panel = panels.first(where: { $0.id == navigation.selectedPanel }) ?? panels.first {
                        PanelEditorPage(configs: configs, executor: executor, navigation: navigation, panel: panel)
                            .id(panel.id)
                    }
                case .triggers: TriggersPage(configs: configs)
                case .appearance: AppearancePage(configs: configs)
                case .general: GeneralPage(configs: configs, cloud: cloud)
                case .about: AboutPage()
                }
            }
            .navigationTitle(title)
        }
    }

    private var title: String {
        navigation.page.title
    }
}

/// 侧栏：上面是面板（可拖动排序，第一个为默认），下面是设置页
private struct Sidebar: View {
    let configs: ConfigController
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        List(selection: selection) {
            Section {
                ForEach(configs.config.panels, id: \.id) { panel in
                    let isDefault = configs.config.defaultPanel?.id == panel.id
                    HStack(spacing: 10) {
                        PanelThumbnail(panel: panel)
                        Text(panel.name).lineLimit(1)
                        Spacer(minLength: 4)
                        if isDefault || !panel.isEnabled {
                            Text(isDefault ? "默认" : "已停用").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(.quaternary))
                        }
                    }
                    .opacity(panel.isEnabled ? 1 : 0.5)
                    .tag(SidebarItem.panel(panel.id))
                    .contextMenu {
                        Button("复制") { PanelCommands.add(panel, configs: configs, navigation: navigation) }
                        Button("设为默认面板") { PanelCommands.makeDefault(panel.id, configs: configs) }.disabled(isDefault || !panel.isEnabled)
                        Divider()
                        Button("删除", role: .destructive) { PanelCommands.remove(panel.id, configs: configs, navigation: navigation) }
                            .disabled(configs.config.panels.count <= 1)
                    }
                }
                .onMove { from, to in configs.update { $0.panels.move(fromOffsets: from, toOffset: to) } }
            } header: {
                HStack {
                    Text("面板")
                    Spacer()
                    Menu {
                        PanelCommands.addMenu(configs: configs, navigation: navigation)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("新建面板")
                }
            }
            Section("设置") {
                ForEach(SettingsPage.allCases.filter { $0 != .panels }) { page in
                    Label(page.title, systemImage: page.symbol).tag(SidebarItem.page(page))
                }
            }
        }
    }

    private var selection: Binding<SidebarItem?> {
        Binding {
            if navigation.page == .panels {
                return (navigation.selectedPanel ?? configs.config.panels.first?.id).map(SidebarItem.panel)
            }
            return .page(navigation.page)
        } set: { item in
            switch item {
            case .panel(let id): if id != navigation.selectedPanel || navigation.page != .panels { navigation.open(panel: id) }
            case .page(let page): navigation.page = page
            case nil: break
            }
        }
    }
}

/// FR-10.2：配置已损坏，可从备份恢复
private struct ProblemBanner: View {
    let text: String
    let open: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text("配置已损坏，正在使用默认配置（原文件未改动），可从备份恢复。\(text)").lineLimit(2)
            Spacer()
            Button("查看备份", action: open)
        }
        .font(.callout)
        .padding(10)
        .background(.yellow.opacity(0.12))
    }
}

/// 双向绑定一律经由这个泛型函数创建，不在具体类型上直接写 `Binding(get:set:)`：CI 所用的 Swift 6.3.3（Xcode 26.6）
/// 为具体类型（如 Bool）的绑定闭包生成重抽象 thunk 时编译器崩溃，泛型上下文里不生成这类 thunk
@MainActor
func makeBinding<T>(get: @escaping @MainActor @Sendable () -> T, set: @escaping @MainActor @Sendable (T) -> Void) -> Binding<T> {
    Binding(get: get, set: set)
}

/// 把配置中的一个字段做成双向绑定，修改即写回
@MainActor
func binding<T>(_ configs: ConfigController, _ path: WritableKeyPath<AppConfig, T>) -> Binding<T> {
    makeBinding(get: { configs.config[keyPath: path] }, set: { v in configs.update { $0[keyPath: path] = v } })
}

/// 分组表单下方的说明：左对齐（macOS 默认把 footer 靠右排）
struct FormFooter: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Self.inset)
    }

    /// 与分组标题、分组内文字的左缘对齐
    static let inset: CGFloat = 10
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step = 0.05
    var format: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }

    var body: some View {
        LabeledContent(title) {
            HStack {
                // 不用 step：macOS 会为每一档画刻度，改为写入时取整
                Slider(value: makeBinding(get: { value }, set: { value = ($0 / step).rounded() * step }), in: range)
                Text(format(value)).monospacedDigit().frame(width: 52, alignment: .trailing)
            }
        }
    }
}

// MARK: 外观

private struct AppearancePage: View {
    let configs: ConfigController

    var body: some View {
        let appearance = Appearance(configs.config.appearance)
        Form {
            Section("主题") {
                HStack(spacing: 14) {
                    ForEach(OverlayTheme.allCases, id: \.self) { theme in
                        ThemeCard(theme: theme, selected: appearance.theme == theme, accent: Appearance(withTheme: theme, from: appearance).accent)
                            .onTapGesture { set { $0.theme = theme } }
                    }
                }
                .padding(.vertical, 4)
            }
            Section("面板切换动画") {
                Picker("切换动画", selection: makeBinding(get: { appearance.nav }, set: { n in set { $0.nav = n } })) {
                    ForEach(NavStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("强调色") {
                HStack(spacing: 10) {
                    AccentSwatch(color: .accentColor, label: String(localized: "自动"), selected: appearance.accentHex == nil) { set { $0.accentHex = nil } }
                    ForEach(Appearance.presets, id: \.hex) { preset in
                        let c = Appearance.rgb(preset.hex)!
                        AccentSwatch(color: Color(.sRGB, red: c.r, green: c.g, blue: c.b), label: preset.name,
                                     selected: appearance.accentHex == preset.hex) { set { $0.accentHex = preset.hex } }
                    }
                    Divider().frame(height: 30)
                    ColorPicker("自定义", selection: makeBinding(get: { appearance.accent }, set: { color in
                        if let hex = Appearance.hex(of: NSColor(color)) { set { $0.accentHex = hex } }
                    }), supportsOpacity: false)
                }
            }
            Section("其它") {
                Toggle("显示手指轨迹", isOn: binding(configs, \.general.showTrail))
                Toggle("面板出现时压暗背景", isOn: binding(configs, \.general.dimBackground))
            }
        }
        .formStyle(.grouped)
    }

    private func set(_ change: (inout Appearance) -> Void) {
        var a = Appearance(configs.config.appearance)
        change(&a)
        configs.update { $0.appearance = a.config }
    }
}

extension Appearance {
    /// 换成另一个主题后的外观（预览卡片用：全息主题在自动强调色下为青色）
    init(withTheme theme: OverlayTheme, from other: Appearance) {
        self = other
        self.theme = theme
    }
}

/// 主题预览卡片：深色底上画三枚按钮的缩影
private struct ThemeCard: View {
    let theme: OverlayTheme
    let selected: Bool
    let accent: Color

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.1))
                HStack(spacing: 12) {
                    ForEach(0..<3) { i in sample(lit: i == 1) }
                }
            }
            .frame(width: 180, height: 96)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? accent : Color.secondary.opacity(0.3), lineWidth: selected ? 2 : 1))
            Text(theme == .orb ? String(localized: "\(theme.title)（默认）") : theme.title).font(.callout)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private func sample(lit: Bool) -> some View {
        switch theme {
        case .orb:
            Circle().fill(lit ? accent.opacity(0.7) : Color.white.opacity(0.12))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 0.5))
                .overlay(Image(systemName: "star").foregroundStyle(.white))
                .frame(width: 38, height: 38)
        case .lens:
            Image(systemName: "star").font(.system(size: 18)).foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(lit ? RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.16)) : nil)
                .shadow(color: lit ? accent.opacity(0.6) : .clear, radius: 8)
        case .holo:
            Image(systemName: "star").font(.system(size: 17, weight: .light)).foregroundStyle(accent)
                .frame(width: 44, height: 44)
                .overlay(CornerBrackets(length: 8, inset: lit ? 0 : 4).stroke(accent.opacity(lit ? 1 : 0.5), lineWidth: 1.2))
        }
    }
}

private struct AccentSwatch: View {
    let color: Color
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Circle().fill(color).frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.9 : 0), lineWidth: 2).padding(-3))
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: 通用

private struct GeneralPage: View {
    let configs: ConfigController
    let cloud: CloudSyncController
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var language = AppLanguage.selected
    /// 这个进程启动时的选择，变了才需要重启
    private let launchLanguage = AppLanguage.selected
    @State private var message: String?
    @State private var pendingImport: (config: AppConfig, risky: [(panel: String, slot: String, action: Action)])?

    var body: some View {
        Form {
            Section {
                Toggle("启用 TouchOS", isOn: binding(configs, \.general.enabled))
                Toggle("登录时启动", isOn: makeBinding(get: { launchAtLogin }, set: setLaunchAtLogin))
            }
            Section {
                Picker(selection: makeBinding(get: { language }, set: { AppLanguage.select($0); language = $0 })) {
                    ForEach(AppLanguage.allCases) { Text(verbatim: $0.nativeName).tag($0) }
                } label: {
                    Text("语言")
                    Text("已有面板的名称不会跟着改变。")
                }
                if language != launchLanguage {
                    Button("重启以应用") { AppLanguage.relaunch() }
                }
            }
            Section {
                Toggle(isOn: binding(configs, \.general.focusPointerWindow)) {
                    Text("动作发往指针下的窗口")
                    Text("快捷键与窗口摆放执行前，先把指针所在的窗口切到前台（相当于点了它一下）。关闭后发往唤起时的前台应用。")
                }
                Toggle(isOn: binding(configs, \.general.checkUpdates)) {
                    Text("检查更新")
                    Text("每天向 GitHub 查询一次最新版本，有新版本时在菜单中提示。不会自动下载或安装，也不发送任何触控或配置信息。")
                }
            }
            Section {
                ForEach(configs.config.general.blacklist, id: \.self) { id in
                    HStack {
                        AppLabel(bundleID: id)
                        Spacer()
                        Button(role: .destructive) { configs.update { $0.general.blacklist.removeAll { $0 == id } } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Menu("添加正在运行的应用") {
                    ForEach(runningApps, id: \.bundleIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "") {
                            if let id = app.bundleIdentifier { configs.update { $0.general.blacklist.append(id) } }
                        }
                    }
                }
            } header: {
                Text("排除的应用")
            } footer: {
                FormFooter(String(localized: "这些应用在前台时不唤起面板（例如游戏、远程桌面）。"))
            }
            Section {
                Toggle(isOn: makeBinding(get: { configs.config.sync.iCloud }, set: { cloud.setEnabled($0) })) {
                    Text("通过 iCloud 同步配置")
                    Text(cloudStatus).foregroundStyle(cloudStatusIsProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
                .disabled(!cloud.isAvailable && !configs.config.sync.iCloud)
                LabeledContent("存放位置") {
                    HStack {
                        Text("iCloud 云盘 › \(CloudSync.folderName)").foregroundStyle(.secondary)
                        Button("在访达中显示") { cloud.revealInFinder() }.disabled(!cloud.isAvailable)
                    }
                }
            } header: {
                Text("iCloud 同步")
            } footer: {
                FormFooter(String(localized: "面板、外观、唤起方式、排除的应用在各台 Mac 之间同步；面板大小、映射区、按钮间隙与「启用 TouchOS」只属于这台 Mac。在另一台 Mac 上安装后打开这个开关即可接入。"))
            }
            Section("配置文件") {
                HStack {
                    Button("导出…", action: exportConfig)
                    Button("导入…", action: importConfig)
                    Button("在访达中显示") { configs.revealInFinder() }
                    Spacer()
                    Menu("从备份恢复") {
                        ForEach(configs.backups, id: \.self) { url in
                            Button(url.deletingPathExtension().lastPathComponent) { restore(url) }
                        }
                    }
                    .disabled(configs.backups.isEmpty)
                    .fixedSize()
                }
                if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: makeBinding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } })) {
            if let pending = pendingImport {
                ImportConfirmation(risky: pending.risky) { accept in
                    if accept {
                        var c = pending.config
                        c.sync = configs.config.sync  // 同步开关只属于这台 Mac（D35）
                        configs.replace(c)
                        message = String(localized: "已导入")
                    }
                    pendingImport = nil
                }
            }
        }
    }

    private var cloudStatus: String {
        switch cloud.status {
        case .off: cloud.isAvailable ? String(localized: "未开启") : String(localized: "这台 Mac 没有开启 iCloud 云盘（系统设置 → Apple 账户 → iCloud）")
        case .unavailable: String(localized: "这台 Mac 没有开启 iCloud 云盘（系统设置 → Apple 账户 → iCloud）")
        case .downloading: String(localized: "正在从 iCloud 下载配置…")
        case .synced(let date): String(localized: "已同步 · \(date.formatted(date: .omitted, time: .shortened))")
        case .blocked(let reason): reason
        }
    }

    private var cloudStatusIsProblem: Bool {
        switch cloud.status {
        case .unavailable, .blocked: true
        default: false
        }
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier.map { !configs.config.general.blacklist.contains($0) } ?? false
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = on
        } catch {
            message = String(localized: "无法更改登录项：\(error.localizedDescription)")
        }
    }

    private func exportConfig() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "TouchOS.\(ConfigController.exportExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try configs.export(to: url)
            message = String(localized: "已导出到 \(url.lastPathComponent)")
        } catch {
            message = String(localized: "导出失败：\(error.localizedDescription)")
        }
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try ConfigController.readImport(url)
            if result.risky.isEmpty {
                var c = result.config
                c.sync = configs.config.sync  // 同步开关只属于这台 Mac（D35）
                configs.replace(c)
                message = String(localized: "已导入")
            } else {
                pendingImport = result  // FR-9.5：先逐条确认
            }
        } catch {
            message = String(localized: "导入失败：文件不是有效的 TouchOS 配置")
        }
    }

    private func restore(_ url: URL) {
        do {
            try configs.restore(url)
            message = String(localized: "已从备份恢复")
        } catch {
            message = String(localized: "该备份无法读取")
        }
    }
}

/// FR-9.5：导入的配置含 Shell 或脚本动作时逐条列出，确认后才导入
private struct ImportConfirmation: View {
    let risky: [(panel: String, slot: String, action: Action)]
    let done: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("导入的配置包含会运行命令的动作").font(.headline)
            Text("这些动作会以你的用户权限运行。确认来源可信后再导入。").foregroundStyle(.secondary)
            List(Array(risky.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(item.panel) › \(item.slot)").font(.callout.weight(.medium))
                    Text(item.action.codePreview).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            .frame(minHeight: 160)
            HStack {
                Spacer()
                Button("取消") { done(false) }.keyboardShortcut(.cancelAction)
                Button("导入") { done(true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

extension Action {
    /// 导入确认里显示的命令内容
    var codePreview: String {
        switch self {
        case .shell(let command, _, _): command
        case .appleScript(let source, _): source
        default: typeName
        }
    }
}

/// 应用图标与名称
struct AppLabel: View {
    let bundleID: String

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        HStack(spacing: 8) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
            }
            Text(url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID)
        }
    }
}

// MARK: 关于

private struct AboutPage: View {
    var body: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Nekro TouchOS").font(.title.weight(.semibold))
            Text("版本 \(version)").foregroundStyle(.secondary)
            Text("轻点后按住唤出面板，手指在触控板上的位置直接对应按钮，抬起即执行。").multilineTextAlignment(.center)
            Link("项目主页 github.com/NekroAI/touchos", destination: URL(string: "https://github.com/NekroAI/touchos")!)
            Text("开源许可：GPL-3.0-or-later").font(.callout).foregroundStyle(.secondary)
            Text("TouchOS 读取触控板原始触点，仅在内存中处理，从不记录或上传。")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
