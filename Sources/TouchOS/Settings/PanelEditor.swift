import AppKit
import ImageIO
import SwiftUI
import TouchOSCore

/// 面板编辑（FR-11.3、FR-11.4）：舞台上用浮层同一套渲染画出面板（跟随当前主题与强调色，所见即所得），
/// 直接在上面添加、移动、调整大小；选中按钮时右侧滑出按钮属性
struct PanelEditorPage: View {
    let configs: ConfigController
    let executor: ActionExecutor
    @Bindable var navigation: SettingsNavigation
    let panel: PanelLayout

    var body: some View {
        let selected = navigation.selectedSlot.flatMap { panel.slot($0) } != nil
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                PanelHeader(configs: configs, navigation: navigation, panel: panel)
                PanelStage(configs: configs, navigation: navigation, panel: panel)
                    .padding([.horizontal, .bottom], 20)
            }
            .frame(minWidth: 480, maxWidth: .infinity)
            if selected {
                Divider()
                SlotInspector(configs: configs, executor: executor, navigation: navigation, panel: panel)
                    .frame(width: 320)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: selected)
        .onExitCommand { navigation.selectedSlot = nil }
    }
}

/// 修改某个面板
@MainActor
func updatePanel(_ configs: ConfigController, _ id: String, _ change: (inout PanelLayout) -> Void) {
    configs.update { c in
        if let i = c.panels.firstIndex(where: { $0.id == id }) { change(&c.panels[i]) }
    }
}

// MARK: 面板操作（侧栏与标题栏共用）

@MainActor
enum PanelCommands {
    static let blankGrid = PanelLayout(id: "panel", name: String(localized: "新面板"), rows: PresetPanels.rows, cols: PresetPanels.cols,
                                       slots: [PresetPanels.close("panel")])
    static let blankRing = PanelLayout.ring(id: "ring", name: String(localized: "新环形面板"), items: [],
                                            center: Slot(id: "ring.close", shape: .rect(.zero), title: String(localized: "关闭"), symbol: "xmark", action: .none))

    static func add(_ template: PanelLayout, configs: ConfigController, navigation: SettingsNavigation) {
        var c = configs.config
        var panel = c.duplicate(template)
        if template.id == blankGrid.id || template.id == blankRing.id { panel.name = template.name }
        c.panels.append(panel)
        configs.replace(c)
        navigation.open(panel: panel.id)
    }

    static func makeDefault(_ id: String, configs: ConfigController) {
        configs.update { c in
            guard let i = c.panels.firstIndex(where: { $0.id == id }) else { return }
            c.panels.insert(c.panels.remove(at: i), at: 0)
        }
    }

    /// 停用 / 启用（D37）：停用的面板保留配置，不参与唤起与切换；至少保留一个启用的面板
    static func setEnabled(_ id: String, _ on: Bool, configs: ConfigController) {
        configs.update { c in
            guard let i = c.panels.firstIndex(where: { $0.id == id }) else { return }
            if !on && c.panels.filter(\.isEnabled).count <= 1 && c.panels[i].isEnabled { return }
            c.panels[i].isEnabled = on
        }
    }

    static func canDisable(_ panel: PanelLayout, configs: ConfigController) -> Bool {
        !panel.isEnabled || configs.config.panels.filter(\.isEnabled).count > 1
    }


    static func remove(_ id: String, configs: ConfigController, navigation: SettingsNavigation) {
        guard configs.config.panels.count > 1 else { return }
        configs.update { $0.removePanel(id) }
        if navigation.selectedPanel == id { navigation.open(panel: configs.config.panels.first?.id) }
    }

    /// "新建面板"菜单内容
    @ViewBuilder static func addMenu(configs: ConfigController, navigation: SettingsNavigation) -> some View {
        Button("空白网格") { add(blankGrid, configs: configs, navigation: navigation) }
        Button("环形") { add(blankRing, configs: configs, navigation: navigation) }
        Divider()
        Section("从模板") {
            ForEach(PresetPanels.templates, id: \.id) { preset in
                Button(preset.name) { add(preset, configs: configs, navigation: navigation) }
            }
        }
    }
}

/// 侧栏里面板的缩略图：按布局画出按钮块
struct PanelThumbnail: View {
    let panel: PanelLayout

    static let size = CGSize(width: 26, height: 18)

