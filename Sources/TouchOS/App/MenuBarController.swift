import AppKit

/// 菜单栏图标与菜单（SRS FR-11.1）。启用/暂停、设置、检查更新随对应任务加入。
@MainActor
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var debugItem: NSMenuItem?

    /// 设置后菜单中出现"调试叠层"（FR-14.4）
    var onToggleDebugOverlay: (() -> Void)? {
        didSet { rebuildMenu() }
    }

    /// 设置后调试区出现"5 秒后阻塞拦截"（AC-17）
    var onDebugStall: (() -> Void)? {
        didSet { rebuildMenu() }
    }

    /// 调试区的开关项（实验布局、常驻模式等），状态存在 UserDefaults
    struct DebugToggle {
        let title: String
        let key: String
        let onChange: (Bool) -> Void
    }

    var debugToggles: [DebugToggle] = [] {
        didSet { rebuildMenu() }
    }

    /// 调试区的多选一项（面板大小、映射区大小等）：子菜单列出各取值，选中值存在 UserDefaults（Double）
    struct DebugChoice {
        let title: String
        let key: String
        let options: [(label: String, value: Double)]
        /// 未设置时视为选中的值
        let current: () -> Double
    }

    var debugChoices: [DebugChoice] = [] {
        didSet { rebuildMenu() }
    }

    var debugOverlayVisible = false {
        didSet { debugItem?.state = debugOverlayVisible ? .on : .off }
    }

    override init() {
        super.init()
        statusLine.isEnabled = false
        rebuildMenu()
        setStatus("正常", warning: false)
    }

    /// FR-11.1 当前状态：正常 / 输入不可用 / 拦截不可用 / 缺少权限
    func setStatus(_ text: String, warning: Bool) {
        statusLine.title = "状态：\(text)"
        // 图标待定（docs/decisions.md 待决事项 2），暂用 SF Symbols
        statusItem.button?.image = warning
            ? NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "TouchOS：\(text)")
            : NSImage(systemSymbolName: "hand.point.up.left", accessibilityDescription: "TouchOS")
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let title = NSMenuItem(title: "TouchOS \(version)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        // 菜单项只能属于一个菜单，重建前先从旧菜单移除；否则 AppKit 抛出的异常会在启动回调里被静默吞掉
        statusLine.menu?.removeItem(statusLine)
        menu.addItem(statusLine)
        menu.addItem(.separator())
        if onToggleDebugOverlay != nil {
            let item = NSMenuItem(title: "调试叠层", action: #selector(toggleDebugOverlay), keyEquivalent: "d")
            item.target = self
            item.state = debugOverlayVisible ? .on : .off
            debugItem = item
            menu.addItem(item)
            for (i, toggle) in debugToggles.enumerated() {
                let item = NSMenuItem(title: toggle.title, action: #selector(flipDebugToggle(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i
                item.state = UserDefaults.standard.bool(forKey: toggle.key) ? .on : .off
                menu.addItem(item)
            }
            for (i, choice) in debugChoices.enumerated() {
                let sub = NSMenu()
                for (j, option) in choice.options.enumerated() {
                    let item = NSMenuItem(title: option.label, action: #selector(pickDebugChoice(_:)), keyEquivalent: "")
                    item.target = self
                    item.tag = i * Self.choiceStride + j
                    item.state = abs(choice.current() - option.value) < 1e-6 ? .on : .off
                    sub.addItem(item)
                }
                let parent = NSMenuItem(title: choice.title, action: nil, keyEquivalent: "")
                parent.submenu = sub
                menu.addItem(parent)
            }
            if onDebugStall != nil {
                let stall = NSMenuItem(title: "5 秒后阻塞拦截（AC-17）", action: #selector(debugStall), keyEquivalent: "")
                stall.target = self
                menu.addItem(stall)
            }
            menu.addItem(.separator())
        }
        menu.addItem(NSMenuItem(title: "退出 TouchOS", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func flipDebugToggle(_ item: NSMenuItem) {
        let toggle = debugToggles[item.tag]
        let on = !UserDefaults.standard.bool(forKey: toggle.key)
        UserDefaults.standard.set(on, forKey: toggle.key)
        item.state = on ? .on : .off
        toggle.onChange(on)
    }

    /// 多选一项的菜单 tag = 项序号 × 该值 + 选项序号
    private static let choiceStride = 100

    @objc private func pickDebugChoice(_ item: NSMenuItem) {
        let choice = debugChoices[item.tag / Self.choiceStride]
        UserDefaults.standard.set(choice.options[item.tag % Self.choiceStride].value, forKey: choice.key)
        for sibling in item.menu?.items ?? [] { sibling.state = sibling === item ? .on : .off }
    }

    @objc private func debugStall() {
        onDebugStall?()
    }

    @objc private func toggleDebugOverlay() {
        onToggleDebugOverlay?()
    }
}
