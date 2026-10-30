import CoreGraphics
import Foundation

/// 全部用户配置（SRS 第 10 章，结构按 D23 扩展：面板列表、唤起方式绑定、外观）。
/// 状态机只读取由它生成的 `Tuning` 与 `SessionEnvironment` 快照（FR-10.3）
public struct AppConfig: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public struct General: Codable, Equatable, Sendable {
        /// 暂停时不接受唤起、不显示面板（FR-11.2）
        public var enabled = true
        public var haptics = true
        public var showTrail = true
        public var dimBackground = false
        /// 这些应用在前台时不接受唤起
        public var blacklist: [String] = []
        /// 每天查询一次 GitHub Releases，有新版本时在菜单中提示（D44）
        public var checkUpdates = true
        /// 快捷键与窗口动作执行前，先把焦点切到指针下的窗口（D27）
        public var focusPointerWindow = true
        /// 面板打开时的光标（D52）
        public var cursorFreeze = CursorFreeze.hide

        public init() {}

        private enum Keys: String, CodingKey {
            case enabled, haptics, showTrail, dimBackground, blacklist, focusPointerWindow, checkUpdates, cursorFreeze
        }

        /// 缺省的字段取默认值：旧版本写出的文件没有后来新增的字段
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            let d = General()
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
            haptics = try c.decodeIfPresent(Bool.self, forKey: .haptics) ?? d.haptics
            showTrail = try c.decodeIfPresent(Bool.self, forKey: .showTrail) ?? d.showTrail
            dimBackground = try c.decodeIfPresent(Bool.self, forKey: .dimBackground) ?? d.dimBackground
            blacklist = try c.decodeIfPresent([String].self, forKey: .blacklist) ?? d.blacklist
            focusPointerWindow = try c.decodeIfPresent(Bool.self, forKey: .focusPointerWindow) ?? d.focusPointerWindow
            checkUpdates = try c.decodeIfPresent(Bool.self, forKey: .checkUpdates) ?? d.checkUpdates
            // 新版本可能增加取值：不认识的按默认处理，不让整份配置读取失败
            cursorFreeze = (try c.decodeIfPresent(String.self, forKey: .cursorFreeze)).flatMap(CursorFreeze.init) ?? d.cursorFreeze
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(enabled, forKey: .enabled)
            try c.encode(haptics, forKey: .haptics)
            try c.encode(showTrail, forKey: .showTrail)
            try c.encode(dimBackground, forKey: .dimBackground)
            try c.encode(blacklist, forKey: .blacklist)
            try c.encode(focusPointerWindow, forKey: .focusPointerWindow)
            try c.encode(checkUpdates, forKey: .checkUpdates)
            try c.encode(cursorFreeze, forKey: .cursorFreeze)
        }
    }

    public struct Appearance: Codable, Equatable, Sendable {
        /// orb / lens / holo
        public var theme = "orb"
        /// depth / drum
        public var nav = "drum"
        /// RRGGBB；nil 为自动
        public var accent: String?

        public init() {}
    }

    /// 启用的唤起方式（D26、D38）：可以多选，方位分区每个单独开关。默认开轻点后按住与四指轻点（D25）
    public struct Triggers: Codable, Equatable, Sendable {
        /// `PanelTrigger.key`，按 `PanelTrigger.all` 的顺序
        public var enabled: [String] = [PanelTrigger.tapHold.key, PanelTrigger.fourFingerTap.key]

        public init() {}

        /// 启用的唤起方式；写错的忽略
        public var list: [PanelTrigger] { PanelTrigger.all.filter { enabled.contains($0.key) } }

        public func isOn(_ trigger: PanelTrigger) -> Bool { enabled.contains(trigger.key) }

        public mutating func set(_ trigger: PanelTrigger, _ on: Bool) {
            var keys = Set(enabled)
            if on { keys.insert(trigger.key) } else { keys.remove(trigger.key) }
            // 认识的按固定顺序排列，不认识的保留在后面，不丢用户手写的内容
            enabled = PanelTrigger.all.map(\.key).filter(keys.contains) + enabled.filter { PanelTrigger(key: $0) == nil }
        }

        enum Keys: String, CodingKey { case enabled, hold, anchorCorner, threeFingerTap, fourFingerTap, cornerDoubleTap }

        /// D26 之前是几个开关加一个角落：按旧的含义换算，并加上新的默认方式轻点后按住（D25）。
        /// 旧版本里绑定了面板的其他角也能唤起，这部分由 `AppConfig` 在读完绑定后补上。
        /// 一指按住角落已去掉、角落轻点两下改为方位分区的轻点后按住（D38），见 `PanelTrigger.migrated(key:)`
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            let keys: [String]
            if let enabled = try c.decodeIfPresent([String].self, forKey: .enabled) {
                keys = enabled
            } else {
                let corner = try c.decodeIfPresent(String.self, forKey: .anchorCorner) ?? "bottomLeft"
                var list = [PanelTrigger.tapHold.key]
                if try c.decodeIfPresent(Bool.self, forKey: .cornerDoubleTap) ?? false { list.append("doubleTap.\(corner)") }
                if try c.decodeIfPresent(Bool.self, forKey: .threeFingerTap) ?? false { list.append(PanelTrigger.threeFingerTap.key) }
                if try c.decodeIfPresent(Bool.self, forKey: .fourFingerTap) ?? true { list.append(PanelTrigger.fourFingerTap.key) }
                keys = list
            }
            var migrated: [String] = []
            for key in keys {
                if let k = PanelTrigger.migrated(key: key), !migrated.contains(k) { migrated.append(k) }
            }
            // 原来只开了一指按住角落：去掉后至少保留默认的轻点后按住，面板仍能唤起
            if migrated.isEmpty && !keys.isEmpty { migrated = [PanelTrigger.tapHold.key] }
            enabled = PanelTrigger.all.map(\.key).filter(migrated.contains) + migrated.filter { PanelTrigger(key: $0) == nil }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(enabled, forKey: .enabled)
        }
    }

    /// 尺寸（D21）
    public struct Sizes: Codable, Equatable, Sendable {
        public var panelScale = Tuning().panelScale
        public var mappingScale = Tuning().mappingScale
        /// 按钮间隙（毫米，D31）
        public var hitGapMM = Tuning().hitGapMM

        public init() {}

        private enum Keys: String, CodingKey { case panelScale, mappingScale, hitGapMM }

        /// 缺省的字段取默认值：旧版本写出的文件没有后来新增的字段
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            let d = Sizes()
            panelScale = try c.decodeIfPresent(Double.self, forKey: .panelScale) ?? d.panelScale
            mappingScale = try c.decodeIfPresent(Double.self, forKey: .mappingScale) ?? d.mappingScale
            hitGapMM = try c.decodeIfPresent(Double.self, forKey: .hitGapMM) ?? d.hitGapMM
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(panelScale, forKey: .panelScale)
            try c.encode(mappingScale, forKey: .mappingScale)
            try c.encode(hitGapMM, forKey: .hitGapMM)
        }
    }

    /// 同步（D35）：只属于这台 Mac，不写进 iCloud
    public struct Sync: Codable, Equatable, Sendable {
        /// 通过 iCloud 云盘同步配置
        public var iCloud = false

        public init() {}

        private enum Keys: String, CodingKey { case iCloud }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            iCloud = try c.decodeIfPresent(Bool.self, forKey: .iCloud) ?? false
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(iCloud, forKey: .iCloud)
        }
    }

    public struct Binding: Codable, Equatable, Sendable {
        /// `PanelTrigger.key`
        public var trigger: String
        public var panel: String

        public init(trigger: PanelTrigger, panel: String) {
            self.init(key: trigger.key, panel: panel)
        }

        init(key: String, panel: String) {
            self.trigger = key
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
    /// 四指轻点默认打开「窗口」：轻点后手指已离开触控板，接着朝一个方向划一下，正合环形面板（D41）
    public var bindings: [Binding] = [Binding(trigger: .fourFingerTap, panel: PresetPanels.window.id)]
    public var sync = Sync()

    public init() {}

    /// 内置默认配置：预置四个面板，轻点后按住打开第一个，四指轻点打开「窗口」
    public static let `default` = AppConfig()

    private enum Keys: String, CodingKey { case schemaVersion, general, appearance, triggers, sizes, panels, bindings, sync }

    /// 缺省的段落取默认值：手写或旧版本的文件只写了部分内容也能读取
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        general = try c.decodeIfPresent(General.self, forKey: .general) ?? General()
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? Appearance()
        triggers = try c.decodeIfPresent(Triggers.self, forKey: .triggers) ?? Triggers()
        sizes = try c.decodeIfPresent(Sizes.self, forKey: .sizes) ?? Sizes()
        panels = try c.decodeIfPresent([Layout].self, forKey: .panels) ?? PresetPanels.all
        bindings = (try c.decodeIfPresent([Binding].self, forKey: .bindings) ?? []).compactMap { b in
            // 一指按住角落的绑定丢弃，角落轻点两下的换成同一方位（D38）
            PanelTrigger.migrated(key: b.trigger).map { Binding(key: $0, panel: b.panel) }
        }
        sync = try c.decodeIfPresent(Sync.self, forKey: .sync) ?? Sync()
        if let old = try? c.nestedContainer(keyedBy: Triggers.Keys.self, forKey: .triggers), !old.contains(.enabled) {
            // D26 之前：开着轻点两下时，绑定了面板的其他角也能唤起
            let zones = triggers.list.contains { if case .zoneTapHold = $0 { true } else { false } }
            for trigger in bindingMap.keys {
                if case .zoneTapHold = trigger, zones { triggers.set(trigger, true) }
            }
        }
    }

    /// 参与唤起与切换的面板：去掉停用的（D37）。全部停用时退回第一个，保证总有面板可开
    public var activePanels: [Layout] {
        let on = panels.filter(\.isEnabled)
        return on.isEmpty ? Array(panels.prefix(1)) : on
    }

    /// 默认面板：第一个启用的面板
    public var defaultPanel: Layout? { activePanels.first }

    /// 绑定表；写错的唤起方式忽略
    public var bindingMap: [PanelTrigger: String] {
        bindings.reduce(into: [:]) { map, b in
            if let t = PanelTrigger(key: b.trigger) { map[t] = b.panel }
        }
    }

    /// 把配置中的参数写入 `Tuning`，其余参数保留
    public func apply(to t: inout Tuning) {
        let list = triggers.list
        t.zoneTapHold = list.compactMap { if case .zoneTapHold(let z) = $0 { z } else { nil } }
        t.threeFingerTap = list.contains(.threeFingerTap)
        t.fourFingerTap = list.contains(.fourFingerTap)
        t.tapHold = list.contains(.tapHold)
        t.panelScale = min(max(sizes.panelScale, Tuning.panelScaleRange.lowerBound), Tuning.panelScaleRange.upperBound)
        t.mappingScale = min(max(sizes.mappingScale, Tuning.mappingScaleRange.lowerBound), Tuning.mappingScaleRange.upperBound)
        t.hitGapMM = min(max(sizes.hitGapMM, Tuning.hitGapRange.lowerBound), Tuning.hitGapRange.upperBound)
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
            guard let step = steps[version] else { throw ConfigError.invalid(String(localized: "缺少从版本 \(version) 迁移的步骤")) }
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
        let separator = String(localized: "、")
        return switch kind {
        case .noPanels: String(localized: "没有任何面板")
        case .duplicatePanel(let id): String(localized: "面板 ID 重复：\(id)")
        case .duplicateSlot(let id): String(localized: "按钮 ID 重复：\(id)")
        case .gridSize(let p): String(localized: "面板 \(p) 的网格行列数超出范围（1–\(AppConfig.maxRows) 行、1–\(AppConfig.maxCols) 列）")
        case .outsideGrid(let p, let s): String(localized: "面板 \(p) 的按钮 \(s) 越出网格")
        case .overlap(let p, let s): String(localized: "面板 \(p) 的按钮重叠：\(s.joined(separator: separator))")
        case .unknownBinding(let t): String(localized: "无法识别的唤起方式：\(t)")
        case .unknownPanel(let t, let p): String(localized: "唤起方式 \(t) 绑定的面板 \(p) 不存在")
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
        for key in triggers.enabled where PanelTrigger(key: key) == nil {
            issues.append(.init(kind: .unknownBinding(key)))
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
