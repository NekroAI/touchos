import CoreGraphics
import Foundation
import Testing
@testable import TouchOSCore

// D23：双指上下切换面板、捏合总览、按住关闭进入编辑、弹簧与总览网格

private let rate = 90.0

private func panel(_ id: String) -> Layout {
    Layout(id: id, name: id, rows: Layout.test.rows, cols: Layout.test.cols, slots: Layout.test.slots)
}

private let four = [panel("p0"), panel("p1"), panel("p2"), panel("p3")]

private func run(_ g: Gesture, panels: [Layout] = four, events: [(TimeInterval, SessionEvent)] = [],
                 until: TimeInterval) -> Harness {
    var env = SessionEnvironment.test
    env.panels = panels
    var h = Harness(tuning: .test, environment: env)
    h.run(g.frames(rate: rate), events: events, until: until)
    return h
}

/// 四指轻点打开面板，板上不留手指
private func opened() -> Gesture {
    .fourFingerTap()
}

/// 两指在 0.8 落下，用 `over` 秒同时移到新位置后抬起
private func twoFingers(from a: (Double, Double), _ b: (Double, Double), to a2: (Double, Double), _ b2: (Double, Double),
                        over: TimeInterval, liftAt: TimeInterval) -> Gesture {
    opened().touch(id: 2, at: a, t: 0.8).touch(id: 3, at: b, t: 0.8)
        .move(id: 2, to: a2, over: over).move(id: 3, to: b2, over: over)
        .lift(id: 2, t: liftAt).lift(id: 3, t: liftAt)
}

private func context(_ h: Harness) -> ActiveContext? {
    if case .active(let ctx) = h.machine.state { ctx } else { nil }
}

/// 两指竖直移动 `dy`（触控板归一化，向上为正）。上推切到下一个面板（D32）
private func swipe(_ dy: Double, over: TimeInterval = 0.15) -> Gesture {
    twoFingers(from: (0.4, 0.4), (0.6, 0.4), to: (0.4, 0.4 + dy), (0.6, 0.4 + dy), over: over, liftAt: 0.8 + over + 0.02)
}

@Suite struct PanelNavigationTests {
    @Test func swipeUpMovesToNextPanelWithHaptic() throws {
        // 100 mm 高的板上移动 20 mm，`P.navDistanceMM` 30：超过一半
        let h = run(swipe(0.2), until: 2.0)
        let ctx = try #require(context(h))
        #expect(ctx.panelIndex == 1 && ctx.layout.id == "p1")
        #expect(ctx.nav.target == 1 && ctx.nav.isSettled(at: 2.0))
        #expect(h.effects.contains(.haptic) && h.ends.isEmpty)
    }

    @Test func swipeDownGoesBack() throws {
        let g = swipe(0.2).touch(id: 2, at: (0.4, 0.6), t: 1.5).touch(id: 3, at: (0.6, 0.6), t: 1.5)
            .move(id: 2, to: (0.4, 0.4), over: 0.15).move(id: 3, to: (0.6, 0.4), over: 0.15).lift(id: 2, t: 1.7).lift(id: 3, t: 1.7)
        #expect(try #require(context(run(g, until: 2.6))).panelIndex == 0)
    }

    @Test func shortSlowSwipeSnapsBack() throws {
        let h = run(swipe(0.05, over: 0.5), until: 2.5)
        let ctx = try #require(context(h))
        #expect(ctx.panelIndex == 0 && ctx.nav.target == 0)
    }

    @Test func fastLongSwipeMovesOnlyOnePanel() throws {
        let h = run(swipe(0.5, over: 0.08), until: 2.0)
        #expect(try #require(context(h)).panelIndex == 1)
    }

    @Test func pullingPastFirstPanelResistsAndReturns() throws {
        // 拉动中：超出范围的部分被压缩
        let g = opened().touch(id: 2, at: (0.4, 0.6), t: 0.8).touch(id: 3, at: (0.6, 0.6), t: 0.8)
            .move(id: 2, to: (0.4, 0.3), over: 0.2).move(id: 3, to: (0.6, 0.3), over: 0.2).hold(id: 2, until: 1.2).hold(id: 3, until: 1.2)
        let pulling = try #require(context(run(g, until: 1.1)))
        let raw = -30.0 / 30  // 移动 30 mm，按 `P.navDistanceMM` 30 应为 −1
        let nav = pulling.nav.value(at: 1.1)
        #expect(nav < 0 && nav > raw)
        let released = g.lift(id: 2, t: 1.2).lift(id: 3, t: 1.2)
        let ctx = try #require(context(run(released, until: 2.5)))
        #expect(ctx.panelIndex == 0 && abs(ctx.nav.value(at: 2.5)) < 0.01)
    }

