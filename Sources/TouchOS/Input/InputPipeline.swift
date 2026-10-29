import Foundation
import OSLog
import TouchOSCore

/// input.queue 上的输入处理（SRS 2.3）：原始接触 → `TouchFrame`（FR-4.2、4.3）、布局自检（FR-4.1）、帧率统计。
/// 私有框架回调经 `enqueue` 投递到串行队列（libdispatch 入队无锁），回调线程不加锁、不等待。
/// 除 `queue` 外的状态只在 `queue` 上访问。
final class InputPipeline: @unchecked Sendable {
    let queue = DispatchQueue(label: "ai.nekro.touchos.input", qos: .userInteractive)

    typealias DebugSink = @Sendable (TouchFrame, FrameRateMeter.Summary?) -> Void

    private let log = Logger(subsystem: TouchOSCore.logSubsystem, category: "input")
    private let onFrame: @Sendable (TouchFrame) -> Void
    private let onLayoutMismatch: @Sendable () -> Void

    private var activeDevices: Set<TrackpadDeviceID> = []
    private var trackers: [TrackpadDeviceID: ContactTracker] = [:]
    private var selfChecks: [TrackpadDeviceID: LayoutSelfCheck] = [:]
    private var meters: [TrackpadDeviceID: FrameRateMeter] = [:]
    private var layoutMismatch = false
    private var debugSink: DebugSink?

    /// `onFrame`、`onLayoutMismatch` 在 input.queue 上调用。
    init(onFrame: @escaping @Sendable (TouchFrame) -> Void, onLayoutMismatch: @escaping @Sendable () -> Void) {
        self.onFrame = onFrame
        self.onLayoutMismatch = onLayoutMismatch
    }

    /// 在私有框架回调线程上调用。
    func enqueue(device: TrackpadDeviceID, timestamp: TimeInterval, raw: [RawContact]) {
        queue.async { self.process(device: device, timestamp: timestamp, raw: raw) }
    }

    /// 设置当前启用的设备；其他设备的帧（例如停止注册前仍在途中的帧）一律丢弃，其跟踪状态清空。
    func setActiveDevices(_ ids: Set<TrackpadDeviceID>) {
        queue.async {
            self.activeDevices = ids
            for id in self.trackers.keys where !ids.contains(id) {
                self.trackers[id] = nil
                self.selfChecks[id] = nil
                self.meters[id] = nil
            }
        }
    }

    /// 调试叠层订阅（FR-14.4）；nil 取消订阅。数据只在内存中流转，不写盘（FR-4.7）。
    func setDebugSink(_ sink: DebugSink?) {
        queue.async { self.debugSink = sink }
    }

    private func process(device: TrackpadDeviceID, timestamp: TimeInterval, raw: [RawContact]) {
        guard !layoutMismatch, activeDevices.contains(device) else { return }
        if selfChecks[device, default: LayoutSelfCheck()].observe(raw) {
            layoutMismatch = true
            log.error("contact layout self-check failed; input disabled")
            onLayoutMismatch()
            return
        }
        let contacts = trackers[device, default: ContactTracker()].process(raw)
        guard !contacts.isEmpty else { return }
        let frame = TouchFrame(device: device, timestamp: timestamp, contacts: contacts)

        // 一段持续触摸以所有接触 ended / cancelled 的那一帧结束
        let stillTouching = contacts.contains { $0.phase != .ended && $0.phase != .cancelled }
        var meter = meters[device, default: FrameRateMeter()]
        _ = meter.observe(timestamp: timestamp, hasContacts: true)
        let live = debugSink == nil ? nil : meter.summary
        if !stillTouching, let s = meter.observe(timestamp: timestamp, hasContacts: false) {
            log.info("touch: device \(device.raw, privacy: .public) frames \(s.frames, privacy: .public) duration \(s.duration, format: .fixed(precision: 3), privacy: .public)s mean \(s.meanHz, format: .fixed(precision: 1), privacy: .public)Hz p95 \(s.p95Interval * 1000, format: .fixed(precision: 1), privacy: .public)ms max \(s.maxInterval * 1000, format: .fixed(precision: 1), privacy: .public)ms")
        }
        meters[device] = meter

        onFrame(frame)
        debugSink?(frame, live)
    }
}
