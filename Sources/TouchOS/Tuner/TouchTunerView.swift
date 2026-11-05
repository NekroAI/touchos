import SwiftUI
import TouchOSCore

/// 手感调试的界面（D57）：触点画布、读数与阈值、上次唤起判定、阈值调节；调试模式时附带排查工具
struct TouchTunerView: View {
    let model: TouchTunerModel
    let configs: ConfigController
    let onClose: () -> Void
    let debugActions: [(title: String, run: () -> Void)]

    var body: some View {
        let tuning = thresholds
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.devices.isEmpty {
                Card { Text("没有启用的触控板").foregroundStyle(.secondary) }
            }
            ForEach(model.devices, id: \.device.id) { state in
                DeviceCard(state: state, thresholds: tuning, clickStage: model.pressure?.stage)
            }
            Card { JudgementView(judgement: model.judgement, thresholds: tuning) }
            Card { Adjustments(configs: configs) }
            if model.debugMode {
                Card { DebugSections(model: model, actions: debugActions) }
            }
        }
        .padding(14)
        .frame(width: TouchTunerController.width - 20, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("手感调试").font(.headline)
                Text("轻点一下后立刻按住，看两下的读数是否达到唤起阈值。").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "关闭"))
        }
    }

    private var thresholds: Thresholds {
        let s = configs.config.sizes
        return Thresholds(size: Float(s.minHoldSize), pressure: Float(s.minHoldPressure))
    }
}

/// 唤起阈值（D56、D57）：0 表示该项不检查
struct Thresholds {
    let size: Float
    let pressure: Float

    func passes(size s: Float, pressure p: Float) -> Bool { s >= size && p >= pressure }
}

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct SectionTitle: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }
}

// MARK: 触控板

private struct DeviceCard: View {
    /// 画布上圆点的最小半径与随接触面积增加的幅度（pt）
    static let dotRadius: CGFloat = 6
    static let dotGrowth: CGFloat = 10
    /// 读数条的满格：接触面积与压力（框架原始单位，按妙控板实测范围取，D56、D57）
    static let sizeScale: Float = 1.2
    static let pressureScale: Float = 150

    let state: TouchTunerModel.DeviceState
    let thresholds: Thresholds
    let clickStage: Int?

    var body: some View {
        let mm = state.device.surfaceSizeMM
        Card {
            HStack {
                Text(state.device.displayName).font(.subheadline.weight(.semibold))
                Spacer()
                Text(verbatim: "\(Int(mm.width))×\(Int(mm.height)) mm").font(.caption).foregroundStyle(.secondary)
            }
            canvas
            readings
            Divider()
            footer
        }
    }

