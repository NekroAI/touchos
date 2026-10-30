import AppKit
import CoreGraphics
import Foundation
import OSLog
import TouchOSCore

/// 动作调度（SRS 9.3）：串行后台队列，不阻塞输入、拦截与主线程；失败只通知、不重试（FR-9.1、FR-9.2）。
final class ActionExecutor: @unchecked Sendable {
    /// FR-9.1：待执行超过该数量时丢弃最旧的
    static let maxPending = 5

    private let log = Logger(subsystem: TouchOSCore.logSubsystem, category: "action")
    private let queue = DispatchQueue(label: "ai.nekro.touchos.actions", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: [ActionRequest] = []
    private var focusPointer = AppConfig.General().focusPointerWindow

    /// 快捷键与窗口动作执行前是否先把焦点切到指针下的窗口（D27），随配置更新
    var focusesPointerWindow: Bool {
        get { lock.withLock { focusPointer } }
        set { lock.withLock { focusPointer = newValue } }
    }

    func enqueue(_ request: ActionRequest) {
        lock.lock()
        pending.append(request)
        if pending.count > Self.maxPending {
            pending.removeFirst(pending.count - Self.maxPending)
            log.info("action queue full; dropped oldest")
        }
        lock.unlock()
        queue.async { self.runNext() }
    }

    private func runNext() {
        lock.lock()
        guard !pending.isEmpty else { lock.unlock(); return }
        let request = pending.removeFirst()
        lock.unlock()

        // 面板隐藏后至少 `P.actionDelayMs` 再执行，确保按键发往原前台应用（SRS 5.5）
        let wait = request.notBefore - ProcessInfo.processInfo.systemUptime
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }

        do {
            try run(request)
        } catch let failure as ActionFailure {
            log.error("action failed: \(request.title, privacy: .public): \(failure.reason, privacy: .public)")
            Notifier.post(title: request.title, body: failure.reason)
        } catch {
            log.error("action failed: \(request.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
            Notifier.post(title: request.title, body: error.localizedDescription)
        }
    }

    /// 快捷键与窗口动作发往指针下的窗口（D27）：返回切换后的目标应用；未开启、指针下没有其他应用的窗口时为 nil
    private func focusPointerWindow(for action: Action) -> String? {
        guard focusesPointerWindow, PointerFocus.applies(to: action) else { return nil }
        return PointerFocus.focusWindowUnderPointer()
    }

    private func run(_ request: ActionRequest) throws {
        let target = focusPointerWindow(for: request.action)
        switch request.action {
        case .none:
            break
        case .keyboardShortcut(let combo):
            // FR-9.3：前台应用变了仍执行，只记录（不含坐标）
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            if target == nil, front != request.frontmostBundleID { log.info("frontmost changed before shortcut") }
            KeyboardShortcutExecutor.post(combo)
            log.info("shortcut \(combo.displayLabel, privacy: .public)")
        case .openApp(let bundleID):
            try Launcher.openApp(bundleID)
        case .openURL(let url, let browser):
            try Launcher.openURL(url, browserBundleID: browser)
        case .openFile(let path):
            try Launcher.openFile(path)
        case .shell(let command, let timeout, let notify):
            let output = try ProcessRunner.run("/bin/zsh", ["-c", command], timeout: timeout)
            if notify, !output.isEmpty { Notifier.post(title: request.title, body: String(output.prefix(ProcessRunner.notifyLimit))) }
        case .appleScript(let source, let language):
            let args = language == .javaScript ? ["-l", "JavaScript", "-e", source] : ["-e", source]
            _ = try ProcessRunner.run("/usr/bin/osascript", args, timeout: ProcessRunner.defaultTimeout)
        case .shortcut(let name):
            _ = try ProcessRunner.run("/usr/bin/shortcuts", ["run", name], timeout: ProcessRunner.shortcutTimeout)
        case .system(let command):
            try SystemControl.run(command, frontmostBundleID: target ?? request.frontmostBundleID)
        case .textSnippet(let text):
            TextTyper.type(text)
            log.info("text snippet")  // 不记录内容
        }
    }
}

/// 一句给用户看的失败原因（FR-9.2）
struct ActionFailure: Error {
    let reason: String
}

/// 合成键盘事件（SRS 9.2）：修饰键先按下、后抬起，主键按下与抬起间隔 8 ms；事件带 FR-7.3 标记。
enum KeyboardShortcutExecutor {
    static let keyHoldInterval: TimeInterval = 0.008

