import CoreGraphics
import Foundation
import Testing
@testable import TouchOSCore

// 唤起方式（decisions.md D19、D25、D26）：三指 / 四指轻点、单指在角落轻点两下、轻点后按住、关闭锚指按住

private let rate = 90.0

private func tuning(_ change: (inout Tuning) -> Void) -> Tuning {
    var t = Tuning.test
    change(&t)
    return t
}

private func run(_ g: Gesture, tuning: Tuning, environment: SessionEnvironment = .test, until: TimeInterval) -> Harness {
    var h = Harness(tuning: tuning, environment: environment)
    h.run(g.frames(rate: rate), until: until)
    return h
}

/// `n` 根手指在 `x` 附近几乎同时落下，`lift` 时全部抬起；`after` 为此前的手势
private func fingers(_ n: Int, x: Double = 0.5, start: TimeInterval = 0, lift: TimeInterval,
                     after: Gesture = Gesture(device: .builtIn)) -> Gesture {
    var g = after
    for i in 0..<n {
        g = g.touch(id: i + 1, at: (x - 0.15 + 0.1 * Double(i), 0.5), t: start + 0.01 * Double(i))
    }
    for i in 0..<n {
        g = g.lift(id: i + 1, t: lift)
    }
    return g
}

private func shownSticky(_ h: Harness) -> Bool {
    h.effects.contains { if case .showPanel(let s) = $0 { s.sticky } else { false } }
}

private func activeID(_ h: Harness) -> String? {
    if case .active(let ctx) = h.machine.state { ctx.layout.id } else { nil }
}

private func activeCorner(_ h: Harness) -> AnchorCorner? {
    if case .active(let ctx) = h.machine.state { ctx.corner } else { nil }
}

@Suite struct TapDetectorTests {
    private let mm = CGSize(width: 100, height: 100)

    private func taps(_ g: Gesture) -> [TapDetector.Tap] {
        var d = TapDetector()
        return g.frames(rate: rate).compactMap { d.feed($0, surfaceMM: mm, maxDuration: 0.25, maxMoveMM: 3) }
    }

    @Test func countsFingersAndAveragesPosition() throws {
        let tap = try #require(taps(fingers(4, lift: 0.12)).first)
        #expect(tap.fingers == 4)
        #expect(abs(tap.centroid.x - 0.5) < 1e-6 && abs(tap.centroid.y - 0.5) < 1e-6)
    }

    @Test func rejectsLongMovingOrAlreadyTouchingGroups() {
        #expect(taps(fingers(4, lift: 0.4)).isEmpty)
        let moving = Gesture(device: .builtIn).touch(id: 1, at: (0.5, 0.5), t: 0).move(id: 1, to: (0.6, 0.5), over: 0.1).lift(id: 1, t: 0.15)
        #expect(taps(moving).isEmpty)
        // 第二根手指在第一根仍按着时落下又抬起：整组直到全部抬起才结算，超时后不算
        let resting = Gesture(device: .builtIn).touch(id: 1, at: (0.2, 0.2), t: 0).hold(id: 1, until: 0.6)
            .touch(id: 2, at: (0.5, 0.5), t: 0.3).lift(id: 2, t: 0.4).lift(id: 1, t: 0.6)
        #expect(taps(resting).isEmpty)
    }

    @Test func groupStartingWithFingersAlreadyDownIsIgnored() {
        var d = TapDetector()
        var frames = fingers(1, lift: 0.1).frames(rate: rate)
        frames.removeFirst()  // 没看到落下：第一帧已是 moved / stationary
        #expect(frames.compactMap { d.feed($0, surfaceMM: mm, maxDuration: 0.25, maxMoveMM: 3) }.isEmpty)
    }
}

@Suite struct TapTriggerTests {
    @Test func fourFingerTapOpensStickyPanelImmediately() {
        let h = run(fingers(4, lift: 0.12), tuning: tuning { $0.fourFingerTap = true }, until: 0.3)
        #expect(h.isActive)
        #expect(shownSticky(h))
        #expect(h.effects.contains(.cursor(.arm)) && h.effects.contains(.cursor(.lock)))
        #expect(h.policies.last?.mode == .active)
    }