    private var canvas: some View {
        Canvas { ctx, size in
            var cross = Path()
            cross.move(to: CGPoint(x: size.width / 2, y: 0))
            cross.addLine(to: CGPoint(x: size.width / 2, y: size.height))
            cross.move(to: CGPoint(x: 0, y: size.height / 2))
            cross.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            ctx.stroke(cross, with: .color(.secondary.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            for c in state.contacts {
                // 触控板坐标原点在左下，画布原点在左上；圆点随接触面积变大，达到阈值为强调色
                let p = CGPoint(x: c.position.x * size.width, y: (1 - c.position.y) * size.height)
                let r = Self.dotRadius + CGFloat(min(c.size, Self.sizeScale)) * Self.dotGrowth
                let color: Color = thresholds.passes(size: c.size, pressure: c.pressure) ? .accentColor : .gray
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(color.opacity(0.85)))
                ctx.draw(Text(verbatim: "\(c.id)").font(.caption2.bold()).foregroundStyle(.white), at: p)
            }
        }
        .aspectRatio(state.device.surfaceSizeMM.width / state.device.surfaceSizeMM.height, contentMode: .fit)
        .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.15)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.secondary.opacity(0.4)))
    }

    /// 板上第一根手指的实时读数；没有手指时显示刚抬起那根的峰值
    @ViewBuilder private var readings: some View {
        let c = state.contacts.first
        let peak = c.flatMap { state.peaks[$0.id] } ?? state.lastPeak
        HStack {
            SectionTitle(title: c.map { _ in "当前触点" } ?? "上次触摸（峰值）")
            Spacer()
            if state.contacts.count > 1 {
                Text("另有 \(state.contacts.count - 1) 根手指").font(.caption).foregroundStyle(.secondary)
            }
        }
        Meter(title: "接触面积", note: "按得越实越大。轻点后按住的两下都要达到阈值才打开面板。",
              value: c?.size, peak: peak?.size, threshold: thresholds.size, scale: Self.sizeScale,
              format: { String(format: "%.2f", $0) })
        Meter(title: "压力", note: "触控板报告的压力值，不用按下去也有读数，波动较大。",
              value: c?.pressure, peak: peak?.pressure, threshold: thresholds.pressure, scale: Self.pressureScale,
              format: { String(format: "%.0f", $0) })
        // 没有手指时也占住这一行，面板高度不随触摸变化
        let mm = state.device.surfaceSizeMM
        let density = c.map { String(format: "%.2f", $0.ellipse.density) } ?? "—"
        let ellipse = c.map { String(format: "%.1f × %.1f", $0.ellipse.majorAxis, $0.ellipse.minorAxis) } ?? "—"
        let offset = c.map { String(format: "%+.1f / %+.1f", ($0.position.x - 0.5) * mm.width, ($0.position.y - 0.5) * mm.height) } ?? "—"
        // 只显示在屏幕上，不记录（FR-4.7）
        Text("密度 \(density) · 椭圆 \(ellipse) · 离中心 \(offset) mm")
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            .help(String(localized: "仅供观察，不参与判定。"))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("物理点按")
                Spacer()
                Text(clickTitle).monospacedDigit()
            }
            .help(String(localized: "把触控板真正按下去时系统报告的阶段。轻点后按住的第二下期间按下会放弃唤起。"))
            HStack {
                Text("帧率")
                Spacer()
                Text(rate).monospacedDigit()
            }
            .help(String(localized: "触控板每秒送来的触点帧数，偏低时指示点会显得不跟手。"))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var clickTitle: String {
        switch clickStage ?? 0 {
        case 1: String(localized: "点按")
        case 2: String(localized: "深按")
        default: String(localized: "未按下")
        }
    }

    private var rate: String {
        if let s = state.live { return String(format: "%.1f Hz", s.meanHz) }
        if let s = state.lastTouch {
            let hz = String(format: "%.1f", s.meanHz)
            return String(localized: "上次 \(hz) Hz")
        }
        return "—"
    }
}

/// 一项读数与阈值：条是实时值，细线是本次峰值，竖标是阈值（0 不检查时不画）
private struct Meter: View {
    static let barHeight: CGFloat = 8

    let title: LocalizedStringKey
    let note: LocalizedStringKey
    let value: Float?
    let peak: Float?
    let threshold: Float
    let scale: Float
    let format: (Float) -> String

    var body: some View {
        let shown = value ?? peak
        let reached = shown.map { $0 >= threshold } ?? false
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.callout)
                Spacer()
                Text(shown.map(format) ?? "—")
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(value == nil ? .secondary : .primary)
                Text(threshold > 0 ? String(localized: "阈值 \(format(threshold))") : String(localized: "不检查"))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(minWidth: 64, alignment: .trailing)
            }
            .lineLimit(1)
            GeometryReader { geo in
                let w = geo.size.width
                let x = { (v: Float) in CGFloat(min(max(v / scale, 0), 1)) * w }
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.1))
                    if let shown {
                        Capsule().fill((reached || threshold == 0 ? Color.accentColor : .orange).opacity(value == nil ? 0.45 : 1))
                            .frame(width: max(x(shown), Self.barHeight))
                            .animation(.easeOut(duration: 0.08), value: shown)
                    }
                    if let peak, value != nil {
                        Rectangle().fill(.primary.opacity(0.5)).frame(width: 2).offset(x: x(peak) - 1)
                    }
                    if threshold > 0 {
                        Rectangle().fill(.primary).frame(width: 2, height: Self.barHeight + 6).offset(x: x(threshold) - 1)
                    }
                }
            }
            .frame(height: Self.barHeight)
            .padding(.vertical, 3)  // 阈值竖标上下各伸出 3 pt
            Text(note).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: 判定

