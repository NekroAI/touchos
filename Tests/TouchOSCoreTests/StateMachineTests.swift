import CoreGraphics
import Foundation
import Testing
@testable import TouchOSCore

private let rate = 90.0
private let close = Action.keyboardShortcut(KeyCombo(keyCode: 13, modifiers: [.command], displayLabel: "⌘W"))

/// 锚指在 t = 0 落在锚定区
private func anchorDown() -> Gesture {
    Gesture(device: .builtIn).touch(id: 1, at: Spot.anchor, t: 0)
}

private func run(_ g: Gesture, tuning: Tuning = .test, environment: SessionEnvironment = .test,
                 events: [(TimeInterval, SessionEvent)] = [], until: TimeInterval? = nil) -> Harness {
    var h = Harness(tuning: tuning, environment: environment)
    h.run(g.frames(rate: rate), events: events, until: until)
    return h
}

@Suite struct IdleAndArmedTests {
    @Test func t1ArmsOnLoneNewContactInAnchorZone() {
        let h = run(anchorDown().hold(id: 1, until: 0.05), until: 0.05)
        #expect(h.effects == [.policy(TapPolicy(mode: .armed)), .cursor(.arm), .armed(.builtIn)])
        guard case .armed(let ctx) = h.machine.state else { Issue.record("not armed"); return }
        #expect(ctx.anchorID == 1 && ctx.startedAt == 0)
    }

    @Test func t1IgnoresContactsThatCannotAnchor() {
        let outside = run(Gesture(device: .builtIn).touch(id: 1, at: Spot.gap, t: 0).hold(id: 1, until: 0.4))
        let twoFingers = run(anchorDown().touch(id: 2, at: Spot.gap, t: 0).hold(id: 1, until: 0.4))
        var suspended = SessionEnvironment.test
        suspended.suspended = true
        var noLayout = SessionEnvironment.test
        noLayout.panels = []
        let wrongDevice = Gesture(device: .external).touch(id: 1, at: Spot.anchor, t: 0).hold(id: 1, until: 0.4)
        for h in [outside, twoFingers, run(anchorDown().hold(id: 1, until: 0.4), environment: suspended),
                  run(anchorDown().hold(id: 1, until: 0.4), environment: noLayout), run(wrongDevice)] {
            #expect(h.effects.isEmpty)
            #expect(h.machine.state == .idle)
        }
    }

    @Test func t2EntersActiveAfterDwellAndShowsPanelAfterDelay() throws {
        // AC-1
        let h = run(anchorDown().hold(id: 1, until: 0.7), until: 0.7)
        #expect(h.isActive)
        let entered = try #require(h.firstTime { $0 == .policy(TapPolicy(mode: .active)) })
        #expect(entered >= 0.2 && entered < 0.2 + Harness.tickInterval)
        #expect(h.effects.contains(.cursor(.lock)))
        let shown = try #require(h.firstTime { if case .showPanel = $0 { true } else { false } })
        #expect(shown - entered >= 0.2 && shown - entered < 0.2 + Harness.tickInterval)
    }

    @Test func t2ZeroDelayShowsPanelImmediately() throws {
        var tuning = Tuning.test
        tuning.panelDelayMs = 0
        let h = run(anchorDown().hold(id: 1, until: 0.3), tuning: tuning, until: 0.3)
        let entered = try #require(h.firstTime { $0 == .policy(TapPolicy(mode: .active)) })
        #expect(h.firstTime { if case .showPanel(let s) = $0 { s.size == CGSize(width: 600, height: 400) } else { false } } == entered)
    }

    @Test func t3MovementAbandonsButSmallJitterDoesNot() {
        // 板宽 150 mm：0.02 → 3 mm ≥ 2 mm；0.01 → 1.5 mm
        let moved = run(anchorDown().move(id: 1, to: (0.07, 0.06), over: 0.05).hold(id: 1, until: 0.4))
        #expect(moved.failures == [.moved])
        #expect(Array(moved.effects.suffix(3)) == [.cursor(.compensate), .policy(TapPolicy(mode: .idle)), .armFailed(.moved)])
        let jitter = run(anchorDown().move(id: 1, to: (0.06, 0.06), over: 0.05).hold(id: 1, until: 0.4), until: 0.4)
        #expect(jitter.failures.isEmpty && jitter.isActive)
    }

