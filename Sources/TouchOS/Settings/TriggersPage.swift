import AppKit
import Combine
import SwiftUI
import TouchOSCore

/// 唤起与手感（D25、D26）：左边逐项开关唤起方式、各自选择打开的面板；右边按实际比例画出触控板分区，
/// 悬停某一项时突出它在板上的范围
struct TriggersPage: View {
    let configs: ConfigController
    @State private var focus: PreviewFocus?
    @State private var tapToClick = TapToClick.isOn
    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            Form {
                Section {
                    row(.tapHold, detail: "单指轻点一下，紧接着在附近按住：第二下落下面板就出现，滑到按钮上抬起即执行")
                    if tapToClick && configs.config.triggers.isOn(.tapHold) { TapToClickWarning() }
                    row(.fourFingerTap, detail: "四指同时轻点；面板开着时再轻点一次关闭")
                    row(.threeFingerTap, detail: "三指同时轻点；会占用系统的三指查询手势")
                } header: {
                    SectionHeader(title: "唤起方式", note: "可以同时开启多种，每种打开不同的面板；面板之间用双指上下滑动切换，双指捏合查看全部。")
                    if configs.config.triggers.list.isEmpty {
                        Label("没有开启任何唤起方式，面板无法唤起。", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    ForEach(PanelTrigger.corners, id: \.self) { row(.hold($0), title: $0.title) }
                } header: {
                    SectionHeader(title: "一指按住角落", note: "一指按住角落不动，面板出现后用另一指选择；按住的手指抬起即关闭。")
                }
                Section {
                    ForEach(PanelTrigger.corners, id: \.self) { row(.cornerDoubleTap($0), title: $0.title) }
                } header: {
                    SectionHeader(title: "在角落轻点两下", note: "在开启了这一项的角落里轻点，优先算作「角落轻点两下」，不会触发轻点后按住。")
                }
                Section("手感") {
                    Toggle("常驻：锚指抬起后面板保留", isOn: binding(configs, \.general.stickyPanel))
                    LabeledSlider(title: "面板大小（占屏幕）", value: binding(configs, \.sizes.panelScale), range: Tuning.panelScaleRange)
                        .onHover { hover(.panel, $0) }
                    LabeledSlider(title: "映射区大小（占触控板）", value: binding(configs, \.sizes.mappingScale), range: Tuning.mappingScaleRange)
                        .onHover { hover(.mapping, $0) }
                    LabeledSlider(title: "按钮间隙", value: binding(configs, \.sizes.hitGapMM), range: Tuning.hitGapRange,
                                  step: 0.5, format: { String(format: "%.1f mm", $0) })
                        .onHover { hover(.gap, $0) }
                    Toggle("触觉反馈", isOn: binding(configs, \.general.haptics))
                }
            }
            .formStyle(.grouped)
            Divider()
            ScrollView {
                TriggerPreview(config: configs.config, focus: focus)
                    .padding(20)
            }
            .frame(width: TriggerPreview.width + 40)
        }
        .onReceive(poll) { _ in tapToClick = TapToClick.isOn }
    }

    private func row(_ trigger: PanelTrigger, title: String? = nil, detail: String? = nil) -> some View {
        TriggerRow(configs: configs, trigger: trigger, title: title ?? trigger.title, detail: detail)
            .onHover { hover(.trigger(trigger), $0) }
    }

    private func hover(_ f: PreviewFocus, _ inside: Bool) {
        if inside { focus = f } else if focus == f { focus = nil }
    }
}

private struct SectionHeader: View {
    let title: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            Text(note).font(.caption).fontWeight(.regular).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 预览里突出显示的内容
enum PreviewFocus: Equatable {
    case trigger(PanelTrigger)
    case mapping
    case panel
    case gap
}

/// 一种唤起方式：名称与说明、打开哪个面板、开关
private struct TriggerRow: View {
    let configs: ConfigController
    let trigger: PanelTrigger
    let title: String
    let detail: String?

    var body: some View {
        let on = configs.config.triggers.isOn(trigger)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            Picker("打开", selection: panel) {
                Text("默认面板（\(configs.config.defaultPanel?.name ?? "—")）").tag(String?.none)
                // 停用的面板仍可选，但唤起时打开默认面板（D37）
                ForEach(configs.config.panels, id: \.id) { Text($0.isEnabled ? $0.name : "\($0.name)（已停用）").tag(Optional($0.id)) }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(!on)
            .opacity(on ? 1 : 0.5)
            Toggle(title, isOn: Binding(get: { on }, set: { v in configs.update { $0.triggers.set(trigger, v) } }))
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .contentShape(Rectangle())
    }

    private var panel: Binding<String?> {
        Binding(get: { configs.config.binding(for: trigger) }, set: { id in configs.update { $0.bind(trigger, to: id) } })
    }
}

/// 系统「轻点来点按」开着时，轻点后按住的第一下会先点一次鼠标（D25）
private struct TapToClickWarning: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 6) {
                Text("系统的「轻点来点按」已开启：轻点后按住的第一下会先在光标处点一次。建议在系统设置 › 触控板中关闭它，用按压来点按。")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button("打开触控板设置") { NSWorkspace.shared.open(TapToClick.settingsURL) }
            }
        }
        .padding(.vertical, 2)
    }
}

