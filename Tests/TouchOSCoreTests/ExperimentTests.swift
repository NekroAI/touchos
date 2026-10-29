import CoreGraphics
import Foundation
import Testing
@testable import TouchOSCore

// 交互实验（decisions.md D12、D13、D23）：扇区、滑杆、按压动作、各角绑定面板

private let rate = 90.0

private func key(_ code: UInt16, _ mods: Set<Modifier>, _ label: String) -> Action {
    .keyboardShortcut(KeyCombo(keyCode: code, modifiers: mods, displayLabel: label))
}

private let closeTab = key(13, [.command], "⌘W")
private let selectAll = key(0, [.command], "⌘A")

private func sector(_ center: Double, inner: Double, outer: Double?) -> SlotShape {
    .sector(Sector(innerRadius: inner, outerRadius: outer, startAngle: center - 45, endAngle: center + 45))
}

/// 4 个 90° 扇区 + 中心取消圆盘（半径 0.3）
private let radial = Layout(id: "radial", name: "环形", slots: [
    Slot(id: "up", shape: sector(0, inner: 0.3, outer: nil), title: "上", symbol: "", action: selectAll),
    Slot(id: "right", shape: sector(90, inner: 0.3, outer: nil), title: "右", symbol: "", action: selectAll),
    Slot(id: "down", shape: sector(180, inner: 0.3, outer: 0.6), title: "下", symbol: "", action: selectAll),
    Slot(id: "left", shape: sector(270, inner: 0.3, outer: nil), title: "左", symbol: "", action: selectAll),
    Slot(id: "cancel", shape: .sector(Sector(innerRadius: 0, outerRadius: 0.3, startAngle: 0, endAngle: 360)),
         title: "取消", symbol: "", action: .none),
])

/// 上半：左"关闭"（⌘W）、右"普通"（⌘A）；下半：横向音量滑杆
private let experiment = Layout(id: "exp", name: "实验", slots: [
    Slot(id: "dual", shape: .rect(CGRect(x: 0, y: 0, width: 0.5, height: 0.5)), title: "关闭", symbol: "", action: closeTab),
    Slot(id: "plain", shape: .rect(CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)), title: "普通", symbol: "", action: selectAll),
    Slot(id: "slider", shape: .rect(CGRect(x: 0, y: 0.5, width: 1, height: 0.5)), title: "音量", symbol: "",
         action: .none, slider: .volume),
])

private enum ExpSpot {
    static let dual = (0.2, 0.85)
    static let plain = (0.8, 0.85)
    static let sliderLeft = (0.2, 0.2)
    static let sliderRight = (0.8, 0.2)
    static let bottomRightAnchor = (0.95, 0.06)
}

private func environment(_ panels: [Layout], bindings: [PanelTrigger: String] = [:]) -> SessionEnvironment {
    var env = SessionEnvironment.test
    env.panels = panels
    env.bindings = bindings
    return env
}

private func run(_ g: Gesture, environment: SessionEnvironment = environment([experiment]),
                 events: [(TimeInterval, SessionEvent)] = [], until: TimeInterval) -> Harness {
    var h = Harness(tuning: .test, environment: environment)
    h.run(g.frames(rate: rate), events: events, until: until)
    return h
}

private func anchored(until: TimeInterval = 1.2) -> Gesture {
    Gesture(device: .builtIn).touch(id: 1, at: Spot.anchor, t: 0).hold(id: 1, until: until)
}

private func activeLayout(_ h: Harness) -> String? {
    if case .active(let ctx) = h.machine.state { ctx.layout.id } else { nil }
}

@Suite struct SectorGeometryTests {
    // 面板 600 × 400：圆心 (300, 200)，单位半径 200 pt，空隙 6 pt
    let tester = HitTester(layout: radial, panelSize: CGSize(width: 600, height: 400), slotGap: 6, hysteresis: 0.02)