    /// 在 `rect` 里画出按钮块（触控板预览也用）
    static func draw(_ panel: PanelLayout, in ctx: inout GraphicsContext, rect: CGRect,
                     fill: GraphicsContext.Shading = .style(.secondary), line: GraphicsContext.Shading = .style(.tertiary)) {
        let unit = min(rect.width, rect.height) / 18  // 缩略图高 18 时的线宽、圆点等为 1
        if panel.isRing {
            let n = max(panel.ringItems.count, 1)
            let c = CGPoint(x: rect.midX, y: rect.midY), r = rect.height / 2 - 2 * unit
            for i in 0..<n {
                let a = Double(i) / Double(n) * 2 * .pi
                let p = CGPoint(x: c.x + r * sin(a), y: c.y - r * cos(a))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 1.6 * unit, y: p.y - 1.6 * unit, width: 3.2 * unit, height: 3.2 * unit)), with: fill)
            }
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 2 * unit, y: c.y - 2 * unit, width: 4 * unit, height: 4 * unit)), with: line, lineWidth: unit)
        } else {
            for slot in panel.slots {
                guard let n = panel.normalizedRect(of: slot) else { continue }
                let r = CGRect(x: rect.minX + n.minX * rect.width, y: rect.minY + n.minY * rect.height,
                               width: n.width * rect.width, height: n.height * rect.height)
                    .insetBy(dx: 0.8 * unit, dy: 0.8 * unit)
                if slot.isCancel {
                    let d = 3.5 * unit
                    ctx.stroke(Path(ellipseIn: r.insetBy(dx: (r.width - d) / 2, dy: (r.height - d) / 2)), with: line, lineWidth: unit)
                } else {
                    ctx.fill(Path(roundedRect: r, cornerRadius: 1.2 * unit), with: fill)
                }
            }
        }
    }

    var body: some View {
        Canvas { ctx, size in
            Self.draw(panel, in: &ctx, rect: CGRect(origin: .zero, size: size))
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
    }
}

// MARK: 标题栏

