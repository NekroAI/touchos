import Foundation

/// 锚定区位置（SRS 6.1）：四角之一，或整条左 / 右边缘
public enum AnchorCorner: String, Sendable, CaseIterable {
    case bottomLeft, bottomRight, topLeft, topRight, leftEdge, rightEdge
}

/// 可调参数（SRS 附录参数总表）。默认值为原型前的估计值，M0 闸门时按实测修正。
/// 代码中所有阈值都从这里读取（SRS 0.3）；K8 起由配置文件 `anchor` / `tuning` 段提供。
public struct Tuning: Equatable, Sendable {
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
    /// 相邻按钮判定区之间不触发的空隙（触控板毫米），面板外沿也留同样宽的一圈（decisions.md D31）
    public var hitGapMM = 2.5
    public static let hitGapRange = 0.0...5.0
    /// `P.liftLookbackMs`
    public var liftLookbackMs = 60.0
    /// 指点指抬起后等这么久再执行；期间手指在抬起点 `liftReturnMM` 以内落回则当作没抬起，接着移动（D36）
    public var liftGraceMs = 100.0
    public var liftReturnMM = 15.0
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
    /// 唤起方式（D19、D25、D26）：可以同时开启多种，每种可以绑定不同的面板。
    /// 轻点唤起时板上没有锚指，面板直接进入常驻状态（D14）
    /// 锚指按住：启用的角（SRS 默认只有左下角）
    public var holdCorners: [AnchorCorner] = [.bottomLeft]
    /// 单指在角落轻点两下：启用的角
    public var doubleTapCorners: [AnchorCorner] = []
    public var threeFingerTap = false
    public var fourFingerTap = false
    /// 轻点后按住（D25）
    public var tapHold = false
    /// `P.tapHoldReachMM`：轻点后按住的第二次落点与第一次轻点的最大距离
    public var tapHoldReachMM = 10.0
    /// `P.tapHoldMinMs`：轻点后按住时第二根手指至少停留多久，抬起才执行；0 为不限制（D25，默认不启用）
    public var tapHoldMinMs = 0.0
    /// `P.tapMaxMs`：一次轻点从第一根手指落下到全部抬起的最长时长
    public var tapMaxMs = 250.0
    /// `P.tapMaxMoveMM`：轻点期间每根手指的最大位移
    public var tapMaxMoveMM = 3.0
    /// `P.doubleTapGapMs`：角落双击、轻点后按住两次触摸之间（前一次抬起到后一次落下）的最长间隔
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
    /// 在按钮上按住多久开始连续触发、之后每隔多久触发一次（D33）。应用启动后换成系统键盘的「重复前延迟」与「按键重复速度」
    public var repeatDelayMs = 500.0
    public var repeatIntervalMs = 83.0
    /// `P.actionDelayMs`
    public var actionDelayMs = 30.0
    /// `P.smoothing`
    public var smoothing = 0.5
    /// `P.panelScale`（修订：0.6 → 0.4，见 decisions.md D20）：按钮组画小、排紧凑。
    /// 触控板到面板是归一化映射，面板在屏幕上的大小不影响手指的移动距离与精度
    public var panelScale = 0.4
    /// 参考网格（D29）：这个行列数的面板占满 `panelScale` 与 `mappingScale`；其他行列数的面板格子大小不变，
    /// 面板在屏幕上与映射区在触控板上按行列数同比伸缩
    public var referenceRows = 3
    public var referenceCols = 5
    /// 面板伸缩的上限：不超过屏幕的这个比例（映射区另以整块触控板为上限），超出时整体缩小
    public var panelMaxScale = 0.9
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
