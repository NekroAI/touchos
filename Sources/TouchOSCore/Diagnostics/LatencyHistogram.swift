import Foundation

/// 等宽分桶的耗时直方图，用于 NFR-1、NFR-2 实测与调试叠层显示。超出最后一个桶的样本计入溢出桶，最大值单独精确记录。
/// 拦截回调里用原子计数器逐桶累计，再用 `init(bucketWidth:counts:max:)` 组装成快照计算分位数。
public struct LatencyHistogram: Equatable, Sendable {
    public let bucketWidth: TimeInterval
    /// 最后一个元素是溢出桶
    public private(set) var counts: [UInt64]
    public private(set) var max: TimeInterval

    public init(bucketWidth: TimeInterval, buckets: Int) {
        self.init(bucketWidth: bucketWidth, counts: Array(repeating: 0, count: buckets + 1), max: 0)
    }

    public init(bucketWidth: TimeInterval, counts: [UInt64], max: TimeInterval) {
        precondition(bucketWidth > 0 && counts.count >= 2)
        self.bucketWidth = bucketWidth
        self.counts = counts
        self.max = max
    }

    public var count: UInt64 { counts.reduce(0, +) }

    /// 样本所在的桶号；负值计入第一个桶，超出范围计入溢出桶
    public func bucket(of value: TimeInterval) -> Int {
        guard value > 0 else { return 0 }
        return Swift.min(Int(value / bucketWidth), counts.count - 1)
    }

    public mutating func record(_ value: TimeInterval) {
        counts[bucket(of: value)] += 1
        max = Swift.max(max, value)
    }

    /// 分位数（0–1），取所在桶的上界（偏保守）；落在溢出桶时返回最大值。没有样本时为 nil。
    public func percentile(_ p: Double) -> TimeInterval? {
        let total = count
        guard total > 0 else { return nil }
        let target = Swift.max(1, UInt64((Double(total) * p).rounded(.up)))
        var seen: UInt64 = 0
        for (i, c) in counts.enumerated() {
            seen += c
            guard seen >= target else { continue }
            return i == counts.count - 1 ? max : Swift.min(Double(i + 1) * bucketWidth, max)
        }
        return max
    }
}