private struct JudgementView: View {
    let judgement: TriggerJudgement?
    let thresholds: Thresholds

    /// 行数固定：没有判定、第一下就被挡下时，缺的行显示"—"，面板高度不随判定变化
    var body: some View {
        SectionTitle(title: "上次唤起判定")
        Group {
            if let j = judgement {
                Label {
                    Text(title(j.outcome)).font(.callout.weight(.semibold))
                } icon: {
                    Image(systemName: opened(j) ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(opened(j) ? .green : .orange)
                }
            } else {
                Text("还没有判定。轻点一下后立刻按住试试。").font(.callout).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        reading("第一下", judgement?.tap)
        reading("第二下", judgement?.hold)
    }

    private func opened(_ j: TriggerJudgement) -> Bool {
        if case .opened = j.outcome { true } else { false }
    }

    /// 一下的面积与压力峰值，不到阈值的标橙
    private func reading(_ label: LocalizedStringKey, _ r: TriggerJudgement.Reading?) -> some View {
        let size = r.map { String(format: "%.2f", $0.size) } ?? "—"
        let pressure = r.map { String(format: "%.0f", $0.pressure) } ?? "—"
        return HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text("面积 \(size)").foregroundStyle(r.map { $0.size < thresholds.size } == true ? .orange : .primary)
            Text("压力 \(pressure)").foregroundStyle(r.map { $0.pressure < thresholds.pressure } == true ? .orange : .primary)
        }
        .font(.caption.monospacedDigit())
        .lineLimit(1)
    }

    private func title(_ outcome: TriggerJudgement.Outcome) -> String {
        switch outcome {
        case .opened: String(localized: "已打开面板")
        case .filtered(.light): String(localized: "第一下太轻：接触面积不够")
        case .filtered(.lightPressure): String(localized: "第一下太轻：压力不够")
        case .filtered(.palm), .failed(.palm): String(localized: "接触面积过大，像手掌")
        case .filtered(.typing), .failed(.typing): String(localized: "刚打过字，暂不唤起")
        case .filtered(.typingEdge): String(localized: "刚打过字，边缘暂不唤起")
        case .failed(.light): String(localized: "第二下太轻：接触面积不够")
        case .failed(.lightPressure): String(localized: "第二下太轻：压力不够")
        case .failed(.moved): String(localized: "第二下按住时移动了")
        case .failed(.lifted): String(localized: "第二下没按住就抬起（普通连按）")
        case .failed(.pressed): String(localized: "第二下按下了触控板")
        case .failed(.secondTouch): String(localized: "按住时又落下一根手指")
        }
    }
}

// MARK: 调节

/// 与设置「唤起与手感」中的同名选项是同一份配置，改动立即生效
private struct Adjustments: View {
    let configs: ConfigController

    var body: some View {
        SectionTitle(title: "阈值调节")
        TunerSlider(title: "唤起所需面积", value: binding(configs, \.sizes.minHoldSize), range: Tuning.minHoldSizeRange,
                    step: 0.05, format: { $0 == 0 ? String(localized: "不检查") : String(format: "%.2f", $0) })
        TunerSlider(title: "唤起所需压力", value: binding(configs, \.sizes.minHoldPressure), range: Tuning.minHoldPressureRange,
                    step: 5, format: { $0 == 0 ? String(localized: "不检查") : String(format: "%.0f", $0) })
        TunerSlider(title: "按住多久打开面板", value: binding(configs, \.sizes.tapHoldDelayMs), range: Tuning.tapHoldDelayRange,
                    step: 10, format: { "\(Int($0)) ms" })
        Text("与设置中的同名选项相同，改动立即生效。有意唤起却打不开时调小阈值，误开时调大。")
            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private struct TunerSlider: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(format(value)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            // 不用 step：macOS 会为每一档画刻度，改为写入时取整（同 LabeledSlider）
            Slider(value: makeBinding(get: { value }, set: { value = ($0 / step).rounded() * step }), in: range)
                .controlSize(.small)
        }
    }
}
