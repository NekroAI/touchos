import Foundation

// 面板布局与动作（SRS 9.1、第 10 章）。JSON 编解码在 K8 加入。

public struct SlotID: Hashable, Sendable, ExpressibleByStringLiteral {
    public let raw: String

    public init(_ raw: String) { self.raw = raw }
    public init(stringLiteral value: String) { self.raw = value }
}

/// 网格单元（FR-10.5）
public struct GridCell: Equatable, Sendable {
    public let row: Int
    public let col: Int
    public let rowSpan: Int
    public let colSpan: Int

    public init(row: Int, col: Int, rowSpan: Int = 1, colSpan: Int = 1) {
        self.row = row
        self.col = col
        self.rowSpan = rowSpan
        self.colSpan = colSpan
    }
}

public struct Slot: Equatable, Sendable {
    public let id: SlotID
    public let cell: GridCell
    public let title: String
    /// SF Symbols 名称（应用图标、本地图片在 K12 加入）
    public let symbol: String
    /// 连续触发（T12）
    public let repeats: Bool
    public let action: Action

    public init(id: SlotID, cell: GridCell, title: String, symbol: String, repeats: Bool = false, action: Action) {
        self.id = id
        self.cell = cell
        self.title = title
        self.symbol = symbol
        self.repeats = repeats
        self.action = action
    }
}

public struct Layout: Equatable, Sendable {
    public let id: String
    public let name: String
    public let rows: Int
    public let cols: Int
    /// 数组顺序即 z 序（FR-6.9）
    public let slots: [Slot]

    public init(id: String, name: String, rows: Int, cols: Int, slots: [Slot]) {
        self.id = id
        self.name = name
        self.rows = rows
        self.cols = cols
        self.slots = slots
    }

    /// 槽位的面板归一化矩形，原点左上（FR-10.5）
    public func normalizedRect(of slot: Slot) -> CGRect {
        CGRect(x: Double(slot.cell.col) / Double(cols), y: Double(slot.cell.row) / Double(rows),
               width: Double(slot.cell.colSpan) / Double(cols), height: Double(slot.cell.rowSpan) / Double(rows))
    }

    public func slot(_ id: SlotID) -> Slot? { slots.first { $0.id == id } }
}

public enum Modifier: String, Sendable, CaseIterable {
    case command, option, control, shift, function
}

public struct KeyCombo: Equatable, Sendable {
    /// 虚拟键码，与键盘布局无关
    public let keyCode: UInt16
    public let modifiers: Set<Modifier>
    /// 编辑器显示用，如 "⌘W"
    public let displayLabel: String

    public init(keyCode: UInt16, modifiers: Set<Modifier>, displayLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.displayLabel = displayLabel
    }
}

public enum ScriptLanguage: String, Sendable { case appleScript, javaScript }

public enum SystemCommand: String, Sendable {
    case volumeUp, volumeDown, mute
    case brightnessUp, brightnessDown
    case playPause, nextTrack, previousTrack
    case lockScreen, missionControl, showDesktop, launchpad
    case screenshotArea, screenshotWindow
}

public enum Action: Equatable, Sendable {
    case none                                   // 安全区
    case keyboardShortcut(KeyCombo)
    case openApp(bundleID: String)
    case openURL(url: URL, browserBundleID: String?)
    case openFile(path: String)
    case shell(command: String, timeoutSec: Double, notifyOutput: Bool)
    case appleScript(source: String, language: ScriptLanguage)
    case shortcut(name: String)                 // 系统"快捷指令"
    case system(SystemCommand)
    // M2 预留：macro([Action])、textSnippet(String)、windowManagement(WindowCommand)、subPanel(LayoutID)
}
