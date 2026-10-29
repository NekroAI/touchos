import AppKit
import SwiftUI
import TouchOSCore

/// 调试叠层（SRS FR-14.4）：每台设备的实时触点与帧率。只在内存中显示，永不写盘（FR-4.7）。
/// 另显示最近 10 条状态转移、候选失败与会话结束原因，以及延迟实测（NFR-1、NFR-2、AC-1），统计从打开叠层时开始。
@MainActor
@Observable
final class DebugOverlayModel {
    struct DeviceState {
        var device: TrackpadDevice
        var contacts: [Contact] = []
        var live: FrameRateMeter.Summary?
        var lastTouch: FrameRateMeter.Summary?
    }

    var devices: [DeviceState] = []
    var status = ""
    /// 会话状态、最近一次候选失败或会话结束原因
    var session: [String] = []

    /// 只保留最近 10 条（FR-14.4）
    static let sessionLines = 10
    /// NFR-1 指示点延迟：0.5 ms 一个桶，统计到 100 ms
    static let pointerBucketWidth: TimeInterval = 0.0005
    static let pointerBuckets = 200

    var pointerLatency = LatencyHistogram(bucketWidth: pointerBucketWidth, buckets: pointerBuckets)
    var tapTiming: LatencyHistogram?
    var lastPanelShown: (anchorToActive: TimeInterval, activeToShown: TimeInterval)?

    func record(_ sample: LatencySample) {
        switch sample {
        case .pointer(let t): pointerLatency.record(t)
        case .panelShown(let a, let b): lastPanelShown = (a, b)
        }
    }

    func resetLatency() {
        pointerLatency = LatencyHistogram(bucketWidth: Self.pointerBucketWidth, buckets: Self.pointerBuckets)
        tapTiming = nil
        lastPanelShown = nil
    }

    func log(_ line: String) {
        session.append(line)
        if session.count > Self.sessionLines { session.removeFirst(session.count - Self.sessionLines) }
    }

    func setDevices(_ list: [TrackpadDevice]) {
        devices = list.map { d in devices.first { $0.device.id == d.id } ?? DeviceState(device: d) }
    }

    func receive(_ frame: TouchFrame, live: FrameRateMeter.Summary?) {
        guard let i = devices.firstIndex(where: { $0.device.id == frame.device }) else { return }
        let touching = frame.contacts.filter { $0.phase != .ended && $0.phase != .cancelled }
        devices[i].contacts = touching
        if let live { devices[i].live = live }
        if touching.isEmpty, let last = devices[i].live {
            devices[i].lastTouch = last
            devices[i].live = nil
        }
    }
}

@MainActor
final class DebugOverlayController {
    /// 隐藏开关：发布构建中 `defaults write ai.nekro.touchos showDebugOverlayMenu -bool true` 后菜单出现该项
    static let hiddenSwitchKey = "showDebugOverlayMenu"
    /// 叠层可见时刷新拦截耗时统计的间隔
    static let timingRefreshInterval: TimeInterval = 1

    static var isAvailable: Bool {
        #if DEBUG
        true
        #else
        UserDefaults.standard.bool(forKey: hiddenSwitchKey)
        #endif
    }

    let model = DebugOverlayModel()
    private let pipeline: InputPipeline
    private let tap: EventTapController
    private var panel: NSPanel?
    private var timer: Timer?

    var isVisible: Bool { panel?.isVisible ?? false }

    init(pipeline: InputPipeline, tap: EventTapController) {
        self.pipeline = pipeline
        self.tap = tap
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let model = self.model
        pipeline.setDebugSink { frame, live in
            DispatchQueue.main.async { model.receive(frame, live: live) }
        }
        model.resetLatency()
        tap.resetTiming()
        let tap = self.tap
        timer = Timer.scheduledTimer(withTimeInterval: Self.timingRefreshInterval, repeats: true) { _ in
            MainActor.assumeIsolated { model.tapTiming = tap.timingSnapshot() }
        }
        panel.orderFrontRegardless()
    }

