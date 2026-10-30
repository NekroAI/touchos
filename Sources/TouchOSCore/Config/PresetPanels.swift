import Foundation

/// 预置面板（D23、D29）：网格 5 × 3，正中为关闭；"编辑"为环形。首次启动写入配置，之后由用户在编辑器中修改。
/// 不放系统手势已能完成的功能（如调度中心）。
public enum PresetPanels {
    public static let cols = 5
    public static let rows = 3

    private static func key(_ code: UInt16, _ mods: Set<Modifier>, _ label: String) -> Action {
        .keyboardShortcut(KeyCombo(keyCode: code, modifiers: mods, displayLabel: label))
    }

    private static func cell(_ panel: String, _ id: String, _ col: Int, _ row: Int, w: Int = 1, h: Int = 1,
                             _ title: String, _ symbol: String, _ action: Action,
                             slider: SliderTarget? = nil, widget: WidgetKind? = nil) -> Slot {
        Slot(id: SlotID("\(panel).\(id)"), shape: .cell(GridCell(row: row, col: col, rowSpan: h, colSpan: w)),
             title: title, symbol: symbol, action: action, slider: slider, widget: widget)
    }

    /// 正中的关闭：抬起关闭，按住进入编辑
    public static func close(_ panel: String, col: Int = 2, row: Int = 1) -> Slot {
        cell(panel, "close", col, row, "关闭", "xmark", .none)
    }

    /// 默认面板（D29、D41）：各应用通用的高频操作，不铺满。关闭正下方留空，手指下滑不会误触；退出放在角上。
    /// 按钮上显示按键组合（刷新 ⌘R 在不同应用里含义不同，看得见实际按下的键）
    public static let common = Layout(id: "common", name: "常用", rows: rows, cols: cols, slots: [
        cell("common", "quit", 0, 0, "退出", "rectangle.portrait.and.arrow.right", key(12, [.command], "⌘Q")),
        cell("common", "closeWindow", 1, 0, "关闭窗口", "xmark.square", key(13, [.command], "⌘W")),
        cell("common", "reload", 2, 0, "刷新", "arrow.clockwise", key(15, [.command], "⌘R")),
        cell("common", "settings", 3, 0, "设置", "gearshape", key(43, [.command], "⌘,")),
        cell("common", "volume", 4, 0, h: 3, "音量", "speaker.wave.2", .none, slider: .volume),
        cell("common", "selectAll", 0, 1, "全选", "selection.pin.in.out", key(0, [.command], "⌘A")),
        cell("common", "copy", 1, 1, "拷贝", "doc.on.doc", key(8, [.command], "⌘C")),
        close("common"),
        cell("common", "paste", 3, 1, "粘贴", "doc.on.clipboard", key(9, [.command], "⌘V")),
        cell("common", "lock", 0, 2, "锁屏", "lock", .system(.lockScreen)),
        cell("common", "shot", 1, 2, "截图", "camera.viewfinder", .system(.screenshotArea)),
        cell("common", "return", 3, 2, "回车", "return", key(36, [], "↩")),
    ])

    /// 输入一个字符的按钮：没有图标，按钮中间直接画这个字符（D30）
    private static func char(_ panel: String, _ id: String, _ col: Int, _ row: Int, _ text: String) -> Slot {
        cell(panel, id, col, row, text, "", .textSnippet(text))
    }

    /// 数字键盘（D30）：4 × 4，没有小键盘时临时输入一串数字。按压连续输入，抬起关闭；关闭在左下角。
    /// 放在屏幕右侧，像键盘右边的小键盘，不挡住左侧正在输入的地方（D41）
    public static let numpad = Layout(id: "numpad", name: "数字", rows: 4, cols: 4, placement: .right, slots:
        [("7", 0, 0), ("8", 1, 0), ("9", 2, 0), ("4", 0, 1), ("5", 1, 1), ("6", 2, 1), (",", 3, 1),
         ("1", 0, 2), ("2", 1, 2), ("3", 2, 2), ("0", 1, 3), (".", 2, 3)]
            .map { t, col, row in char("numpad", t == "," ? "comma" : t == "." ? "point" : "d\(t)", col, row, t) }
        + [
            cell("numpad", "delete", 3, 0, "删除", "delete.left", key(51, [], "⌫")),
            cell("numpad", "return", 3, 2, "回车", "return", key(36, [], "↩")),
            close("numpad", col: 0, row: 3),
            cell("numpad", "tab", 3, 3, "Tab", "arrow.right.to.line", key(48, [], "⇥")),
        ])

    /// 符号（D30）：键盘上不好打的常用符号，内容按需修改
    public static let symbols = Layout(id: "symbols", name: "符号", rows: rows, cols: cols, slots: [
        char("symbols", "times", 0, 0, "×"), char("symbols", "divide", 1, 0, "÷"), char("symbols", "plusMinus", 2, 0, "±"),
        char("symbols", "approx", 3, 0, "≈"), char("symbols", "notEqual", 4, 0, "≠"),
        char("symbols", "lessEqual", 0, 1, "≤"), char("symbols", "greaterEqual", 1, 1, "≥"), close("symbols"),
        char("symbols", "degree", 3, 1, "°"), char("symbols", "ellipsis", 4, 1, "……"),
        char("symbols", "right", 0, 2, "→"), char("symbols", "left", 1, 2, "←"), char("symbols", "check", 2, 2, "✓"),
        char("symbols", "dash", 3, 2, "——"), char("symbols", "dot", 4, 2, "·"),
    ])

