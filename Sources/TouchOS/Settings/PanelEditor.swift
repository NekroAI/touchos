import SwiftUI
import TouchOSCore

/// 面板页（FR-11.3、FR-11.4）：左栏面板列表，中栏所见即所得编辑，右栏按钮属性
struct PanelsPage: View {
    let configs: ConfigController
    let executor: ActionExecutor
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        let panels = configs.config.panels
        let current = panels.first { $0.id == navigation.selectedPanel } ?? panels.first
        HSplitView {
            PanelList(configs: configs, navigation: navigation, current: current?.id)
                .frame(minWidth: 180, idealWidth: 200, maxWidth: 240)
            if let current {
                PanelCanvas(configs: configs, navigation: navigation, panel: current)
                    .frame(minWidth: 420, maxWidth: .infinity)
                SlotInspector(configs: configs, executor: executor, navigation: navigation, panel: current)
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
            }
        }
    }
}

/// 修改某个面板
@MainActor
func updatePanel(_ configs: ConfigController, _ id: String, _ change: (inout PanelLayout) -> Void) {
    configs.update { c in
        if let i = c.panels.firstIndex(where: { $0.id == id }) { change(&c.panels[i]) }
    }
}

// MARK: 面板列表

private struct PanelList: View {
    let configs: ConfigController
    @Bindable var navigation: SettingsNavigation
    let current: String?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { current }, set: { navigation.selectedPanel = $0; navigation.selectedSlot = nil })) {
                Section {
                    ForEach(Array(configs.config.panels.enumerated()), id: \.element.id) { i, panel in
                        HStack {
                            Image(systemName: panel.isRing ? "circle.circle" : "square.grid.3x2").foregroundStyle(.secondary)
                            Text(panel.name)
                            Spacer()
                            if i == 0 { Text("默认").font(.caption2).foregroundStyle(.secondary) }
                        }
                        .tag(Optional(panel.id))
                    }
                    .onMove { from, to in configs.update { $0.panels.move(fromOffsets: from, toOffset: to) } }
                } header: {
                    Text("面板（拖动排序，第一个为默认）")
                }
            }
            Divider()
            HStack(spacing: 4) {
                Menu {
                    Button("空白网格") { add(Self.blankGrid) }
                    Button("环形") { add(Self.blankRing) }
                    Divider()
                    ForEach(PresetPanels.all, id: \.id) { preset in
                        Button("模板：\(preset.name)") { add(preset) }
                    }
                } label: { Image(systemName: "plus") }
                .menuIndicator(.hidden)
                .fixedSize()
                Button { duplicate() } label: { Image(systemName: "plus.square.on.square") }
                    .help("复制面板")
                Button { remove() } label: { Image(systemName: "minus") }
                    .disabled(configs.config.panels.count <= 1)
                    .help("删除面板")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    static let blankGrid = PanelLayout(id: "panel", name: "新面板", rows: PresetPanels.rows, cols: PresetPanels.cols,
                                       slots: [PresetPanels.close("panel")])
    static let blankRing = PanelLayout.ring(id: "ring", name: "新环形面板", items: [],
                                            center: Slot(id: "ring.close", shape: .rect(.zero), title: "关闭", symbol: "xmark", action: .none))

    private func add(_ template: PanelLayout) {
        var c = configs.config
        var panel = c.duplicate(template)
        if template.id == "panel" || template.id == "ring" { panel.name = template.name }
        c.panels.append(panel)
        configs.replace(c)
        navigation.selectedPanel = panel.id
        navigation.selectedSlot = nil
    }

    private func duplicate() {
        guard let id = current, let panel = configs.config.panels.first(where: { $0.id == id }) else { return }
        add(panel)
    }

    private func remove() {
        guard let id = current else { return }
        configs.update { $0.removePanel(id) }
        navigation.selectedPanel = configs.config.panels.first?.id
        navigation.selectedSlot = nil
    }
}

// MARK: 中栏

/// 面板预览的宽高比：与触控板一致（妙控板约 1.4）
private let canvasAspect: CGFloat = 1.42

