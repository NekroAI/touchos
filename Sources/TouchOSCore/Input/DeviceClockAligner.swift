import Foundation

/// 把设备时钟的时间戳换算到系统单调时钟（D49、D52）。
/// 取"收到时刻 − 设备时间戳"的最小值作为偏移，既保留设备时钟的帧间隔精度，又与其他时间可比。
/// 设备时钟可能暂停、变慢或重置（内置触控板实测反复落后），此后最小值不再成立，
/// 所以每次手指落下都重新对齐，一段触摸中落后超过 `resyncThreshold` 也重新对齐。
public struct DeviceClockAligner: Equatable, Sendable {
    public let resyncThreshold: TimeInterval
    private var offset: TimeInterval?

    public init(resyncThreshold: TimeInterval) {
        self.resyncThreshold = resyncThreshold
    }

    /// 返回换算后的时间戳、这一帧是否因落后超过阈值而重新对齐、对齐前落后多少秒
    public mutating func align(deviceTime: TimeInterval, received: TimeInterval,
                               touchBegan: Bool = false) -> (timestamp: TimeInterval, resynced: Bool, lag: TimeInterval) {
        let sample = received - deviceTime
        guard let current = offset else {
            offset = sample
            return (received, false, 0)
        }
        let lag = sample - current
        let resynced = lag > resyncThreshold
        let next = resynced || touchBegan ? sample : min(current, sample)
        offset = next
        return (deviceTime + next, resynced, lag)
    }
}