    @Test func horizontalAndSinglePanelSwipesAreIgnored() throws {
        let horizontal = twoFingers(from: (0.3, 0.4), (0.5, 0.4), to: (0.6, 0.4), (0.8, 0.4), over: 0.15, liftAt: 1.0)
        let h = run(horizontal, until: 1.5)
        #expect(try #require(context(h)).panelIndex == 0)
        #expect(!h.effects.contains(.haptic))
        let single = run(swipe(0.3), panels: [panel("only")], until: 1.5)
        #expect(try #require(context(single)).nav.target == 0)
    }

    @Test func pointerDoesNotHoverUntilTransitionSettles() throws {
        // 切换刚结束就落下指点指：弹簧仍在过渡，不命中；停稳后按原位置命中
        let pointer = { (until: TimeInterval) in swipe(0.2).touch(id: 2, at: Spot.close, t: 1.0).hold(id: 2, until: until) }
        let early = try #require(context(run(pointer(1.03), until: 1.03)))
        #expect(early.hovered == nil)
        let late = try #require(context(run(pointer(2.0), until: 2.0)))
        #expect(late.hovered == "close" && late.layout.id == "p1")
    }
}

@Suite struct OverviewTests {
    /// 两指捏合 45 mm（150 mm 宽），超过 `P.pinchDistanceMM`
    private func pinched() -> Gesture {
        twoFingers(from: (0.3, 0.5), (0.7, 0.5), to: (0.45, 0.5), (0.55, 0.5), over: 0.15, liftAt: 1.0)
    }

    /// 4 个面板排成 2 × 2；面板 600 × 400 中右下缩略图中心 (450, 300) 对应的触控板位置
    private let lastThumbnail = (0.725, 0.275)

    @Test func pinchOpensOverviewAndLiftSelectsPanel() throws {
        let g = pinched().touch(id: 2, at: lastThumbnail, t: 2.0).hold(id: 2, until: 2.1).lift(id: 2, t: 2.1)
        let open = try #require(context(run(pinched(), until: 1.9)))
        #expect(open.overview.target == 1)
        let h = run(g, until: 3.0)
        let ctx = try #require(context(h))
        #expect(ctx.panelIndex == 3 && ctx.overview.target == 0)
        #expect(h.actions.isEmpty && h.ends.isEmpty)
    }

    @Test func pressInOverviewSelectsHoveredPanel() throws {
        let g = pinched().touch(id: 2, at: lastThumbnail, t: 2.0).hold(id: 2, until: 2.5)
        let h = run(g, events: [(2.3, .physicalPress)], until: 2.5)
        let ctx = try #require(context(h))
        #expect(ctx.panelIndex == 3 && ctx.overview.target == 0)
    }

    @Test func smallPinchSnapsBackAndSpreadCloses() throws {
        let small = twoFingers(from: (0.3, 0.5), (0.7, 0.5), to: (0.33, 0.5), (0.67, 0.5), over: 0.4, liftAt: 1.3)
        #expect(try #require(context(run(small, until: 2.0))).overview.target == 0)
        let spread = pinched().touch(id: 2, at: (0.45, 0.5), t: 1.8).touch(id: 3, at: (0.55, 0.5), t: 1.8)
            .move(id: 2, to: (0.3, 0.5), over: 0.15).move(id: 3, to: (0.7, 0.5), over: 0.15).lift(id: 2, t: 2.0).lift(id: 3, t: 2.0)
        #expect(try #require(context(run(spread, until: 3.0))).overview.target == 0)
    }

    @Test func liftOnOverviewGapStays() throws {
        let g = pinched().touch(id: 2, at: (0.5, 0.5), t: 2.0).hold(id: 2, until: 2.1).lift(id: 2, t: 2.1)
        let h = run(g, until: 2.5)
        #expect(try #require(context(h)).overview.target == 1)
    }
}

