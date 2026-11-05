import AppKit
import SwiftUI
import TouchOSCore

/// 手感调试（D57，取代 D52 的调试叠层入口）：菜单栏常驻入口，实时显示触点读数、唤起阈值与判定结果，可直接调节阈值。
/// 调试模式只决定是否附带排查用的工具（诊断日志、延迟、指针诊断、状态流水）。触点只显示在屏幕上，永不写盘（FR-4.7）
@MainActor
@Observable
final class TouchTunerModel {
    /// 一根手指一次触摸中的峰值
    struct Peak: Equatable {
        var size: Float
        var pressure: Float
    }

    struct DeviceState {
        var device: TrackpadDevice
        var contacts: [Contact] = []
        /// 板上各手指从落下起的峰值
        var peaks: [Int: Peak] = [:]
        /// 最近抬起的手指的峰值：手指离开后仍能读到
        var lastPeak: Peak?
        var live: FrameRateMeter.Summary?
        var lastTouch: FrameRateMeter.Summary?
    }

    var devices: [DeviceState] = []
    var judgement: TriggerJudgement?
    /// 力度触控板最近一次压力事件：阶段（0 无、1 点按、2 深按）与力度
    var pressure: (stage: Int, value: Float)?

    // MARK: 调试模式（D52、D57）

    var debugMode = false
    /// 会话状态、最近一次确认失败或会话结束原因
    var session: [String] = []
    /// 只保留最近 10 条（FR-14.4）
    static let sessionLines = 10
    /// NFR-1 指示点延迟：0.5 ms 一个桶，统计到 100 ms
    static let pointerBucketWidth: TimeInterval = 0.0005
    static let pointerBuckets = 200
    var pointerLatency = LatencyHistogram(bucketWidth: pointerBucketWidth, buckets: pointerBuckets)
    var tapTiming: LatencyHistogram?
    var lastPanelShown: (armToActive: TimeInterval, activeToShown: TimeInterval)?
    /// 指针诊断（D47）：激活态丢弃的指针事件数与校正情况，统计从打开叠层时开始
    var droppedMoves: UInt64 = 0
    var clockResyncs: UInt64 = 0
    var cursor: CursorLock.Diagnostics?

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
        var state = devices[i]
        let touching = frame.contacts.filter(\.isTouching)
        for c in touching {
            let old = c.phase == .began ? nil : state.peaks[c.id]
            state.peaks[c.id] = Peak(size: max(old?.size ?? 0, c.size), pressure: max(old?.pressure ?? 0, c.pressure))
        }
        for id in state.peaks.keys where !touching.contains(where: { $0.id == id }) {
            state.lastPeak = state.peaks.removeValue(forKey: id)
        }
        state.contacts = touching
        if let live { state.live = live }
        if touching.isEmpty, let last = state.live {
            state.lastTouch = last
            state.live = nil
        }
        devices[i] = state
    }
}

@MainActor
final class TouchTunerController {
    /// 可见时刷新拦截耗时与指针诊断的间隔
    static let timingRefreshInterval: TimeInterval = 1
    static let width: CGFloat = 380

    let model = TouchTunerModel()
    private let pipeline: InputPipeline
    private let tap: EventTapController
    private let cursor: CursorLock
    private let configs: ConfigController
    private var panel: NSPanel?
    private var timer: Timer?
    /// 显示或隐藏之后（菜单项打勾）
    var onVisibilityChange: ((Bool) -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    init(pipeline: InputPipeline, tap: EventTapController, cursor: CursorLock, configs: ConfigController) {
        self.pipeline = pipeline
        self.tap = tap
        self.cursor = cursor
        self.configs = configs
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        guard !isVisible else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let model = self.model
        pipeline.setDebugSink { frame, live in
            DispatchQueue.main.async { model.receive(frame, live: live) }
        }
        model.resetLatency()
        tap.resetTiming()
        cursor.resetDiagnostics()
        let tap = self.tap, cursor = self.cursor, pipeline = self.pipeline
        timer = Timer.scheduledTimer(withTimeInterval: Self.timingRefreshInterval, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard model.debugMode else { return }
                model.tapTiming = tap.timingSnapshot()
                model.droppedMoves = tap.droppedActiveMoves
                model.clockResyncs = pipeline.clockResyncs
                model.cursor = cursor.diagnostics
            }
        }
        panel.orderFrontRegardless()
        onVisibilityChange?(true)
    }

    func hide() {
        pipeline.setDebugSink(nil)
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        onVisibilityChange?(false)
    }

    private func makePanel() -> NSPanel {
        let height = (NSScreen.main?.visibleFrame.height ?? 900) - 40
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: height),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // 窗口比内容高，阴影画在卡片上
        // 不激活的面板：点按钮不改变前台应用，否则排查时条件就变了（D52）。透明区域的点击会穿透到下面的窗口
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = TunerHostingView(rootView: TouchTunerView(
            model: model, configs: configs, onClose: { [weak self] in self?.hide() },
            debugActions: DebugActions.make(tap: tap, cursor: cursor, model: model)))
        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: v.maxX - Self.width - 20, y: v.maxY - 20))
        }
        return panel
    }
}

/// 面板不是主窗口，按钮和滑杆要第一下点击就响应；拖动空白处移动面板
private final class TunerHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
}
