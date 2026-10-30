import AppKit
import ApplicationServices
import OSLog
import TouchOSCore

/// 动作前把焦点切到指针下的窗口（D27）。指针移到另一个窗口上、没点击就唤起时，快捷键本会发往原来的前台应用。
/// 只用公开接口：窗口列表找指针下最上层的普通窗口，辅助功能接口把它提到最前、设为主窗口并让其应用到前台。
/// 在动作队列上调用（不在主线程）；光标此时已回到冻结点，即唤起时指针所在的位置。
enum PointerFocus {
    /// 等目标应用到前台的最长时间；等不到照常执行
    static let activationTimeout: TimeInterval = 0.3
    static let pollInterval: TimeInterval = 0.01
    /// 切换后再等一下，让目标窗口成为键盘焦点
    static let settleDelay: TimeInterval = 0.03
    /// 辅助功能窗口与窗口列表的位置大小比对容差（pt）
    static let frameTolerance: CGFloat = 2

    private static let log = Logger(subsystem: TouchOSCore.logSubsystem, category: "action")

    /// 只有发往窗口的动作需要：快捷键与窗口摆放
    static func applies(to action: Action) -> Bool {
        switch action {
        case .keyboardShortcut, .textSnippet: true
        case .system(let c): [.windowLeftHalf, .windowRightHalf, .windowFill, .windowCenter, .windowNextDisplay].contains(c)
        default: false
        }
    }

    /// 返回目标应用的 bundle ID；指针下没有其他应用的普通窗口（桌面、本应用的窗口）时为 nil，维持现状
    static func focusWindowUnderPointer() -> String? {
        guard let point = CGEvent(source: nil)?.location, let target = windowUnder(point),
              let app = NSRunningApplication(processIdentifier: target.pid) else { return nil }
        let axApp = AXUIElementCreateApplication(target.pid)
        let window = axWindow(of: axApp, matching: target.bounds)
        if focusedPID() == target.pid, window == nil || window.map({ isFocused($0, in: axApp) }) == true {
            return app.bundleIdentifier  // 已经是它
        }
        if let window {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        // macOS 14 起后台应用调用 activate 可能被拒（协作式激活）；辅助功能的 AXFrontmost 不受此限制，两个都做
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        app.activate()
        let deadline = ProcessInfo.processInfo.systemUptime + activationTimeout
        while focusedPID() != target.pid && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: pollInterval)
        }
        if focusedPID() == target.pid {
            Thread.sleep(forTimeInterval: settleDelay)
        } else {
            log.info("pointer window did not come to front in time")
        }
        return app.bundleIdentifier
    }

    /// 指针下最上层的普通窗口（第 0 层：排除菜单栏、Dock、浮层）。最上层是本应用的窗口时为 nil
    private static func windowUnder(_ point: CGPoint) -> (pid: pid_t, bounds: CGRect)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        for info in list {  // 由前到后
            guard info[kCGWindowLayer as String] as? Int == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict), bounds.contains(point)
            else { continue }
            return pid == ProcessInfo.processInfo.processIdentifier ? nil : (pid, bounds)
        }
        return nil
    }

    private static func axWindow(of app: AXUIElement, matching bounds: CGRect) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { w in
            guard let frame = frame(of: w) else { return false }
            return abs(frame.minX - bounds.minX) <= frameTolerance && abs(frame.minY - bounds.minY) <= frameTolerance
                && abs(frame.width - bounds.width) <= frameTolerance && abs(frame.height - bounds.height) <= frameTolerance
        }
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size, CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &p)  // 上面已核对类型
        AXValueGetValue(size as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    private static func isFocused(_ window: AXUIElement, in app: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success, let value else { return false }
        return CFEqual(value, window)
    }

    /// 当前拥有键盘焦点的应用。不用 NSWorkspace.frontmostApplication：它在主线程的通知里更新，后台线程上读到的可能是旧值
    private static func focusedPID() -> pid_t? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        var pid: pid_t = 0
        return AXUIElementGetPid(value as! AXUIElement, &pid) == .success ? pid : nil  // 上面已核对类型
    }
}
