import Foundation

/// iCloud 同步（D35）：哪些设置跟着 iCloud 走、两边都改过时怎么办。文件读写与监听在应用层，这里只做判断。
///
/// 只属于这台 Mac、不写进 iCloud 的设置：「启用 TouchOS」开关、尺寸（面板大小、映射区、按钮间隙，随屏幕与触控板不同）、
/// 同步开关本身。其余（面板、外观、唤起方式与绑定、排除的应用等）各台 Mac 一致
public enum CloudSync {
    /// iCloud 云盘里的文件夹与文件名：固定，不让用户选（负责人要求），另一台 Mac 打开开关即可接入
    public static let folderName = "Nekro TouchOS"
    public static let fileName = "config.json"

    /// 写进 iCloud 的内容：去掉只属于本机的设置。键排序固定，内容相同则字节相同，可以直接比较
    public static func payload(_ config: AppConfig) throws -> Data {
        guard var json = try JSONSerialization.jsonObject(with: config.encoded()) as? [String: Any] else {
            throw ConfigError.notAnObject
        }
        json["sync"] = nil
        json["sizes"] = nil
        if var general = json["general"] as? [String: Any] {
            general["enabled"] = nil
            json["general"] = general
        }
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// 把 iCloud 中的配置合进本机：只属于本机的设置保留本机的值
    public static func merge(cloud: AppConfig, into local: AppConfig) -> AppConfig {
        var merged = cloud
        merged.general.enabled = local.general.enabled
        merged.sizes = local.sizes
        merged.sync = local.sync
        return merged
    }

    /// iCloud 带来的、本机还没有的会运行命令的动作：应用前要用户确认（与导入相同，FR-9.5）
    public static func newRiskyActions(cloud: AppConfig, local: AppConfig) -> [(panel: String, slot: String, action: Action)] {
        let known = local.panels.flatMap { $0.slots.map(\.action) }.filter(\.runsCode)
        return cloud.panels.flatMap { p in
            p.slots.filter { $0.action.runsCode && !known.contains($0.action) }.map { (p.name, $0.title, $0.action) }
        }
    }

    public enum Decision: Equatable, Sendable {
        /// 两边一致，或只有本机在等写盘之外没有变化
        case none
        /// 本机改过、iCloud 没变：写上去
        case upload
        /// iCloud 改过、本机没变：拿下来
        case download
        /// 两边都改过（例如离线时各改了一次）：修改时间新的一方胜出，落选的一方进本机备份
        case conflict(keepCloud: Bool)
    }

    /// - Parameters:
    ///   - cloud: iCloud 中的内容；没有文件时为 nil
    ///   - local: 本机配置的 `payload`
    ///   - synced: 上一次两边一致时的内容；从未同步过为 nil
    ///   - cloudIsNewer: iCloud 文件的修改时间晚于本机配置文件
    public static func decide(cloud: Data?, local: Data, synced: Data?, cloudIsNewer: Bool) -> Decision {
        guard let cloud else { return .upload }
        if cloud == local { return .none }
        let cloudChanged = cloud != synced, localChanged = local != synced
        switch (cloudChanged, localChanged) {
        case (true, false): return .download
        case (false, true): return .upload
        default: return .conflict(keepCloud: cloudIsNewer)
        }
    }
}
