import CoreGraphics
import Foundation
import OSLog
import TouchOSCore

/// 动作调度（SRS 9.3）：串行后台队列，不阻塞输入、拦截与主线程；失败只记录、不重试。
/// M0 只实现模拟快捷键（K7），其余动作类型在 K9 加入。
final class ActionExecutor: @unchecked Sendable {
    /// FR-9.1：待执行超过该数量时丢弃最旧的
    static let maxPending = 5

    private let log = Logger(subsystem: TouchOSCore.logSubsystem, category: "action")
    private let queue = DispatchQueue(label: "ai.nekro.touchos.actions", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: [ActionRequest] = []

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

        switch request.action {
        case .none:
            break
        case .keyboardShortcut(let combo):
            KeyboardShortcutExecutor.post(combo)
            log.info("shortcut \(combo.displayLabel, privacy: .public)")
        default:
            log.error("action not implemented yet: \(request.title, privacy: .public)")
        }
    }
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
