import Foundation

/// 版本号（如 `v0.1.0`）：只比较数字段，带预发布后缀的版本不算正式版本（D44）
public struct AppVersion: Comparable, Sendable {
    private let parts: [Int]

    public init?(_ string: String) {
        let text = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        self.parts = parts.compactMap(\.self)
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}

/// GitHub Releases 上的一个正式版本（D44）
public struct ReleaseInfo: Equatable, Sendable {
    public let tag: String
    public let url: URL

    /// 解析 `releases/latest` 的响应。草稿、预发布、版本号不合法，或链接不在本仓库之下时返回 nil：
    /// 这个链接会被打开，不信任响应里的任意地址
    public static func parse(json data: Data) -> ReleaseInfo? {
        struct Payload: Decodable {
            let tag_name: String
            let html_url: String
            let draft: Bool?
            let prerelease: Bool?
        }
        guard let p = try? JSONDecoder().decode(Payload.self, from: data), p.draft != true, p.prerelease != true,
              AppVersion(p.tag_name) != nil, let url = URL(string: p.html_url), url.scheme == "https", url.host == "github.com",
              url.path.hasPrefix("/NekroAI/touchos/") else { return nil }
        return ReleaseInfo(tag: p.tag_name, url: url)
    }

    /// 比 `current` 新才算更新；当前版本号不合法（开发构建）时不提示
    public func isNewer(than current: String) -> Bool {
        guard let mine = AppVersion(current), let theirs = AppVersion(tag) else { return false }
        return theirs > mine
    }
}
