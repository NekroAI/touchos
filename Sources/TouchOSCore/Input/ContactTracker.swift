import CoreGraphics
import Foundation

/// 私有框架给出的一个接触，已从 C 结构体拷贝出来；`state` 为框架原始状态码。
public struct RawContact: Equatable, Sendable {
    public let id: Int
    public let state: Int
    public let position: CGPoint        // 归一化 0–1，原点左下
    public let velocity: CGVector       // 归一化单位/秒
    public let size: Float
    public let pressure: Float
    public let ellipse: ContactEllipse

    public init(id: Int, state: Int, position: CGPoint, velocity: CGVector, size: Float, pressure: Float,
                ellipse: ContactEllipse = ContactEllipse()) {
        self.ellipse = ellipse
        self.id = id
        self.state = state
        self.position = position
        self.velocity = velocity
        self.size = size
        self.pressure = pressure
    }
}

/// 私有框架的原始状态码（SRS FR-4.2）。1、2、6、7（悬停、离开感应范围等）及未列出的状态码一律忽略。
public enum RawContactState {
    public static let began = 3
    public static let touching = 4
    public static let ended = 5
}

/// 把一台设备的原始接触序列转换为 `Contact`（SRS FR-4.2、FR-4.3）。每台设备一个实例，只在 input.queue 上使用。
public struct ContactTracker: Sendable {
    /// 上一帧仍在接触中的手指
    private var touching: [Int: Contact] = [:]

    public init() {}

    public mutating func process(_ raw: [RawContact]) -> [Contact] {
        var contacts: [Contact] = []
        var seen = Set<Int>()
        for r in raw {
            let phase: ContactPhase
            switch r.state {
            case RawContactState.began:
                phase = .began
            case RawContactState.touching:
                if let prev = touching[r.id] {
                    let moved = hypot(r.position.x - prev.position.x, r.position.y - prev.position.y) > ContactPhase.movementThreshold
                    phase = moved ? .moved : .stationary
                } else {
                    // SPEC-QUESTION: FR-4.2 没有规定"接触中"却没有上一帧（例如在手指已在板上时才注册回调）的情况。
                    // 按字面理解为位移为 0 → stationary；该接触没有 began，因此不会成为唤起的第二下或指点指。
                    phase = .stationary
                }
            case RawContactState.ended:
                phase = .ended
            default:
                continue
            }
            let contact = Contact(id: r.id, phase: phase, position: r.position, velocity: r.velocity,
                                  size: r.size, pressure: r.pressure, ellipse: r.ellipse)
            contacts.append(contact)
            seen.insert(r.id)
            touching[r.id] = phase == .ended ? nil : contact
        }
        // FR-4.3：未经 ended 就消失的接触补发 cancelled
        for id in touching.keys.sorted() where !seen.contains(id) {
            let last = touching.removeValue(forKey: id)!
            contacts.append(Contact(id: id, phase: .cancelled, position: last.position, velocity: .zero,
                                    size: last.size, pressure: last.pressure, ellipse: last.ellipse))
        }
        return contacts
    }
}

/// 启动自检（SRS FR-4.1）：连续若干帧出现归一化坐标落在 0–1 以外，判定接触结构体布局与本机系统不符。
/// 只统计含有效接触（FR-4.2 列出的状态码）的帧；有效接触全部在范围内的帧使计数清零。
public struct LayoutSelfCheck: Sendable {
    public static let mismatchFrames = 30

    private var consecutive = 0

    public init() {}

    /// 返回 true 表示已判定布局不符。
    public mutating func observe(_ raw: [RawContact]) -> Bool {
        let valid = raw.filter { [RawContactState.began, RawContactState.touching, RawContactState.ended].contains($0.state) }
        guard !valid.isEmpty else { return consecutive >= Self.mismatchFrames }
        let outOfRange = valid.contains { !(0...1).contains($0.position.x) || !(0...1).contains($0.position.y) }
        consecutive = outOfRange ? consecutive + 1 : 0
        return consecutive >= Self.mismatchFrames
    }
}