private struct PanelCanvas: View {
    let configs: ConfigController
    @Bindable var navigation: SettingsNavigation
    let panel: PanelLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField("面板名称", text: Binding(get: { panel.name }, set: { n in updatePanel(configs, panel.id) { $0.name = n } }))
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .frame(maxWidth: 260)
                Spacer()
                if !panel.isRing {
                    GridSizeStepper(title: "行", value: panel.rows, range: 1...AppConfig.maxRows) { resize(rows: $0, cols: panel.cols) }
                    GridSizeStepper(title: "列", value: panel.cols, range: 1...AppConfig.maxCols) { resize(rows: panel.rows, cols: $0) }
                }
            }
            if panel.isRing || panel.slots.allSatisfy({ if case .sector = $0.shape { true } else { false } }) && !panel.slots.isEmpty {
                RingEditor(configs: configs, navigation: navigation, panel: panel)
            } else {
                GridEditor(configs: configs, navigation: navigation, panel: panel)
                    .aspectRatio(canvasAspect, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                Text("点空格添加按钮；拖动按钮移动；拖右下角改大小。触控板上的位置与这里一一对应。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let note {
                Label(note, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    @State private var note: String?

    private func resize(rows: Int, cols: Int) {
        guard let resized = panel.resized(rows: rows, cols: cols) else {
            note = "有按钮会超出新的网格，先移动或删除它们"
            return
        }
        note = nil
        updatePanel(configs, panel.id) { $0 = resized }
    }
}

private struct GridSizeStepper: View {
    let title: String
    let value: Int
    let range: ClosedRange<Int>
    let set: (Int) -> Void

    var body: some View {
        Stepper("\(title) \(value)", onIncrement: value < range.upperBound ? { set(value + 1) } : nil,
                onDecrement: value > range.lowerBound ? { set(value - 1) } : nil).fixedSize()
    }
}

/// 网格编辑：所见即所得，按触控板宽高比显示（FR-11.4）
private struct GridEditor: View {
    let configs: ConfigController
    @Bindable var navigation: SettingsNavigation
    let panel: PanelLayout
    /// 正在拖动的按钮与位移（移动或改大小）
    @State private var drag: (id: SlotID, offset: CGSize, resize: Bool)?
    @State private var hoverCell: GridCell?

    var body: some View {
        GeometryReader { geo in
            let cw = geo.size.width / CGFloat(panel.cols), ch = geo.size.height / CGFloat(panel.rows)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.12))
                ForEach(0..<panel.rows, id: \.self) { r in
                    ForEach(0..<panel.cols, id: \.self) { c in
                        if panel.slot(atRow: r, col: c) == nil {
                            EmptyCell(hovered: hoverCell == GridCell(row: r, col: c))
                                .frame(width: cw, height: ch)
                                .offset(x: CGFloat(c) * cw, y: CGFloat(r) * ch)
                                .onHover { hoverCell = $0 ? GridCell(row: r, col: c) : nil }
                                .onTapGesture { addSlot(row: r, col: c) }
                        }
                    }
                }
                ForEach(panel.slots, id: \.id) { slot in
                    if case .cell(let cell) = slot.shape {
                        let frame = rect(cell, cw, ch)
                        let moving = drag?.id == slot.id
                        let proposal = moving ? proposed(cell, cw, ch) : nil
                        if let proposal {
                            // 松手后的落点
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(panel.canPlace(proposal, ignoring: slot.id) ? Color.accentColor : .red,
                                              style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                                .frame(width: rect(proposal, cw, ch).width - 8, height: rect(proposal, cw, ch).height - 8)
                                .position(x: rect(proposal, cw, ch).midX, y: rect(proposal, cw, ch).midY)
                        }
                        EditorChip(slot: slot, selected: navigation.selectedSlot == slot.id)
                            .frame(width: frame.width - 8 + (moving && drag!.resize ? drag!.offset.width : 0),
                                   height: frame.height - 8 + (moving && drag!.resize ? drag!.offset.height : 0))
                            .position(x: frame.midX + (moving && drag!.resize ? drag!.offset.width / 2 : 0),
                                      y: frame.midY + (moving && drag!.resize ? drag!.offset.height / 2 : 0))
                            .offset(moving && !drag!.resize ? drag!.offset : .zero)
                            .zIndex(moving ? 10 : 1)
                            .onTapGesture { navigation.selectedSlot = slot.id }
                            .gesture(DragGesture(minimumDistance: 3)
                                .onChanged { v in
                                    navigation.selectedSlot = slot.id
                                    drag = (slot.id, v.translation, false)
                                }
                                .onEnded { _ in commit(slot, cell, cw, ch) })
                            .overlay(alignment: .bottomTrailing) {
                                if navigation.selectedSlot == slot.id && !moving {
                                    ResizeHandle()
                                        .position(x: frame.width - 6, y: frame.height - 6)
                                        .frame(width: frame.width, height: frame.height)
                                        .gesture(DragGesture(minimumDistance: 1)
                                            .onChanged { v in drag = (slot.id, v.translation, true) }
                                            .onEnded { _ in commit(slot, cell, cw, ch) })
                                }
                            }
                    }
                }
            }
        }
    }

    private func rect(_ c: GridCell, _ cw: CGFloat, _ ch: CGFloat) -> CGRect {
        CGRect(x: CGFloat(c.col) * cw, y: CGFloat(c.row) * ch, width: CGFloat(c.colSpan) * cw, height: CGFloat(c.rowSpan) * ch)
    }

    /// 拖动中的落点：移动按格取整；改大小按格取整、至少一格
    private func proposed(_ cell: GridCell, _ cw: CGFloat, _ ch: CGFloat) -> GridCell? {
        guard let d = drag else { return nil }
        let dc = Int((d.offset.width / cw).rounded()), dr = Int((d.offset.height / ch).rounded())
        if d.resize {
            return GridCell(row: cell.row, col: cell.col, rowSpan: max(1, cell.rowSpan + dr), colSpan: max(1, cell.colSpan + dc))
        }
        return GridCell(row: cell.row + dr, col: cell.col + dc, rowSpan: cell.rowSpan, colSpan: cell.colSpan)
    }

    private func commit(_ slot: Slot, _ cell: GridCell, _ cw: CGFloat, _ ch: CGFloat) {
        defer { drag = nil }
        guard let target = proposed(cell, cw, ch), target != cell, panel.canPlace(target, ignoring: slot.id) else { return }
        updatePanel(configs, panel.id) { p in
            if let i = p.slots.firstIndex(where: { $0.id == slot.id }) { p.slots[i].shape = .cell(target) }
        }
    }

    private func addSlot(row: Int, col: Int) {
        let id = SlotID(AppConfig.uniqueID("\(panel.id).slot", existing: configs.config.allSlotIDs))
        let slot = Slot(id: id, shape: .cell(GridCell(row: row, col: col)), title: "新按钮", symbol: "star",
                        action: .keyboardShortcut(KeyCombo(keyCode: 0, modifiers: [.command], displayLabel: "⌘A")))
        updatePanel(configs, panel.id) { $0.slots.append(slot) }
        navigation.selectedSlot = id
    }
}

private struct EmptyCell: View {
    let hovered: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.white.opacity(hovered ? 0.35 : 0.1), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .overlay(Image(systemName: "plus").foregroundStyle(.white.opacity(hovered ? 0.7 : 0)))
            .padding(4)
            .contentShape(Rectangle())
    }
}