enum TapToClick {
    /// 内置触控板与妙控板各有一份设置，任一开着都算
    private static let domains = ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"]
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension")!

    static var isOn: Bool {
        domains.contains { domain in
            CFPreferencesAppSynchronize(domain as CFString)
            return CFPreferencesCopyAppValue("Clicking" as CFString, domain as CFString) as? Bool ?? false
        }
    }
}

// MARK: 预览

/// 按实际比例画出触控板分区与屏幕上的面板，随设置实时变化
struct TriggerPreview: View {
    let config: AppConfig
    let focus: PreviewFocus?

    static let width: CGFloat = 320
    private static let holdColor = Color.orange
    private static let doubleTapColor = Color.purple
    private static let tapHoldColor = Color.teal

    private var device: CGSize { MultitouchBridge.fallbackSurfaceMM }

    private var tuning: Tuning {
        var t = Tuning()
        config.apply(to: &t)
        return t
    }

    /// 预览里画在映射区中的面板：悬停的唤起方式打开的面板，否则为默认面板
    private var shownPanel: PanelLayout? {
        let id: String? = if case .trigger(let t) = focus { config.binding(for: t) } else { nil }
        return config.activePanels.first { $0.id == id } ?? config.defaultPanel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("触控板").font(.headline)
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            let height = Self.width * device.height / device.width
            Canvas { ctx, size in draw(&ctx, size) }
                .frame(width: Self.width, height: height)
                .animation(.easeOut(duration: 0.15), value: focus)
            legend
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                Text("屏幕").font(.headline)
                Text("面板占屏幕 \(Int((tuning.panelScale * 100).rounded()))%，总在屏幕中央").font(.caption).foregroundStyle(.secondary)
            }
            ScreenPreview(panel: shownPanel, tuning: tuning, device: device, emphasized: focus == .panel)
                .frame(width: Self.width)
        }
        .frame(width: Self.width, alignment: .leading)
    }

    private var caption: String {
        if case .trigger(let t) = focus, let panel = shownPanel {
            return "「\(t.title)」打开「\(panel.name)」" + (config.triggers.isOn(t) ? "" : "（未开启）")
        }
        return "按妙控板比例绘制，\(Int(device.width.rounded())) × \(Int(device.height.rounded())) mm"
    }

    private var legend: some View {
        let reach = Int(tuning.tapHoldReachMM.rounded())
        return VStack(alignment: .leading, spacing: 6) {
            LegendItem(color: .accentColor, text: "映射区：手指位置对应面板上的按钮，在区外抬起即取消")
            if config.triggers.isOn(.tapHold) {
                LegendItem(color: Self.tapHoldColor, text: "轻点后按住：第二下落在第一下 \(reach) mm 以内，板上任意位置都可以")
            }
            if !tuning.holdCorners.isEmpty { LegendItem(color: Self.holdColor, text: "一指按住角落") }
            if !tuning.doubleTapCorners.isEmpty { LegendItem(color: Self.doubleTapColor, text: "角落轻点两下") }
        }
    }

    /// 某一部分是否淡化：有悬停时，不相关的部分淡化
    private func dimmed(_ relevant: Bool) -> Double { focus == nil || relevant ? 1 : 0.3 }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let t = tuning
        let pad = CGRect(origin: .zero, size: size)
        // 触控板归一化坐标（原点左下）→ 视图坐标
        func view(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * size.width, y: (1 - r.maxY) * size.height, width: r.width * size.width, height: r.height * size.height)
        }
        let corner = size.width * 0.05
        ctx.fill(Path(roundedRect: pad, cornerRadius: corner), with: .color(.secondary.opacity(0.12)))
        ctx.stroke(Path(roundedRect: pad.insetBy(dx: 0.5, dy: 0.5), cornerRadius: corner), with: .color(.secondary.opacity(0.4)), lineWidth: 1)

        // 映射区与其中的面板：映射区随面板的网格伸缩（D29）
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let scale = shownPanel.map { PanelGeometry(screen: screen, deviceMM: device, tuning: t).mapping(of: $0) }
            ?? CGSize(width: t.mappingScale, height: t.mappingScale)
        let mapping = view(Mapper(margin: t.mappingMargin, size: scale).mappingRect)
        var m = ctx
        m.opacity = dimmed(focus == .mapping || focus == .panel || focus == .gap || { if case .trigger = focus { true } else { false } }())
        m.fill(Path(roundedRect: mapping, cornerRadius: 6), with: .color(.accentColor.opacity(focus == .mapping ? 0.22 : 0.12)))
        m.stroke(Path(roundedRect: mapping, cornerRadius: 6), with: .color(.accentColor.opacity(0.8)), lineWidth: focus == .mapping ? 2 : 1)
        if let panel = shownPanel, focus == .gap, !panel.isRing {
            // 按真实比例画出各按钮的判定区：之间与外沿的空白就是不触发的间隙（D31）
            let perMM = mapping.width / (scale.width * device.width)
            let tester = HitTester(layout: panel, panelSize: mapping.size, slotGap: t.hitGapMM / 2 * perMM, hysteresis: 0, extendsEdges: false)
            for slot in panel.slots {
                guard let r = tester.rect(of: slot) else { continue }
                let shape = Path(roundedRect: r.offsetBy(dx: mapping.minX, dy: mapping.minY), cornerRadius: 2)
                m.fill(shape, with: .color(.accentColor.opacity(0.45)))
                m.stroke(shape, with: .color(.accentColor.opacity(0.8)), lineWidth: 0.5)
            }
        } else if let panel = shownPanel {
            PanelThumbnail.draw(panel, in: &m, rect: mapping.insetBy(dx: mapping.width * 0.06, dy: mapping.height * 0.06),
                                fill: .color(.accentColor.opacity(0.45)), line: .color(.accentColor.opacity(0.8)))
        }
        if mapping.minY > 18 {
            m.draw(Text("区外抬起 = 取消").font(.system(size: 10)).foregroundStyle(.secondary),
                   at: CGPoint(x: pad.midX, y: (mapping.maxY + pad.maxY) / 2))
        }

        // 角落
        for c in PanelTrigger.corners {
            let hold = t.holdCorners.contains(c), double = t.doubleTapCorners.contains(c)
            let focusedHold = focus == .trigger(.hold(c)), focusedDouble = focus == .trigger(.cornerDoubleTap(c))
            guard hold || double || focusedHold || focusedDouble else { continue }
            let zone = view(anchorZone(c, width: t.anchorZoneW, height: t.anchorZoneH))
            var z = ctx
            z.opacity = dimmed(focusedHold || focusedDouble)
            let shape = Path(roundedRect: zone.insetBy(dx: 2, dy: 2), cornerRadius: 5)
            if hold || focusedHold {
                z.fill(shape, with: .color(Self.holdColor.opacity(hold ? 0.45 : 0.15)))
            }
            if double || focusedDouble {
                if !(hold || focusedHold) { z.fill(shape, with: .color(Self.doubleTapColor.opacity(double ? 0.3 : 0.1))) }
                z.stroke(shape, with: .color(Self.doubleTapColor), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
            } else if !hold {
                z.stroke(shape, with: .color(Self.holdColor), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            let symbol = hold || focusedHold ? (double || focusedDouble ? "hand.tap.fill" : "hand.point.up.left.fill") : "hand.tap"
            z.draw(Text(Image(systemName: symbol)).font(.system(size: 12)).foregroundStyle(.primary.opacity(0.8)),
                   at: CGPoint(x: zone.midX, y: zone.midY))
        }

        // 轻点后按住：在映射区中心示意第二下的允许范围
        let tapHoldOn = config.triggers.isOn(.tapHold)
        if tapHoldOn || focus == .trigger(.tapHold) {
            var h = ctx
            h.opacity = dimmed(focus == .trigger(.tapHold)) * (tapHoldOn ? 1 : 0.5)
            let r = t.tapHoldReachMM / device.width * size.width
            let center = CGPoint(x: mapping.maxX - mapping.width * 0.22, y: mapping.minY + mapping.height * 0.3)
            h.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)),
                   with: .color(Self.tapHoldColor.opacity(0.18)))
            h.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)),
                     with: .color(Self.tapHoldColor), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
            h.fill(Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)), with: .color(Self.tapHoldColor))
        }
    }
}

