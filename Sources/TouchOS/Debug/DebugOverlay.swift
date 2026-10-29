import AppKit
import SwiftUI
import TouchOSCore

/// 调试叠层（SRS FR-14.4）：每台设备的实时触点与帧率。只在内存中显示，永不写盘（FR-4.7）。
/// 另显示最近 10 条状态转移、候选失败与会话结束原因；拦截耗时待加入。
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

    static var isAvailable: Bool {
        #if DEBUG
        true
        #else
        UserDefaults.standard.bool(forKey: hiddenSwitchKey)
        #endif
    }

    let model = DebugOverlayModel()
    private let pipeline: InputPipeline
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    init(pipeline: InputPipeline) {
        self.pipeline = pipeline
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
        panel.orderFrontRegardless()
    }

    private func hide() {
        pipeline.setDebugSink(nil)
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 520),
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