    @Test func angleIsClockwiseFromUp() {
        #expect(tester.angle(of: CGPoint(x: 300, y: 0)) == 0)
        #expect(tester.angle(of: CGPoint(x: 500, y: 200)) == 90)
        #expect(tester.angle(of: CGPoint(x: 100, y: 200)) == 270)
    }

    @Test func hitsSectorsByAngleAndRadius() {
        #expect(tester.hit(CGPoint(x: 300, y: 20)) == "up")
        #expect(tester.hit(CGPoint(x: 290, y: 20)) == "up")  // 跨 0° 的扇区
        #expect(tester.hit(CGPoint(x: 590, y: 10)) == "right")  // 向外无限延伸到面板角落
        #expect(tester.hit(CGPoint(x: 300, y: 230)) == "cancel")
        #expect(tester.hit(CGPoint(x: 300, y: 290)) == "down")
        #expect(tester.hit(CGPoint(x: 300, y: 390)) == nil)  // 超出"下"的外半径
        #expect(tester.hit(CGPoint(x: 300, y: 262)) == nil)  // 取消圆盘与内环之间的空隙
        #expect(tester.hit(CGPoint(x: 400, y: 100)) == nil)  // 45° 分界线上的空隙
        #expect(tester.visualRect(of: radial.slots[0]) == nil)
        #expect(tester.rect(of: radial.slots[0]) == nil)
    }

    @Test func sectorHysteresisWidensCurrentSlot() {
        let p = CGPoint(x: 300 + 150 * sin(47 * Double.pi / 180), y: 200 - 150 * cos(47 * Double.pi / 180))
        #expect(tester.hit(p) == nil)
        #expect(tester.hit(p, current: "up") == "up")
    }

    @Test func sliderValueFollowsLongAxis() {
        let horizontal = HitTester(layout: experiment, panelSize: CGSize(width: 600, height: 400), slotGap: 6, hysteresis: 0)
        let slider = experiment.slots[2]
        #expect(horizontal.sliderValue(of: slider, at: CGPoint(x: 6, y: 300)) == 0)
        #expect(horizontal.sliderValue(of: slider, at: CGPoint(x: 300, y: 300)) == 0.5)
        #expect(horizontal.sliderValue(of: slider, at: CGPoint(x: 700, y: 300)) == 1)
        #expect(horizontal.sliderValue(of: experiment.slots[0], at: .zero) == nil)

        let vertical = Layout(id: "v", name: "v", slots: [
            Slot(id: "v", shape: .rect(CGRect(x: 0, y: 0, width: 0.2, height: 1)), title: "", symbol: "", action: .none, slider: .demo),
        ])
        let t = HitTester(layout: vertical, panelSize: CGSize(width: 600, height: 400), slotGap: 0, hysteresis: 0)
        #expect(t.sliderValue(of: vertical.slots[0], at: CGPoint(x: 50, y: 100)) == 0.75)  // 从下往上
    }
}

@Suite struct PressTests {
    @Test func pressExecutesAndKeepsPanel() {
        // D18：按压执行一次并保留，可以连按
        let g = anchored().touch(id: 2, at: ExpSpot.dual, t: 0.5).hold(id: 2, until: 1.0)
        let h = run(g, events: [(0.6, .physicalPress), (0.75, .physicalPress)], until: 1.0)
        #expect(h.actions.map(\.action) == [closeTab, closeTab])
        #expect(h.ends.isEmpty)
        #expect(h.isActive)
    }

    @Test func liftAfterPressOnSameSlotClosesWithoutExecuting() {
        let g = anchored().touch(id: 2, at: ExpSpot.dual, t: 0.5).hold(id: 2, until: 0.8).lift(id: 2, t: 0.8)
        let h = run(g, events: [(0.65, .physicalPress)], until: 1.0)
        #expect(h.actions.map(\.action) == [closeTab])
        #expect(h.ends == [.liftAfterPress])
    }

