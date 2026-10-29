import CoreGraphics
import Foundation

/// 锚定区（SRS 6.1）：触控板归一化坐标中的矩形，原点左下。
public func anchorZone(_ corner: AnchorCorner, width w: Double, height h: Double) -> CGRect {
    switch corner {
    case .bottomLeft: CGRect(x: 0, y: 0, width: w, height: h)
    case .bottomRight: CGRect(x: 1 - w, y: 0, width: w, height: h)
    case .topLeft: CGRect(x: 0, y: 1 - h, width: w, height: h)
    case .topRight: CGRect(x: 1 - w, y: 1 - h, width: w, height: h)
    case .leftEdge: CGRect(x: 0, y: 0, width: w, height: 1)
    case .rightEdge: CGRect(x: 1 - w, y: 0, width: w, height: 1)
    }
}

/// 闭区间包含（锚定区边界上的点算在区内）
func closedContains(_ rect: CGRect, _ p: CGPoint) -> Bool {
    p.x >= rect.minX && p.x <= rect.maxX && p.y >= rect.minY && p.y <= rect.maxY
}

/// 坐标映射（SRS 6.2，按 decisions.md D9 修订）：触控板归一化坐标 → 面板坐标。
/// 映射区是居中、占触控板 `scale` 比例（宽高同比）的矩形，与面板线性绝对映射；映射区以外的坐标钳制到面板边缘，
/// 因此边缘与角落的槽位相当于向外延伸。指点指可以落在四周 `margin` 宽的边缘以内的任何位置。
public struct Mapper: Sendable {
    public let margin: Double
    public let scale: Double

    public init(margin: Double, scale: Double) {
        self.margin = margin
        self.scale = scale
    }

    /// 新接触可以成为指点指的区域（锚定区另行排除，FR-6.5）
    public func acceptsPointerStart(_ p: CGPoint) -> Bool {
        p.x >= margin && p.x <= 1 - margin && p.y >= margin && p.y <= 1 - margin
    }

    /// 映射区（触控板归一化坐标，原点左下）
    public var mappingRect: CGRect {
        CGRect(x: (1 - scale) / 2, y: (1 - scale) / 2, width: scale, height: scale)
    }

    /// 面板归一化坐标（0–1，原点左上，y 向下），越界钳制在边缘
    public func normalizedPanelPoint(_ p: CGPoint) -> CGPoint {
        let r = mappingRect
        let u = min(max((p.x - r.minX) / r.width, 0), 1)
        let v = min(max((p.y - r.minY) / r.height, 0), 1)
        return CGPoint(x: u, y: 1 - v)
    }

    /// 面板坐标（pt，原点左上）
    public func panelPoint(_ p: CGPoint, panelSize: CGSize) -> CGPoint {
        let n = normalizedPanelPoint(p)
        return CGPoint(x: n.x * panelSize.width, y: n.y * panelSize.height)
    }
}

/// 面板尺寸（FR-6.4、FR-8.6）：宽高比等于设备映射区的物理宽高比，取能放入"屏幕可见区域 × 比例"的最大矩形。
/// 映射区宽高按同一比例缩放，物理宽高比与整块触控板相同。
public func panelSize(screen: CGSize, deviceMM: CGSize, scale: Double) -> CGSize {
    let aspect = deviceMM.width / deviceMM.height
    let maxW = screen.width * scale, maxH = screen.height * scale
    return maxW / maxH > aspect ? CGSize(width: maxH * aspect, height: maxH) : CGSize(width: maxW, height: maxW / aspect)
}

/// 命中与滞回（SRS 6.3）。坐标为面板 pt，原点左上。
public struct HitTester: Sendable {
    public let layout: Layout
    public let panelSize: CGSize
    /// `P.slotGap`：每个槽位各内缩的 pt，内缩部分即空隙（FR-10.5）
    public let slotGap: Double
    /// `P.hysteresis`：面板比例
    public let hysteresis: Double

    public init(layout: Layout, panelSize: CGSize, slotGap: Double, hysteresis: Double) {
        self.layout = layout
        self.panelSize = panelSize
        self.slotGap = slotGap
        self.hysteresis = hysteresis
    }

    /// 槽位的绘制矩形（pt）：各边内缩 `slotGap`（FR-10.5）
    public func visualRect(of slot: Slot) -> CGRect {
        let n = layout.normalizedRect(of: slot)
        return CGRect(x: n.minX * panelSize.width, y: n.minY * panelSize.height,
                      width: n.width * panelSize.width, height: n.height * panelSize.height)
            .insetBy(dx: slotGap, dy: slotGap)
    }

    /// 槽位的可命中矩形（pt）：槽位之间保留空隙；贴着面板外边的一侧延伸到面板边界，
    /// 使钳制到边缘的坐标仍能命中边缘槽位（decisions.md D9）
    public func rect(of slot: Slot) -> CGRect {
        let n = layout.normalizedRect(of: slot)
        var r = visualRect(of: slot)
        if n.minX <= 0 { r = CGRect(x: 0, y: r.minY, width: r.maxX, height: r.height) }
        if n.minY <= 0 { r = CGRect(x: r.minX, y: 0, width: r.width, height: r.maxY) }
        if n.maxX >= 1 { r.size.width = panelSize.width - r.minX }
        if n.maxY >= 1 { r.size.height = panelSize.height - r.minY }
        return r
    }

    /// 不带滞回的命中（FR-6.7、FR-6.11）；重叠时取 z 序最后一个（FR-6.9）。nil 表示空隙。
    public func hit(_ p: CGPoint) -> SlotID? {
        layout.slots.last { closedContains(rect(of: $0), p) }?.id
    }

    /// 带滞回的命中（FR-6.8）：只有离开"当前槽位外扩滞回量"的区域后才重新命中。
    public func hit(_ p: CGPoint, current: SlotID?) -> SlotID? {
        if let current, let slot = layout.slot(current) {
            let expanded = rect(of: slot).insetBy(dx: -hysteresis * panelSize.width, dy: -hysteresis * panelSize.height)
            if closedContains(expanded, p) { return current }
        }
        return hit(p)
    }
}

/// 指点指的位置历史与抬起去抖（SRS 6.4）。位置为触控板归一化坐标。
public struct PointerTrack: Equatable, Sendable {
    /// FR-6.10：保留最近 200 ms 的位置
    public static let historyWindow: TimeInterval = 0.2

    public let id: Int
    public private(set) var samples: [(t: TimeInterval, p: CGPoint)] = []

    public init(id: Int, t: TimeInterval, p: CGPoint) {
        self.id = id
        samples = [(t, p)]
    }

    public var latest: CGPoint { samples[samples.count - 1].p }

    public mutating func append(t: TimeInterval, p: CGPoint) {
        samples.append((t, p))
        samples.removeAll { $0.t < t - Self.historyWindow }
    }

    /// 提交坐标：时间戳 ≤ (抬起时刻 − 回看时间) 的最近样本；历史不足时取最早样本（FR-6.10）
    public func commitPoint(liftAt: TimeInterval, lookback: TimeInterval) -> CGPoint {
        samples.last { $0.t <= liftAt - lookback }?.p ?? samples[0].p
    }

    public static func == (a: PointerTrack, b: PointerTrack) -> Bool {
        a.id == b.id && a.samples.elementsEqual(b.samples) { $0.t == $1.t && $0.p == $1.p }
    }
}
