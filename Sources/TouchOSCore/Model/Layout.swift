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
    /// 主显示器亮度
    case brightness
    /// 只显示数值，不控制任何东西
    case demo
}

/// 动态功能：内容随系统状态变化的槽位（D23，内容由外层提供）
public enum WidgetKind: String, Equatable, Sendable, CaseIterable {
    /// 正在播放：封面、曲名、进度；按压或抬起执行槽位的动作（通常是播放 / 暂停）
    case nowPlaying
}

public struct Slot: Equatable, Sendable {
    public var id: SlotID
    public var shape: SlotShape
    public var title: String
    /// SF Symbols 名称（应用图标、本地图片在 K12 加入）
    public var symbol: String
    /// 抬起或按压时执行（D18：按压执行并保留面板，抬起执行并关闭，不再区分连续触发槽位）
    public var action: Action
    /// 设置后为滑杆槽位：槽位内的位置直接对应数值，按压或抬起时确定（交互实验）
    public var slider: SliderTarget?
    public var widget: WidgetKind?

    public init(id: SlotID, shape: SlotShape, title: String, symbol: String, action: Action, slider: SliderTarget? = nil,
                widget: WidgetKind? = nil) {
        self.id = id
        self.shape = shape
        self.title = title
        self.symbol = symbol
        self.action = action
        self.slider = slider
        self.widget = widget
    }

    public init(id: SlotID, cell: GridCell, title: String, symbol: String, action: Action) {
        self.init(id: id, shape: .cell(cell), title: title, symbol: symbol, action: action)
    }
}

/// 面板布局的别名：SwiftUI 也有 `Layout`，视图代码用这个名字避免歧义
public typealias PanelLayout = Layout

/// 面板在屏幕上的水平位置（D41）：输入类面板放在一侧，避免挡住正在输入的地方
public enum PanelPlacement: String, Sendable, CaseIterable {
    case center, left, right
}

public struct Layout: Equatable, Sendable {
    public var id: String
    public var name: String
    /// 网格行列数，只用于换算 `.cell` 形状
    public var rows: Int
    public var cols: Int
    /// 数组顺序即 z 序（FR-6.9）
    public var slots: [Slot]
    /// 停用的面板保留配置，但不参与唤起与切换（D37）
    public var isEnabled: Bool
    public var placement: PanelPlacement

    public init(id: String, name: String, rows: Int = 1, cols: Int = 1, placement: PanelPlacement = .center, slots: [Slot],
                isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.rows = rows
        self.cols = cols
        self.slots = slots
        self.isEnabled = isEnabled
        self.placement = placement
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

    /// 环形排布（D23）：`items` 从正上方起顺时针均分一圈，内半径 `inner`（单位半径），向外延伸到面板边缘；
    /// `center` 放在环心
    public static func ring(id: String, name: String, items: [Slot], center: Slot?, inner: Double = 0.36) -> Layout {
        let step = 360 / Double(max(items.count, 1))
        var slots = items.enumerated().map { i, s in
            Slot(id: s.id, shape: .sector(Sector(innerRadius: inner, outerRadius: nil, startAngle: Double(i) * step - step / 2,
                                                 endAngle: Double(i) * step + step / 2)),
                 title: s.title, symbol: s.symbol, action: s.action, slider: s.slider, widget: s.widget)
        }
        if let c = center {
            slots.append(Slot(id: c.id, shape: .sector(Sector(innerRadius: 0, outerRadius: inner * 0.62, startAngle: 0, endAngle: 360)),
                              title: c.title, symbol: c.symbol, action: c.action))
        }
        return Layout(id: id, name: name, slots: slots)
    }

    /// 环形排布（全部为扇区）
    public var isRing: Bool {
        !slots.isEmpty && slots.allSatisfy { if case .sector = $0.shape { true } else { false } }
    }
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

public enum SystemCommand: String, Sendable, CaseIterable {
    case volumeUp, volumeDown, mute
    case brightnessUp, brightnessDown
    case playPause, nextTrack, previousTrack
    case lockScreen, missionControl, showDesktop, launchpad
    case screenshotArea, screenshotWindow
    /// 前台窗口：左半屏、右半屏、填满、居中、移到下一个显示器（D23）；上半屏、下半屏（D38 环形「窗口」面板）
    case windowLeftHalf, windowRightHalf, windowFill, windowCenter, windowNextDisplay
    case windowTopHalf, windowBottomHalf
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
    /// 输入一段文字（D30，SRS 预留的 M2 动作提前实现）：直接送字符，与键盘布局、输入法无关，任何符号都能输入
    case textSnippet(String)
    // M2 预留：macro([Action])、windowManagement(WindowCommand)、subPanel(LayoutID)

    /// 按住按钮时是否连续触发（D33）：输入文字、不带 ⌘ 的按键（删除、方向、回车、Tab）、音量与亮度步进。
    /// 带 ⌘ 的快捷键（⌘W、⌘Q 连发会连关窗口）、打开、脚本、锁屏、窗口摆放等只触发一次
    public var repeatsWhileHeld: Bool {
        switch self {
        case .textSnippet: true
        case .keyboardShortcut(let combo): !combo.modifiers.contains(.command)
        case .system(let command): [.volumeUp, .volumeDown, .brightnessUp, .brightnessDown].contains(command)
        default: false
        }
    }
}
