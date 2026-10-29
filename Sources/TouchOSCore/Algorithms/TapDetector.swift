import CoreGraphics
import Foundation

/// 多指 / 单指轻点识别（唤起方式实验，decisions.md D19）。
/// 一组触摸从板上没有手指时的第一根手指落下开始，到全部手指抬起结束；全程不超过 `P.tapMaxMs`、
/// 每根手指位移不超过 `P.tapMaxMoveMM` 才算一次轻点。只观察，不拦截任何事件：判定在手指全部抬起之后。
public struct TapDetector: Equatable, Sendable {
    public struct Tap: Equatable, Sendable {
        public let device: TrackpadDeviceID
        public let fingers: Int
        /// 各手指落点的平均位置（触控板归一化坐标，原点左下）
        public let centroid: CGPoint
        public let startedAt: TimeInterval
        public let endedAt: TimeInterval
    }

    private struct Group: Equatable, Sendable {
        let device: TrackpadDeviceID
        let startedAt: TimeInterval
        var origins: [Int: CGPoint]
        /// 已不可能构成轻点（超时、移动过大、开始时板上已有手指），等全部抬起后丢弃
        var valid: Bool
    }

    private var group: Group?

    public init() {}

    public mutating func reset() {
        group = nil
    }

    /// `surfaceMM` 用于把位移换算成毫米。返回在这一帧结束的轻点
    public mutating func feed(_ frame: TouchFrame, surfaceMM: CGSize, maxDuration: TimeInterval, maxMoveMM: Double) -> Tap? {
        if let group, group.device != frame.device { return nil }  // 同一时刻只跟踪一台设备
        let touching = frame.contacts.filter(\.isTouching)
        guard var g = group else {
            guard !touching.isEmpty else { return nil }
            let fresh = touching.allSatisfy { $0.phase == .began }
            group = Group(device: frame.device, startedAt: frame.timestamp,
                          origins: Dictionary(touching.map { ($0.id, $0.position) }, uniquingKeysWith: { a, _ in a }), valid: fresh)
            return nil
        }
        for c in touching {
            guard let origin = g.origins[c.id] else {
                if c.phase == .began { g.origins[c.id] = c.position } else { g.valid = false }
                continue
            }
            let dx = (c.position.x - origin.x) * surfaceMM.width
            let dy = (c.position.y - origin.y) * surfaceMM.height
            if hypot(dx, dy) > maxMoveMM { g.valid = false }
        }
        if frame.timestamp - g.startedAt > maxDuration { g.valid = false }
        guard touching.isEmpty else {
            group = g
            return nil
        }
        group = nil
        guard g.valid, !g.origins.isEmpty else { return nil }
        let n = CGFloat(g.origins.count)
        let sum = g.origins.values.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return Tap(device: g.device, fingers: g.origins.count, centroid: CGPoint(x: sum.x / n, y: sum.y / n),
                   startedAt: g.startedAt, endedAt: frame.timestamp)
    }
}