    @Test func movingToAnotherSlotAfterPressCommitsOnLift() {
        let g = anchored().touch(id: 2, at: ExpSpot.dual, t: 0.5).hold(id: 2, until: 0.7)
            .move(id: 2, to: ExpSpot.plain, over: 0.1).hold(id: 2, until: 0.9).lift(id: 2, t: 0.9)
        let h = run(g, events: [(0.6, .physicalPress)], until: 1.1)
        #expect(h.actions.map(\.action) == [closeTab, selectAll])
        #expect(h.ends == [.committed("plain")])
    }

    @Test func pressOnSliderAppliesPreviewAndKeepsIt() {
        var env = environment([experiment])
        env.sliderValues[.volume] = 0.3
        let g = anchored().touch(id: 2, at: ExpSpot.sliderRight, t: 0.5).hold(id: 2, until: 0.7)
            .move(id: 2, to: ExpSpot.plain, over: 0.1).hold(id: 2, until: 1.0)
        let h = run(g, environment: env, events: [(0.6, .physicalPress)], until: 1.0)
        let applied = h.effects.compactMap { if case .slider(.volume, let v) = $0 { v } else { nil } }
        #expect(applied.count == 1 && abs(applied[0] - 0.84) < 0.011)
        #expect(h.isActive)
        // 移出滑杆后显示新设定的值，而不是进入时的 0.3
        let last = h.effects.compactMap { if case .updatePanel(let s) = $0 { s } else { nil } }.last
        #expect(last?.sliderValues["slider"] == applied[0])
    }

    @Test func pressOnCancelOrWithoutPointerDoesNothing() {
        let cancel = anchored().touch(id: 2, at: Spot.null, t: 0.5).hold(id: 2, until: 0.9)
        let single = anchored()
        for h in [run(cancel, environment: .test, events: [(0.6, .physicalPress)], until: 1.0),
                  run(single, environment: .test, events: [(0.6, .physicalPress)], until: 1.0)] {
            #expect(h.actions.isEmpty)
            #expect(h.isActive)
        }
    }

    @Test func pressWithoutPointerNoLongerFlipsPanels() {
        // D23：去掉按压翻页，改为双指切换
        let h = run(anchored(), environment: environment([experiment, radial]), events: [(0.3, .physicalPress)], until: 0.5)
        #expect(activeLayout(h) == "exp")
    }
}

@Suite struct CornerPanelTests {
    @Test func cornerOpensItsBoundPanel() {
        let env = environment([experiment, radial], bindings: [.hold(.bottomRight): "radial"])
        let left = run(anchored(until: 0.5), environment: env, until: 0.5)
        #expect(activeLayout(left) == "exp")
        let right = run(Gesture(device: .builtIn).touch(id: 1, at: ExpSpot.bottomRightAnchor, t: 0).hold(id: 1, until: 0.5),
                        environment: env, until: 0.5)
        #expect(activeLayout(right) == "radial")
    }

    @Test func pointerCannotStartInTheActiveCornersZone() {
        let env = environment([experiment], bindings: [.hold(.bottomRight): "exp"])
        let g = Gesture(device: .builtIn).touch(id: 1, at: ExpSpot.bottomRightAnchor, t: 0).hold(id: 1, until: 1.0)
            .touch(id: 2, at: (0.94, 0.08), t: 0.5).hold(id: 2, until: 0.9)
        let h = run(g, environment: env, until: 0.9)
        guard case .active(let ctx) = h.machine.state else { Issue.record("not active"); return }
        #expect(ctx.pointer == nil)
    }
}

