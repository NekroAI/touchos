import CoreGraphics
import Foundation

/// 全部用户配置（SRS 第 10 章，结构按 D23 扩展：面板列表、唤起方式绑定、外观）。
/// 状态机只读取由它生成的 `Tuning` 与 `SessionEnvironment` 快照（FR-10.3）
public struct AppConfig: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public struct General: Codable, Equatable, Sendable {
        /// 暂停时不接受锚定、不显示面板（FR-11.2）
        public var enabled = true
        public var haptics = true
        public var showTrail = true
        /// 常驻模式：锚指抬起后面板保留（D14）
        public var stickyPanel = false
        public var dimBackground = false
        /// 这些应用在前台时不接受唤起
        public var blacklist: [String] = []

        public init() {}
    }

    public struct Appearance: Codable, Equatable, Sendable {
        /// orb / lens / holo
        public var theme = "orb"
        /// depth / drum
        public var nav = "depth"
        /// RRGGBB；nil 为自动
        public var accent: String?

        public init() {}
    }

    /// 唤起方式开关（D19、D20：默认只开四指轻点）
    public struct Triggers: Codable, Equatable, Sendable {
        public var hold = false
        public var anchorCorner = AnchorCorner.bottomLeft
        public var threeFingerTap = false
        public var fourFingerTap = true
        public var cornerDoubleTap = false

        public init() {}
    }

    /// 尺寸（D21）
    public struct Sizes: Codable, Equatable, Sendable {
        public var panelScale = Tuning().panelScale
        public var mappingScale = Tuning().mappingScale

        public init() {}
    }

    public struct Binding: Codable, Equatable, Sendable {
        /// `PanelTrigger.key`
        public var trigger: String
        public var panel: String

        public init(trigger: PanelTrigger, panel: String) {
            self.trigger = trigger.key
            self.panel = panel
        }
    }

    public var schemaVersion = currentVersion
    public var general = General()
    public var appearance = Appearance()
    public var triggers = Triggers()
    public var sizes = Sizes()
    /// 第一个为默认面板（D23）
    public var panels: [Layout] = PresetPanels.all
    public var bindings: [Binding] = []

    public init() {}

    /// 内置默认配置：预置四个面板，四指轻点打开第一个
    public static let `default` = AppConfig()

    private enum Keys: String, CodingKey { case schemaVersion, general, appearance, triggers, sizes, panels, bindings }

    /// 缺省的段落取默认值：手写或旧版本的文件只写了部分内容也能读取
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        general = try c.decodeIfPresent(General.self, forKey: .general) ?? General()
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? Appearance()
        triggers = try c.decodeIfPresent(Triggers.self, forKey: .triggers) ?? Triggers()
        sizes = try c.decodeIfPresent(Sizes.self, forKey: .sizes) ?? Sizes()
        panels = try c.decodeIfPresent([Layout].self, forKey: .panels) ?? PresetPanels.all
        bindings = try c.decodeIfPresent([Binding].self, forKey: .bindings) ?? []
    }

    /// 绑定表；写错的唤起方式忽略
    public var bindingMap: [PanelTrigger: String] {
        bindings.reduce(into: [:]) { map, b in
            if let t = PanelTrigger(key: b.trigger) { map[t] = b.panel }
        }
    }

    /// 把配置中的参数写入 `Tuning`，其余参数保留
    public func apply(to t: inout Tuning) {
        t.holdTrigger = triggers.hold
        t.anchorCorner = triggers.anchorCorner
        t.threeFingerTap = triggers.threeFingerTap
        t.fourFingerTap = triggers.fourFingerTap
        t.cornerDoubleTap = triggers.cornerDoubleTap
        t.stickyPanel = general.stickyPanel
        t.panelScale = min(max(sizes.panelScale, Tuning.panelScaleRange.lowerBound), Tuning.panelScaleRange.upperBound)
        t.mappingScale = min(max(sizes.mappingScale, Tuning.mappingScaleRange.lowerBound), Tuning.mappingScaleRange.upperBound)
    }

    // MARK: 编码

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// 解码并迁移到当前版本；版本高于当前、结构错误时抛出
    public static func decode(_ data: Data) throws -> AppConfig {
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ConfigError.notAnObject }
        json = try ConfigMigrator.migrate(json)
        let migrated = try JSONSerialization.data(withJSONObject: json)
        do {
            return try JSONDecoder().decode(AppConfig.self, from: migrated)
        } catch {
            throw ConfigError.invalid(String(describing: error))
        }
    }
}

public enum ConfigError: Error, Equatable {
    case notAnObject
    case newerVersion(Int)
    case invalid(String)
}

// MARK: 迁移（FR-10.4）

/// 按版本顺序执行迁移：`steps[v]` 把版本 v 的 JSON 升到 v + 1
public enum ConfigMigrator {
    public typealias Step = @Sendable ([String: Any]) -> [String: Any]

