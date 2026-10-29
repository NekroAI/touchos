import CoreGraphics
import Foundation

/// 跟手与弹簧过渡（decisions.md D23）。用闭式解表示：核心据此判定是否停稳、命中，
/// 浮层在每一帧用同一时钟求值，二者看到的位置完全一致；过渡中被手指打断时，从当前值与速度接着跟手。
public struct Motion: Equatable, Sendable {
    public let from: Double
    public let velocity: Double
    public let target: Double
    public let start: TimeInterval
    /// 周期（秒）与阻尼比
    public let response: Double
    public let damping: Double

    /// 停稳判定：位置与速度都足够小
    static let settleDistance = 0.002
    static let settleVelocity = 0.02

    public init(from: Double, velocity: Double = 0, to target: Double, start: TimeInterval, response: Double, damping: Double) {
        self.from = from
        self.velocity = velocity
        self.target = target
        self.start = start
        self.response = response
        self.damping = damping
    }

    /// 静止在某个值（跟手时每帧用它表示手指给出的位置）
    public static func at(_ value: Double) -> Motion {
        Motion(from: value, to: value, start: 0, response: 1, damping: 1)
    }

    private var omega: Double { 2 * .pi / response }

    public func value(at t: TimeInterval) -> Double {
        let tau = max(0, t - start), a = from - target, w = omega
        guard a != 0 || velocity != 0 else { return target }
        if damping < 1 {
            let wd = w * (1 - damping * damping).squareRoot()
            let b = (velocity + damping * w * a) / wd
            return target + exp(-damping * w * tau) * (a * cos(wd * tau) + b * sin(wd * tau))
        }
        return target + (a + (velocity + w * a) * tau) * exp(-w * tau)
    }

    public func velocity(at t: TimeInterval) -> Double {
        let tau = max(0, t - start), a = from - target, w = omega
        guard a != 0 || velocity != 0 else { return 0 }
        if damping < 1 {
            let z = damping, wd = w * (1 - z * z).squareRoot()
            let b = (velocity + z * w * a) / wd
            let e = exp(-z * w * tau)
            return e * ((b * wd - z * w * a) * cos(wd * tau) - (a * wd + z * w * b) * sin(wd * tau))
        }
        let c = velocity + w * a
        return (c - w * (a + c * tau)) * exp(-w * tau)
    }

    public func isSettled(at t: TimeInterval) -> Bool {
        abs(value(at: t) - target) < Self.settleDistance && abs(velocity(at: t)) < Self.settleVelocity
    }
}

/// 超出范围时的阻力：越往外拉越难拉，最多再拉出约 1 / `stiffness`
public func rubberBand(_ x: Double, in range: ClosedRange<Double>, stiffness c: Double = 0.55) -> Double {
    func band(_ d: Double) -> Double { d * c / (1 + c * d) }
    if x < range.lowerBound { return range.lowerBound - band(range.lowerBound - x) }
    if x > range.upperBound { return range.upperBound + band(x - range.upperBound) }
    return x
}

/// 总览（D23）：所有面板按网格缩小排在面板区域内。核心按它判定指向哪个面板，浮层按它摆放缩略图
public struct OverviewGrid: Equatable, Sendable {
    public let count: Int
    public let panelSize: CGSize

    /// 缩略图在各自格子里所占的比例，四周留出缝
    public static let fill = 0.86

    public init(count: Int, panelSize: CGSize) {
        self.count = count
        self.panelSize = panelSize
    }

    public var cols: Int { max(1, Int(Double(count).squareRoot().rounded(.up))) }
    public var rows: Int { max(1, (count + cols - 1) / cols) }
    /// 缩略图相对面板的缩放
    public var scale: Double { Self.fill / Double(max(cols, rows)) }

    /// 第 `index` 个缩略图的中心（面板 pt，原点左上）；最后一行不满时居中
    public func center(of index: Int) -> CGPoint {
        let row = index / cols, col = index % cols
        let inRow = row == rows - 1 ? count - row * cols : cols
        let cellW = panelSize.width / Double(cols), cellH = panelSize.height / Double(rows)
        let offset = Double(cols - inRow) * cellW / 2
        return CGPoint(x: offset + (Double(col) + 0.5) * cellW, y: (Double(row) + 0.5) * cellH)
    }

    /// 点（面板 pt）落在哪个缩略图上
    public func index(at p: CGPoint) -> Int? {
        let w = panelSize.width * scale, h = panelSize.height * scale
        return (0..<count).first { i in
            let c = center(of: i)
            return abs(p.x - c.x) <= w / 2 && abs(p.y - c.y) <= h / 2
        }
    }
}