    public static let browser = Layout(id: "browser", name: "浏览器", rows: rows, cols: cols, slots: [
        cell("browser", "new", 0, 0, "新标签", "plus.square", key(17, [.command], "⌘T")),
        cell("browser", "closeTab", 1, 0, "关闭标签", "xmark.square", key(13, [.command], "⌘W")),
        cell("browser", "reopen", 2, 0, "恢复标签", "arrow.uturn.backward", key(17, [.command, .shift], "⇧⌘T")),
        cell("browser", "reload", 3, 0, "刷新", "arrow.clockwise", key(15, [.command], "⌘R")),
        cell("browser", "address", 4, 0, "地址栏", "magnifyingglass", key(37, [.command], "⌘L")),
        cell("browser", "back", 0, 1, "后退", "chevron.backward", key(33, [.command], "⌘[")),
        cell("browser", "prevTab", 1, 1, "上一标签", "arrow.left.square", key(48, [.control, .shift], "⌃⇧⇥")),
        close("browser"),
        cell("browser", "nextTab", 3, 1, "下一标签", "arrow.right.square", key(48, [.control], "⌃⇥")),
        cell("browser", "forward", 4, 1, "前进", "chevron.forward", key(30, [.command], "⌘]")),
        cell("browser", "volume", 0, 2, w: 2, "音量", "speaker.wave.2", .none, slider: .volume),
        cell("browser", "copy", 2, 2, "拷贝", "doc.on.doc", key(8, [.command], "⌘C")),
        cell("browser", "paste", 3, 2, "粘贴", "doc.on.clipboard", key(9, [.command], "⌘V")),
        cell("browser", "shot", 4, 2, "截图", "camera.viewfinder", .system(.screenshotArea)),
    ])

    /// 媒体（D41）：正在播放卡片本身就是播放 / 暂停，不再另设按钮；锁屏、截图在「常用」里
    public static let media = Layout(id: "media", name: "媒体", rows: rows, cols: cols, slots: [
        cell("media", "nowPlaying", 0, 0, w: 2, h: 2, "正在播放", "music.note", .system(.playPause), widget: .nowPlaying),
        cell("media", "previous", 3, 0, "上一首", "backward.fill", .system(.previousTrack)),
        cell("media", "next", 4, 0, "下一首", "forward.fill", .system(.nextTrack)),
        close("media"),
        cell("media", "volume", 3, 1, w: 2, "音量", "speaker.wave.2", .none, slider: .volume),
        cell("media", "mute", 0, 2, "静音", "speaker.slash", .system(.mute)),
        cell("media", "brightness", 1, 2, w: 2, "亮度", "sun.max", .none, slider: .brightness),
    ])

    private static func ringItem(_ panel: String, _ id: String, _ title: String, _ symbol: String, _ action: Action) -> Slot {
        Slot(id: SlotID("\(panel).\(id)"), shape: .rect(.zero), title: title, symbol: symbol, action: action)
    }

    /// 环形「窗口」（D38）：方向即结果，上下左右四个半屏；四个斜角是居中、全屏、最小化、关闭窗口。
    /// 从正上方起顺时针排列
    public static let window = Layout.ring(id: "window", name: "窗口", items: [
        ringItem("window", "top", "上半屏", "rectangle.tophalf.filled", .system(.windowTopHalf)),
        ringItem("window", "fullscreen", "全屏", "arrow.up.left.and.arrow.down.right", key(3, [.control, .command], "⌃⌘F")),
        ringItem("window", "right", "右半屏", "rectangle.righthalf.filled", .system(.windowRightHalf)),
        ringItem("window", "closeWindow", "关闭窗口", "xmark.rectangle", key(13, [.command], "⌘W")),
        ringItem("window", "bottom", "下半屏", "rectangle.bottomhalf.filled", .system(.windowBottomHalf)),
        ringItem("window", "minimize", "最小化", "minus.rectangle", key(46, [.command], "⌘M")),
        ringItem("window", "left", "左半屏", "rectangle.lefthalf.filled", .system(.windowLeftHalf)),
        ringItem("window", "center", "居中", "rectangle.center.inset.filled", .system(.windowCenter)),
    ], center: Slot(id: "window.close", shape: .rect(.zero), title: "关闭", symbol: "xmark", action: .none))

    /// 首次启动写入的面板，第一个为默认面板；双指切换按这个顺序，常用的挨着默认面板（D38、D41）
    public static let all = [common, window, media, numpad]
    /// 新建面板可选的模板：默认面板之外还有符号、浏览器
    public static let templates = all + [symbols, browser]

    /// 面板来自哪个预置面板：ID 相同，或是它的副本（`browser-2`、`browser-2-3`）
    public static func origin(of id: String) -> Layout? {
        templates.first { preset in
            id == preset.id || (id.hasPrefix(preset.id + "-")
                && id.dropFirst(preset.id.count + 1).split(separator: "-").allSatisfy { Int($0) != nil })
        }
    }
}
