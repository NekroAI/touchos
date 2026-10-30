import AppKit
import TouchOSCore

/// 菜单栏图标与菜单（SRS FR-11.1）
@MainActor
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    /// 有新版本时菜单中显示下载入口（D44）
    var availableUpdate: ReleaseInfo? {
        didSet { rebuildMenu() }
    }
    private let warningDot = NSView()
    private static let warningDotSize: CGFloat = 7

    /// FR-11.1：启用 / 暂停、打开设置
    var onToggleEnabled: (() -> Void)? {
        didSet { rebuildMenu() }
    }

    var onOpenSettings: (() -> Void)? {
        didSet { rebuildMenu() }
    }

    var enabled = true {
        didSet { enabledItem?.state = enabled ? .on : .off }
    }

    private var enabledItem: NSMenuItem?

    /// "外观"子菜单（主题、切换动画、强调色），放在状态行下方
    var appearanceItem: NSMenuItem? {
        didSet { rebuildMenu() }
    }

    override init() {
        super.init()
        statusLine.isEnabled = false
        rebuildMenu()
        setStatus(String(localized: "正常"), warning: false)
    }

    /// FR-11.1 当前状态：正常 / 输入不可用 / 拦截不可用 / 缺少权限
    func setStatus(_ text: String, warning: Bool, paused: Bool = false) {
        statusLine.title = String(localized: "状态：\(text)")
        // 品牌标志（D43）；暂停时变淡，异常时右下角加一个橙点，文字说明在菜单的状态行
        guard let button = statusItem.button else { return }
        button.image = BrandMark.menuBarImage(description: warning || paused ? "TouchOS：\(text)" : "TouchOS",
                                              alpha: paused ? BrandMark.pausedAlpha : 1)
        warningDot.isHidden = !warning
        if warningDot.superview == nil {
            warningDot.wantsLayer = true
            warningDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            warningDot.layer?.cornerRadius = Self.warningDotSize / 2
            button.addSubview(warningDot)
        }
        let side = Self.warningDotSize
        warningDot.frame = NSRect(x: button.bounds.midX + BrandMark.menuBarSize / 2 - side,
                                  y: button.isFlipped ? button.bounds.midY + BrandMark.menuBarSize / 2 - side
                                      : button.bounds.midY - BrandMark.menuBarSize / 2,
                                  width: side, height: side)
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
        if let availableUpdate {
            let item = NSMenuItem(title: String(localized: "有新版本 \(availableUpdate.tag)，前往下载…"), action: #selector(openUpdate), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        if onToggleEnabled != nil {
            let item = NSMenuItem(title: String(localized: "启用 TouchOS"), action: #selector(toggleEnabled), keyEquivalent: "")
            item.target = self
            item.state = enabled ? .on : .off
            enabledItem = item
            menu.addItem(item)
        }
        if onOpenSettings != nil {
            let item = NSMenuItem(title: String(localized: "设置…"), action: #selector(openSettings), keyEquivalent: ",")
            item.target = self
            menu.addItem(item)
        }
        if let appearanceItem {
            appearanceItem.menu?.removeItem(appearanceItem)
            menu.addItem(appearanceItem)
            menu.addItem(.separator())
        }
        menu.addItem(NSMenuItem(title: String(localized: "退出 TouchOS"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func openUpdate() {
        if let url = availableUpdate?.url { NSWorkspace.shared.open(url) }
    }

    @objc private func toggleEnabled() {
        onToggleEnabled?()
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }
}
