import Foundation

/// 锚定区位置（SRS 6.1）：四角之一，或整条左 / 右边缘
public enum AnchorCorner: String, Sendable, CaseIterable {
    case bottomLeft, bottomRight, topLeft, topRight, leftEdge, rightEdge
}

/// 可调参数（SRS 附录参数总表）。默认值为原型前的估计值，M0 闸门时按实测修正。
/// 代码中所有阈值都从这里读取（SRS 0.3）；K8 起由配置文件 `anchor` / `tuning` 段提供。
public struct Tuning: Equatable, Sendable {
    public var anchorCorner = AnchorCorner.bottomLeft
    /// `P.anchorZoneW` / `P.anchorZoneH`：锚定区宽高（触控板比例）
    public var anchorZoneW = 0.12
    public var anchorZoneH = 0.15
    /// `P.dwellMs`
    public var dwellMs = 200.0
    /// `P.stillThresholdMM`
    public var stillThresholdMM = 2.0
    /// `P.palmSize`：nil 表示使用校准值，未校准时用 `defaultPalmSize`（FR-10.8）
    public var palmSize: Float?
    /// `P.mappingMargin`：四周不接受指点指落下的边缘宽度（触控板比例；修订见 decisions.md D9）
    public var mappingMargin = 0.05
    /// `P.mappingScale`：映射区占触控板的比例，宽高同比，居中（decisions.md D9）
    public var mappingScale = 0.6
    public static let mappingScaleRange = 0.4...1.0
    /// `P.hysteresis`（面板比例）
    public var hysteresis = 0.02
    /// `P.liftLookbackMs`
    public var liftLookbackMs = 60.0
    /// `P.panelDelayMs`
    public var panelDelayMs = 200.0
    /// `P.cooldownMs`
    public var cooldownMs = 150.0
    /// `P.momentumSuppressMs`
    public var momentumSuppressMs = 1200.0
    /// `P.frameTimeoutMs`
    public var frameTimeoutMs = 500.0
    /// `P.maxSessionSec`
    public var maxSessionSec = 30.0
    /// `P.actionDelayMs`
    public var actionDelayMs = 30.0
    /// `P.smoothing`
    public var smoothing = 0.5
    /// `P.panelScale`
    public var panelScale = 0.6
    /// `P.trailMs`
    public var trailMs = 300.0
    /// `P.slotGap`（pt）
    public var slotGap = 6.0
    /// `P.minSlotMM`
    public var minSlotMM = 12.0

    /// 未校准时的手掌阈值（接触面积，框架原始单位）。
    /// SPEC-QUESTION: SRS 只说"内置默认值"，没有给数值。这里是估计值，待 M0 实测拇指与手掌的接触面积后修正。
    public static let defaultPalmSize: Float = 3.0

    public init() {}

    public var effectivePalmSize: Float { palmSize ?? Self.defaultPalmSize }
}