    @Test func panelOriginIsWhereTheTapLanded() throws {
        // D20：按钮从唤起位置弹开。测试面板 600×400，映射区 0.05–0.95
        let h = run(fingers(4, x: 0.5, lift: 0.12), tuning: tuning { $0.fourFingerTap = true }, until: 0.3)
        let shown = try #require(h.effects.compactMap { if case .showPanel(let s) = $0 { s } else { nil } }.first)
        let origin = try #require(shown.origin)
        #expect(abs(origin.x - shown.size.width / 2) < 1)
        #expect(abs(origin.y - shown.size.height / 2) < 1)
    }

    @Test func tapsAreIgnoredWhenTheirTriggerIsOff() {
        #expect(!run(fingers(4, lift: 0.12), tuning: .test, until: 0.3).isActive)
        #expect(!run(fingers(4, lift: 0.12), tuning: tuning { $0.threeFingerTap = true }, until: 0.3).isActive)
        #expect(!run(fingers(3, lift: 0.12), tuning: tuning { $0.fourFingerTap = true }, until: 0.3).isActive)
        #expect(run(fingers(3, lift: 0.12), tuning: tuning { $0.threeFingerTap = true }, until: 0.3).isActive)
    }

    @Test func slowTapDoesNotTrigger() {
        #expect(!run(fingers(4, lift: 0.4), tuning: tuning { $0.fourFingerTap = true }, until: 0.6).isActive)
    }

    @Test func eachTapTriggerOpensItsBoundPanel() {
        var env = SessionEnvironment.test
        let other = Layout(id: "other", name: "其他", slots: [])
        env.panels = [.test, other]
        env.bindings = [.threeFingerTap: "other", .fourFingerTap: "missing"]
        let t = tuning { $0.fourFingerTap = true; $0.threeFingerTap = true }
        #expect(activeID(run(fingers(3, lift: 0.12), tuning: t, environment: env, until: 0.3)) == "other")
        // 绑定的面板不存在：打开默认面板
        #expect(activeID(run(fingers(4, lift: 0.12), tuning: t, environment: env, until: 0.3)) == "test")
    }

    @Test func cornerDoubleTapOpensThatCorner() {
        let g = Gesture(device: .builtIn).touch(id: 1, at: Spot.anchor, t: 0).lift(id: 1, t: 0.08)
            .touch(id: 2, at: Spot.anchor, t: 0.25).lift(id: 2, t: 0.33)
        let h = run(g, tuning: tuning { $0.doubleTapCorners = [.bottomLeft] }, until: 0.5)
        #expect(activeCorner(h) == .bottomLeft)
        #expect(shownSticky(h))
        // 锚指按住同时开着：两下轻点各自是一次失败的候选，不影响双击判定
        #expect(h.failures == [.lifted, .lifted])
    }

    @Test func cornerDoubleTapNeedsTwoQuickTapsInTheSameCorner() {
        let t = tuning { $0.doubleTapCorners = [.bottomLeft] }
        let slow = Gesture(device: .builtIn).touch(id: 1, at: Spot.anchor, t: 0).lift(id: 1, t: 0.08)
            .touch(id: 2, at: Spot.anchor, t: 0.6).lift(id: 2, t: 0.68)
        #expect(!run(slow, tuning: t, until: 0.9).isActive)
        let elsewhere = Gesture(device: .builtIn).touch(id: 1, at: Spot.anchor, t: 0).lift(id: 1, t: 0.08)
            .touch(id: 2, at: Spot.gap, t: 0.2).lift(id: 2, t: 0.28)
        #expect(!run(elsewhere, tuning: t, until: 0.5).isActive)
        let single = Gesture(device: .builtIn).touch(id: 1, at: Spot.anchor, t: 0).lift(id: 1, t: 0.08)
        #expect(!run(single, tuning: t, until: 0.5).isActive)
    }

