import CoreGraphics
import TouchOSCore

/// 调试专用的交互实验布局（调试菜单"实验布局"开启后生效）：
/// 左下角两页（混排矩形、环形窗口管理），右下角两页（滑杆、双环）。
/// 按压执行并保留、抬起执行并关闭（D18），任何槽位都可以按压连续触发。
/// 只用快捷键动作；其他动作类型在 K9 实现。
enum ExperimentLayouts {
    static let panels: [AnchorCorner: [Layout]] = [
        .bottomLeft: [mixed, radialWindows],
        .bottomRight: [sliders, doubleRing],
    ]

    private static func key(_ code: UInt16, _ mods: Set<Modifier>, _ label: String) -> Action {
        .keyboardShortcut(KeyCombo(keyCode: code, modifiers: mods, displayLabel: label))
    }

    private static func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> SlotShape {
        .rect(CGRect(x: x, y: y, width: w, height: h))
    }

    /// 以 `center` 度为中心、宽 `width` 度的扇区
    private static func sector(_ center: Double, width: Double, inner: Double, outer: Double?) -> SlotShape {
        .sector(Sector(innerRadius: inner, outerRadius: outer, startAngle: center - width / 2, endAngle: center + width / 2))
    }

    private static func cancelDisc(_ radius: Double) -> Slot {
        Slot(id: "cancel", shape: .sector(Sector(innerRadius: 0, outerRadius: radius, startAngle: 0, endAngle: 360)),
             title: "取消", symbol: "xmark.circle", action: .none)
    }

    /// 实验 1：大小混排的矩形 + 横向音量滑杆
    static let mixed = Layout(id: "exp-mixed", name: "实验 · 混排", slots: [
        Slot(id: "new-tab", shape: rect(0, 0, 0.25, 0.34), title: "新标签", symbol: "plus.square.on.square",
             action: key(17, [.command], "⌘T")),
        Slot(id: "close", shape: rect(0.25, 0, 0.25, 0.34), title: "关闭标签", symbol: "xmark.square",
             action: key(13, [.command], "⌘W")),
        Slot(id: "reopen", shape: rect(0.5, 0, 0.25, 0.34), title: "恢复标签", symbol: "arrow.uturn.backward.square",
             action: key(17, [.command, .shift], "⇧⌘T")),
        Slot(id: "reload", shape: rect(0.75, 0, 0.25, 0.34), title: "刷新", symbol: "arrow.clockwise",
             action: key(15, [.command], "⌘R")),
        Slot(id: "prev-tab", shape: rect(0, 0.34, 0.25, 0.32), title: "上一标签", symbol: "chevron.left.square", action: key(48, [.control, .shift], "⌃⇧⇥")),
        Slot(id: "cancel", shape: rect(0.25, 0.34, 0.5, 0.32), title: "取消", symbol: "xmark.circle", action: .none),
        Slot(id: "next-tab", shape: rect(0.75, 0.34, 0.25, 0.32), title: "下一标签", symbol: "chevron.right.square", action: key(48, [.control], "⌃⇥")),
        Slot(id: "volume", shape: rect(0, 0.66, 0.5, 0.34), title: "音量", symbol: "speaker.wave.2", action: .none,
             slider: .volume),
        Slot(id: "copy", shape: rect(0.5, 0.66, 0.25, 0.34), title: "拷贝", symbol: "doc.on.doc",
             action: key(8, [.command], "⌘C")),
        Slot(id: "paste", shape: rect(0.75, 0.66, 0.25, 0.34), title: "粘贴", symbol: "doc.on.clipboard",
             action: key(9, [.command], "⌘V")),
    ])

    /// 实验 2：8 扇区环形，窗口平铺（macOS 15 起的 fn⌃ 快捷键），中心取消
    static let radialWindows = Layout(id: "exp-radial", name: "实验 · 环形窗口", slots: [
        Slot(id: "top", shape: sector(0, width: 45, inner: 0.3, outer: nil), title: "上半屏", symbol: "rectangle.tophalf.filled",
             action: key(126, [.function, .control], "fn⌃↑")),
        Slot(id: "fill", shape: sector(45, width: 45, inner: 0.3, outer: nil), title: "填充", symbol: "rectangle.fill",
             action: key(3, [.function, .control], "fn⌃F")),
        Slot(id: "right", shape: sector(90, width: 45, inner: 0.3, outer: nil), title: "右半屏", symbol: "rectangle.righthalf.filled",
             action: key(124, [.function, .control], "fn⌃→")),
        Slot(id: "center", shape: sector(135, width: 45, inner: 0.3, outer: nil), title: "居中", symbol: "rectangle.center.inset.filled",
             action: key(8, [.function, .control], "fn⌃C")),
        Slot(id: "bottom", shape: sector(180, width: 45, inner: 0.3, outer: nil), title: "下半屏", symbol: "rectangle.bottomhalf.filled",
             action: key(125, [.function, .control], "fn⌃↓")),
        Slot(id: "minimize", shape: sector(225, width: 45, inner: 0.3, outer: nil), title: "最小化", symbol: "minus.rectangle",
             action: key(46, [.command], "⌘M")),
        Slot(id: "left", shape: sector(270, width: 45, inner: 0.3, outer: nil), title: "左半屏", symbol: "rectangle.lefthalf.filled",
             action: key(123, [.function, .control], "fn⌃←")),
        Slot(id: "cycle", shape: sector(315, width: 45, inner: 0.3, outer: nil), title: "切换窗口", symbol: "macwindow.on.rectangle", action: key(50, [.command], "⌘`")),
        cancelDisc(0.3),
    ])

