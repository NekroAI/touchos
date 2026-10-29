import Foundation

/// 统计一台设备持续触摸时的帧间隔，用于调试叠层显示帧率与 M0 实测（SRS 附录待实测项）。
/// 只统计相邻两帧都有接触的间隔；手指全部离开后开始新的一段。不记录任何坐标（FR-4.7）。
public struct FrameRateMeter: Sendable {
    public struct Summary: Equatable, Sendable {
        public let frames: Int
        public let duration: TimeInterval
        public let meanHz: Double
        public let p95Interval: TimeInterval
        public let maxInterval: TimeInterval
    }

    /// 只保留最近这么多个间隔，限制内存
    public static let capacity = 2048

    private var lastTimestamp: TimeInterval?
    private var intervals: [TimeInterval] = []
    private var frames = 0

    public init() {}

    /// 记录一帧。返回值：若这一帧结束了一段持续触摸（`hasContacts == false` 且此前有接触），返回该段的统计。
    public mutating func observe(timestamp: TimeInterval, hasContacts: Bool) -> Summary? {
        guard hasContacts else {
            defer { reset() }
            return frames > 1 ? summary : nil
        }
        if let last = lastTimestamp {
            intervals.append(timestamp - last)
            if intervals.count > Self.capacity { intervals.removeFirst(intervals.count - Self.capacity) }
        }
        lastTimestamp = timestamp
        frames += 1
        return nil
    }

    /// 当前这段持续触摸的统计；不足两帧时为 nil。
    public var summary: Summary? {
        guard !intervals.isEmpty else { return nil }
        let sorted = intervals.sorted()
        let total = intervals.reduce(0, +)
        let p95 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
        return Summary(frames: frames, duration: total, meanHz: Double(intervals.count) / total,
                       p95Interval: p95, maxInterval: sorted[sorted.count - 1])
    }

    private mutating func reset() {
        lastTimestamp = nil
        intervals.removeAll(keepingCapacity: true)
        frames = 0
    }
}
