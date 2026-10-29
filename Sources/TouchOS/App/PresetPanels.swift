import TouchOSCore

/// 面板布局；SwiftUI 也有 `Layout`，视图代码用这个名字避免歧义
typealias PanelLayout = Layout

/// 预置面板（D23）：网格 5 × 3，正中为关闭；"常用"为环形。首次启动写入配置，之后由用户在编辑器中修改。
/// 不放系统手势已能完成的功能（如调度中心）。
enum PresetPanels {
    static let cols = 5
    static let rows = 3

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
    static func close(_ panel: String, col: Int = 2, row: Int = 1) -> Slot {
        cell(panel, "close", col, row, "关闭", "xmark", .none)
    }

    static let browser = Layout(id: "browser", name: "浏览器", rows: rows, cols: cols, slots: [
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

    static let media = Layout(id: "media", name: "媒体", rows: rows, cols: cols, slots: [
        cell("media", "nowPlaying", 0, 0, w: 2, h: 2, "正在播放", "music.note", .system(.playPause), widget: .nowPlaying),
        cell("media", "previous", 2, 0, "上一首", "backward.fill", .system(.previousTrack)),
        cell("media", "playPause", 3, 0, "播放 / 暂停", "playpause.fill", .system(.playPause)),
        cell("media", "next", 4, 0, "下一首", "forward.fill", .system(.nextTrack)),
        close("media"),
        cell("media", "volume", 3, 1, w: 2, "音量", "speaker.wave.2", .none, slider: .volume),
        cell("media", "mute", 0, 2, "静音", "speaker.slash", .system(.mute)),
        cell("media", "brightness", 1, 2, w: 2, "亮度", "sun.max", .none, slider: .brightness),
        cell("media", "shot", 3, 2, "截图", "camera.viewfinder", .system(.screenshotArea)),
        cell("media", "lock", 4, 2, "锁屏", "lock", .system(.lockScreen)),
    ])

    static let window = Layout(id: "window", name: "窗口", rows: rows, cols: cols, slots: [
        cell("window", "left", 0, 0, "左半屏", "rectangle.lefthalf.filled", .system(.windowLeftHalf)),
        cell("window", "fill", 1, 0, "填满", "rectangle.inset.filled", .system(.windowFill)),
        cell("window", "center", 2, 0, "居中", "rectangle.center.inset.filled", .system(.windowCenter)),
        cell("window", "fullscreen", 3, 0, "全屏", "arrow.up.left.and.arrow.down.right", key(3, [.control, .command], "⌃⌘F")),
        cell("window", "right", 4, 0, "右半屏", "rectangle.righthalf.filled", .system(.windowRightHalf)),
        cell("window", "lastApp", 0, 1, w: 2, "上一个应用", "arrow.left.arrow.right", key(48, [.command], "⌘⇥")),
        close("window"),
        cell("window", "display", 3, 1, "下一个显示器", "display.2", .system(.windowNextDisplay)),
        cell("window", "minimize", 4, 1, "最小化", "minus.rectangle", key(46, [.command], "⌘M")),
        cell("window", "hide", 0, 2, "隐藏", "eye.slash", key(4, [.command], "⌘H")),
        cell("window", "finder", 1, 2, "访达", "folder", .openApp(bundleID: "com.apple.finder")),
        cell("window", "notes", 2, 2, "备忘录", "note.text", .openApp(bundleID: "com.apple.Notes")),
        cell("window", "terminal", 3, 2, "终端", "terminal", .openApp(bundleID: "com.apple.Terminal")),
        cell("window", "settings", 4, 2, "系统设置", "gearshape", .openApp(bundleID: "com.apple.systempreferences")),
    ])

    private static func ringItem(_ id: String, _ title: String, _ symbol: String, _ action: Action) -> Slot {
        Slot(id: SlotID("edit.\(id)"), shape: .rect(.zero), title: title, symbol: symbol, action: action)
    }

    static let editing = Layout.ring(id: "edit", name: "编辑", items: [
        ringItem("copy", "拷贝", "doc.on.doc", key(8, [.command], "⌘C")),
        ringItem("paste", "粘贴", "doc.on.clipboard", key(9, [.command], "⌘V")),
        ringItem("cut", "剪切", "scissors", key(7, [.command], "⌘X")),
        ringItem("redo", "重做", "arrow.uturn.forward", key(6, [.command, .shift], "⇧⌘Z")),
        ringItem("find", "查找", "magnifyingglass", key(3, [.command], "⌘F")),
        ringItem("save", "保存", "square.and.arrow.down", key(1, [.command], "⌘S")),
        ringItem("selectAll", "全选", "selection.pin.in.out", key(0, [.command], "⌘A")),
        ringItem("undo", "撤销", "arrow.uturn.backward", key(6, [.command], "⌘Z")),
    ], center: Slot(id: "edit.close", shape: .rect(.zero), title: "关闭", symbol: "xmark", action: .none))

    static let all = [browser, media, window, editing]
}