    @Test func t4PhysicalPressAbandons() {
        let h = run(anchorDown().hold(id: 1, until: 0.4), events: [(0.1, .physicalPress)])
        #expect(h.failures == [.pressed])
        #expect(!h.effects.contains(.cursor(.lock)))
    }

    @Test func t5SecondTouchAbandons() {
        let h = run(anchorDown().hold(id: 1, until: 0.4).touch(id: 2, at: Spot.gap, t: 0.1))
        #expect(h.failures == [.secondTouch])
    }

    @Test func t6LiftAbandons() {
        let h = run(anchorDown().lift(id: 1, t: 0.1))
        #expect(h.failures == [.lifted])
        #expect(h.machine.state == .idle)
    }

    @Test func t7PalmAbandons() {
        let g = Gesture(device: .builtIn).touch(id: 1, at: Spot.anchor, t: 0, size: Tuning.defaultPalmSize).hold(id: 1, until: 0.4)
        #expect(run(g).failures == [.palm])
    }

    @Test func t19AbortsArmedWithoutFailureReason() {
        for event in [SessionEvent.deviceRemoved(.builtIn), .tapDisabled, .forceCancel("lock")] {
            let h = run(anchorDown().hold(id: 1, until: 0.4), events: [(0.1, event)])
            #expect(h.failures.isEmpty)
            #expect(h.effects.contains(.cursor(.compensate)))
            #expect(!h.effects.contains(.cursor(.lock)))
        }
        let other = run(anchorDown().hold(id: 1, until: 0.4), events: [(0.1, .deviceRemoved(.external))], until: 0.4)
        #expect(other.isActive)
    }
}

@Suite struct ActiveTests {
    @Test func t8T9T11SelectAndCommitOnLift() throws {
        // AC-4
        let g = anchorDown().hold(id: 1, until: 1.0)
            .touch(id: 2, at: Spot.gap, t: 0.3).move(id: 2, to: Spot.close, over: 0.2).hold(id: 2, until: 0.7).lift(id: 2, t: 0.7)
        let h = run(g)
        #expect(h.actions.map(\.action) == [close])
        let request = try #require(h.actions.first)
        #expect(request.frontmostBundleID == "com.example.app" && request.title == "关闭")
        #expect(abs(request.notBefore - 0.73) < 1e-9)
        #expect(h.ends == [.committed("close")])
        #expect(h.effects.contains(.haptic))
        // 5.5 退出顺序：隐藏面板 → 光标回到冻结点 → 冷却策略 → 动作
        let i = try #require(h.effects.firstIndex(of: .hidePanel))
        #expect(h.effects[i + 1] == .cursor(.restore))
        guard case .policy(let p) = h.effects[i + 2] else { Issue.record("no cooldown policy"); return }
        #expect(p.mode == .cooldown && abs(p.cooldownUntil - 0.85) < 1e-9 && abs(p.momentumUntil - 1.9) < 1e-9 && !p.passGestures)
        #expect(h.effects[i + 3] == .action(request))
    }

    @Test func t9PanelFollowsPointerOnceVisible() throws {
        let g = anchorDown().hold(id: 1, until: 1.0)
            .touch(id: 2, at: Spot.gap, t: 0.3).move(id: 2, to: Spot.close, over: 0.3).hold(id: 2, until: 0.9)
        let h = run(g, until: 0.9)
        let updates = h.effects.compactMap { if case .updatePanel(let s) = $0 { s } else { nil } }
        #expect(!updates.isEmpty)
        let last = try #require(updates.last)
        #expect(last.hovered == "close")
        let pointer = try #require(last.pointer)
        #expect(abs(pointer.x - 533.333) < 0.01 && abs(pointer.y - 44.444) < 0.01)
    }