private struct ResizeHandle: View {
    var body: some View {
        Circle().fill(Color.accentColor).frame(width: 12, height: 12)
            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
            .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
    }
}

/// 编辑器里的按钮：不随主题变化，强调"是什么、在哪里"
struct EditorChip: View {
    let slot: Slot
    let selected: Bool

    var body: some View {
        let close = slot.isCancel
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(close ? Color.black.opacity(0.4) : Color.white.opacity(selected ? 0.16 : 0.08))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.white.opacity(0.15), lineWidth: selected ? 2 : 1))
            .overlay {
                VStack(spacing: 5) {
                    Image(systemName: slot.symbol).font(.system(size: 18)).frame(height: 20)
                    Text(slot.title).font(.caption).lineLimit(1)
                    if let detail { Text(detail).font(.caption2).foregroundStyle(.white.opacity(0.5)).lineLimit(1) }
                }
                .foregroundStyle(.white)
                .padding(4)
            }
            .contentShape(Rectangle())
    }

    private var detail: String? {
        if slot.widget != nil { return "正在播放" }
        if let s = slot.slider { return s == .volume ? "音量滑杆" : s == .brightness ? "亮度滑杆" : "滑杆" }
        if slot.isCancel { return "关闭 · 按住编辑" }
        return slot.action.shortLabel ?? slot.action.summary
    }
}