@Suite struct SliderTests {
    @Test func sliderPreviewsWhileMovingAndAppliesOnLift() {
        let g = anchored().touch(id: 2, at: ExpSpot.sliderLeft, t: 0.5).move(id: 2, to: ExpSpot.sliderRight, over: 0.2)
            .hold(id: 2, until: 0.8).lift(id: 2, t: 0.8)
        let h = run(g, until: 1.0)
        let applied = h.effects.compactMap { if case .slider(.volume, let v) = $0 { v } else { nil } }
        #expect(applied.count == 1)
        #expect(abs(applied[0] - 0.84) < 0.011)
        let previews = h.effects.compactMap { if case .updatePanel(let s) = $0 { s.sliderValues["slider"] } else { nil } }
        #expect(previews.count > 5 && previews == previews.sorted())
        #expect(h.actions.isEmpty)
        #expect(h.ends == [.committed("slider")])
        // 滑杆的值在会话结束之前送出
        let sliderAt = h.effects.firstIndex { if case .slider = $0 { true } else { false } }
        let endAt = h.effects.firstIndex(of: .sessionEnded(.committed("slider")))
        #expect(sliderAt != nil && endAt != nil && sliderAt! < endAt!)
    }

    @Test func leavingSliderRestoresValueAndAppliesNothing() {
        var env = environment([experiment])
        env.sliderValues[.volume] = 0.3
        let g = anchored().touch(id: 2, at: ExpSpot.sliderLeft, t: 0.5).move(id: 2, to: ExpSpot.sliderRight, over: 0.2)
            .move(id: 2, to: ExpSpot.plain, over: 0.2).hold(id: 2, until: 1.0).lift(id: 2, t: 1.0)
        let h = run(g, environment: env, until: 1.2)
        #expect(!h.effects.contains { if case .slider = $0 { true } else { false } })
        let last = h.effects.compactMap { if case .updatePanel(let s) = $0 { s } else { nil } }.last
        #expect(last?.sliderValues["slider"] == 0.3)
        #expect(h.actions.map(\.action) == [selectAll])
    }

    @Test func panelStartsWithEnvironmentSliderValue() {
        var env = environment([experiment])
        env.sliderValues[.volume] = 0.4
        let h = run(anchored(until: 0.6), environment: env, until: 0.6)
        let shown = h.effects.compactMap { if case .showPanel(let s) = $0 { s } else { nil } }
        #expect(shown.first?.sliderValues["slider"] == 0.4)
    }
}

@Suite struct StickyPanelTests {
    static var sticky: Tuning {
        var t = Tuning.test
        t.stickyPanel = true
        return t
    }

    private func runSticky(_ g: Gesture, environment: SessionEnvironment = .test,
                           events: [(TimeInterval, SessionEvent)] = [], until: TimeInterval) -> Harness {
        var h = Harness(tuning: Self.sticky, environment: environment)
        h.run(g.frames(rate: rate), events: events, until: until)
        return h
    }

    /// 锚指驻留进入激活后在 0.4 抬起
    private func anchorThenLift() -> Gesture {
        Gesture(device: .builtIn).touch(id: 1, at: Spot.anchor, t: 0).hold(id: 1, until: 0.4).lift(id: 1, t: 0.4)
    }

    @Test func liftingAnchorKeepsPanelAndSingleFingerCommits() {
        // 新手指复用锚指的 ID，并且落在锚定角附近也可以成为指点指
        let g = anchorThenLift().touch(id: 1, at: Spot.anchor, t: 0.8).move(id: 1, to: Spot.close, over: 0.2)
            .hold(id: 1, until: 1.2).lift(id: 1, t: 1.2)
        let h = runSticky(g, until: 1.4)
        #expect(h.actions.map(\.action) == [closeTab])
        #expect(h.ends == [.committed("close")])
        let sticky = h.effects.contains { if case .updatePanel(let s) = $0 { s.sticky } else { false } }
        #expect(sticky)
    }