    @Test func holdTriggerCanBeTurnedOff() {
        let g = Gesture(device: .builtIn).touch(id: 1, at: Spot.anchor, t: 0).hold(id: 1, until: 0.6)
        let h = run(g, tuning: tuning { $0.holdCorners = [] }, until: 0.6)
        #expect(!h.isActive && h.failures.isEmpty && h.policies.isEmpty)
    }

    @Test func repeatingTheTapClosesThePanelAfterItCompletes() {
        // D22：面板开着时再四指轻点，等轻点完成才关闭；第三次轻点重新打开
        let t = tuning { $0.fourFingerTap = true }
        let twice = fingers(4, start: 0.5, lift: 0.6, after: fingers(4, lift: 0.12))
        let h = run(twice, tuning: t, until: 0.8)
        #expect(h.ends == [.tapToggle])
        #expect(h.firstTime { $0 == .sessionEnded(.tapToggle) }.map { $0 >= 0.6 } == true)
        #expect(h.policies.last?.passGestures == false)
        let thrice = fingers(4, start: 1.2, lift: 1.3, after: twice)
        #expect(run(thrice, tuning: t, until: 1.5).isActive)
    }

    @Test func otherMultiFingerTapsKeepThePanelWithoutSelecting() {
        let t = tuning { $0.fourFingerTap = true }
        // 两指轻点在按钮上：既不执行也不关闭
        let g = fingers(4, lift: 0.12).touch(id: 7, at: Spot.close, t: 0.5)
            .touch(id: 8, at: Spot.close, t: 0.51).lift(id: 7, t: 0.6).lift(id: 8, t: 0.6)
        let h = run(g, tuning: t, until: 0.8)
        #expect(h.isActive && h.ends.isEmpty && h.actions.isEmpty)
    }

    @Test func tapOpenedPanelSelectsWithOneFingerAndClosesWhenIdle() {
        let t = tuning { $0.fourFingerTap = true }
        let select = fingers(4, lift: 0.12).touch(id: 9, at: Spot.close, t: 0.5).hold(id: 9, until: 0.7).lift(id: 9, t: 0.7)
        let h = run(select, tuning: t, until: 0.9)
        #expect(h.ends == [.committed("close")])
        let idle = run(fingers(4, lift: 0.12), tuning: t, until: 6)
        #expect(idle.ends == [.idleTimeout])
    }
}

@Suite struct TapHoldTests {
    private let t = tuning { $0.tapHold = true }

    private func opened(_ h: Harness) -> Bool {
        h.effects.contains { if case .showPanel = $0 { true } else { false } }
    }

    /// 在 `p` 轻点一下（0–0.08），`second` 时刻在 `q` 再落下、按住到 `lift`
    private func tapThenHold(_ p: (Double, Double), _ q: (Double, Double), second: TimeInterval = 0.2,
                             lift: TimeInterval = 0.4, firstLift: TimeInterval = 0.08) -> Gesture {
        Gesture(device: .builtIn).touch(id: 1, at: p, t: 0).lift(id: 1, t: firstLift)
            .touch(id: 2, at: q, t: second).hold(id: 2, until: lift).lift(id: 2, t: lift)
    }

    @Test func secondTouchDownOpensThePanelAndLiftCommits() {
        let h = run(tapThenHold(Spot.a, (0.21, 0.85)), tuning: t, until: 0.6)
        // 第二下落下的那一帧就出面板，且已悬停在手指下的按钮上
        let shown = h.effects.compactMap { if case .showPanel(let s) = $0 { s } else { nil } }.first
        #expect(shown?.hovered == "a" && shown?.sticky == true)
        #expect(h.firstTime { if case .showPanel = $0 { true } else { false } }.map { abs($0 - 0.2) < 0.02 } == true)
        #expect(h.ends == [.committed("a")])
        #expect(h.actions.map(\.title) == ["全选"])
    }

