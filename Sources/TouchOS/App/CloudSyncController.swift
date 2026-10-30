import AppKit
import Observation
import OSLog
import TouchOSCore

/// iCloud 同步（D35）：配置放在 iCloud 云盘的固定文件夹里，由 iCloud 云盘负责在各台 Mac 之间传。
/// 不用 iCloud 键值存储或 CloudKit：它们需要付费开发者账号签发的权限，自签名证书（D3）带上会被系统拒绝启动。
/// 应用没有沙盒，可以直接读写 `~/Library/Mobile Documents/com~apple~CloudDocs/`。
///
/// 本机配置文件仍是运行时唯一的来源；每次写盘后、iCloud 文件夹有变化时、以及定时各对一次账：
/// 只有一边改过就照着改，两边都改过时修改时间新的一方胜出，落选的一方进本机备份
@MainActor
@Observable
final class CloudSyncController {
    enum Status: Equatable {
        case off
        /// 这台 Mac 没有开启 iCloud 云盘
        case unavailable
        /// 文件还在云端（"优化 Mac 储存空间"），等待下载
        case downloading
        case synced(Date)
        /// 无法同步，附原因；本机配置不受影响
        case blocked(String)
    }

    /// 定时对账的间隔：文件夹监听偶尔收不到 iCloud 写入的通知，用它兜底
    static let pollInterval: TimeInterval = 15
    /// 文件夹变化后稍等再读：iCloud 下载与替换文件会连续触发多次
    static let settleDelay: TimeInterval = 0.5

    private(set) var status: Status = .off
    @ObservationIgnored private let configs: ConfigController
    @ObservationIgnored private let log = Logger(subsystem: TouchOSCore.logSubsystem, category: "icloud")
    @ObservationIgnored private var source: DispatchSourceFileSystemObject?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pending: DispatchWorkItem?
    /// 等文件从云端下载完再开启（新 Mac 上打开开关时）：已选好用哪一份，或下载完再问
    @ObservationIgnored private var enableWhenDownloaded: PendingChoice?

    private enum PendingChoice {
        case ask
        case use(cloud: Bool)
    }

    init(configs: ConfigController) {
        self.configs = configs
    }

    // MARK: 位置

