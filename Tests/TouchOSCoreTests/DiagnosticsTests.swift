import Testing
@testable import TouchOSCore

@Suite struct LatencyHistogramTests {
    @Test func emptyHasNoPercentile() {
        let h = LatencyHistogram(bucketWidth: 0.001, buckets: 10)
        #expect(h.count == 0)
        #expect(h.percentile(0.95) == nil)
    }

    @Test func percentileIsBucketUpperBoundCappedByMax() {
        var h = LatencyHistogram(bucketWidth: 0.001, buckets: 10)
        for _ in 0..<99 { h.record(0.0004) }
        h.record(0.0052)
        #expect(h.count == 100)
        #expect(h.percentile(0.5) == 0.001)
        #expect(h.percentile(0.99) == 0.001)
        #expect(h.percentile(1.0) == 0.0052)  // 桶上界 0.006 被最大值截断
        #expect(h.max == 0.0052)

        var single = LatencyHistogram(bucketWidth: 0.001, buckets: 10)
        single.record(0.0003)
        #expect(single.percentile(0.5) == 0.0003)  // 桶上界不超过实际最大值
    }

    @Test func overflowAndNegativeSamples() {
        var h = LatencyHistogram(bucketWidth: 0.001, buckets: 2)
        h.record(-1)
        h.record(0.5)
        #expect(h.counts == [1, 0, 1])
        #expect(h.percentile(1.0) == 0.5)
        #expect(h.bucket(of: 0.0015) == 1)
    }

    @Test func snapshotFromCounts() {
        let h = LatencyHistogram(bucketWidth: 0.001, counts: [0, 3, 1], max: 0.004)
        #expect(h.percentile(0.5) == 0.002)
        #expect(h.percentile(1.0) == 0.004)
    }
}
