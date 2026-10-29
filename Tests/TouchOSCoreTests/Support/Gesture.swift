import Foundation
@testable import TouchOSCore

extension TrackpadDeviceID {
    static let builtIn = TrackpadDeviceID(raw: 1)
    static let external = TrackpadDeviceID(raw: 2)
}

/// 合成触点帧构造器（SRS FR-14.1）：用时间与位置描述手势，再按固定帧率采样成 `TouchFrame` 序列。
///
/// 采样规则模拟输入层（SRS 第 4 章）的输出：
/// - 采样时刻为 `起点 + k / rate`，起点是最早一次落指的时间；事件时间向后取整到采样时刻。
/// - 落指所在的采样帧为 `began`，抬起所在的采样帧为 `ended`（与 `began` 至少相隔一帧）；
///   其间按 FR-4.2 与上一帧比较位移，分为 `moved` / `stationary`。
/// - 手指位置在关键帧之间线性插值，最后一个关键帧之后保持不动。
/// - 每台设备各出一帧；某台设备在某采样时刻没有任何接触时不出帧（私有框架在无接触时停止回调）。
struct Gesture {
    /// 手指默认接触面积（框架原始单位），远小于手掌
    static let fingerSize: Float = 1

    private struct Keyframe {
        let t: TimeInterval
        let position: CGPoint
    }

    private struct Finger {
        let id: Int
        let device: TrackpadDeviceID
        let size: Float
        let pressure: Float
        var keyframes: [Keyframe]
        var liftAt: TimeInterval?

        var lastTime: TimeInterval { keyframes[keyframes.count - 1].t }

        func position(at t: TimeInterval) -> CGPoint {
            guard let next = keyframes.firstIndex(where: { $0.t > t }) else { return keyframes[keyframes.count - 1].position }
            guard next > 0 else { return keyframes[0].position }
            let a = keyframes[next - 1], b = keyframes[next]
            let f = (t - a.t) / (b.t - a.t)
            return CGPoint(x: a.position.x + (b.position.x - a.position.x) * f,
                           y: a.position.y + (b.position.y - a.position.y) * f)
        }
    }

    let device: TrackpadDeviceID
    private var fingers: [Finger] = []

    init(device: TrackpadDeviceID) {
        self.device = device
    }

    /// 手指 `id` 在 `t` 时刻落在 `at`。`device` 缺省为构造器的设备。
    func touch(id: Int, at p: (Double, Double), t: TimeInterval, device: TrackpadDeviceID? = nil,
               size: Float = Gesture.fingerSize, pressure: Float = 0) -> Gesture {
        let device = device ?? self.device
        precondition(activeIndex(id, device) == nil, "手指 \(id) 尚未抬起")
        var g = self
        g.fingers.append(Finger(id: id, device: device, size: size, pressure: pressure,
                                keyframes: [Keyframe(t: t, position: CGPoint(x: p.0, y: p.1))]))
        return g
    }

    /// 手指 `id` 原地保持到 `until`。以下各方法的 `device` 缺省为构造器的设备（手指 ID 按设备区分）。
    func hold(id: Int, until: TimeInterval, device: TrackpadDeviceID? = nil) -> Gesture {
        update(id, device) { f in
            precondition(until >= f.lastTime, "hold 的时间早于手指 \(id) 的上一个关键帧")
            f.keyframes.append(Keyframe(t: until, position: f.keyframes[f.keyframes.count - 1].position))
        }
    }

    /// 手指 `id` 从上一个关键帧起，用 `over` 秒匀速移到 `to`。
    func move(id: Int, to p: (Double, Double), over: TimeInterval, device: TrackpadDeviceID? = nil) -> Gesture {
        update(id, device) { f in
            precondition(over > 0, "move 的时长必须为正")
            f.keyframes.append(Keyframe(t: f.lastTime + over, position: CGPoint(x: p.0, y: p.1)))
        }
    }

    /// 手指 `id` 在 `t` 时刻抬起。
    func lift(id: Int, t: TimeInterval, device: TrackpadDeviceID? = nil) -> Gesture {
        update(id, device) { f in
            precondition(t >= f.lastTime, "抬起时间早于手指 \(id) 的上一个关键帧")
            f.liftAt = t
        }
    }

    /// 按 `rate` Hz 采样成帧序列，按时间排序；同一时刻多台设备时按设备 ID 排序。
    func frames(rate: Double) -> [TouchFrame] {
        precondition(rate > 0 && !fingers.isEmpty)
        let start = fingers.map { $0.keyframes[0].t }.min()!
        // 事件时间向后取整到采样序号；减去极小量，避免浮点误差把恰好落在采样点上的事件推到下一帧
        func index(_ t: TimeInterval) -> Int { Int(((t - start) * rate - 1e-9).rounded(.up)) }
        func time(_ k: Int) -> TimeInterval { start + Double(k) / rate }

        // 每根手指的 [落指帧, 最后一帧]，以及最后一帧是否为抬起
        let spans: [(first: Int, last: Int, lifted: Bool)] = fingers.map { f in
            let first = index(f.keyframes[0].t)
            if let lift = f.liftAt { return (first, max(index(lift), first + 1), true) }
            return (first, max(index(f.lastTime), first), false)
        }
        let lastIndex = spans.map(\.last).max()!
        let devices = Set(fingers.map(\.device)).sorted { $0.raw < $1.raw }

        var frames: [TouchFrame] = []
        for k in 0...lastIndex {
            for device in devices {
                var contacts: [Contact] = []
                for (f, span) in zip(fingers, spans) where f.device == device && (span.first...span.last).contains(k) {
                    let p = f.position(at: time(k))
                    let phase: ContactPhase
                    var velocity = CGVector.zero
                    if k == span.first {
                        phase = .began
                    } else {
                        let prev = f.position(at: time(k - 1))
                        velocity = CGVector(dx: (p.x - prev.x) * rate, dy: (p.y - prev.y) * rate)
                        if k == span.last && span.lifted {
                            phase = .ended
                        } else {
                            phase = hypot(p.x - prev.x, p.y - prev.y) > ContactPhase.movementThreshold ? .moved : .stationary
                        }
                    }
                    contacts.append(Contact(id: f.id, phase: phase, position: p, velocity: velocity,
                                            size: f.size, pressure: f.pressure))
                }
                if !contacts.isEmpty {
                    frames.append(TouchFrame(device: device, timestamp: time(k), contacts: contacts))
                }
            }
        }
        return frames
    }

    private func activeIndex(_ id: Int, _ device: TrackpadDeviceID) -> Int? {
        fingers.lastIndex { $0.id == id && $0.device == device && $0.liftAt == nil }
    }

    private func update(_ id: Int, _ device: TrackpadDeviceID?, _ body: (inout Finger) -> Void) -> Gesture {
        guard let i = activeIndex(id, device ?? self.device) else { preconditionFailure("手指 \(id) 不在板上") }
        var g = self
        body(&g.fingers[i])
        return g
    }
}