    /// 实验 3：竖向音量滑杆 + 横向演示滑杆 + 撤销 / 重做
    static let sliders = Layout(id: "exp-sliders", name: "实验 · 滑杆", slots: [
        Slot(id: "volume", shape: rect(0, 0, 0.28, 1), title: "音量", symbol: "speaker.wave.2", action: .none, slider: .volume),
        Slot(id: "demo", shape: rect(0.28, 0, 0.72, 0.32), title: "演示滑杆", symbol: "slider.horizontal.3", action: .none,
             slider: .demo),
        Slot(id: "cancel", shape: rect(0.28, 0.32, 0.36, 0.68), title: "取消", symbol: "xmark.circle", action: .none),
        Slot(id: "undo", shape: rect(0.64, 0.32, 0.36, 0.34), title: "撤销", symbol: "arrow.uturn.backward", action: key(6, [.command], "⌘Z")),
        Slot(id: "redo", shape: rect(0.64, 0.66, 0.36, 0.34), title: "重做", symbol: "arrow.uturn.forward", action: key(6, [.command, .shift], "⇧⌘Z")),
    ])

    /// 实验 4：双环。内环 4 个编辑动作，外环 8 个标签与页面动作，验证两圈是否分得清
    static let doubleRing = Layout(id: "exp-ring2", name: "实验 · 双环", slots: [
        Slot(id: "copy", shape: sector(0, width: 90, inner: 0.24, outer: 0.58), title: "拷贝", symbol: "doc.on.doc",
             action: key(8, [.command], "⌘C")),
        Slot(id: "paste", shape: sector(90, width: 90, inner: 0.24, outer: 0.58), title: "粘贴", symbol: "doc.on.clipboard",
             action: key(9, [.command], "⌘V")),
        Slot(id: "undo", shape: sector(180, width: 90, inner: 0.24, outer: 0.58), title: "撤销", symbol: "arrow.uturn.backward",
             action: key(6, [.command], "⌘Z")),
        Slot(id: "cut", shape: sector(270, width: 90, inner: 0.24, outer: 0.58), title: "剪切", symbol: "scissors",
             action: key(7, [.command], "⌘X")),
        Slot(id: "new-tab", shape: sector(0, width: 45, inner: 0.58, outer: nil), title: "新标签", symbol: "plus.square",
             action: key(17, [.command], "⌘T")),
        Slot(id: "next-tab", shape: sector(45, width: 45, inner: 0.58, outer: nil), title: "下一标签", symbol: "chevron.right.square",
             action: key(48, [.control], "⌃⇥")),
        Slot(id: "find", shape: sector(90, width: 45, inner: 0.58, outer: nil), title: "查找", symbol: "magnifyingglass",
             action: key(3, [.command], "⌘F")),
        Slot(id: "reload", shape: sector(135, width: 45, inner: 0.58, outer: nil), title: "刷新", symbol: "arrow.clockwise",
             action: key(15, [.command], "⌘R")),
        Slot(id: "close", shape: sector(180, width: 45, inner: 0.58, outer: nil), title: "关闭标签", symbol: "xmark.square",
             action: key(13, [.command], "⌘W")),
        Slot(id: "reopen", shape: sector(225, width: 45, inner: 0.58, outer: nil), title: "恢复标签", symbol: "arrow.uturn.backward.square",
             action: key(17, [.command, .shift], "⇧⌘T")),
        Slot(id: "prev-tab", shape: sector(270, width: 45, inner: 0.58, outer: nil), title: "上一标签", symbol: "chevron.left.square",
             action: key(48, [.control, .shift], "⌃⇧⇥")),
        Slot(id: "address", shape: sector(315, width: 45, inner: 0.58, outer: nil), title: "地址栏", symbol: "link",
             action: key(37, [.command], "⌘L")),
        cancelDisc(0.24),
    ])
}