    @Test func gapKeepsPanelAndCancelCloses() {
        let gap = anchorThenLift().touch(id: 2, at: Spot.gap, t: 0.8).hold(id: 2, until: 1.0).lift(id: 2, t: 1.0)
        let h1 = runSticky(gap, until: 1.5)
        #expect(h1.isActive && h1.ends.isEmpty)
        let cancel = anchorThenLift().touch(id: 2, at: Spot.null, t: 0.8).hold(id: 2, until: 1.0).lift(id: 2, t: 1.0)
        let h2 = runSticky(cancel, until: 1.2)
        #expect(h2.ends == [.cancelSlot])
        #expect(h2.actions.isEmpty)
    }

    @Test func idleTimeoutClosesOnlyWithoutFingers() {
        let idle = runSticky(anchorThenLift(), until: 6.0)
        #expect(idle.ends == [.idleTimeout])
        let closedAt = idle.firstTime { $0 == .sessionEnded(.idleTimeout) } ?? 0
        #expect(closedAt > 5.4 && closedAt < 5.5)
        // 指点指一直停在空隙上：没有超时
        let resting = anchorThenLift().touch(id: 2, at: Spot.gap, t: 0.5).hold(id: 2, until: 7)
        #expect(runSticky(resting, until: 7).isActive)
    }

    @Test func threeFingerMovementOrRestHandsOffToSystem() {
        // D22：三指以上停留超过轻点时限，或开始移动，才交还系统手势
        let three = { (g: Gesture) in g.touch(id: 2, at: (0.4, 0.5), t: 0.8).touch(id: 3, at: (0.5, 0.5), t: 0.8)
            .touch(id: 4, at: (0.6, 0.5), t: 0.8) }
        let resting = three(anchorThenLift()).hold(id: 2, until: 1.3).hold(id: 3, until: 1.3).hold(id: 4, until: 1.3)
        let h = runSticky(resting, until: 1.3)
        #expect(h.ends == [.handoff])
        #expect(h.policies.contains { $0.mode == .cooldown && $0.passGestures })
        let swipe = three(anchorThenLift()).move(id: 2, to: (0.3, 0.5), over: 0.1).move(id: 3, to: (0.4, 0.5), over: 0.1)
            .move(id: 4, to: (0.5, 0.5), over: 0.1)
        #expect(runSticky(swipe, until: 1.0).ends == [.handoff])
        // 两指停留不交还：面板保留（D23 双指用于切换面板）
        let two = anchorThenLift().touch(id: 2, at: Spot.gap, t: 0.8).touch(id: 3, at: Spot.a, t: 0.81).hold(id: 2, until: 1.4)
            .hold(id: 3, until: 1.4)
        #expect(runSticky(two, until: 1.4).isActive)
    }

    @Test func pressOnGapDoesNothingInStickyMode() {
        let env = environment([Layout.test, radial])
        let g = anchorThenLift().touch(id: 2, at: Spot.gap, t: 0.8).hold(id: 2, until: 1.2)
        let h = runSticky(g, environment: env, events: [(1.0, .physicalPress)], until: 1.2)
        #expect(activeLayout(h) == "test" && h.actions.isEmpty)
    }

    @Test func withoutStickyModeLiftingAnchorStillCancels() {
        var h = Harness(tuning: .test, environment: .test)
        h.run(anchorThenLift().frames(rate: rate), until: 0.6)
        #expect(h.ends == [.anchorLifted])
    }
}

@Suite struct OverscanTests {
    @Test func pointerIsNotClampedForDisplay() {
        let m = Mapper(margin: 0.05, scale: 0.6)
        let size = CGSize(width: 600, height: 400)
        let p = m.unclampedPanelPoint(CGPoint(x: 0.95, y: 0.05), panelSize: size)
        #expect(abs(p.x - 750) < 1e-9 && abs(p.y - 500) < 1e-9)
        #expect(m.panelPoint(CGPoint(x: 0.95, y: 0.05), panelSize: size) == CGPoint(x: 600, y: 400))
        let o = m.overscan(panelSize: size)
        #expect(abs(o.width - 200) < 1e-9 && abs(o.height - 133.333) < 0.001)
    }
}
