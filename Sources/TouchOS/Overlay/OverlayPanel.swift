import AppKit
import SwiftUI
import TouchOSCore

/// 浮层（SRS 8.1、8.2）：永不获得焦点、鼠标穿透、出现在所有桌面和全屏应用之上；只渲染视图模型，不处理输入。
/// 启动时创建并保持隐藏，激活时只切换可见性（FR-8.4）。
/// 唤起的是一组悬浮按钮而不是一个窗口（D20）：没有容器背景，窗口铺满整屏、完全透明。
final class OverlayPanel: NSPanel {
    init(model: OverlayModel) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                   styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // 出现在所有桌面并能叠加在全屏应用上；不进入窗口循环与 Mission Control（FR-8.2、8.3）
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .transient]
        contentView = NSHostingView(rootView: OverlayRoot(model: model))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 铺满鼠标（冻结光标）所在屏幕：按钮组居中于整块屏幕（修订 FR-8.5 的"可见区域中心"，负责人反馈：
    /// 中心的取消要在屏幕正中），指示点可以越出按钮组（D15），背景压暗铺满整屏。
    /// 返回按钮组左上角在窗口内容坐标（原点左上）中的位置
    func show(groupSize: CGSize) -> CGPoint {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else {
            orderFrontRegardless()
            return .zero
        }
        let f = screen.frame
        setFrame(f, display: false)
        orderFrontRegardless()
        return CGPoint(x: (f.width - groupSize.width) / 2, y: (f.height - groupSize.height) / 2)
    }

    func hide() {
        orderOut(nil)
    }
}

/// 指示点的位置样本（按钮组 pt），用于帧间插值与轨迹（FR-8.9、SRS 8.3）
struct PointerSample {
    let t: TimeInterval
    let p: CGPoint
}

@MainActor
@Observable
final class OverlayModel {
    /// 按钮组的生命周期（D20）：弹开 → 显示 → 提交（选中的留下）→ 消散，或整体收拢
    enum Phase: Equatable {
        case entering, shown, committing(SlotID), dissolving(SlotID), collapsing

        var appeared: Bool { self != .entering }
        var chosen: SlotID? {
            switch self {
            case .committing(let id), .dissolving(let id): id
            default: nil
            }
        }
        var leaving: Bool { chosen != nil || self == .collapsing }
    }

    private(set) var state: PanelState?
    var phase = Phase.shown {
        didSet { if phase != oldValue { phaseAt = ProcessInfo.processInfo.systemUptime } }
    }
    /// 阶段开始的时刻：面板堆栈据此计算邻近面板的淡入淡出
    private(set) var phaseAt: TimeInterval = 0
    /// 本次显示的时刻
    var shownAt: TimeInterval = 0
    /// 主题、切换动画、强调色（每次显示时读取）
    var appearance = Appearance()
    /// 按钮组左上角在窗口中的位置
    var groupOrigin = CGPoint.zero
    /// 背景压暗（调试菜单开关）
    var dim = false
    var slotGap = 0.0
    /// `P.trailMs`（秒）
    var trailDuration = 0.3
    /// 各槽位的波纹与按下回弹的触发计数，每加一播放一次
    private(set) var pulses: [SlotID: Int] = [:]
    /// 当前悬停期间各槽位按压执行的次数，悬停变化时清零
    private(set) var presses: [SlotID: Int] = [:]
    /// 最近的指示点样本；指点指抬起后保留到轨迹淡出
    private(set) var samples: [PointerSample] = []
    private(set) var pointerDown = false

    func pulse(_ id: SlotID) { pulses[id, default: 0] += 1 }

    /// 按压执行一次：计数加一；`animate` 为假（减少动态效果）时不播放回弹与波纹
    func press(_ id: SlotID, animate: Bool) {
        presses[id, default: 0] += 1
        if animate { pulse(id) }
    }

    /// 指示点每帧都变，单独存在 `samples` 里；`state` 去掉指示点后只在槽位、悬停、页码等变化时更新，
    /// 避免每一帧都让全部按钮重新计算视图
    func apply(_ new: PanelState?) {
        let now = ProcessInfo.processInfo.systemUptime
        var stripped = new
        stripped?.pointer = nil
        if stripped?.hovered != state?.hovered { presses.removeAll() }
        if stripped != state { state = stripped }
        if new == nil { pulses.removeAll() }
        if let p = new?.pointer {
            if !pointerDown { samples.removeAll() }  // 新的指点指不接上一条轨迹
            samples.append(PointerSample(t: now, p: p))
            pointerDown = true
        } else {
            pointerDown = false
        }
        samples.removeAll { now - $0.t > max(trailDuration, PanelMetrics.maxSampleInterval) * 2 }
    }

