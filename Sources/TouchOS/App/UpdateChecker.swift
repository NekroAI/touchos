import Foundation
import OSLog
import TouchOSCore

/// 更新提示（D44）：启动后与每天查询一次 GitHub Releases，有新版本时在菜单中显示下载入口。
/// 只发送一个不带 Cookie 的公开请求，不下载、不安装；失败时不打扰用户，等下一次
@MainActor
final class UpdateChecker {
    private static let endpoint = URL(string: "https://api.github.com/repos/NekroAI/touchos/releases/latest")!
    private static let firstDelay: Duration = .seconds(10)
    private static let interval: Duration = .seconds(24 * 60 * 60)
    private static let timeout: TimeInterval = 15
    private let log = Logger(subsystem: TouchOSCore.logSubsystem, category: "update")
    private var task: Task<Void, Never>?

    var onChange: ((ReleaseInfo?) -> Void)?

    var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            task?.cancel()
            task = nil
            if enabled { start() } else { onChange?(nil) }
        }
    }

    private func start() {
        task = Task { [weak self] in
            try? await Task.sleep(for: Self.firstDelay)
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    private func check() async {
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Nekro-TouchOS/\(current)", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let release = ReleaseInfo.parse(json: data) else {
            log.info("update check: no result")
            return
        }
        guard !Task.isCancelled else { return }
        onChange?(release.isNewer(than: current) ? release : nil)
    }
}