    static var cloudDocs: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }
    static var folder: URL { cloudDocs.appendingPathComponent(CloudSync.folderName, isDirectory: true) }
    static var fileURL: URL { folder.appendingPathComponent(CloudSync.fileName) }
    /// 文件只在云端时，iCloud 云盘留下的占位文件
    static var placeholderURL: URL { folder.appendingPathComponent(".\(CloudSync.fileName).icloud") }

    var isAvailable: Bool { FileManager.default.fileExists(atPath: Self.cloudDocs.path) }
    /// iCloud 云盘里已经有配置（可能还没下载到本机）
    var hasCloudConfig: Bool {
        FileManager.default.fileExists(atPath: Self.fileURL.path) || FileManager.default.fileExists(atPath: Self.placeholderURL.path)
    }
    /// 上一次两边一致时的内容，只存在本机
    private var syncedURL: URL { configs.directory.appendingPathComponent("icloud-synced.json") }

    // MARK: 开关

    /// 启动时：开着同步就开始监听并对账
    func start() {
        configs.onSaved = { [weak self] in self?.reconcile() }
        guard configs.config.sync.iCloud else { return }
        watch()
        reconcile()
    }

    /// 设置里的开关。打开时 iCloud 中已有不同的配置，先问用哪一份
    func setEnabled(_ on: Bool) {
        guard on else {
            stopWatching()
            enableWhenDownloaded = nil
            configs.update { $0.sync.iCloud = false }
            status = .off
            return
        }
        guard isAvailable else {
            status = .unavailable
            return
        }
        if downloadIfNeeded() {
            enableWhenDownloaded = enableWhenDownloaded ?? .ask
            watch()
            return
        }
        guard let choice = chooseSide() else { return }
        enable(useCloud: choice)
    }

    /// 首次启动时在 iCloud 云盘里找到配置：问是否接入、用哪一份（D35，另一台 Mac 装好后开箱即用）
    func offerToJoin() {
        guard isAvailable, hasCloudConfig, !configs.config.sync.iCloud else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "在 iCloud 云盘中找到了 TouchOS 配置")
        var lines = [String(localized: "可能来自你的另一台 Mac。开启 iCloud 同步后，两台 Mac 用同一份配置：要用哪一份？另一份会放进这台 Mac 的配置备份，可以随时恢复。")]
        if let date = Self.modifiedAt(Self.fileURL) {
            lines.append(String(localized: "iCloud 中的配置修改于 \(date.formatted(date: .abbreviated, time: .shortened))。"))
        }
        lines.append(String(localized: "面板大小、映射区、按钮间隙、按住与确认时间只属于这台 Mac，不受影响。"))
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: String(localized: "使用 iCloud 中的配置"))
        alert.addButton(withTitle: String(localized: "使用这台 Mac 的配置"))
        alert.addButton(withTitle: String(localized: "暂不同步"))
        let useCloud: Bool
        switch alert.runModal() {
        case .alertFirstButtonReturn: useCloud = true
        case .alertSecondButtonReturn: useCloud = false
        default: return
        }
        if downloadIfNeeded() {
            // 用这台 Mac 的也要等下载完：被替换的那份要先进备份
            enableWhenDownloaded = .use(cloud: useCloud)
            watch()
            return
        }
        enable(useCloud: useCloud)
    }

    /// 打开同步：`useCloud` 为 true 时以 iCloud 中的配置为准，否则以本机为准
    private func enable(useCloud: Bool) {
        enableWhenDownloaded = nil
        if let local = try? CloudSync.payload(configs.config), let cloud = try? Data(contentsOf: Self.fileURL) {
            // 把"上一次一致"设成将要被替换的一方，对账时就会照着另一方改；被替换的一方先进本机备份
            try? (useCloud ? local : cloud).write(to: syncedURL, options: .atomic)
            if cloud != local, let replaced = useCloud ? try? configs.config.encoded() : cloud { configs.keepBackup(replaced) }
        }
        configs.update { $0.sync.iCloud = true }
        watch()
        reconcile()
    }

    /// iCloud 中已有不同的配置时问用哪一份；nil 表示取消
    private func chooseSide() -> Bool? {
        guard let cloud = try? Data(contentsOf: Self.fileURL), let local = try? CloudSync.payload(configs.config), cloud != local else {
            return false
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "iCloud 云盘中已有 TouchOS 配置")
        if let date = Self.modifiedAt(Self.fileURL) {
            alert.informativeText = String(localized: "iCloud 中的配置修改于 \(date.formatted(date: .abbreviated, time: .shortened))。要用哪一份？另一份会放进这台 Mac 的配置备份，可以随时恢复。")
        } else {
            alert.informativeText = String(localized: "要用哪一份？另一份会放进这台 Mac 的配置备份，可以随时恢复。")
        }
        alert.addButton(withTitle: String(localized: "使用 iCloud 中的配置"))
        alert.addButton(withTitle: String(localized: "使用这台 Mac 的配置"))
        alert.addButton(withTitle: String(localized: "取消"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return true
        case .alertSecondButtonReturn: return false
        default: return nil
        }
    }

    func revealInFinder() {
        if FileManager.default.fileExists(atPath: Self.fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([Self.fileURL])
        } else {
            NSWorkspace.shared.open(Self.cloudDocs)
        }
    }

    // MARK: 对账

    func reconcile() {
        if let pending = enableWhenDownloaded {
            guard !downloadIfNeeded() else { return }
            let decided: Bool? = switch pending {
            case .use(let cloud): cloud
            case .ask: chooseSide()
            }
            guard let choice = decided else {
                // 下载完后取消了：不开启
                enableWhenDownloaded = nil
                stopWatching()
                status = .off
                return
            }
            enable(useCloud: choice)
            return
        }
        guard configs.config.sync.iCloud else {
            status = .off
            return
        }
        guard isAvailable else {
            status = .unavailable
            return
        }
        // 文件还在云端时不能当作"没有文件"而上传，否则会覆盖另一台 Mac 的配置
        guard !downloadIfNeeded() else { return }
        collectConflictCopies()
        guard let local = try? CloudSync.payload(configs.config) else { return }
        let cloud = try? Data(contentsOf: Self.fileURL)
        let synced = try? Data(contentsOf: syncedURL)
        let cloudIsNewer = (Self.modifiedAt(Self.fileURL) ?? .distantPast) > (configs.modifiedAt ?? .distantPast)
        switch CloudSync.decide(cloud: cloud, local: local, synced: synced, cloudIsNewer: cloudIsNewer) {
        case .none:
            markSynced(local)
        case .upload:
            upload(local)
        case .download:
            if let cloud { download(cloud, local: local) }
        case .conflict(let keepCloud):
            log.info("icloud conflict, keep cloud: \(keepCloud, privacy: .public)")
            if keepCloud, let cloud {
                if let old = try? configs.config.encoded() { configs.keepBackup(old) }
                download(cloud, local: local)
            } else {
                if let cloud { configs.keepBackup(cloud) }
                upload(local)
            }
        }
    }

    private func upload(_ local: Data) {
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try local.write(to: Self.fileURL, options: .atomic)
            markSynced(local)
        } catch {
            log.error("icloud upload failed: \(error.localizedDescription, privacy: .public)")
            status = .blocked(String(localized: "无法写入 iCloud 云盘：\(error.localizedDescription)"))
        }
    }

    private func download(_ cloud: Data, local: Data) {
        let incoming: AppConfig
        do {
            incoming = try AppConfig.decode(cloud)
        } catch ConfigError.newerVersion {
            status = .blocked(String(localized: "iCloud 中的配置来自更新版本的 TouchOS，这台 Mac 升级后才能同步"))
            return
        } catch {
            status = .blocked(String(localized: "iCloud 中的配置无法读取，已保留这台 Mac 的配置"))
            return
        }
        let risky = CloudSync.newRiskyActions(cloud: incoming, local: configs.config)
        if !risky.isEmpty, !confirm(risky) {
            // 不接受：保留本机，并用本机覆盖 iCloud，免得反复询问
            configs.keepBackup(cloud)
            upload(local)
            return
        }
        markSynced(cloud)
        configs.replace(CloudSync.merge(cloud: incoming, into: configs.config))
    }

    /// iCloud 带来了会运行命令的动作：与导入相同，先让用户确认（FR-9.5）
    private func confirm(_ risky: [(panel: String, slot: String, action: Action)]) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "iCloud 同步带来了会运行命令的按钮")
        var lines = risky.prefix(8).map { String(localized: "「\($0.panel)」的「\($0.slot)」") }
        if risky.count > 8 { lines.append(String(localized: "等 \(risky.count) 个")) }
        lines += ["", String(localized: "如果不是你在另一台 Mac 上添加的，请选择保留这台 Mac 的配置。")]
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: String(localized: "保留这台 Mac 的配置"))
        alert.addButton(withTitle: String(localized: "接受"))
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func markSynced(_ data: Data) {
        try? data.write(to: syncedURL, options: .atomic)
        status = .synced(Date())
    }

    /// 文件只在云端时请求下载；返回 true 表示还要等
    private func downloadIfNeeded() -> Bool {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: Self.fileURL.path), fm.fileExists(atPath: Self.placeholderURL.path) else { return false }
        do {
            try fm.startDownloadingUbiquitousItem(at: Self.fileURL)
        } catch {
            log.error("icloud download request failed: \(error.localizedDescription, privacy: .public)")
        }
        status = .downloading
        return true
    }

    /// iCloud 云盘遇到冲突时会留下「config 2.json」这样的副本：收进本机备份后删除，以主文件为准
    private func collectConflictCopies() {
        let fm = FileManager.default
        let stem = (CloudSync.fileName as NSString).deletingPathExtension
        let files = (try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "json" && url.lastPathComponent.hasPrefix(stem + " ") {
            if let data = try? Data(contentsOf: url) { configs.keepBackup(data) }
            try? fm.removeItem(at: url)
        }
    }

    private static func modifiedAt(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: 监听

    private func watch() {
        stopWatching()
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let fd = open(Self.folder.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .attrib],
                                                                   queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scheduleReconcile() } }
            source.setCancelHandler { close(fd) }
            source.resume()
            self.source = source
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
    }

    private func stopWatching() {
        source?.cancel()
        source = nil
        timer?.invalidate()
        timer = nil
    }

    private func scheduleReconcile() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.reconcile() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }
}