    private static let modifierKeys: [(Modifier, CGKeyCode, CGEventFlags)] = [
        (.control, 59, .maskControl), (.option, 58, .maskAlternate), (.shift, 56, .maskShift),
        (.command, 55, .maskCommand), (.function, 63, .maskSecondaryFn),
    ]

    static func post(_ combo: KeyCombo) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        source.userData = EventTapController.syntheticMarker
        let mods = modifierKeys.filter { combo.modifiers.contains($0.0) }

        var flags: CGEventFlags = []
        for (_, code, flag) in mods {
            flags.insert(flag)
            send(source, code, down: true, flags: flags)
        }
        send(source, combo.keyCode, down: true, flags: flags)
        Thread.sleep(forTimeInterval: keyHoldInterval)
        send(source, combo.keyCode, down: false, flags: flags)
        for (_, code, flag) in mods.reversed() {
            flags.remove(flag)
            send(source, code, down: false, flags: flags)
        }
    }

    private static func send(_ source: CGEventSource, _ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: EventTapController.syntheticMarker)
        event.post(tap: .cghidEventTap)
    }
}

/// 输入文字（D30）：按键事件携带 Unicode 字符串，不经过键码与键盘布局，输入法也不会拦截改写。
/// 每个事件最多带 20 个 UTF-16 单元，长文本分段发送；事件带 FR-7.3 标记
enum TextTyper {
    static let chunk = 20

    static func type(_ text: String) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        source.userData = EventTapController.syntheticMarker
        var units = Array(text.utf16)
        while !units.isEmpty {
            // 不把代理对拆到两段
            var n = min(chunk, units.count)
            if n < units.count, UTF16.isLeadSurrogate(units[n - 1]) { n -= 1 }
            let part = Array(units.prefix(n))
            units.removeFirst(n)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { return }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: part.count, unicodeString: part)
                event.setIntegerValueField(.eventSourceUserData, value: EventTapController.syntheticMarker)
                event.post(tap: .cghidEventTap)
            }
        }
    }
}

/// 打开应用、URL、文件（SRS 9.2）
enum Launcher {
    /// 允许直接打开的 URL 协议；其余协议须有已安装应用注册
    static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    static func openApp(_ bundleID: String) throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw ActionFailure(reason: String(localized: "未安装 \(bundleID)"))
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    static func openURL(_ url: URL, browserBundleID: String?) throws {
        guard let scheme = url.scheme?.lowercased(),
              allowedSchemes.contains(scheme) || NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
            throw ActionFailure(reason: String(localized: "无法打开链接 \(url.absoluteString)"))
        }
        if let browserBundleID, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browserBundleID) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    static func openFile(_ path: String) throws {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else { throw ActionFailure(reason: String(localized: "找不到 \(path)")) }
        NSWorkspace.shared.open(URL(fileURLWithPath: expanded))
    }
}

/// 子进程（Shell、脚本、快捷指令）：工作目录为用户主目录，超时终止（SRS 9.2）
enum ProcessRunner {
    static let defaultTimeout: TimeInterval = 10
    /// 快捷指令可能要等用户交互，给得宽一些
    static let shortcutTimeout: TimeInterval = 60
    /// 输出通知只取前这么多字
    static let notifyLimit = 200

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            throw ActionFailure(reason: String(localized: "无法启动 \(executable)"))
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw ActionFailure(reason: String(localized: "超过 \(Int(timeout)) 秒未完成，已终止"))
        }
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ActionFailure(reason: message.isEmpty ? String(localized: "退出码 \(process.terminationStatus)") : String(message.prefix(notifyLimit)))
        }
        return output
    }
}
