// 只使用 CoreGraphics 的几何类型（CGPoint 等）；FR-3.2 禁止的是 CGEvent 等事件类型
import CoreGraphics
import Foundation

// 触点数据模型（SRS 4.2）。坐标为触控板归一化坐标：x、y 均在 0–1，原点左下，y 向上（SRS 0.5）。

public struct TrackpadDeviceID: Hashable, Sendable {
    public let raw: UInt64

    public init(raw: UInt64) {
        self.raw = raw
    }
}

/// 一块物理触控板（内置或外接妙控板）
public struct TrackpadDevice: Equatable, Sendable {
    public let id: TrackpadDeviceID
    public let isBuiltIn: Bool
    public let displayName: String      // "内置触控板" / "妙控板"
    public let surfaceSizeMM: CGSize    // 物理宽高，单位毫米

    public init(id: TrackpadDeviceID, isBuiltIn: Bool, displayName: String, surfaceSizeMM: CGSize) {
        self.id = id
        self.isBuiltIn = isBuiltIn
        self.displayName = displayName
        self.surfaceSizeMM = surfaceSizeMM
    }
}

public enum ContactPhase: Equatable, Sendable {
    case began, moved, stationary, ended, cancelled

    /// 接触中的帧与上一帧相比，位移超过该值（归一化单位）记为 `moved`，否则为 `stationary`（SRS FR-4.2）
    public static let movementThreshold: Double = 0.001
}

public struct Contact: Equatable, Sendable {
    public let id: Int                  // 同一手指在接触期间保持不变
    public let phase: ContactPhase
    public let position: CGPoint        // 归一化 0–1，原点左下
    public let velocity: CGVector       // 归一化单位/秒
    public let size: Float              // 接触面积（框架原始单位）
    public let pressure: Float          // 力度触控板可用，否则为 0

    public init(id: Int, phase: ContactPhase, position: CGPoint, velocity: CGVector, size: Float, pressure: Float) {
        self.id = id
        self.phase = phase
        self.position = position
        self.velocity = velocity
        self.size = size
        self.pressure = pressure
    }
}

public struct TouchFrame: Equatable, Sendable {
    public let device: TrackpadDeviceID
    public let timestamp: TimeInterval  // 设备单调时钟，单位秒，只用于算间隔
    public let contacts: [Contact]

    public init(device: TrackpadDeviceID, timestamp: TimeInterval, contacts: [Contact]) {
        self.device = device
        self.timestamp = timestamp
        self.contacts = contacts
    }
}
