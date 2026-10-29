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

/// 坐标映射（SRS 6.2，按 decisions.md D9、D21 修订）：触控板归一化坐标 → 面板坐标。
/// 映射区是居中、占触控板 `scale` 比例（宽高同比）的矩形，与面板线性绝对映射。映射区以外不命中任何槽位，
/// 在那里抬起即关闭面板（D21）；指示点照常画在面板之外（D15）。指点指可以落在四周 `margin` 宽的边缘以内的任何位置。
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

    /// 点是否在映射区内（含边界）
    public func contains(_ p: CGPoint) -> Bool {
        closedContains(mappingRect, p)
    }

    /// 面板归一化坐标（0–1，原点左上，y 向下），越界钳制在边缘
    public func normalizedPanelPoint(_ p: CGPoint) -> CGPoint {
        let r = mappingRect
        let u = min(max((p.x - r.minX) / r.width, 0), 1)
        let v = min(max((p.y - r.minY) / r.height, 0), 1)
        return CGPoint(x: u, y: 1 - v)
    }

    /// 不钳制的面板坐标（pt，原点左上）：映射区以外落在面板之外，用于显示指示点的真实位置（decisions.md D15）
    public func unclampedPanelPoint(_ p: CGPoint, panelSize: CGSize) -> CGPoint {
        let r = mappingRect
        return CGPoint(x: (p.x - r.minX) / r.width * panelSize.width, y: (1 - (p.y - r.minY) / r.height) * panelSize.height)
    }

    /// 整块触控板对应的显示范围相对面板每边多出的宽度（pt）
    public func overscan(panelSize: CGSize) -> CGSize {
        CGSize(width: (1 - scale) / 2 / scale * panelSize.width, height: (1 - scale) / 2 / scale * panelSize.height)
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

    /// 扇区的圆心与单位半径（pt）：面板中心、短边的一半
    public var center: CGPoint { CGPoint(x: panelSize.width / 2, y: panelSize.height / 2) }
    public var unitRadius: Double { min(panelSize.width, panelSize.height) / 2 }

    /// 矩形类槽位的绘制矩形（pt）：各边内缩 `slotGap`（FR-10.5）；扇区为 nil
    public func visualRect(of slot: Slot) -> CGRect? {
        guard let n = layout.normalizedRect(of: slot) else { return nil }
        return CGRect(x: n.minX * panelSize.width, y: n.minY * panelSize.height,
                      width: n.width * panelSize.width, height: n.height * panelSize.height)
            .insetBy(dx: slotGap, dy: slotGap)
    }

    /// 矩形类槽位的可命中矩形（pt）：槽位之间保留空隙；贴着面板外边的一侧延伸到面板边界，
    /// 使钳制到边缘的坐标仍能命中边缘槽位（decisions.md D9）
    public func rect(of slot: Slot) -> CGRect? {
        guard let n = layout.normalizedRect(of: slot), var r = visualRect(of: slot) else { return nil }
        if n.minX <= 0 { r = CGRect(x: 0, y: r.minY, width: r.maxX, height: r.height) }
        if n.minY <= 0 { r = CGRect(x: r.minX, y: 0, width: r.width, height: r.maxY) }
        if n.maxX >= 1 { r.size.width = panelSize.width - r.minX }
        if n.maxY >= 1 { r.size.height = panelSize.height - r.minY }
        return r
    }

    /// 点相对面板中心的角度：0 为正上方，顺时针，0..<360
    public func angle(of p: CGPoint) -> Double {
        let deg = atan2(p.x - center.x, center.y - p.y) * 180 / .pi
        return deg < 0 ? deg + 360 : deg
    }

    /// 点是否落在槽位内。`expand`（pt）为正时向外扩（滞回），为 0 时按空隙内缩后的形状判定。
    func contains(_ slot: Slot, _ p: CGPoint, expandX: Double = 0, expandY: Double = 0) -> Bool {
        switch slot.shape {
        case .cell, .rect:
            guard let r = rect(of: slot) else { return false }
            return closedContains(r.insetBy(dx: -expandX, dy: -expandY), p)
        case .sector(let s):
            let d = hypot(p.x - center.x, p.y - center.y)
            let inset = slotGap - expandX
            if s.innerRadius > 0, d < s.innerRadius * unitRadius + inset { return false }
            if let outer = s.outerRadius, d > outer * unitRadius - inset { return false }
            guard !s.isFullCircle else { return true }
            // 空隙按弧长换算成角度：离圆心越近，同样宽的空隙占的角度越大
            let halfGap = inset / max(d, 1) * 180 / .pi
            var a = (angle(of: p) - s.startAngle).truncatingRemainder(dividingBy: 360)
            if a < 0 { a += 360 }
            return a >= halfGap && a <= s.endAngle - s.startAngle - halfGap
        }
    }

    /// 不带滞回的命中（FR-6.7、FR-6.11）；重叠时取 z 序最后一个（FR-6.9）。nil 表示空隙。
    public func hit(_ p: CGPoint) -> SlotID? {
        layout.slots.last { contains($0, p) }?.id
    }

    /// 带滞回的命中（FR-6.8）：只有离开"当前槽位外扩滞回量"的区域后才重新命中。
    public func hit(_ p: CGPoint, current: SlotID?) -> SlotID? {
        if let current, let slot = layout.slot(current),
           contains(slot, p, expandX: hysteresis * panelSize.width, expandY: hysteresis * panelSize.height) {
            return current
        }
        return hit(p)
    }

    /// 滑杆槽位上某点对应的数值（0–1）：宽大于高时从左到右，否则从下到上；越界钳制
    public func sliderValue(of slot: Slot, at p: CGPoint) -> Double? {
        guard slot.slider != nil, let r = visualRect(of: slot), r.width > 0, r.height > 0 else { return nil }
        let v = r.width >= r.height ? (p.x - r.minX) / r.width : (r.maxY - p.y) / r.height
        return min(max(v, 0), 1)
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