    @Test func t8IgnoresContactsInAnchorZoneOrMargin() {
        for spot in [(0.1, 0.1), (0.97, 0.5)] {
            let g = anchorDown().hold(id: 1, until: 1.0)
                .touch(id: 2, at: spot, t: 0.3).move(id: 2, to: Spot.close, over: 0.2).lift(id: 2, t: 0.6)
            let h = run(g, until: 0.9)
            #expect(h.actions.isEmpty && h.isActive)
        }
    }

    @Test func t10BlindSelectionBeforePanelAppears() {
        // AC-11、FR-6.12
        var tuning = Tuning.test
        tuning.panelDelayMs = 300
        let g = anchorDown().hold(id: 1, until: 1.0).touch(id: 2, at: Spot.close, t: 0.25).lift(id: 2, t: 0.35)
        let h = run(g, tuning: tuning)
        #expect(h.actions.map(\.action) == [close])
        #expect(!h.effects.contains { if case .showPanel = $0 { true } else { false } })
    }

    @Test func t12PressRepeatsWithoutLeavingAndLiftOnlyCloses() {
        // AC-7（修订：见 decisions.md D18，连续触发改为按压）
        let g = anchorDown().hold(id: 1, until: 1.2).touch(id: 2, at: Spot.vol, t: 0.3).hold(id: 2, until: 0.9).lift(id: 2, t: 0.9)
        let h = run(g, events: [(0.4, .physicalPress), (0.55, .physicalPress), (0.7, .physicalPress)])
        #expect(h.actions.map(\.action) == Array(repeating: .system(.volumeUp), count: 3))
        #expect(h.effects.filter { $0 == .flashSlot("vol") }.count >= 2)
        #expect(h.ends == [.liftAfterPress])
    }

    @Test func liftOnAnySlotExecutesOnceAndCloses() {
        let g = anchorDown().hold(id: 1, until: 1.0).touch(id: 2, at: Spot.vol, t: 0.3).lift(id: 2, t: 0.4)
        let h = run(g)
        #expect(h.actions.map(\.action) == [.system(.volumeUp)])
        #expect(h.ends == [.committed("vol")])
    }

    @Test func t13GapLiftCloses() {
        // AC-5（修订：见 decisions.md D37，在空白处抬起与取消相同）
        let g = anchorDown().hold(id: 1, until: 1.0).touch(id: 2, at: Spot.gap, t: 0.3).lift(id: 2, t: 0.4)
        let h = run(g)
        #expect(h.actions.isEmpty)
        #expect(h.ends == [.cancelSlot])
    }

    @Test func liftOnCancelSlotClosesWithoutAction() {
        // D17：锚指仍按着时也关闭
        let g = anchorDown().hold(id: 1, until: 1.0).touch(id: 2, at: Spot.null, t: 0.3).lift(id: 2, t: 0.4)
        let h = run(g)
        #expect(h.actions.isEmpty)
        #expect(h.ends == [.cancelSlot])
    }

    @Test func t14AnchorLiftCancels() {
        // AC-6
        let g = anchorDown().hold(id: 1, until: 0.5).lift(id: 1, t: 0.5)
            .touch(id: 2, at: Spot.close, t: 0.3).hold(id: 2, until: 0.8).lift(id: 2, t: 0.8)
        let h = run(g)
        #expect(h.actions.isEmpty)
        #expect(h.ends == [.anchorLifted])
    }

    @Test func t15ThirdFingerCancelsAndPassesGestures() throws {
        // AC-8
        let g = anchorDown().hold(id: 1, until: 0.6)
            .touch(id: 2, at: Spot.close, t: 0.3).hold(id: 2, until: 0.6)
            .touch(id: 3, at: Spot.vol, t: 0.4).hold(id: 3, until: 0.6)
        let h = run(g)
        #expect(h.ends == [.thirdFinger] && h.actions.isEmpty)
        let cooldown = try #require(h.policies.first { $0.mode == .cooldown })
        #expect(cooldown.passGestures)
    }

    @Test func t16EscapeCancels() {
        let h = run(anchorDown().hold(id: 1, until: 0.6), events: [(0.3, .escapeKey)])
        #expect(h.ends == [.escape])
    }