    /// 某一时刻的显示位置：在最后两个样本之间按经过的时间线性插值（FR-8.9）
    func displayedPointer(at now: TimeInterval) -> CGPoint? {
        guard pointerDown, let b = samples.last else { return nil }
        guard samples.count >= 2 else { return b.p }
        let a = samples[samples.count - 2]
        let interval = min(max(b.t - a.t, PanelMetrics.minSampleInterval), PanelMetrics.maxSampleInterval)
        let k = min((now - b.t) / interval, 1)
        return CGPoint(x: a.p.x + (b.p.x - a.p.x) * k, y: a.p.y + (b.p.y - a.p.y) * k)
    }
}

/// 按钮组视觉尺寸与动效参数（SRS 8.3，修订见 decisions.md D20、D23）。各主题的画法常量放在各自的视图里
enum PanelMetrics {
    /// 按钮在槽位可见区域（已扣掉 `P.slotGap`）基础上每边再小的量
    static let chipInset: CGFloat = 2
    /// 环形布局的圆形按钮：直径取环宽与弦长中较小者的该比例，再限制在上下限之间
    static let roundChipFill: CGFloat = 0.7
    static let roundChipMin: CGFloat = 40
    static let roundChipMax: CGFloat = 76
    /// 关闭：中心一个小圆（按住进入编辑，D23）
    static let cancelChipSize: CGFloat = 42
    static let titleSize: CGFloat = 12
    static let captionSize: CGFloat = 10.5

    /// 悬停放大（液态光斑主题；其余主题由按钮自身的形态变化表现悬停），每边外扩不超过 `hoverGrowMax`
    static let hoverScale: CGFloat = 1.09
    static let hoverGrowMax: CGFloat = 8
    /// 提交：选中的按钮放大、停留，然后放大淡出
    static let commitScale: CGFloat = 1.1
    static let commitGrowMax: CGFloat = 12
    static let dissolveScale: CGFloat = 1.18
    /// 按压：缩小后回弹
    static let pressScale: CGFloat = 0.92
    static let pressDown: TimeInterval = 0.06
    static let pressRelease: TimeInterval = 0.28

    /// 弹开：从唤起位置方向拉近 `enterPull` 倍距离、缩小，按离唤起位置的距离依次出现，最晚延迟 `enterStagger`
    static let enterScale: CGFloat = 0.85
    static let enterPull: CGFloat = 0.35
    static let enterStagger: TimeInterval = 0.08
    static let enterResponse = 0.3
    static let enterDamping = 0.78
    /// 收拢：向按钮组中心拉近、缩小、淡出
    static let collapseScale: CGFloat = 0.6
    static let collapsePull: CGFloat = 0.6

    /// 玻璃：毛玻璃只保留一部分强度（负责人反馈：不要实心），文字加阴影保证可读
    static let materialOpacity = 0.6
    static let labelShadowOpacity = 0.55

    static let pointerCore: CGFloat = 10
    static let pointerHalo: CGFloat = 30
    static let trailMaxWidth: CGFloat = 5
    static let trailMaxOpacity = 0.45
    /// 指示点在映射区之外（此时抬起即取消，D21、D22）：按钮组整体变淡，显示按钮组范围的轮廓，
    /// 指示点换成不带强调色的 × 并标注"松手取消"
    static let outsideGroupOpacity = 0.45
    static let boundsOpacity = 0.4
    static let cancelPointerSize: CGFloat = 24
    static let cancelPointerFill = 0.75
    static let cancelHintSize: CGFloat = 11
    static let cancelHintOffset: CGFloat = 26
    static let dimOpacity = 0.14

    /// 面板名：唤起后显示这么久再淡出，切换面板时重新出现
    static let titleDuration: TimeInterval = 1.4
    static let titleOffset: CGFloat = 44
    /// 圆形按钮名称在按钮下方的距离
    static let roundTitleOffset: CGFloat = 24

    /// 波纹：从按钮中心按比例扩散并淡出
    static let rippleDuration = 0.45