    /// 版本 0：没有 `schemaVersion` 字段（SRS 10.2 示例之前的手写文件），布局在 `layouts` 字段
    public static let steps: [Int: Step] = [
        0: { old in
            var json = old
            if json["panels"] == nil, let layouts = json["layouts"] { json["panels"] = layouts }
            json["layouts"] = nil
            json["profiles"] = nil
            json["schemaVersion"] = 1
            return json
        },
    ]

    public static func migrate(_ json: [String: Any], to target: Int = AppConfig.currentVersion,
                               steps: [Int: Step] = steps) throws -> [String: Any] {
        var json = json
        var version = json["schemaVersion"] as? Int ?? 0
        guard version <= target else { throw ConfigError.newerVersion(version) }
        while version < target {
            guard let step = steps[version] else { throw ConfigError.invalid("缺少从版本 \(version) 迁移的步骤") }
            json = step(json)
            version += 1
            json["schemaVersion"] = version
        }
        return json
    }
}

// MARK: 校验（FR-10.6）

public struct ConfigIssue: Equatable, Sendable, CustomStringConvertible {
    public enum Kind: Equatable, Sendable {
        case noPanels
        case duplicatePanel(String)
        case duplicateSlot(String)
        case gridSize(panel: String)
        case outsideGrid(panel: String, slot: String)
        case overlap(panel: String, slots: [String])
        case unknownBinding(String)
        case unknownPanel(trigger: String, panel: String)
    }

    public let kind: Kind

    public var description: String {
        switch kind {
        case .noPanels: "没有任何面板"
        case .duplicatePanel(let id): "面板 ID 重复：\(id)"
        case .duplicateSlot(let id): "按钮 ID 重复：\(id)"
        case .gridSize(let p): "面板 \(p) 的网格行列数超出范围（1–\(AppConfig.maxRows) 行、1–\(AppConfig.maxCols) 列）"
        case .outsideGrid(let p, let s): "面板 \(p) 的按钮 \(s) 越出网格"
        case .overlap(let p, let s): "面板 \(p) 的按钮重叠：\(s.joined(separator: "、"))"
        case .unknownBinding(let t): "无法识别的唤起方式：\(t)"
        case .unknownPanel(let t, let p): "唤起方式 \(t) 绑定的面板 \(p) 不存在"
        }
    }
}

extension AppConfig {
    /// FR-11.4：网格行列数范围
    public static let maxRows = 6
    public static let maxCols = 8

    /// 校验结果；空表示可以保存。加载时有问题仍按 FR-6.9 使用（重叠按 z 序命中），只在设置页警告
    public func validate() -> [ConfigIssue] {
        var issues: [ConfigIssue] = []
        if panels.isEmpty { issues.append(.init(kind: .noPanels)) }
        var panelIDs = Set<String>(), slotIDs = Set<String>()
        for panel in panels {
            if !panelIDs.insert(panel.id).inserted { issues.append(.init(kind: .duplicatePanel(panel.id))) }
            for slot in panel.slots where !slotIDs.insert(slot.id.raw).inserted {
                issues.append(.init(kind: .duplicateSlot(slot.id.raw)))
            }
            issues += Self.gridIssues(panel)
        }
        for b in bindings {
            if PanelTrigger(key: b.trigger) == nil {
                issues.append(.init(kind: .unknownBinding(b.trigger)))
            } else if !panelIDs.contains(b.panel) {
                issues.append(.init(kind: .unknownPanel(trigger: b.trigger, panel: b.panel)))
            }
        }
        return issues
    }

    static func gridIssues(_ panel: Layout) -> [ConfigIssue] {
        let cells = panel.slots.compactMap { s -> (String, GridCell)? in
            if case .cell(let c) = s.shape { (s.id.raw, c) } else { nil }
        }
        guard !cells.isEmpty else { return [] }
        guard (1...maxRows).contains(panel.rows), (1...maxCols).contains(panel.cols) else {
            return [.init(kind: .gridSize(panel: panel.id))]
        }
        var issues: [ConfigIssue] = []
        var owner = [[String?]](repeating: [String?](repeating: nil, count: panel.cols), count: panel.rows)
        var overlaps: [String] = []
        for (id, c) in cells {
            guard c.row >= 0, c.col >= 0, c.rowSpan >= 1, c.colSpan >= 1,
                  c.row + c.rowSpan <= panel.rows, c.col + c.colSpan <= panel.cols else {
                issues.append(.init(kind: .outsideGrid(panel: panel.id, slot: id)))
                continue
            }
            for r in c.row..<(c.row + c.rowSpan) {
                for col in c.col..<(c.col + c.colSpan) {
                    if let other = owner[r][col] {
                        for x in [other, id] where !overlaps.contains(x) { overlaps.append(x) }
                    } else {
                        owner[r][col] = id
                    }
                }
            }
        }
        if !overlaps.isEmpty { issues.append(.init(kind: .overlap(panel: panel.id, slots: overlaps))) }
        return issues
    }
}
