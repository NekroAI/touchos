import AppKit
import Foundation

/// 调试工具的诊断日志（D51）：只留在内存里的环形缓冲，由用户从菜单复制后自行发出。
/// 只记录状态、方式、耗时和次数，不记录触点坐标或轨迹（FR-4.7、NFR-10），也不记录光标坐标。
/// 任意线程可调用；未开启调试工具时不做任何事。
final class DiagnosticLog: @unchecked Sendable {
    static let shared = DiagnosticLog()
    /// 保留的行数：够复现十几次会话
    private static let capacity = 2000

    private let lock = NSLock()
    private var enabled = false
    private var lines: [String] = []
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func enable() {
        lock.withLock { enabled = true }
    }

    func record(_ line: @autoclosure () -> String) {
        guard lock.withLock({ enabled }) else { return }
        let text = line()
        lock.withLock {
            lines.append("\(formatter.string(from: Date())) \(text)")
            if lines.count > Self.capacity { lines.removeFirst(lines.count - Self.capacity) }
        }
    }

    func clear() {
        lock.withLock { lines.removeAll() }
    }

    /// 环境信息加全部日志，复制到剪贴板
    @MainActor func copyToPasteboard() {
        let all = lock.withLock { lines }
        let info = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        var model = [UInt8](repeating: 0, count: 64)
        var size = model.count
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let header = ["TouchOS \(info) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(String(decoding: model.prefix { $0 != 0 }, as: UTF8.self))",
                      "冻结方式设置 \(CursorLock.FreezeMethod.current.rawValue) · 显示器 \(Self.displaySummary)"]  // l10n-ignore
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((header + all).joined(separator: "\n"), forType: .string)
    }

    /// 每块显示器的编号、旋转、是否主屏 / 内置
    static var displaySummary: String {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetActiveDisplayList(16, &ids, &count)
        return ids.prefix(Int(count)).map { d in
            "\(d)[\(Int(CGDisplayRotation(d)))°\(CGDisplayIsMain(d) != 0 ? " main" : "")\(CGDisplayIsBuiltin(d) != 0 ? " builtin" : "")]"
        }.joined(separator: " ")
    }
}