    /// 按比例放大，但每边外扩不超过 `maxGrow`
    static func scale(_ factor: CGFloat, for size: CGSize, maxGrow: CGFloat) -> CGFloat {
        let longest = max(size.width, size.height)
        return longest > 0 ? min(factor, 1 + maxGrow * 2 / longest) : factor
    }
    /// 插值用的样本间隔上下限：触点约 66 Hz，超过上限视为停顿后的新移动
    static let minSampleInterval: TimeInterval = 0.004
    static let maxSampleInterval: TimeInterval = 0.05
}

/// 一个按钮画在哪里、画成什么样。命中区域仍由 `HitTester` 按槽位形状判定，与这里无关
struct ChipGeometry: Equatable {
    enum Kind { case tile, round, cancel }

    var frame: CGRect
    var kind: Kind

    func scaled(_ k: CGFloat) -> ChipGeometry {
        let w = frame.width * k, h = frame.height * k
        return ChipGeometry(frame: CGRect(x: frame.midX - w / 2, y: frame.midY - h / 2, width: w, height: h), kind: kind)
    }

    static func of(_ slot: Slot, tester: HitTester) -> ChipGeometry? {
        switch slot.shape {
        case .cell, .rect:
            guard let r = tester.visualRect(of: slot) else { return nil }
            if slot.isCancel { return round(at: CGPoint(x: r.midX, y: r.midY), diameter: PanelMetrics.cancelChipSize, kind: .cancel) }
            return ChipGeometry(frame: r.insetBy(dx: PanelMetrics.chipInset, dy: PanelMetrics.chipInset), kind: .tile)
        case .sector(let s):
            if slot.isCancel || (s.innerRadius == 0 && s.isFullCircle) {
                return round(at: tester.center, diameter: PanelMetrics.cancelChipSize, kind: slot.isCancel ? .cancel : .round)
            }
            // 环形布局画成沿环排列的圆形按钮，不画扇形
            let unit = tester.unitRadius
            let outer = min(s.outerRadius ?? Self.openOuterRadius, Self.openOuterRadius)
            let r = (s.innerRadius + outer) / 2 * unit
            let ring = (outer - s.innerRadius) * unit
            let width = min(s.endAngle - s.startAngle, 180) * .pi / 180
            let chord = 2 * r * sin(width / 2)
            let d = min(max(min(ring, chord) * PanelMetrics.roundChipFill, PanelMetrics.roundChipMin), PanelMetrics.roundChipMax)
            let a = (s.startAngle + s.endAngle) / 2 * .pi / 180
            return round(at: CGPoint(x: tester.center.x + r * sin(a), y: tester.center.y - r * cos(a)), diameter: d, kind: .round)
        }
    }

    /// 向外无限延伸的扇区按这个外半径摆放按钮（单位半径的比例）
    private static let openOuterRadius = 0.98

    private static func round(at c: CGPoint, diameter d: CGFloat, kind: Kind) -> ChipGeometry {
        ChipGeometry(frame: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d), kind: kind)
    }
}

/// 浮层根视图：可选的背景压暗、面板堆栈（每帧按核心给出的弹簧求值）、指示点
private struct OverlayRoot: View {
    let model: OverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let state = model.state {
                let groupRect = CGRect(origin: model.groupOrigin, size: state.size)
                if model.dim {
                    Color.black.opacity(model.phase.appeared && !model.phase.leaving ? PanelMetrics.dimOpacity : 0)
                        .animation(.easeOut(duration: 0.2), value: model.phase)
                }
                TimelineView(.animation) { timeline in
                    let _ = timeline.date
                    PanelStack(model: model, state: state, now: ProcessInfo.processInfo.systemUptime, reduceMotion: reduceMotion)
                }
                .frame(width: state.size.width, height: state.size.height, alignment: .topLeading)
                .offset(x: groupRect.minX, y: groupRect.minY)
                if !model.phase.leaving {
                    PointerLayer(model: model, groupRect: groupRect,
                                 overCancel: state.hovered.flatMap { state.layout.slot($0) }?.isCancel ?? false,
                                 showTrail: !reduceMotion)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.overlayStyle, OverlayStyle(model.appearance))
    }
}

extension Action {
    /// 按钮点亮时显示的小字说明
    var shortLabel: String? {
        switch self {
        case .none: nil
        case .keyboardShortcut(let k): k.displayLabel
        case .openApp: "打开应用"
        case .openURL(let url, _): url.host ?? "打开链接"
        case .openFile: "打开文件"
        case .shell: "Shell"
        case .appleScript: "脚本"
        case .shortcut(let name): name
        case .system: nil
        }
    }
}