    @Test func secondTouchMustBeQuickNearAndAlone() {
        #expect(!opened(run(tapThenHold(Spot.a, Spot.a, second: 0.6, lift: 0.8), tuning: t, until: 1)))
        #expect(!opened(run(tapThenHold(Spot.a, Spot.close, lift: 0.6), tuning: t, until: 0.6)))
        // 第一下太久不算轻点
        #expect(!opened(run(tapThenHold(Spot.a, Spot.a, second: 0.5, lift: 0.8, firstLift: 0.4), tuning: t, until: 0.8)))
        // 两指同时落下
        let two = Gesture(device: .builtIn).touch(id: 1, at: Spot.a, t: 0).lift(id: 1, t: 0.08)
            .touch(id: 2, at: Spot.a, t: 0.2).touch(id: 3, at: Spot.gap, t: 0.2).hold(id: 2, until: 0.5).hold(id: 3, until: 0.5)
        #expect(!opened(run(two, tuning: t, until: 0.5)))
        // 关闭时不唤起
        #expect(!opened(run(tapThenHold(Spot.a, Spot.a), tuning: .test, until: 0.6)))
    }

    @Test func physicalClickIsNotATap() {
        // 触摸期间按下过（物理单击 / 双击）：不算轻点
        var pressed = Harness(tuning: t, environment: .test)
        pressed.run(tapThenHold(Spot.a, Spot.a).frames(rate: rate), events: [(0.04, .physicalPress)], until: 0.3)
        #expect(!opened(pressed))
        // 抬起之后才到的按下（系统"轻点来点按"）不影响
        var tapToClick = Harness(tuning: t, environment: .test)
        tapToClick.run(tapThenHold(Spot.a, Spot.a).frames(rate: rate), events: [(0.1, .physicalPress)], until: 0.3)
        #expect(opened(tapToClick))
    }

    @Test func minimumDwellCancelsEarlyLifts() {
        let dwell = tuning { $0.tapHold = true; $0.tapHoldMinMs = 300 }
        let early = run(tapThenHold(Spot.a, Spot.a, lift: 0.35), tuning: dwell, until: 0.6)
        #expect(early.ends == [.earlyLift] && early.actions.isEmpty)
        let late = run(tapThenHold(Spot.a, Spot.a, lift: 0.6), tuning: dwell, until: 0.8)
        #expect(late.ends == [.committed("a")])
    }

    @Test func liftOutsideTheMappingRegionCancels() {
        let small = tuning { $0.tapHold = true; $0.mappingScale = 0.4 }
        let h = run(tapThenHold((0.1, 0.5), (0.1, 0.5)), tuning: small, until: 0.6)
        #expect(h.ends == [.liftOutside] && h.actions.isEmpty)
    }

    @Test func opensItsBoundPanel() {
        var env = SessionEnvironment.test
        env.panels = [.test, Layout(id: "other", name: "其他", slots: [])]
        env.bindings = [.tapHold: "other"]
        #expect(activeID(run(tapThenHold(Spot.gap, Spot.gap, lift: 1), tuning: t, environment: env, until: 0.5)) == "other")
    }

    @Test func cornerDoubleTapTakesTapsInItsCorner() {
        // D26：第一下落在开启了"轻点两下"的角落，让给角落轻点两下：第二下落下时不出面板，抬起后才出
        let both = tuning { $0.tapHold = true; $0.doubleTapCorners = [.bottomLeft]; $0.holdCorners = [] }
        let g = Gesture(device: .builtIn).touch(id: 1, at: Spot.anchor, t: 0).lift(id: 1, t: 0.08)
            .touch(id: 2, at: Spot.anchor, t: 0.2).lift(id: 2, t: 0.28)
        let h = run(g, tuning: both, until: 0.4)
        #expect(h.firstTime { if case .showPanel = $0 { true } else { false } }.map { $0 >= 0.28 } == true)
        #expect(activeCorner(h) == .bottomLeft)
        // 其他位置照常是轻点后按住
        #expect(run(tapThenHold(Spot.a, Spot.a), tuning: both, until: 0.6).ends == [.committed("a")])
    }
}