@Suite struct HoldToEditTests {
    /// 指点指停在安全区（测试布局的"取消"）
    private func resting(until: TimeInterval) -> Gesture {
        opened().touch(id: 2, at: Spot.null, t: 0.8).hold(id: 2, until: until)
    }

    @Test func holdingPressOnCloseOpensEditor() {
        let h = run(resting(until: 2.0), events: [(1.0, .physicalPress)], until: 2.0)
        #expect(h.ends == [.edit("p0")])
        #expect(h.effects.contains(.openEditor("p0")))
        let opened = h.firstTime { $0 == .openEditor("p0") } ?? 0
        #expect(opened >= 1.6 && opened < 1.62)
        #expect(h.actions.isEmpty)
    }

    @Test func releasingEarlyCloses() {
        let h = run(resting(until: 2.0), events: [(1.0, .physicalPress), (1.3, .physicalRelease)], until: 2.0)
        #expect(h.ends == [.cancelSlot])
        #expect(!h.effects.contains(.openEditor("p0")))
    }

    @Test func movingOffCloseCancelsHold() throws {
        let g = opened().touch(id: 2, at: Spot.null, t: 0.8).hold(id: 2, until: 1.1).move(id: 2, to: Spot.gap, over: 0.1)
            .hold(id: 2, until: 2.0)
        let h = run(g, events: [(1.0, .physicalPress)], until: 2.0)
        #expect(h.ends.isEmpty)
        #expect(try #require(context(h)).holdStartedAt == nil)
    }

    @Test func releaseWithoutHoldIsIgnored() {
        let h = run(resting(until: 1.5), events: [(1.0, .physicalRelease)], until: 1.5)
        #expect(h.ends.isEmpty && h.isActive)
    }
}

@Suite struct MotionTests {
    @Test func springStartsAtFromAndSettlesOnTarget() {
        for damping in [0.7, 1.0] {
            let m = Motion(from: 0, velocity: 2, to: 1, start: 1, response: 0.4, damping: damping)
            #expect(m.value(at: 1) == 0 && m.value(at: 0.5) == 0)
            #expect(abs(m.velocity(at: 1) - 2) < 1e-9)
            #expect(!m.isSettled(at: 1.05))
            #expect(m.isSettled(at: 4) && abs(m.value(at: 4) - 1) < 0.002)
        }
    }

    @Test func underdampedSpringOvershoots() {
        let m = Motion(from: 0, to: 1, start: 0, response: 0.4, damping: 0.5)
        #expect(stride(from: 0, to: 1, by: 0.01).contains { m.value(at: $0) > 1 })
    }

    @Test func staticMotionIsAlwaysSettled() {
        let m = Motion.at(0.3)
        #expect(m.value(at: 99) == 0.3 && m.velocity(at: 99) == 0 && m.isSettled(at: 0))
    }

    @Test func rubberBandCompressesOutsideRange() {
        #expect(rubberBand(0.5, in: 0...1) == 0.5)
        let over = rubberBand(3, in: 0...1), under = rubberBand(-2, in: 0...1)
        #expect(over > 1 && over < 1 + 1 / 0.55)
        #expect(under < 0 && under > -1 / 0.55)
        #expect(rubberBand(1.1, in: 0...1) < rubberBand(1.2, in: 0...1))
    }
}

@Suite struct OverviewGridTests {
    let size = CGSize(width: 600, height: 400)

    @Test func layoutForCounts() {
        #expect(OverviewGrid(count: 1, panelSize: size).cols == 1)
        let three = OverviewGrid(count: 3, panelSize: size)
        #expect(three.cols == 2 && three.rows == 2 && three.scale == 0.43)
        // 最后一行只有一个：居中
        #expect(three.center(of: 2) == CGPoint(x: 300, y: 300))
        let five = OverviewGrid(count: 5, panelSize: size)
        #expect(five.cols == 3 && five.rows == 2)
    }

    @Test func indexRoundTripsThroughCenters() {
        for n in 1...7 {
            let grid = OverviewGrid(count: n, panelSize: size)
            for i in 0..<n { #expect(grid.index(at: grid.center(of: i)) == i) }
        }
        #expect(OverviewGrid(count: 4, panelSize: size).index(at: CGPoint(x: 300, y: 200)) == nil)
    }
}