    private func hide() {
        pipeline.setDebugSink(nil)
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 600),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: DebugOverlayView(model: model))
        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: v.maxX - 380, y: v.maxY - 20))
        }
        return panel
    }
}

private struct DebugOverlayView: View {
    let model: DebugOverlayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TouchOS 调试叠层").font(.headline)
            if !model.status.isEmpty {
                Text(model.status).foregroundStyle(.orange)
            }
            if model.devices.isEmpty {
                Text("没有启用的触控板").foregroundStyle(.secondary)
            }
            ForEach(model.devices, id: \.device.id) { state in
                DeviceSection(state: state)
            }
            LatencySection(model: model)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(model.session.enumerated()), id: \.offset) { _, line in Text(line) }
            }
            .frame(height: CGFloat(DebugOverlayModel.sessionLines) * 15, alignment: .top)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(12)
        .frame(width: 360, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct DeviceSection: View {
    static let contactRows = 3
    static let lineHeight: CGFloat = 15

    let state: DebugOverlayModel.DeviceState

    var body: some View {
        let size = state.device.surfaceSizeMM
        VStack(alignment: .leading, spacing: 4) {
            Text("\(state.device.displayName) · \(Int(size.width))×\(Int(size.height)) mm · \(String(state.device.id.raw))")
            Canvas { ctx, canvas in
                for c in state.contacts {
                    // 触控板坐标原点在左下，画布原点在左上
                    let p = CGPoint(x: c.position.x * canvas.width, y: (1 - c.position.y) * canvas.height)
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)), with: .color(.accentColor))
                    ctx.draw(Text("\(c.id)").font(.caption2).foregroundStyle(.white), at: p)
                }
            }
            .aspectRatio(size.width / size.height, contentMode: .fit)
            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary))
            // 文字区固定行数，触摸时不挤压上方的触控板区域
            VStack(alignment: .leading, spacing: 2) {
                ForEach(state.contacts.prefix(Self.contactRows), id: \.id) { c in
                    Text("#\(c.id) \(String(describing: c.phase)) size \(c.size, format: .number.precision(.fractionLength(2))) pressure \(c.pressure, format: .number.precision(.fractionLength(2)))")
                }
            }
            .frame(height: CGFloat(Self.contactRows) * Self.lineHeight, alignment: .top)
            Text("持续触摸 \(state.live.map(rate) ?? "—")")
            Text("上一段 \(state.lastTouch.map(rate) ?? "—")").foregroundStyle(.secondary)
        }
    }

    private func rate(_ s: FrameRateMeter.Summary) -> String {
        String(format: "%.1f Hz · p95 %.1f ms · max %.1f ms · %d 帧", s.meanHz, s.p95Interval * 1000, s.maxInterval * 1000, s.frames)
    }
}

/// 延迟实测（NFR-1、NFR-2、AC-1）
private struct LatencySection: View {
    let model: DebugOverlayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("指示点 \(summary(model.pointerLatency, p: 0.95, label: "p95"))")
            Text("拦截回调 \(model.tapTiming.map { summary($0, p: 0.99, label: "p99", micro: true) } ?? "—")")
            if let s = model.lastPanelShown {
                Text(String(format: "锚定→激活 %.0f ms · 激活→面板 %.0f ms", s.anchorToActive * 1000, s.activeToShown * 1000))
            } else {
                Text("锚定→激活 — · 激活→面板 —")
            }
        }
    }

    private func summary(_ h: LatencyHistogram, p: Double, label: String, micro: Bool = false) -> String {
        guard let v = h.percentile(p) else { return "—" }
        let (scale, unit) = micro ? (1e6, "µs") : (1e3, "ms")
        return String(format: "%@ %.1f %@ · max %.1f %@ · %llu 次", label, v * scale, unit, h.max * scale, unit, h.count)
    }
}
