import AppKit
import SwiftUI
import TouchOSCore
import UniformTypeIdentifiers

/// 选中按钮时从右侧滑出的属性栏（FR-11.5–11.7）
struct SlotInspector: View {
    let configs: ConfigController
    let executor: ActionExecutor
    @Bindable var navigation: SettingsNavigation
    let panel: PanelLayout

    var body: some View {
        if let id = navigation.selectedSlot, let slot = panel.slot(id) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    SlotIconPreview(slot: slot).font(.title3).foregroundStyle(.tint).frame(width: 24, height: 24)
                    Text(slot.title.isEmpty ? String(localized: "按钮") : slot.title).font(.headline).lineLimit(1)
                    Spacer()
                    Button { navigation.selectedSlot = nil } label: {
                        Image(systemName: "xmark").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(.quaternary))
                    }
                    .buttonStyle(.plain)
                    .help("完成（Esc）")
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 6)
                SlotForm(configs: configs, executor: executor, navigation: navigation, panel: panel, slot: slot)
                    .id(slot.id)
            }
        }
    }
}

/// 按钮做什么
private enum SlotKind: String, CaseIterable, Identifiable {
    case action, close, volume, brightness, nowPlaying

    var id: String { rawValue }

    var title: String {
        switch self {
        case .action: String(localized: "执行动作")
        case .close: String(localized: "关闭面板")
        case .volume: String(localized: "音量滑杆")
        case .brightness: String(localized: "亮度滑杆")
        case .nowPlaying: String(localized: "正在播放")
        }
    }

    init(_ slot: Slot) {
        if slot.widget != nil { self = .nowPlaying }
        else if slot.slider == .volume { self = .volume }
        else if slot.slider == .brightness { self = .brightness }
        else if slot.isCancel { self = .close }
        else { self = .action }
    }
}

/// 动作类型（编辑器里的选项）
private enum ActionKind: String, CaseIterable, Identifiable {
    case shortcut, text, system, app, url, openWith, file, shortcutsApp, shell, script

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shortcut: String(localized: "快捷键")
        case .text: String(localized: "输入文字")
        case .system: String(localized: "系统功能")
        case .app: String(localized: "打开应用")
        case .url: String(localized: "打开链接")
        case .openWith: String(localized: "用应用打开剪贴板")
        case .file: String(localized: "打开文件或文件夹")
        case .shortcutsApp: String(localized: "运行快捷指令")
        case .shell: String(localized: "Shell 命令")
        case .script: "AppleScript / JXA"
        }
    }

    init?(_ action: Action) {
        switch action {
        case .none: return nil
        case .keyboardShortcut: self = .shortcut
        case .system: self = .system
        case .openApp: self = .app
        case .openURL: self = .url
        case .openFile: self = .file
        case .shortcut: self = .shortcutsApp
        case .shell: self = .shell
        case .appleScript: self = .script
        case .textSnippet: self = .text
        case .openWith: self = .openWith
        }
    }

    var placeholder: Action {
        switch self {
        case .shortcut: .keyboardShortcut(KeyCombo(keyCode: 0, modifiers: [.command], displayLabel: "⌘A"))
        case .text: .textSnippet("")
        case .system: .system(.playPause)
        case .app: .openApp(bundleID: "com.apple.finder")
        case .url: .openURL(url: URL(string: "https://")!, browserBundleID: nil)
        case .openWith: .openWith(bundleID: AppChooser.defaultBrowser ?? "com.apple.Safari", input: .clipboard, searchURL: nil)
        case .file: .openFile(path: "~/Downloads")
        case .shortcutsApp: .shortcut(name: "")
        case .shell: .shell(command: "", timeoutSec: ProcessRunner.defaultTimeout, notifyOutput: false)
        case .script: .appleScript(source: "", language: .appleScript)
        }
    }
}

private struct SlotForm: View {
    let configs: ConfigController
    let executor: ActionExecutor
    @Bindable var navigation: SettingsNavigation
    let panel: PanelLayout
    let slot: Slot
    @State private var testNote: String?
    @State private var riskAcknowledged = false

