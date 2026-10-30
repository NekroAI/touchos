import CoreGraphics
import Foundation

// 布局与动作的 JSON 编码（SRS 10.2）。枚举一律带 "type" 判别字段，字段名与 SRS 示例一致；
// 未来新增的可选字段解码时缺省，旧版本写出的文件仍可读取。

extension SlotID: Codable {
    public init(from decoder: Decoder) throws { raw = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }
}

extension GridCell: Codable {
    private enum Keys: String, CodingKey { case row, col, rowSpan, colSpan }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(row: try c.decode(Int.self, forKey: .row), col: try c.decode(Int.self, forKey: .col),
                  rowSpan: try c.decodeIfPresent(Int.self, forKey: .rowSpan) ?? 1,
                  colSpan: try c.decodeIfPresent(Int.self, forKey: .colSpan) ?? 1)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(row, forKey: .row)
        try c.encode(col, forKey: .col)
        try c.encode(rowSpan, forKey: .rowSpan)
        try c.encode(colSpan, forKey: .colSpan)
    }
}

extension Sector: Codable {
    private enum Keys: String, CodingKey { case innerRadius, outerRadius, startAngle, endAngle }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(innerRadius: try c.decode(Double.self, forKey: .innerRadius),
                  outerRadius: try c.decodeIfPresent(Double.self, forKey: .outerRadius),
                  startAngle: try c.decode(Double.self, forKey: .startAngle), endAngle: try c.decode(Double.self, forKey: .endAngle))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(innerRadius, forKey: .innerRadius)
        try c.encodeIfPresent(outerRadius, forKey: .outerRadius)
        try c.encode(startAngle, forKey: .startAngle)
        try c.encode(endAngle, forKey: .endAngle)
    }
}

extension SliderTarget: Codable {}
extension WidgetKind: Codable {}
extension Modifier: Codable {}
extension ScriptLanguage: Codable {}
extension SystemCommand: Codable {}

extension Slot: Codable {
    private enum Keys: String, CodingKey { case id, cell, rect, sector, title, symbol, action, slider, widget }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let shape: SlotShape
        if let cell = try c.decodeIfPresent(GridCell.self, forKey: .cell) {
            shape = .cell(cell)
        } else if let r = try c.decodeIfPresent([Double].self, forKey: .rect), r.count == 4 {
            shape = .rect(CGRect(x: r[0], y: r[1], width: r[2], height: r[3]))
        } else if let sector = try c.decodeIfPresent(Sector.self, forKey: .sector) {
            shape = .sector(sector)
        } else {
            throw DecodingError.dataCorruptedError(forKey: .cell, in: c, debugDescription: "槽位缺少 cell / rect / sector")
        }
        self.init(id: try c.decode(SlotID.self, forKey: .id), shape: shape, title: try c.decode(String.self, forKey: .title),
                  symbol: try c.decodeIfPresent(String.self, forKey: .symbol) ?? "circle",
                  action: try c.decodeIfPresent(Action.self, forKey: .action) ?? .none,
                  slider: try c.decodeIfPresent(SliderTarget.self, forKey: .slider),
                  widget: try c.decodeIfPresent(WidgetKind.self, forKey: .widget))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        switch shape {
        case .cell(let cell): try c.encode(cell, forKey: .cell)
        case .rect(let r): try c.encode([r.minX, r.minY, r.width, r.height], forKey: .rect)
        case .sector(let s): try c.encode(s, forKey: .sector)
        }
        try c.encode(title, forKey: .title)
        try c.encode(symbol, forKey: .symbol)
        try c.encode(action, forKey: .action)
        try c.encodeIfPresent(slider, forKey: .slider)
        try c.encodeIfPresent(widget, forKey: .widget)
    }
}

extension Layout: Codable {
    private enum Keys: String, CodingKey { case id, name, grid, slots, disabled, placement }
    private enum GridKeys: String, CodingKey { case rows, cols }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        var rows = 1, cols = 1
        if c.contains(.grid) {
            let g = try c.nestedContainer(keyedBy: GridKeys.self, forKey: .grid)
            rows = try g.decode(Int.self, forKey: .rows)
            cols = try g.decode(Int.self, forKey: .cols)
        }
        self.init(id: try c.decode(String.self, forKey: .id), name: try c.decode(String.self, forKey: .name), rows: rows, cols: cols,
                  // 写错的位置按居中
                  placement: try c.decodeIfPresent(String.self, forKey: .placement).flatMap(PanelPlacement.init) ?? .center,
                  slots: try c.decode([Slot].self, forKey: .slots),
                  isEnabled: !(try c.decodeIfPresent(Bool.self, forKey: .disabled) ?? false))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        var g = c.nestedContainer(keyedBy: GridKeys.self, forKey: .grid)
        try g.encode(rows, forKey: .rows)
        try g.encode(cols, forKey: .cols)
        try c.encode(slots, forKey: .slots)
        if !isEnabled { try c.encode(true, forKey: .disabled) }  // 只在停用时写出，旧文件不变
        if placement != .center { try c.encode(placement.rawValue, forKey: .placement) }
    }
}

extension KeyCombo: Codable {
    private enum Keys: String, CodingKey { case keyCode, modifiers, displayLabel }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(keyCode: try c.decode(UInt16.self, forKey: .keyCode),
                  modifiers: Set(try c.decodeIfPresent([Modifier].self, forKey: .modifiers) ?? []),
                  displayLabel: try c.decodeIfPresent(String.self, forKey: .displayLabel) ?? "")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(keyCode, forKey: .keyCode)
        // 固定顺序，写出的文件稳定
        try c.encode(Modifier.allCases.filter(modifiers.contains), forKey: .modifiers)
        try c.encode(displayLabel, forKey: .displayLabel)
    }
}