private struct LegendItem: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.7)).frame(width: 10, height: 10)
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 屏幕与面板的相对大小
private struct ScreenPreview: View {
    let panel: PanelLayout?
    let tuning: Tuning
    let device: CGSize
    let emphasized: Bool

    var body: some View {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 6), with: .color(.secondary.opacity(0.12)))
            ctx.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 6), with: .color(.secondary.opacity(0.4)), lineWidth: 1)
            let geometry = PanelGeometry(screen: screen, deviceMM: device, tuning: tuning)
            let real = panel.map(geometry.size(of:)) ?? geometry.group
            let k = size.width / screen.width
            let p = CGRect(x: (size.width - real.width * k) / 2, y: (size.height - real.height * k) / 2,
                           width: real.width * k, height: real.height * k)
            ctx.stroke(Path(roundedRect: p, cornerRadius: 4), with: .color(.accentColor.opacity(emphasized ? 1 : 0.6)),
                       lineWidth: emphasized ? 2 : 1)
            if let panel {
                PanelThumbnail.draw(panel, in: &ctx, rect: p.insetBy(dx: p.width * 0.06, dy: p.height * 0.06),
                                    fill: .color(.accentColor.opacity(0.45)), line: .color(.accentColor.opacity(0.8)))
            }
        }
        .aspectRatio(screen.width / screen.height, contentMode: .fit)
        .animation(.easeOut(duration: 0.15), value: emphasized)
    }
}