    var body: some View {
        Form {
            Section("外观") {
                TextField("名称", text: field(\.title))
                IconField(symbol: field(\.symbol), appIcon: makeBinding(get: { slot.appIcon }, set: { v in edit { $0.appIcon = v } }),
                          actionApp: slot.action.appBundleID)
            }
            Section("功能") {
                Picker("按钮", selection: makeBinding(get: { SlotKind(slot) }, set: setKind)) {
                    ForEach(SlotKind.allCases) { Text($0.title).tag($0) }
                }
                if SlotKind(slot) == .action { actionEditor }
                if SlotKind(slot) == .nowPlaying {
                    Text("按下或抬起时播放 / 暂停。").font(.caption).foregroundStyle(.secondary)
                }
                if SlotKind(slot) == .close {
                    Text("抬起关闭面板；按住约 \(editHoldSeconds) 秒进入编辑。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if SlotKind(slot) == .action {
                Section {
                    HStack {
                        Button("测试") { test() }
                        if let testNote { Text(testNote).font(.caption).foregroundStyle(.secondary) }
                    }
                } footer: {
                    FormFooter(String(localized: "1 秒后执行，可以先切到目标应用。"))
                }
            }
            if panel.isRing, let index = panel.ringItems.firstIndex(where: { $0.id == slot.id }) {
                Section {
                    LabeledContent("顺序") {
                        HStack(spacing: 6) {
                            Text("第 \(index + 1) 个，共 \(panel.ringItems.count) 个").foregroundStyle(.secondary)
                            ControlGroup {
                                Button { moveInRing(by: -1) } label: { Image(systemName: "arrow.counterclockwise") }
                                    .help("逆时针移动")
                                Button { moveInRing(by: 1) } label: { Image(systemName: "arrow.clockwise") }
                                    .help("顺时针移动")
                            }
                            .fixedSize()
                        }
                    }
                }
            }
            Section {
                Button("删除按钮", role: .destructive) { delete() }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: 动作参数

    @ViewBuilder private var actionEditor: some View {
        let kind = ActionKind(slot.action) ?? .shortcut
        Picker("类型", selection: makeBinding(get: { kind }, set: { k in if k != kind { setAction(k.placeholder) } })) {
            ForEach(ActionKind.allCases) { Text($0.title).tag($0) }
        }
        switch slot.action {
        case .keyboardShortcut(let combo):
            LabeledContent("组合键") { ShortcutRecorder(combo: combo) { setAction(.keyboardShortcut($0)) } }
        case .system(let command):
            Picker("功能", selection: makeBinding(get: { command }, set: { setAction(.system($0)) })) {
                ForEach(SystemCommand.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        case .openApp(let id):
            LabeledContent("应用") {
                HStack {
                    AppLabel(bundleID: id)
                    Button("选择…") { if let picked = AppChooser.pick() { setAction(.openApp(bundleID: picked)) } }
                }
            }
        case .openURL(let url, let browser):
            TextField("链接", text: makeBinding(get: { Placeholder.display(url.absoluteString) }, set: { s in
                if let u = URL(string: s), u.scheme != nil { setAction(.openURL(url: u, browserBundleID: browser)) }
            }))
            LabeledContent("用哪个应用打开") {
                AppMenu(bundleID: browser, allowsDefault: true) { setAction(.openURL(url: url, browserBundleID: $0)) }
            }
            inputNote(String(localized: "链接里写 {clipboard} 会代入剪贴板里的文字，例如 https://www.google.com/search?q={clipboard}。"))
        case .openWith(let id, let input, let search):
            LabeledContent("应用") {
                AppMenu(bundleID: id, allowsDefault: false) { if let p = $0 { setAction(.openWith(bundleID: p, input: input, searchURL: search)) } }
            }
            TextField("其他文字时打开", text: makeBinding(get: { search ?? "" }, set: { v in
                setAction(.openWith(bundleID: id, input: input, searchURL: v.isEmpty ? nil : v))
            }), prompt: Text(verbatim: "https://www.google.com/search?q={clipboard}"))
            inputNote(String(localized: "剪贴板里是链接、拷贝的文件或文件路径时，用这个应用打开。是其他文字时，填了「其他文字时打开」就把文字代入 {clipboard} 再打开，没填则提示无法打开。"))
        case .openFile(let path):
            LabeledContent("路径") {
                HStack {
                    Text(path).lineLimit(1).truncationMode(.middle)
                    Button("选择…") { if let p = pickFile() { setAction(.openFile(path: p)) } }
                }
            }
        case .shortcut(let name):
            TextField("快捷指令名称", text: makeBinding(get: { name }, set: { setAction(.shortcut(name: $0)) }))
        case .shell(let command, let timeout, let notify):
            riskNote
            TextEditor(text: makeBinding(get: { command }, set: { setAction(.shell(command: $0, timeoutSec: timeout, notifyOutput: notify)) }))
                .font(.system(.body, design: .monospaced)).frame(minHeight: 70)
            Toggle("把输出显示为通知", isOn: makeBinding(get: { notify }, set: { setAction(.shell(command: command, timeoutSec: timeout, notifyOutput: $0)) }))
            inputNote(String(localized: "用到环境变量 $TOUCHOS_CLIPBOARD 时，它是剪贴板里的文字（拷贝的是文件时为路径，每行一个）。"))
        case .appleScript(let source, let language):
            riskNote
            Picker("语言", selection: makeBinding(get: { language }, set: { setAction(.appleScript(source: source, language: $0)) })) {
                Text("AppleScript").tag(ScriptLanguage.appleScript)
                Text("JavaScript").tag(ScriptLanguage.javaScript)
            }
            TextEditor(text: makeBinding(get: { source }, set: { setAction(.appleScript(source: $0, language: language)) }))
                .font(.system(.body, design: .monospaced)).frame(minHeight: 70)
            inputNote(String(localized: "脚本里用 system attribute 读取环境变量 TOUCHOS_CLIPBOARD 即可拿到剪贴板里的文字（出现这个名字时才会读剪贴板）。"))
        case .textSnippet(let text):
            TextField("文字", text: makeBinding(get: { text }, set: { setAction(.textSnippet($0)) }), prompt: Text("例如 → 或 2026-"))
        case .none:
            EmptyView()
        }
    }

    private func inputNote(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    /// FR-9.4：首次添加会运行命令的动作时提示风险
    private var riskNote: some View {
        Label("该动作会以你的用户权限运行命令", systemImage: "exclamationmark.shield").font(.caption).foregroundStyle(.orange)
    }

    // MARK: 修改

    private func field(_ path: WritableKeyPath<Slot, String>) -> Binding<String> {
        makeBinding(get: { slot[keyPath: path] }, set: { v in edit { $0[keyPath: path] = v } })
    }

    private func edit(_ change: (inout Slot) -> Void) {
        updatePanel(configs, panel.id) { p in
            guard let i = p.slots.firstIndex(where: { $0.id == slot.id }) else { return }
            change(&p.slots[i])
            if p.isRing { p = p.rebuiltRing(items: p.ringItems) }
        }
    }

    /// 图标与名称跟随动作的应用（D58）：原来就跟着旧应用的继续跟；从没有应用的动作换成打开应用时，
    /// 用符号的按钮改用应用图标。用户自己换过图标或改过名称的不动
    private func setAction(_ action: Action) {
        edit { s in
            let old = s.action.appBundleID, new = action.appBundleID
            if old != new {
                if let old, s.appIcon == old { s.appIcon = new }
                else if old == nil, s.appIcon == nil, new != nil, !s.symbol.isEmpty { s.appIcon = new }
                let placeholder = String(localized: "新按钮")
                if let new, s.title.isEmpty || s.title == placeholder || old.map(AppLabel.name) == s.title { s.title = AppLabel.name(new) }
            }
            s.action = action
        }
    }

    private func setKind(_ kind: SlotKind) {
        edit { s in
            s.slider = nil
            s.widget = nil
            switch kind {
            case .action: if s.action == .none || s.slider != nil { s.action = ActionKind.shortcut.placeholder }
            case .close:
                s.action = .none
                s.symbol = "xmark"
            case .volume:
                s.action = .none
                s.slider = .volume
                s.symbol = "speaker.wave.2"
            case .brightness:
                s.action = .none
                s.slider = .brightness
                s.symbol = "sun.max"
            case .nowPlaying:
                s.action = .system(.playPause)
                s.widget = .nowPlaying
                s.symbol = "music.note"
            }
        }
    }

    /// 环形：与相邻项目交换位置（首尾相接）
    private func moveInRing(by step: Int) {
        var items = panel.ringItems
        guard let i = items.firstIndex(where: { $0.id == slot.id }), items.count > 1 else { return }
        let j = (i + step + items.count) % items.count
        items.swapAt(i, j)
        updatePanel(configs, panel.id) { $0 = $0.rebuiltRing(items: items) }
    }

    private func delete() {
        updatePanel(configs, panel.id) { p in
            p.slots.removeAll { $0.id == slot.id }
            if p.isRing || p.ringCenter != nil { p = p.rebuiltRing(items: p.ringItems) }
        }
        navigation.selectedSlot = nil
    }

    private var editHoldSeconds: String { String(format: "%.1f", Tuning().editHoldMs / 1000) }

    private func test() {
        testNote = String(localized: "1 秒后执行…")
        let request = ActionRequest(action: slot.action, title: slot.title, frontmostBundleID: nil,
                                    notBefore: ProcessInfo.processInfo.systemUptime + Self.testDelay)
        executor.enqueue(request)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.testDelay + 0.3) { testNote = String(localized: "已执行") }
    }

    /// FR-11.7
    static let testDelay: TimeInterval = 1

    private func pickFile() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }
}

/// 快捷键录制（FR-11.6）：点击后按下的下一个组合键即为结果，Esc 取消
struct ShortcutRecorder: View {
    let combo: KeyCombo
    let set: (KeyCombo) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? String(localized: "请按下组合键…") : combo.displayLabel)
                .font(.system(.body, design: .rounded).weight(.medium))
                .frame(minWidth: 90)
        }
        .buttonStyle(.bordered)
        .tint(recording ? .accentColor : nil)
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == Self.escape && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                stop()
                return nil
            }
            set(Self.combo(from: event))
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    static let escape: UInt16 = 53

    static func combo(from event: NSEvent) -> KeyCombo {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods = Set<Modifier>()
        var label = ""
        if flags.contains(.control) { mods.insert(.control); label += "⌃" }
        if flags.contains(.option) { mods.insert(.option); label += "⌥" }
        if flags.contains(.shift) { mods.insert(.shift); label += "⇧" }
        if flags.contains(.command) { mods.insert(.command); label += "⌘" }
        // 方向键、功能键自带 fn 标志，不算用户按的修饰键
        let key = keyName(event)
        return KeyCombo(keyCode: event.keyCode, modifiers: mods, displayLabel: label + key)
    }

    private static let names: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
        100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    private static func keyName(_ event: NSEvent) -> String {
        if let name = names[event.keyCode] { return name }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }
}