extension Action: Codable {
    private enum Keys: String, CodingKey {
        case type, keyCode, modifiers, displayLabel, bundleID, url, browserBundleID, path, command, timeoutSec, notifyOutput
        case source, language, name, text
    }

    /// 编辑器与导入确认（FR-9.4、FR-9.5）用的类型名
    public var typeName: String {
        switch self {
        case .none: "none"
        case .keyboardShortcut: "keyboardShortcut"
        case .openApp: "openApp"
        case .openURL: "openURL"
        case .openFile: "openFile"
        case .shell: "shell"
        case .appleScript: "appleScript"
        case .shortcut: "shortcut"
        case .system: "system"
        case .textSnippet: "textSnippet"
        }
    }

    /// 以用户权限运行命令的动作（FR-9.4、FR-9.5）
    public var runsCode: Bool {
        switch self {
        case .shell, .appleScript: true
        default: false
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "none": self = .none
        case "keyboardShortcut": self = .keyboardShortcut(try KeyCombo(from: decoder))
        case "openApp": self = .openApp(bundleID: try c.decode(String.self, forKey: .bundleID))
        case "openURL":
            guard let url = URL(string: try c.decode(String.self, forKey: .url)) else {
                throw DecodingError.dataCorruptedError(forKey: .url, in: c, debugDescription: "链接不合法")
            }
            self = .openURL(url: url, browserBundleID: try c.decodeIfPresent(String.self, forKey: .browserBundleID))
        case "openFile": self = .openFile(path: try c.decode(String.self, forKey: .path))
        case "shell":
            self = .shell(command: try c.decode(String.self, forKey: .command),
                          timeoutSec: try c.decodeIfPresent(Double.self, forKey: .timeoutSec) ?? 10,
                          notifyOutput: try c.decodeIfPresent(Bool.self, forKey: .notifyOutput) ?? false)
        case "appleScript":
            self = .appleScript(source: try c.decode(String.self, forKey: .source),
                                language: try c.decodeIfPresent(ScriptLanguage.self, forKey: .language) ?? .appleScript)
        case "shortcut": self = .shortcut(name: try c.decode(String.self, forKey: .name))
        case "system": self = .system(try c.decode(SystemCommand.self, forKey: .command))
        case "textSnippet": self = .textSnippet(try c.decode(String.self, forKey: .text))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "未知动作类型 \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(typeName, forKey: .type)
        switch self {
        case .none: break
        case .keyboardShortcut(let k): try k.encode(to: encoder)
        case .openApp(let id): try c.encode(id, forKey: .bundleID)
        case .openURL(let url, let browser):
            try c.encode(url.absoluteString, forKey: .url)
            try c.encodeIfPresent(browser, forKey: .browserBundleID)
        case .openFile(let path): try c.encode(path, forKey: .path)
        case .shell(let command, let timeout, let notify):
            try c.encode(command, forKey: .command)
            try c.encode(timeout, forKey: .timeoutSec)
            try c.encode(notify, forKey: .notifyOutput)
        case .appleScript(let source, let language):
            try c.encode(source, forKey: .source)
            try c.encode(language, forKey: .language)
        case .shortcut(let name): try c.encode(name, forKey: .name)
        case .system(let command): try c.encode(command, forKey: .command)
        case .textSnippet(let text): try c.encode(text, forKey: .text)
        }
    }
}

extension PanelTrigger {
    /// 全部唤起方式，设置页与配置文件按这个顺序排列
    public static let all: [PanelTrigger] = [.tapHold, .fourFingerTap, .threeFingerTap] + zones.map(PanelTrigger.zoneTapHold)

    /// 方位分区按触控板上从左上到右下的顺序
    public static let zones: [TriggerZone] = [.topLeft, .top, .topRight, .left, .right, .bottomLeft, .bottom, .bottomRight]

    /// 配置文件中的写法：`tapHold`、`tapHold.topLeft`、`threeFingerTap`、`fourFingerTap`
    public var key: String {
        switch self {
        case .tapHold: "tapHold"
        case .zoneTapHold(let z): "tapHold.\(z.rawValue)"
        case .threeFingerTap: "threeFingerTap"
        case .fourFingerTap: "fourFingerTap"
        }
    }

    public init?(key: String) {
        let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
        switch (parts.first, parts.count == 2 ? TriggerZone(rawValue: parts[1]) : nil) {
        case ("tapHold", let z?): self = .zoneTapHold(z)
        case ("tapHold", nil) where parts.count == 1: self = .tapHold
        case ("threeFingerTap", nil) where parts.count == 1: self = .threeFingerTap
        case ("fourFingerTap", nil) where parts.count == 1: self = .fourFingerTap
        default: return nil
        }
    }

    /// 旧写法换成现在的（D38）：一指按住角落（`hold.*`）已去掉，返回 nil；角落轻点两下（`doubleTap.*`）
    /// 换成同一方位的轻点后按住，原来的左右边缘对应左右两边的中段。其余原样返回，不认识的也保留
    public static func migrated(key: String) -> String? {
        let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
        switch parts.first {
        case "hold" where parts.count == 2:
            return nil
        case "doubleTap" where parts.count == 2:
            let zone = ["leftEdge": "left", "rightEdge": "right"][parts[1]] ?? parts[1]
            return TriggerZone(rawValue: zone).map { PanelTrigger.zoneTapHold($0).key }
        default:
            return key
        }
    }
}
