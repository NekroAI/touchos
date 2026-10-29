import CoreGraphics
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

/// 扇区（环形布局）。半径以面板短边的一半为单位，角度以度为单位、0 为正上方、顺时针增加。
/// 面板宽高比等于触控板物理宽高比，因此扇区在触控板上也是正圆（decisions.md D12）。
public struct Sector: Equatable, Sendable {
    public let innerRadius: Double
    /// nil 表示向外延伸到面板边缘，命中时只看角度（与 D9 的边缘延伸一致）
    public let outerRadius: Double?
    public let startAngle: Double
    public let endAngle: Double

    public init(innerRadius: Double, outerRadius: Double?, startAngle: Double, endAngle: Double) {
        self.innerRadius = innerRadius
        self.outerRadius = outerRadius
        self.startAngle = startAngle
        self.endAngle = endAngle
    }

    public var isFullCircle: Bool { endAngle - startAngle >= 360 }
}

/// 槽位形状（decisions.md D12）：网格只是生成矩形的一种方式
public enum SlotShape: Equatable, Sendable {
    /// 网格单元，按布局的行列数换算（FR-10.5）
    case cell(GridCell)
    /// 面板归一化矩形，原点左上
    case rect(CGRect)
    case sector(Sector)
}

/// 滑杆槽位控制的连续量（交互实验）
public enum SliderTarget: String, Equatable, Sendable {
    /// 系统输出音量
    case volume
    /// 只显示数值，不控制任何东西
    case demo
}

public struct Slot: Equatable, Sendable {
    public let id: SlotID
    public let shape: SlotShape
    public let title: String
    /// SF Symbols 名称（应用图标、本地图片在 K12 加入）
    public let symbol: String
    /// 抬起或按压时执行（D18：按压执行并保留面板，抬起执行并关闭，不再区分连续触发槽位）
    public let action: Action
    /// 设置后为滑杆槽位：槽位内的位置直接对应数值，按压或抬起时确定（交互实验）
    public let slider: SliderTarget?

    public init(id: SlotID, shape: SlotShape, title: String, symbol: String, action: Action, slider: SliderTarget? = nil) {
        self.id = id
        self.shape = shape
        self.title = title
        self.symbol = symbol
        self.action = action
        self.slider = slider
    }

    public init(id: SlotID, cell: GridCell, title: String, symbol: String, action: Action) {
        self.init(id: id, shape: .cell(cell), title: title, symbol: symbol, action: action)
    }
}

public struct Layout: Equatable, Sendable {
    public let id: String
    public let name: String
    /// 网格行列数，只用于换算 `.cell` 形状
    public let rows: Int
    public let cols: Int
    /// 数组顺序即 z 序（FR-6.9）
    public let slots: [Slot]

    public init(id: String, name: String, rows: Int = 1, cols: Int = 1, slots: [Slot]) {
        self.id = id
        self.name = name
        self.rows = rows
        self.cols = cols
        self.slots = slots
    }

    /// 矩形类槽位的面板归一化矩形，原点左上（FR-10.5）；扇区为 nil
    public func normalizedRect(of slot: Slot) -> CGRect? {
        switch slot.shape {
        case .cell(let c):
            CGRect(x: Double(c.col) / Double(cols), y: Double(c.row) / Double(rows),
                   width: Double(c.colSpan) / Double(cols), height: Double(c.rowSpan) / Double(rows))
        case .rect(let r): r
        case .sector: nil
        }
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
