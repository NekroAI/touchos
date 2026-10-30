import AppKit
import CoreGraphics
import Foundation
import TouchOSAtomics
import TouchOSCore

/// 光标冻结与校正（SRS 7.4）。只在 input.queue 上使用。
/// 不使用"断开鼠标与光标关联"接口：冻结完全靠拦截丢弃指针移动，再逐 tick 校验并拉回。
final class CursorLock: @unchecked Sendable {
    /// FR-7.7：偏离冻结点超过该距离（pt）时移回
    static let tolerance: CGFloat = 0.5

    private let tap: EventTapController
    /// 冻结点（Quartz 全局坐标，原点为主屏左上角）
    private var freezePoint: CGPoint?

    /// 调试叠层的指针诊断。偏离量以 0.01 pt 为单位记录
    struct Diagnostics {
        var checks: UInt64
        var corrections: UInt64
        var maxEventDeviation: Double
        var maxScreenDeviation: Double
    }
    private let checks = TOAtomicCreate()!
    private let corrections = TOAtomicCreate()!
    private let maxEventDeviation = TOAtomicCreate()!
    private let maxScreenDeviation = TOAtomicCreate()!

    init(tap: EventTapController) {
        self.tap = tap
    }

    func apply(_ command: CursorCommand) {
        switch command {
        case .arm:
            freezePoint = Self.location
            _ = tap.takeCursorDelta()
        case .compensate:
            // FR-7.6：光标移到"冻结点 + 累计位移"（钳制在屏幕内），看起来只是晚一点开始移动
            let d = tap.takeCursorDelta()
            if let p = freezePoint, d != .zero {
                Self.warp(Self.clampToDisplays(CGPoint(x: p.x + d.dx, y: p.y + d.dy), fallback: p))
            }
            freezePoint = nil
        case .lock:
            _ = tap.takeCursorDelta()
        case .restore:
            // FR-7.8：精确回到冻结点，之后才切换策略（由效果顺序保证）
            if let p = freezePoint { Self.warp(p) }
            freezePoint = nil
        }
    }

    /// FR-7.7：激活态每个 tick 校验一次
    func verify() {
        guard let p = freezePoint else { return }
        // 两个来源都看：只读事件位置时，有的构建上光标在动它却不变（0.1.0 发布版，D47）
        let event = Self.location, screen = Self.screenLocation
        let eventOff = hypot(event.x - p.x, event.y - p.y), screenOff = hypot(screen.x - p.x, screen.y - p.y)
        TOAtomicIncrement(checks)
        TOAtomicMax(maxEventDeviation, UInt64(eventOff * 100))
        TOAtomicMax(maxScreenDeviation, UInt64(screenOff * 100))
        if max(eventOff, screenOff) > Self.tolerance {
            TOAtomicIncrement(corrections)
            Self.warp(p)
        }
    }

    var diagnostics: Diagnostics {
        Diagnostics(checks: TOAtomicLoad(checks), corrections: TOAtomicLoad(corrections),
                    maxEventDeviation: Double(TOAtomicLoad(maxEventDeviation)) / 100,
                    maxScreenDeviation: Double(TOAtomicLoad(maxScreenDeviation)) / 100)
    }

    func resetDiagnostics() {
        for a in [checks, corrections, maxEventDeviation, maxScreenDeviation] { TOAtomicStore(a, 0) }
    }

    private static var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    /// 屏幕坐标系的光标位置，换算到 Quartz 全局坐标（主屏高度减 y）
    private static var screenLocation: CGPoint {
        let p = NSEvent.mouseLocation
        return CGPoint(x: p.x, y: CGDisplayBounds(CGMainDisplayID()).height - p.y)
    }

    private static func warp(_ p: CGPoint) {
        // 把本地事件抑制间隔设为 0，避免移动光标后约 0.25 秒的输入冻结（FR-7.7）
        CGEventSource(stateID: .combinedSessionState)?.localEventsSuppressionInterval = 0
        CGWarpMouseCursorPosition(p)
    }

    private static func clampToDisplays(_ p: CGPoint, fallback: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        var display: CGDirectDisplayID = 0
        if CGGetDisplaysWithPoint(p, 1, &display, &count) == .success, count > 0 { return p }
        guard CGGetDisplaysWithPoint(fallback, 1, &display, &count) == .success, count > 0 else { return fallback }
        let b = CGDisplayBounds(display)
        return CGPoint(x: min(max(p.x, b.minX), b.maxX - 1), y: min(max(p.y, b.minY), b.maxY - 1))
    }
}