// MARK: 环形

/// 环形面板：外圈项目按顺时针排列，中心为关闭
private struct RingEditor: View {
    let configs: ConfigController
    @Bindable var navigation: SettingsNavigation
    let panel: PanelLayout

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            ZStack {
                Circle().fill(Color(white: 0.12))
                ForEach(Array(panel.ringItems.enumerated()), id: \.element.id) { i, slot in
                    let a = Double(i) / Double(max(panel.ringItems.count, 1)) * 2 * .pi
                    EditorChip(slot: slot, selected: navigation.selectedSlot == slot.id)
                        .frame(width: 70, height: 62)
                        .offset(x: sin(a) * 120, y: -cos(a) * 120)
                        .onTapGesture { navigation.selectedSlot = slot.id }
                }
                if let center = panel.ringCenter {
                    EditorChip(slot: center, selected: navigation.selectedSlot == center.id)
                        .frame(width: 64, height: 56)
                        .onTapGesture { navigation.selectedSlot = center.id }
                }
            }
            .frame(width: 330, height: 330)
            VStack(alignment: .leading) {
                Text("外圈项目（顺时针，从正上方开始）").font(.callout).foregroundStyle(.secondary)
                List(selection: $navigation.selectedSlot) {
                    ForEach(panel.ringItems, id: \.id) { slot in
                        Label(slot.title, systemImage: slot.symbol).tag(Optional(slot.id))
                    }
                    .onMove { from, to in
                        var items = panel.ringItems
                        items.move(fromOffsets: from, toOffset: to)
                        updatePanel(configs, panel.id) { $0 = $0.rebuiltRing(items: items) }
                    }
                }
                .frame(minHeight: 200)
                HStack {
                    Button("添加项目") { addItem() }.disabled(panel.ringItems.count >= Self.maxItems)
                    Spacer()
                }
            }
        }
    }

    static let maxItems = 12

    private func addItem() {
        let id = SlotID(AppConfig.uniqueID("\(panel.id).item", existing: configs.config.allSlotIDs))
        let item = Slot(id: id, shape: .rect(.zero), title: "新项目", symbol: "star",
                        action: .keyboardShortcut(KeyCombo(keyCode: 0, modifiers: [.command], displayLabel: "⌘A")))
        updatePanel(configs, panel.id) { $0 = $0.rebuiltRing(items: $0.ringItems + [item]) }
        navigation.selectedSlot = id
    }
}

extension Action {
    /// 编辑器里的一句话说明
    var summary: String {
        switch self {
        case .none: "关闭"
        case .keyboardShortcut(let k): k.displayLabel
        case .openApp(let id): NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.deletingPathExtension().lastPathComponent ?? id
        case .openURL(let url, _): url.host ?? url.absoluteString
        case .openFile(let path): (path as NSString).lastPathComponent
        case .shell: "Shell"
        case .appleScript: "脚本"
        case .shortcut(let name): name
        case .system(let c): c.title
        }
    }
}

extension SystemCommand {
    var title: String {
        switch self {
        case .volumeUp: "音量 +"
        case .volumeDown: "音量 −"
        case .mute: "静音"
        case .brightnessUp: "亮度 +"
        case .brightnessDown: "亮度 −"
        case .playPause: "播放 / 暂停"
        case .nextTrack: "下一首"
        case .previousTrack: "上一首"
        case .lockScreen: "锁屏"
        case .missionControl: "调度中心"
        case .showDesktop: "显示桌面"
        case .launchpad: "启动台"
        case .screenshotArea: "截取区域"
        case .screenshotWindow: "截取窗口"
        case .windowLeftHalf: "窗口：左半屏"
        case .windowRightHalf: "窗口：右半屏"
        case .windowFill: "窗口：填满"
        case .windowCenter: "窗口：居中"
        case .windowNextDisplay: "窗口：下一个显示器"
        }
    }
}