    @Test func t17FrameTimeoutCancels() {
        // 帧在 0.3 s 后停止，锚指未抬起
        let h = run(anchorDown().hold(id: 1, until: 0.3), until: 1.0)
        #expect(h.ends == [.frameTimeout])
        let t = h.firstTime { $0 == .sessionEnded(.frameTimeout) } ?? 0
        #expect(t > 0.8 && t < 0.8 + 2 * Harness.tickInterval)
    }

    @Test func t18MaxDurationCancels() {
        var tuning = Tuning.test
        tuning.maxSessionSec = 0.5
        let h = run(anchorDown().hold(id: 1, until: 1.0), tuning: tuning)
        #expect(h.ends == [.maxDuration])
    }

    @Test func t19AbortsActiveImmediatelyToIdle() {
        let cases: [(SessionEvent, SessionEnd)] = [(.deviceRemoved(.builtIn), .deviceRemoved), (.tapDisabled, .tapDisabled),
                                                   (.forceCancel("lock"), .forced("lock"))]
        for (event, end) in cases {
            let h = run(anchorDown().hold(id: 1, until: 0.6), events: [(0.3, event)], until: 0.31)
            #expect(h.ends == [end])
            #expect(h.machine.state == .idle)
            #expect(Array(h.effects.suffix(4)) == [.hidePanel, .cursor(.restore), .policy(TapPolicy(mode: .idle)), .sessionEnded(end)])
        }
    }

    @Test func liftStabilizerCommitsWhereFingerRested() {
        // FR-6.10：抬起前 30 ms 滑到下方槽位，仍提交原槽位
        let g = anchorDown().hold(id: 1, until: 1.0)
            .touch(id: 2, at: Spot.close, t: 0.3).hold(id: 2, until: 0.6).move(id: 2, to: Spot.vol, over: 0.03).lift(id: 2, t: 0.633)
        #expect(run(g).actions.map(\.action) == [close])
    }

    @Test func outsideMappingRectHoversNothingAndLiftCloses() {
        // 映射区 0.6（0.2–0.8）：右上方映射区之外不选中"关闭"，在那里抬起即关闭面板（decisions.md D21，修订 D9）
        var tuning = Tuning.test
        tuning.mappingScale = 0.6
        let g = anchorDown().hold(id: 1, until: 1.0).touch(id: 2, at: (0.9, 0.9), t: 0.3).lift(id: 2, t: 0.4)
        let h = run(g, tuning: tuning)
        #expect(h.actions.isEmpty)
        #expect(h.ends == [.liftOutside])
        #expect(!h.effects.contains { if case .updatePanel(let s) = $0 { s.hovered != nil } else { false } })
        // 从映射区内移到映射区外：悬停清空
        let out = anchorDown().hold(id: 1, until: 1.0).touch(id: 2, at: (0.75, 0.75), t: 0.3)
            .move(id: 2, to: (0.9, 0.9), over: 0.1).hold(id: 2, until: 0.6)
        guard case .active(let ctx) = run(out, tuning: tuning, until: 0.6).machine.state else { Issue.record("not active"); return }
        #expect(ctx.hovered == nil && ctx.pointer != nil)
    }

    @Test func pointerOnAnotherDeviceIsIgnored() {
        // AC-13、FR-4.4
        var env = SessionEnvironment.test
        env.devices[.external] = TrackpadDevice(id: .external, isBuiltIn: false, displayName: "妙控板",
                                                surfaceSizeMM: CGSize(width: 156, height: 110))
        let g = anchorDown().hold(id: 1, until: 1.0)
            .touch(id: 2, at: Spot.close, t: 0.3, device: .external).lift(id: 2, t: 0.5, device: .external)
        let h = run(g, environment: env, until: 0.9)
        #expect(h.actions.isEmpty && h.isActive)
    }

