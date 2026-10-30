import Foundation

/// 把设备时钟的时间戳换算到系统单调时钟（D49）。
/// 取"收到时刻 − 设备时间戳"的最小值作为偏移，既保留设备时钟的帧间隔精度，又与其他时间可比。
/// 设备时钟可能暂停或重置，此后最小值不再成立、换算结果一直偏早，所以落后超过 `resyncThreshold` 时重新对齐。
public struct DeviceClockAligner: Equatable, Sendable {
    public let resyncThreshold: TimeInterval
    private var offset: TimeInterval?

    public init(resyncThreshold: TimeInterval) {
        self.resyncThreshold = resyncThreshold
    }

    /// 返回换算后的时间戳，以及这一帧是否触发了重新对齐
    public mutating func align(deviceTime: TimeInterval, received: TimeInterval) -> (timestamp: TimeInterval, resynced: Bool) {
        let sample = received - deviceTime
        guard let current = offset else {
            offset = sample
            return (received, false)
        }
        let resynced = sample - current > resyncThreshold
        let next = resynced ? sample : min(current, sample)
        offset = next
        return (deviceTime + next, resynced)
    }
}
