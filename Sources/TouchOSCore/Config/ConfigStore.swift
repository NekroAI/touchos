import Foundation

/// 配置文件读写（FR-10.1、FR-10.2）：`config.json` 写临时文件后原子替换；每次写入前把旧文件轮转到 `backups/`，
/// 保留最近 `maxBackups` 份。加载失败时不覆盖原文件，交回默认配置与原因
public struct ConfigStore: Sendable {
    public static let maxBackups = 5
    public static let fileName = "config.json"

    public enum LoadProblem: Equatable, Sendable {
        /// 解析失败、版本过高或字段非法：已改用默认配置，原文件保留
        case damaged(String)
    }

    public struct Loaded: Sendable {
        public let config: AppConfig
        public let problem: LoadProblem?
        /// 文件不存在（首次启动）
        public let isNew: Bool
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// 默认位置：`~/Library/Application Support/TouchOS/`
    public static var standard: ConfigStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ConfigStore(directory: base.appendingPathComponent("TouchOS", isDirectory: true))
    }

    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }
    public var backupDirectory: URL { directory.appendingPathComponent("backups", isDirectory: true) }

    public func load() -> Loaded {
        guard let data = try? Data(contentsOf: fileURL) else {
            return Loaded(config: .default, problem: nil, isNew: !FileManager.default.fileExists(atPath: fileURL.path))
        }
        do {
            return Loaded(config: try AppConfig.decode(data), problem: nil, isNew: false)
        } catch let error as ConfigError {
            let reason: String = switch error {
            case .newerVersion(let v): String(localized: "配置文件版本 \(v) 高于本程序支持的版本 \(AppConfig.currentVersion)")
            case .notAnObject: String(localized: "配置文件不是 JSON 对象")
            case .invalid(let detail): String(localized: "配置文件内容不合法：\(detail)")
            }
            return Loaded(config: .default, problem: .damaged(reason), isNew: false)
        } catch {
            return Loaded(config: .default, problem: .damaged(String(localized: "配置文件无法解析")), isNew: false)
        }
    }

    public func save(_ config: AppConfig) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try config.encoded()
        if let old = try? Data(contentsOf: fileURL) {
            guard old != data else { return }
            try rotate(old)
        }
        try data.write(to: fileURL, options: .atomic)
    }

    /// 备份文件，新的在前
    public func backups() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// 把一份配置内容放进备份（iCloud 同步冲突时落选的一方，D35）
    public func keepBackup(_ data: Data) throws {
        try rotate(data)
    }

    /// 从备份恢复：校验通过后写回（当前文件先进入备份）
    public func restore(_ backup: URL) throws -> AppConfig {
        let config = try AppConfig.decode(try Data(contentsOf: backup))
        try save(config)
        return config
    }

    private func rotate(_ old: Data) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        // 文件名按时间排序；同一毫秒内多次写入时序号递增（定长，保证字典序即时间序）
        let stamp = Self.stamp(Date())
        var n = 0
        var url: URL
        repeat {
            url = backupDirectory.appendingPathComponent(String(format: "config-%@-%03d.json", stamp, n))
            n += 1
        } while fm.fileExists(atPath: url.path)
        try old.write(to: url, options: .atomic)
        for extra in backups().dropFirst(Self.maxBackups) { try? fm.removeItem(at: extra) }
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.string(from: date)
    }
}
