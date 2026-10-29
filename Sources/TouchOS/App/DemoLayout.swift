import TouchOSCore

/// M0 演示布局（K7：固定 3×3 网格，动作写死为快捷键）。安全区在正中间；不放系统手势已能完成的功能（如调度中心）。
/// K8 起改为从配置与预置模板加载。
enum DemoLayout {
    private static func key(_ code: UInt16, _ mods: Set<Modifier>, _ label: String) -> Action {
        .keyboardShortcut(KeyCombo(keyCode: code, modifiers: mods, displayLabel: label))
    }

    static let layout = Layout(id: "demo", name: "演示", rows: 3, cols: 3, slots: [
        Slot(id: "new-tab", cell: GridCell(row: 0, col: 0), title: "新标签", symbol: "plus.square", action: key(17, [.command], "⌘T")),
        Slot(id: "close", cell: GridCell(row: 0, col: 1), title: "关闭", symbol: "xmark.square", action: key(13, [.command], "⌘W")),
        Slot(id: "reopen", cell: GridCell(row: 0, col: 2), title: "恢复标签", symbol: "arrow.uturn.backward.square",
             action: key(17, [.command, .shift], "⇧⌘T")),
        Slot(id: "prev-tab", cell: GridCell(row: 1, col: 0), title: "上一标签", symbol: "chevron.left.square",
             action: key(48, [.control, .shift], "⌃⇧⇥")),
        Slot(id: "null", cell: GridCell(row: 1, col: 1), title: "取消", symbol: "nosign", action: .none),
        Slot(id: "next-tab", cell: GridCell(row: 1, col: 2), title: "下一标签", symbol: "chevron.right.square",
             action: key(48, [.control], "⌃⇥")),
        Slot(id: "reload", cell: GridCell(row: 2, col: 0), title: "刷新", symbol: "arrow.clockwise.square", action: key(15, [.command], "⌘R")),
        Slot(id: "copy", cell: GridCell(row: 2, col: 1), title: "拷贝", symbol: "doc.on.doc", action: key(8, [.command], "⌘C")),
        Slot(id: "paste", cell: GridCell(row: 2, col: 2), title: "粘贴", symbol: "doc.on.clipboard", action: key(9, [.command], "⌘V")),
    ])
}
