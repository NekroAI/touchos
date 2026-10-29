import AppKit
import ApplicationServices
import OSLog
import TouchOSCore
import UserNotifications

/// 系统控制（SRS 9.2）：媒体键、锁屏、调度中心、截图、前台窗口摆放
enum SystemControl {
    /// 媒体键编号（IOKit `ev_keymap.h` 的 NX_KEYTYPE_*）
    private enum MediaKey: Int {
        case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7, play = 16, next = 17, previous = 18
    }

    /// 截图选窗口：按下 ⌘⇧4 后等这么久再按空格，等系统截图界面出现
    static let windowShotDelay: TimeInterval = 0.25

    static func run(_ command: SystemCommand, frontmostBundleID: String?) throws {
        switch command {
        case .volumeUp: media(.soundUp)
        case .volumeDown: media(.soundDown)
        case .mute: media(.mute)
        // 外接显示器不支持亮度键时系统静默忽略（SRS 9.2）
        case .brightnessUp: media(.brightnessUp)
        case .brightnessDown: media(.brightnessDown)
        case .playPause: media(.play)
        case .nextTrack: media(.next)
        case .previousTrack: media(.previous)
        case .lockScreen: key(12, [.control, .command], "⌃⌘Q")
        case .missionControl: try openSystemApp(["Mission Control"])
        case .showDesktop: _ = try ProcessRunner.run("/System/Applications/Mission Control.app/Contents/MacOS/Mission Control", ["1"],
                                                     timeout: ProcessRunner.defaultTimeout)
        // macOS 26 起启动台改为"应用程序"
        case .launchpad: try openSystemApp(["Launchpad", "Apps"])
        case .screenshotArea: key(21, [.command, .shift], "⇧⌘4")
        case .screenshotWindow:
            key(21, [.command, .shift], "⇧⌘4")
            Thread.sleep(forTimeInterval: windowShotDelay)
            key(49, [], "Space")
        case .windowLeftHalf, .windowRightHalf, .windowFill, .windowCenter, .windowNextDisplay:
            try WindowManager.apply(command, bundleID: frontmostBundleID)
        }
    }

    private static func key(_ code: UInt16, _ mods: Set<Modifier>, _ label: String) {
        KeyboardShortcutExecutor.post(KeyCombo(keyCode: code, modifiers: mods, displayLabel: label))
    }

    private static func openSystemApp(_ names: [String]) throws {
        let url = names.lazy.map { URL(fileURLWithPath: "/System/Applications/\($0).app") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        guard let url else { throw ActionFailure(reason: "本机系统没有该功能") }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// 系统定义事件（子类型 8）模拟媒体键按下与抬起，系统会显示对应的音量 / 亮度提示
    private static func media(_ key: MediaKey) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = (key.rawValue << 16) | ((down ? 0xA : 0xB) << 8)
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                           context: nil, subtype: 8, data1: data1, data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

/// 前台窗口摆放（D23 预置"窗口"面板）：辅助功能接口读写聚焦窗口的位置与大小。
/// 坐标：辅助功能接口用"主屏左上为原点、向下为正"的全局坐标，AppKit 屏幕坐标原点在主屏左下，这里统一换算到前者
enum WindowManager {
    /// "居中"时窗口占可见区域的比例
    static let centerFraction = 0.7

    static func apply(_ command: SystemCommand, bundleID: String?) throws {
        let app = bundleID.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
            ?? NSWorkspace.shared.frontmostApplication
        guard let app else { throw ActionFailure(reason: "没有前台窗口") }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, "AXFocusedWindow" as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw ActionFailure(reason: "\(app.localizedName ?? "前台应用")没有可调整的窗口")
        }
        let window = value as! AXUIElement  // 上面已核对类型
        guard let frame = Self.frame(of: window) else { throw ActionFailure(reason: "无法读取窗口位置") }
        let screens = DispatchQueue.main.sync { Self.screenFrames() }
        guard let current = screens.firstIndex(where: { $0.full.contains(CGPoint(x: frame.midX, y: frame.midY)) }) ?? screens.indices.first
        else { return }
        let area = screens[current].visible
        let target: CGRect
        switch command {
        case .windowLeftHalf: target = CGRect(x: area.minX, y: area.minY, width: area.width / 2, height: area.height)
        case .windowRightHalf: target = CGRect(x: area.midX, y: area.minY, width: area.width / 2, height: area.height)
        case .windowFill: target = area
        case .windowCenter:
            let w = area.width * centerFraction, h = area.height * centerFraction
            target = CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
        default:
            guard screens.count > 1 else { throw ActionFailure(reason: "只有一个显示器") }
            // 按相对位置与比例移到下一个显示器
            let next = screens[(current + 1) % screens.count].visible
            let sx = next.width / area.width, sy = next.height / area.height
            target = CGRect(x: next.minX + (frame.minX - area.minX) * sx, y: next.minY + (frame.minY - area.minY) * sy,
                            width: min(frame.width * sx, next.width), height: min(frame.height * sy, next.height))
        }
        // 先移后改大小，再移一次：跨屏时目标屏更小会先被系统裁剪
        set(window, position: target.origin)
        set(window, size: target.size)
        set(window, position: target.origin)
    }

    /// 各屏幕的完整区域与可见区域（辅助功能坐标）
    @MainActor private static func screenFrames() -> [(full: CGRect, visible: CGRect)] {
        let primary = NSScreen.screens.first?.frame.height ?? 0
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: primary - r.maxY, width: r.width, height: r.height) }
        return NSScreen.screens.map { (flip($0.frame), flip($0.visibleFrame)) }
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var position = CGPoint.zero, size = CGSize.zero
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXPosition" as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(window, "AXSize" as CFString, &s) == .success,
              let p, let s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        AXValueGetValue(p as! AXValue, .cgPoint, &position)  // 上面已核对类型
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    private static func set(_ window: AXUIElement, position: CGPoint) {
        var p = position
        if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(window, "AXPosition" as CFString, v) }
    }

    private static func set(_ window: AXUIElement, size: CGSize) {
        var s = size
        if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(window, "AXSize" as CFString, v) }
    }
}

/// 动作失败通知（FR-9.2）：一条系统通知，不弹窗、不重试。第一次发送时请求授权；用户拒绝则只写日志
enum Notifier {
    private static let log = Logger(subsystem: TouchOSCore.logSubsystem, category: "notify")

    static func post(title: String, body: String) {
        // 不在 .app 包里运行（直接运行可执行文件调试）时通知中心不可用
        guard Bundle.main.bundleURL.pathExtension == "app" else { return log.info("notification skipped: \(body, privacy: .public)") }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
