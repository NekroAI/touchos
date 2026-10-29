import AppKit

/// 菜单栏图标与菜单（SRS FR-11.1）。目前只有版本与退出；启用/暂停、状态、设置、检查更新随对应任务加入。
@MainActor
final class MenuBarController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    init() {
        // 图标待定（docs/decisions.md 待决事项 2），暂用 SF Symbols
        statusItem.button?.image = NSImage(systemSymbolName: "hand.point.up.left", accessibilityDescription: "TouchOS")

        let menu = NSMenu()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let title = NSMenuItem(title: "TouchOS \(version)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 TouchOS", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }
}