private struct PanelHeader: View {
    let configs: ConfigController
    @Bindable var navigation: SettingsNavigation
    let panel: PanelLayout
    @State private var note: String?
    @State private var confirmingReset = false
    @FocusState private var editingName: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                TextField("面板名称", text: makeBinding(get: { panel.name }, set: { n in updatePanel(configs, panel.id) { $0.name = n } }))
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .focused($editingName)
                    .help("点击修改名称")
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            if let note {
                Label(note, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange).lineLimit(2)
            }
            if !panel.isRing {
                HStack(spacing: 4) {
                    SizePicker(value: panel.rows, range: 1...AppConfig.maxRows, isRows: true) { resize(rows: $0, cols: panel.cols) }
                    Text("×").foregroundStyle(.tertiary)
                    SizePicker(value: panel.cols, range: 1...AppConfig.maxCols, isRows: false) { resize(rows: panel.rows, cols: $0) }
                }
            }
            // 面板在屏幕上的位置（D41）：输入类面板放到一侧，不挡住正在输入的地方
            Picker("位置", selection: makeBinding(get: { panel.placement }, set: { v in updatePanel(configs, panel.id) { $0.placement = v } })) {
                ForEach(PanelPlacement.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("面板出现在屏幕上的位置")
            // 启用开关放在标题栏，一眼可见（D37、D38）：停用的面板保留配置，不参与唤起与切换
            Toggle("启用", isOn: makeBinding(get: { panel.isEnabled },
                                         set: { PanelCommands.setEnabled(panel.id, $0, configs: configs) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()
                .disabled(!PanelCommands.canDisable(panel, configs: configs))
                .help(PanelCommands.canDisable(panel, configs: configs) ? "停用后保留配置，不参与唤起和切换" : "至少要有一个启用的面板")
            Menu {
                Button("重命名") { editingName = true }
                Button("复制面板") { PanelCommands.add(panel, configs: configs, navigation: navigation) }
                Button("设为默认面板") { PanelCommands.makeDefault(panel.id, configs: configs) }
                    .disabled(isDefault || !panel.isEnabled)
                Divider()
                Button(resetTitle + "…") { confirmingReset = true }
                Button("删除面板", role: .destructive) { PanelCommands.remove(panel.id, configs: configs, navigation: navigation) }
                    .disabled(configs.config.panels.count <= 1)
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多操作")
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .onChange(of: panel.id) { note = nil }
        .confirmationDialog(resetTitle + "？", isPresented: $confirmingReset) {
            Button(resetTitle, role: .destructive) {
                navigation.selectedSlot = nil
                note = nil
                configs.update { $0.resetPanel(panel.id, to: resetTemplate) }
            }
        } message: {
            if let origin = PresetPanels.origin(of: panel.id) {
                Text(verbatim: String(localized: "「\(panel.name)」的名称、行列和全部按钮都会换成预置的「\(origin.name)」，唤起方式的绑定保留。可以在 通用 › 配置文件 里从备份恢复。"))
            } else {
                Text(verbatim: String(localized: "「\(panel.name)」的名称、行列和全部按钮都会换成空白面板，唤起方式的绑定保留。可以在 通用 › 配置文件 里从备份恢复。"))
            }
        }
    }

    /// 来自预置面板的恢复成预置内容，其余的清空
    private var resetTemplate: PanelLayout {
        PresetPanels.origin(of: panel.id) ?? (panel.isRing ? PanelCommands.blankRing : PanelCommands.blankGrid)
    }

    private var resetTitle: String { PresetPanels.origin(of: panel.id) == nil ? String(localized: "清空面板") : String(localized: "重置面板") }

    private var isDefault: Bool { configs.config.defaultPanel?.id == panel.id }

    /// 哪些唤起方式会打开这个面板
    private var subtitle: String {
        let config = configs.config
        guard panel.isEnabled else { return String(localized: "已停用 · 配置保留，不参与唤起和切换") }
        let active = Set(config.activePanels.map(\.id))
        let opens = config.enabledTriggers.filter {
            (config.binding(for: $0.trigger).flatMap { active.contains($0) ? $0 : nil } ?? config.defaultPanel?.id) == panel.id
        }
        var parts: [String] = []
        if isDefault { parts.append(String(localized: "默认面板")) }
        if opens.isEmpty {
            parts.append(String(localized: "双指上下滑动切换到这里"))
        } else {
            let names = opens.map(\.title).joined(separator: String(localized: "、"))
            parts.append(String(localized: "\(names)打开"))
        }
        return parts.joined(separator: " · ")
    }

    private func resize(rows: Int, cols: Int) {
        guard let resized = panel.resized(rows: rows, cols: cols) else {
            note = String(localized: "有按钮会超出新网格，先移动或删除它们")
            return
        }
        note = nil
        updatePanel(configs, panel.id) { $0 = resized }
    }
}

private struct SizePicker: View {
    let value: Int
    let range: ClosedRange<Int>
    let isRows: Bool
    let set: (Int) -> Void

    private func label(_ n: Int) -> String { isRows ? String(localized: "\(n) 行") : String(localized: "\(n) 列") }

    var body: some View {
        Menu(label(value)) {
            ForEach(Array(range), id: \.self) { n in
                Button { set(n) } label: {
                    if n == value { Label(label(n), systemImage: "checkmark") } else { Text(label(n)) }
                }
            }
        }
        .fixedSize()
        .help(isRows ? String(localized: "行数") : String(localized: "列数"))
    }
}

// MARK: 舞台

/// 舞台背景：当前桌面壁纸（压暗），面板在真实环境里的样子；取不到时用渐变
@MainActor
private enum StageBackdrop {
    static let maxPixels = 1400
    static let image: NSImage? = {
        guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
              ] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }()
}

private struct PanelStage: View {
    let configs: ConfigController
    @Bindable var navigation: SettingsNavigation
    let panel: PanelLayout

    /// 面板在舞台里最多占的比例
    static let fill: CGFloat = 0.86
    static let hintHeight: CGFloat = 30

    var body: some View {
        GeometryReader { geo in
            let panels = panelGeometry
            let real = panels.size(of: panel)
            let size = displaySize(in: CGSize(width: geo.size.width, height: geo.size.height - Self.hintHeight), real: real,
                                   reference: panels.group)
            let geometry = StageGeometry(display: size, real: real)
            VStack(spacing: 0) {
                ZStack {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { navigation.selectedSlot = nil }
                    if panel.isRing {
                        RingCanvas(configs: configs, navigation: navigation, panel: panel, stage: geometry)
                    } else {
                        GridCanvas(configs: configs, navigation: navigation, panel: panel, stage: geometry)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { backdrop }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.08)))
                Text(hint)
                    .font(.callout).foregroundStyle(.tertiary)
                    .frame(height: Self.hintHeight, alignment: .bottom)
            }
        }
        .environment(\.overlayStyle, OverlayStyle(Appearance(configs.config.appearance)))
    }

    @ViewBuilder private var backdrop: some View {
        if let image = StageBackdrop.image {
            // 按填满缩放的图片布局尺寸超出舞台，裁剪只裁显示、不裁命中区域：不让它接收点击，否则会盖住上方的标题栏
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                .blur(radius: 6, opaque: true)
                .overlay(Color.black.opacity(0.3))
                .allowsHitTesting(false)
        } else {
            LinearGradient(colors: [Color(red: 0.13, green: 0.15, blue: 0.24), Color(red: 0.07, green: 0.07, blue: 0.11)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var hint: String {
        panel.isRing ? String(localized: "点按钮编辑 · 拖动外圈按钮调整顺序")
            : String(localized: "点空位添加 · 拖动移动，拖到别的按钮上互换 · 拖右下角调整大小 · 位置与触控板一一对应")
    }

    /// 唤起时各面板在主屏上的实际尺寸（FR-6.4；随网格伸缩，D29）
    private var panelGeometry: PanelGeometry {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        var t = Tuning()
        configs.config.apply(to: &t)
        return PanelGeometry(screen: screen, deviceMM: MultitouchBridge.fallbackSurfaceMM, tuning: t)
    }

    /// 舞台上显示的尺寸：与参考大小的面板用同一比例缩小，行列少的面板看起来更小；放不下时再缩小，不放大
    private func displaySize(in area: CGSize, real: CGSize, reference: CGSize) -> CGSize {
        func fit(_ s: CGSize) -> CGFloat {
            guard s.width > 0, s.height > 0 else { return 1 }
            return min(1, area.width * Self.fill / s.width, area.height * Self.fill / s.height)
        }
        let k = min(fit(reference), fit(real))
        return CGSize(width: real.width * k, height: real.height * k)
    }
}

/// 舞台坐标：面板按实际尺寸渲染后整体缩放，操作层在显示坐标里工作
private struct StageGeometry {
    let display: CGSize
    let real: CGSize

    var scale: CGFloat { real.width > 0 ? display.width / real.width : 1 }

    /// 实际尺寸下的按钮外形换算到显示坐标
    func shown(_ g: ChipGeometry) -> ChipGeometry {
        ChipGeometry(frame: CGRect(x: g.frame.minX * scale, y: g.frame.minY * scale,
                                   width: g.frame.width * scale, height: g.frame.height * scale), kind: g.kind)
    }

    func chip(_ slot: Slot, in layout: PanelLayout) -> ChipGeometry? {
        let tester = HitTester(layout: layout, panelSize: real, slotGap: Tuning().slotGap, hysteresis: 0)
        return ChipGeometry.of(slot, tester: tester).map(shown)
    }
}

/// 舞台上的面板画面：与唤起时同一个视图，选中的按钮以"点亮"状态显示
private struct LivePanel: View {
    let layout: PanelLayout
    let stage: StageGeometry
    let lit: SlotID?

    static let sliderPreview = 0.6

    var body: some View {
        let sliders = Dictionary(uniqueKeysWithValues: layout.slots.filter { $0.slider != nil }.map { ($0.id, Self.sliderPreview) })
        PanelView(layout: layout, size: stage.real, slotGap: Tuning().slotGap, current: true, hovered: lit, phase: .shown,
                  sliderValues: sliders, sliderBase: [:], pulses: [:], presses: [:], origin: nil, outside: false)
            .environment(\.colorScheme, .dark)
            .scaleEffect(stage.scale, anchor: .topLeading)
            .frame(width: stage.display.width, height: stage.display.height, alignment: .topLeading)
            .allowsHitTesting(false)
    }
}

/// 选中框
private struct SelectionMark: View {
    let geometry: ChipGeometry
    static let outset: CGFloat = 5

    var body: some View {
        let r = geometry.frame.insetBy(dx: -Self.outset, dy: -Self.outset)
        Group {
            if geometry.kind == .tile {
                RoundedRectangle(cornerRadius: min(r.width, r.height) * 0.28, style: .continuous).strokeBorder(Color.white, lineWidth: 1.5)
            } else {
                Circle().strokeBorder(Color.white, lineWidth: 1.5)
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 3)
        .frame(width: r.width, height: r.height)
        .position(x: r.midX, y: r.midY)
        .allowsHitTesting(false)
    }
}

// MARK: 网格

private struct GridCanvas: View {
    let configs: ConfigController
    @Bindable var navigation: SettingsNavigation
    let panel: PanelLayout
    let stage: StageGeometry
    /// 正在拖动的按钮与位移（移动或改大小）
    @State private var drag: (id: SlotID, offset: CGSize, resize: Bool)?
    @State private var hoverCell: GridCell?

    var body: some View {
        let size = stage.display
        let cw = size.width / CGFloat(panel.cols), ch = size.height / CGFloat(panel.rows)
        let shown = displayed(cw, ch)
        ZStack(alignment: .topLeading) {
            emptyCells(cw, ch)
            LivePanel(layout: shown, stage: stage, lit: navigation.selectedSlot)
                .animation(.spring(response: 0.28, dampingFraction: 0.8), value: shown)
            if let id = navigation.selectedSlot, let slot = shown.slot(id), let g = stage.chip(slot, in: shown) {
                SelectionMark(geometry: g)
                    .animation(.spring(response: 0.28, dampingFraction: 0.8), value: g)
            }
            if let d = drag, let slot = panel.slot(d.id), case .cell(let cell) = slot.shape,
               let target = proposed(cell, cw, ch), placed(slot.id, target, resize: d.resize) == nil {
                let r = rect(target, cw, ch).insetBy(dx: gap, dy: gap)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.red.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                    .allowsHitTesting(false)
            }
            ForEach(panel.slots, id: \.id) { slot in
                if case .cell(let cell) = slot.shape { handle(slot, cell, cw, ch) }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// 拖动中按落点实时显示，被压住的按钮让到空出的位置（放不下时留在原处）
    private func displayed(_ cw: CGFloat, _ ch: CGFloat) -> PanelLayout {
        guard let d = drag, let slot = panel.slot(d.id), case .cell(let cell) = slot.shape,
              let target = proposed(cell, cw, ch) else { return panel }
        return placed(d.id, target, resize: d.resize) ?? panel
    }

    /// 移动可以和别的按钮互换位置（D29）；改大小只能占空位
    private func placed(_ id: SlotID, _ target: GridCell, resize: Bool) -> PanelLayout? {
        guard resize else { return panel.moving(id, to: target) }
        guard panel.canPlace(target, ignoring: id), let i = panel.slots.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = panel
        copy.slots[i].shape = .cell(target)
        return copy
    }

    @ViewBuilder private func emptyCells(_ cw: CGFloat, _ ch: CGFloat) -> some View {
        ForEach(0..<panel.rows, id: \.self) { r in
            ForEach(0..<panel.cols, id: \.self) { c in
                if panel.slot(atRow: r, col: c) == nil {
                    let cell = GridCell(row: r, col: c)
                    let hovered = hoverCell == cell && drag == nil
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(hovered ? 0.45 : 0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(hovered ? 0.08 : 0)))
                        .overlay(Image(systemName: "plus").font(.title3.weight(.medium)).foregroundStyle(.white.opacity(hovered ? 0.85 : 0)))
                        .padding(gap + PanelMetrics.chipInset * stage.scale)
                        .frame(width: cw, height: ch)
                        .contentShape(Rectangle())
                        .offset(x: CGFloat(c) * cw, y: CGFloat(r) * ch)
                        .onHover { inside in
                            if inside { hoverCell = cell } else if hoverCell == cell { hoverCell = nil }
                        }
                        .onTapGesture { addSlot(row: r, col: c) }
                        .animation(.easeOut(duration: 0.12), value: hovered)
                }
            }
        }
    }

    /// 按钮上方的透明操作区：点选、拖动移动；选中后右下角出现调整大小的把手
    @ViewBuilder private func handle(_ slot: Slot, _ cell: GridCell, _ cw: CGFloat, _ ch: CGFloat) -> some View {
        let frame = rect(cell, cw, ch)
        Color.clear
            .contentShape(Rectangle())
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .onTapGesture { navigation.selectedSlot = slot.id }
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { v in drag = (slot.id, v.translation, false) }
                .onEnded { _ in
                    commit(slot, cell, cw, ch)
                    // 松手后再选中：拖动途中打开属性栏会缩小画布，落点跟着错位
                    navigation.selectedSlot = slot.id
                })
        if navigation.selectedSlot == slot.id && !slot.isCancel && (drag == nil || drag?.resize == true) {
            let target = proposed(cell, cw, ch).flatMap { placed(slot.id, $0, resize: true) != nil ? $0 : nil } ?? cell
            let r = rect(target, cw, ch).insetBy(dx: gap, dy: gap)
            ResizeHandle()
                .position(x: r.maxX - 2, y: r.maxY - 2)
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { v in drag = (slot.id, v.translation, true) }
                    .onEnded { _ in commit(slot, cell, cw, ch) })
        }
    }

    /// 显示坐标下的槽位空隙
    private var gap: CGFloat { Tuning().slotGap * stage.scale }

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
        // 先写入新位置再清掉拖动状态，松手时不会闪回原处
        if let d = drag, let target = proposed(cell, cw, ch), target != cell, let layout = placed(slot.id, target, resize: d.resize) {
            updatePanel(configs, panel.id) { $0 = layout }
        }
        drag = nil
    }

    private func addSlot(row: Int, col: Int) {
        let id = SlotID(AppConfig.uniqueID("\(panel.id).slot", existing: configs.config.allSlotIDs))
        let slot = Slot(id: id, shape: .cell(GridCell(row: row, col: col)), title: String(localized: "新按钮"), symbol: "star",
                        action: .keyboardShortcut(KeyCombo(keyCode: 0, modifiers: [.command], displayLabel: "⌘A")))
        updatePanel(configs, panel.id) { $0.slots.append(slot) }
        navigation.selectedSlot = id
    }
}

private struct ResizeHandle: View {
    static let size: CGFloat = 14

    var body: some View {
        Circle().fill(Color.white).frame(width: Self.size, height: Self.size)
            .overlay(Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 7, weight: .bold)).foregroundStyle(.black))
            .shadow(color: .black.opacity(0.4), radius: 3)
            .frame(width: Self.size * 2, height: Self.size * 2)
            .contentShape(Rectangle())
            .help("拖动调整大小")
    }
}

// MARK: 环形

private struct RingCanvas: View {
    let configs: ConfigController
    @Bindable var navigation: SettingsNavigation
    let panel: PanelLayout
    let stage: StageGeometry

    static let maxItems = 12

    /// 拖动中的外圈按钮与它将落到的位置
    @State private var drag: (id: SlotID, index: Int)?

    var body: some View {
        let size = stage.display
        let shown = drag.map { panel.movingRingItem($0.id, to: $0.index) } ?? panel
        let chips = panel.slots.compactMap { s in stage.chip(s, in: panel).map { (slot: s, geometry: $0) } }
        ZStack(alignment: .topLeading) {
            LivePanel(layout: shown, stage: stage, lit: navigation.selectedSlot)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: shown)
            if let id = navigation.selectedSlot, let slot = shown.slot(id), let g = stage.chip(slot, in: shown) {
                SelectionMark(geometry: g)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: g)
            }
            // 操作区按拖动前的位置排布，拖动途中不会换到别的按钮上
            ForEach(chips, id: \.slot.id) { chip in
                let r = chip.geometry.frame.insetBy(dx: -SelectionMark.outset, dy: -SelectionMark.outset)
                let outer = panel.ringItems.contains { $0.id == chip.slot.id }
                Circle().fill(Color.clear).contentShape(Circle())
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
                    .onTapGesture { navigation.selectedSlot = chip.slot.id }
                    .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
                        .onChanged { v in
                            guard outer else { return }
                            drag = (chip.slot.id, index(at: v.location, size: size))
                        }
                        .onEnded { v in
                            guard outer else { return }
                            let target = index(at: v.location, size: size)
                            // 先写入新顺序再清掉拖动状态，松手时不会闪回原处；松手后再选中（同网格）
                            updatePanel(configs, panel.id) { $0 = $0.movingRingItem(chip.slot.id, to: target) }
                            drag = nil
                            navigation.selectedSlot = chip.slot.id
                        })
            }
        }
        .coordinateSpace(name: Self.space)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .overlay(alignment: .bottomTrailing) {
            Button { addItem() } label: { Label("添加按钮", systemImage: "plus") }
                .disabled(panel.ringItems.count >= Self.maxItems)
        }
    }

    private static let space = "ring"

    /// 拖动位置对应的外圈序号：按角度取最近的一格，从正上方起顺时针
    private func index(at p: CGPoint, size: CGSize) -> Int {
        let n = panel.ringItems.count
        guard n > 0 else { return 0 }
        let angle = atan2(p.x - size.width / 2, size.height / 2 - p.y) * 180 / .pi
        let step = 360 / Double(n)
        return Int(((angle + 360).truncatingRemainder(dividingBy: 360) / step).rounded()) % n
    }

    private func addItem() {
        let id = SlotID(AppConfig.uniqueID("\(panel.id).item", existing: configs.config.allSlotIDs))
        let item = Slot(id: id, shape: .rect(.zero), title: String(localized: "新按钮"), symbol: "star",
                        action: .keyboardShortcut(KeyCombo(keyCode: 0, modifiers: [.command], displayLabel: "⌘A")))
        updatePanel(configs, panel.id) { $0 = $0.rebuiltRing(items: $0.ringItems + [item]) }
        navigation.selectedSlot = id
    }
}

// MARK: 文案

extension AppConfig {
    /// 已开启的唤起方式及其名称
    var enabledTriggers: [(trigger: PanelTrigger, title: String)] {
        triggers.list.map { ($0, $0.title) }
    }
}

extension PanelTrigger {
    var title: String {
        switch self {
        case .tapHold: String(localized: "轻点后按住")
        case .fourFingerTap: String(localized: "四指轻点")
        case .threeFingerTap: String(localized: "三指轻点")
        case .zoneTapHold(let z): String(localized: "\(z.title)轻点后按住")
        }
    }
}

extension PanelPlacement {
    var title: String {
        switch self {
        case .center: String(localized: "屏幕中央")
        case .left: String(localized: "屏幕左侧")
        case .right: String(localized: "屏幕右侧")
        }
    }
}

extension TriggerZone {
    var title: String {
        switch self {
        case .topLeft: String(localized: "左上角")
        case .top: String(localized: "上边")
        case .topRight: String(localized: "右上角")
        case .left: String(localized: "左边")
        case .right: String(localized: "右边")
        case .bottomLeft: String(localized: "左下角")
        case .bottom: String(localized: "下边")
        case .bottomRight: String(localized: "右下角")
        }
    }
}

extension Action {
    /// 编辑器里的一句话说明
    var summary: String {
        switch self {
        case .none: String(localized: "关闭")
        case .keyboardShortcut(let k): k.displayLabel
        case .openApp(let id): NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.deletingPathExtension().lastPathComponent ?? id
        case .openURL(let url, _): url.host ?? url.absoluteString
        case .openFile(let path): (path as NSString).lastPathComponent
        case .shell: "Shell"
        case .appleScript: String(localized: "脚本")
        case .shortcut(let name): name
        case .system(let c): c.title
        case .textSnippet(let text): String(localized: "输入「\(text)」")
        }
    }
}

extension SystemCommand {
    var title: String {
        switch self {
        case .volumeUp: String(localized: "音量 +")
        case .volumeDown: String(localized: "音量 −")
        case .mute: String(localized: "静音")
        case .brightnessUp: String(localized: "亮度 +")
        case .brightnessDown: String(localized: "亮度 −")
        case .playPause: String(localized: "播放 / 暂停")
        case .nextTrack: String(localized: "下一首")
        case .previousTrack: String(localized: "上一首")
        case .lockScreen: String(localized: "锁屏")
        case .missionControl: String(localized: "调度中心")
        case .showDesktop: String(localized: "显示桌面")
        case .launchpad: String(localized: "启动台")
        case .screenshotArea: String(localized: "截取区域")
        case .screenshotWindow: String(localized: "截取窗口")
        case .windowLeftHalf: String(localized: "窗口：左半屏")
        case .windowRightHalf: String(localized: "窗口：右半屏")
        case .windowTopHalf: String(localized: "窗口：上半屏")
        case .windowBottomHalf: String(localized: "窗口：下半屏")
        case .windowFill: String(localized: "窗口：填满")
        case .windowCenter: String(localized: "窗口：居中")
        case .windowNextDisplay: String(localized: "窗口：下一个显示器")
        }
    }
}
