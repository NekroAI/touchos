import Foundation

// 动作执行时读取的内容（D59）：剪贴板的判定与 `{clipboard}` 占位。系统剪贴板由外层读出，这里只做纯逻辑

/// 剪贴板的一份快照
public struct ClipboardSnapshot: Equatable, Sendable {
    /// 拷贝的文件（在访达里拷贝时）
    public var fileURLs: [URL]
    public var text: String?

    public init(fileURLs: [URL] = [], text: String? = nil) {
        self.fileURLs = fileURLs
        self.text = text
    }

    public var isEmpty: Bool { fileURLs.isEmpty && (text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }

    /// 交给 Shell 与脚本的文字（`TOUCHOS_CLIPBOARD`）：拷贝的是文件时为路径，每行一个
    public var plainText: String {
        fileURLs.isEmpty ? text ?? "" : fileURLs.map(\.path).joined(separator: "\n")
    }

    /// 用应用打开时实际打开的东西。依次看：拷贝的文件 → 链接 → 存在的路径 → 代入搜索链接；都不是时为 nil
    public func openTarget(searchURL: String?, fileExists: (String) -> Bool) -> OpenTarget? {
        if !fileURLs.isEmpty { return .files(fileURLs) }
        guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if !raw.contains(where: \.isNewline) {
            if let url = Self.link(raw) {
                if url.isFileURL { return fileExists(url.path) ? .files([url]) : nil }
                return .url(url)
            }
            if raw.hasPrefix("/") || raw.hasPrefix("~") {
                let path = (raw as NSString).expandingTildeInPath
                if fileExists(path) { return .files([URL(fileURLWithPath: path)]) }
            }
        }
        guard let searchURL, !searchURL.isEmpty, let url = URL(string: Placeholder.fill(searchURL, with: raw)), url.scheme != nil else {
            return nil
        }
        return .url(url)
    }

    /// 文字是不是一个链接：带协议（`https://`、`file://`、`mailto:` 等），或以 `www.` 开头（按 https）；不能有空白
    static func link(_ s: String) -> URL? {
        guard !s.contains(where: \.isWhitespace) else { return nil }
        if s.lowercased().hasPrefix("www.") { return URL(string: "https://" + s) }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              scheme.first?.isLetter == true, scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+.-".contains($0) }) else { return nil }
        if scheme == "mailto" { return url }
        // 要求 `协议://`：排除 "note:abc"、"C:" 一类
        return s.range(of: "://") != nil && (url.host != nil || url.isFileURL) ? url : nil
    }
}

/// 用应用打开剪贴板时打开的东西
public enum OpenTarget: Equatable, Sendable {
    case files([URL])
    case url(URL)
}

/// 链接里的占位（D59）
public enum Placeholder {
    public static let clipboard = "{clipboard}"
    /// 链接经过 `URL` 规范化后，花括号会被编码成这样
    static let encodedClipboard = "%7Bclipboard%7D"

    public static func contains(_ template: String) -> Bool {
        template.contains(clipboard) || template.range(of: encodedClipboard, options: .caseInsensitive) != nil
    }

    /// 编辑器里把编码过的占位还原成 `{clipboard}` 显示
    public static func display(_ template: String) -> String {
        template.replacingOccurrences(of: encodedClipboard, with: clipboard, options: .caseInsensitive)
    }

    /// 把占位换成文字：整个模板就是占位时原样代入（剪贴板本身就是链接），否则按网址参数编码
    public static func fill(_ template: String, with text: String) -> String {
        let t = display(template)
        if t == clipboard { return text }
        let encoded = text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
        return t.replacingOccurrences(of: clipboard, with: encoded)
    }

    /// RFC 3986 的非保留字符，其余一律编码（`&`、`=`、`#`、`+` 不会打断查询参数）
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

extension Action {
    /// 动作打开的应用（打开应用、用应用打开剪贴板），按钮图标可以跟随它（D58）
    public var appBundleID: String? {
        switch self {
        case .openApp(let id), .openWith(let id, _, _): id
        default: nil
        }
    }

    /// 执行前要读的内容；不需要时为 nil，不碰剪贴板（D59：只在真正用到时读取，避免系统的读取提示）
    public var input: ActionInput? {
        switch self {
        case .openWith(_, let input, _): input
        case .openURL(let url, _): Placeholder.contains(url.absoluteString) ? .clipboard : nil
        case .shell(let command, _, _): command.contains(ActionInput.clipboardVariable) ? .clipboard : nil
        case .appleScript(let source, _): source.contains(ActionInput.clipboardVariable) ? .clipboard : nil
        default: nil
        }
    }
}

extension ActionInput {
    /// Shell 与脚本通过这个环境变量拿到剪贴板，不做文本替换，内容不会被当成命令执行
    public static let clipboardVariable = "TOUCHOS_CLIPBOARD"
}