    @Test func vanishedPointerIsDroppedWithoutCommit() {
        var h = Harness()
        h.run(anchorDown().hold(id: 1, until: 0.5).touch(id: 2, at: Spot.close, t: 0.3).hold(id: 2, until: 0.5).frames(rate: rate), until: 0.5)
        let anchorOnly = TouchFrame(device: .builtIn, timestamp: 0.52, contacts: [
            Contact(id: 1, phase: .stationary, position: CGPoint(x: 0.05, y: 0.06), velocity: .zero, size: 1, pressure: 0),
            Contact(id: 2, phase: .cancelled, position: CGPoint(x: 0.85, y: 0.85), velocity: .zero, size: 1, pressure: 0),
        ])
        h.send(.frame(anchorOnly), at: 0.52)
        #expect(h.actions.isEmpty && h.isActive)
        guard case .active(let ctx) = h.machine.state else { return }
        #expect(ctx.pointer == nil && ctx.hovered == nil)
    }
}

@Suite struct CooldownTests {
    @Test func t20ReturnsToIdleKeepingMomentumSuppression() throws {
        let g = anchorDown().hold(id: 1, until: 1.0).touch(id: 2, at: Spot.close, t: 0.3).lift(id: 2, t: 0.4)
        let h = run(g)
        #expect(h.machine.state == .idle)
        let last = try #require(h.policies.last)
        #expect(last.mode == .idle && abs(last.momentumUntil - 1.6) < 1e-9)
        let idleAt = try #require(h.firstTime { $0 == .policy(last) })
        #expect(idleAt >= 0.55 && idleAt < 0.55 + Harness.tickInterval)
    }

    @Test func t21IgnoresNewContactsDuringCooldownThenArmsAgain() {
        let g = anchorDown().hold(id: 1, until: 0.4).touch(id: 2, at: Spot.close, t: 0.3).lift(id: 2, t: 0.4).lift(id: 1, t: 0.4)
            .touch(id: 3, at: Spot.anchor, t: 0.45).lift(id: 3, t: 0.5)    // 冷却期内（截止 0.55）
            .touch(id: 4, at: Spot.anchor, t: 0.7).hold(id: 4, until: 1.0)  // 冷却结束后
        let h = run(g, until: 1.0)
        #expect(h.failures.isEmpty)
        #expect(h.effects.filter { $0 == .armed(.builtIn) }.count == 2)
        #expect(h.isActive)
    }

    @Test func anchorLiftDuringGraceCommitsThePointerLift() {
        // D36：指点指先抬起、锚指在宽限期内跟着抬起，仍执行指点指所在的按钮
        let g = anchorDown().hold(id: 1, until: 0.53).touch(id: 2, at: Spot.close, t: 0.3).hold(id: 2, until: 0.5).lift(id: 2, t: 0.5)
            .lift(id: 1, t: 0.53)
        let h = run(g, until: 0.8)
        #expect(h.ends == [.committed("close")] && h.actions.count == 1)
    }

    @Test func tuningChangesWaitUntilIdle() {
        var h = Harness()
        h.run(anchorDown().hold(id: 1, until: 0.3).frames(rate: rate), until: 0.3)
        var t = Tuning.test
        t.mappingScale = 0.5
        h.send(.tuning(t), at: 0.3)
        #expect(h.machine.tuning.mappingScale == 0.9)  // 激活中：延后
        h.send(.escapeKey, at: 0.31)
        h.send(.tick(0.5), at: 0.5)                    // 冷却结束回到空闲
        h.send(.tick(0.52), at: 0.52)
        #expect(h.machine.state == .idle)
        h.send(.frame(TouchFrame(device: .builtIn, timestamp: 0.6, contacts: [])), at: 0.6)
        #expect(h.machine.tuning.mappingScale == 0.5)
        var idle = Harness()
        idle.send(.tuning(t), at: 0)
        #expect(idle.machine.tuning.mappingScale == 0.5)  // 空闲：立即生效
    }

    @Test func environmentUpdatesApplyToNextSession() {
        var h = Harness()
        var env = SessionEnvironment.test
        env.suspended = true
        h.send(.environment(env), at: 0)
        h.run(anchorDown().hold(id: 1, until: 0.4).frames(rate: rate))
        #expect(h.effects.isEmpty)
        #expect(h.machine.environment.suspended)
    }
}
