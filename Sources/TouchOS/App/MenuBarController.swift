import AppKit

/// 菜单栏图标与菜单（SRS FR-11.1）。启用/暂停、设置、检查更新随对应任务加入。
@MainActor
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var debugItem: NSMenuItem?

    var inputStatus: AppCoordinator.InputStatus = .normal {
        didSet { updateStatus() }
    }

    /// 设置后菜单中出现"调试叠层"（FR-14.4）
    var onToggleDebugOverlay: (() -> Void)? {
        didSet { rebuildMenu() }
    }

    var debugOverlayVisible = false {
        didSet { debugItem?.state = debugOverlayVisible ? .on : .off }
    }

    override init() {
        super.init()
        statusLine.isEnabled = false
        rebuildMenu()
        updateStatus()
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
            menu.addItem(.separator())
        }
        menu.addItem(NSMenuItem(title: "退出 TouchOS", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func updateStatus() {
        // 图标待定（docs/decisions.md 待决事项 2），暂用 SF Symbols
        switch inputStatus {
        case .normal:
            statusLine.title = "状态：正常"
            statusItem.button?.image = NSImage(systemSymbolName: "hand.point.up.left", accessibilityDescription: "TouchOS")
        case .unavailable(let reason):
            statusLine.title = "状态：输入不可用（\(reason)）"
            statusItem.button?.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "TouchOS：输入不可用")
        }
    }

    @objc private func toggleDebugOverlay() {
        onToggleDebugOverlay?()
    }
}
