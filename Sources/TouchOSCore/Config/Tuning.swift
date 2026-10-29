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
    /// `P.mappingScale`：映射区占触控板的比例，宽高同比，居中（decisions.md D9）。
    /// 修订 0.6 → 0.4（D21）：随面板一起缩小，手指移动与屏幕上指示点移动的比例保持不变
    public var mappingScale = 0.4
    public static let mappingScaleRange = 0.3...1.0
    public static let panelScaleRange = 0.3...0.9
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
    /// 常驻模式（交互实验，decisions.md D14）：锚指抬起后面板保留，单指操作
    public var stickyPanel = false
    /// `P.stickyIdleMs`：常驻模式下板上没有手指超过该时长自动关闭
    public var stickyIdleMs = 5000.0
    /// 唤起方式（交互实验，decisions.md D19）：锚指按住、三指 / 四指轻点、单指在角落轻点两下，可同时开启。
    /// 轻点唤起时板上没有锚指，面板直接进入常驻状态（D14）
    public var holdTrigger = true
    public var threeFingerTap = false
    public var fourFingerTap = false
    public var cornerDoubleTap = false
    /// `P.tapMaxMs`：一次轻点从第一根手指落下到全部抬起的最长时长
    public var tapMaxMs = 250.0
    /// `P.tapMaxMoveMM`：轻点期间每根手指的最大位移
    public var tapMaxMoveMM = 3.0
    /// `P.doubleTapGapMs`：角落双击两次轻点之间（前一次抬起到后一次落下）的最长间隔
    public var doubleTapGapMs = 300.0
    /// `P.navDistanceMM`：双指上下移动这么远切换一个面板（D23）
    public var navDistanceMM = 30.0
    /// `P.pinchDistanceMM`：双指间距变化这么多完成一次进入或退出总览
    public var pinchDistanceMM = 25.0
    /// `P.navClassifyMM`：双指位移或间距变化超过该值后判定是切换、捏合还是水平移动
    public var navClassifyMM = 4.0
    /// `P.navProjection`：松手时按速度向前推算落点的时长（秒）
    public var navProjection = 0.18
    /// 面板切换与总览过渡的弹簧：周期（秒）与阻尼比
    public var navResponse = 0.42
    public var navDamping = 0.86
    public var overviewResponse = 0.4
    public var overviewDamping = 0.9
    /// `P.editHoldMs`：在关闭上按住多久进入编辑（D23）
    public var editHoldMs = 600.0
    /// `P.actionDelayMs`
    public var actionDelayMs = 30.0
    /// `P.smoothing`
    public var smoothing = 0.5
    /// `P.panelScale`（修订：0.6 → 0.4，见 decisions.md D20）：按钮组画小、排紧凑。
    /// 触控板到面板是归一化映射，面板在屏幕上的大小不影响手指的移动距离与精度
    public var panelScale = 0.4
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
