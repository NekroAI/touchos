import CoreGraphics
import Foundation
import Testing
@testable import TouchOSCore

private let rate = 90.0
private let close = Action.keyboardShortcut(KeyCombo(keyCode: 13, modifiers: [.command], displayLabel: "⌘W"))

private func run(_ g: Gesture, tuning: Tuning = .test, environment: SessionEnvironment = .test,
                 events: [(TimeInterval, SessionEvent)] = [], until: TimeInterval? = nil) -> Harness {
    var h = Harness(tuning: tuning, environment: environment)
    h.run(g.frames(rate: rate), events: events, until: until)
    return h
}

/// 第一下轻点之后，手指 2 在 0.1 s 落在 `p`（第二下），不预设之后的动作
private func secondDown(_ p: (Double, Double) = Spot.gap, size: Float = Gesture.fingerSize) -> Gesture {
    Gesture(device: .builtIn).touch(id: 1, at: p, t: 0).lift(id: 1, t: 0.05).touch(id: 2, at: p, t: 0.1, size: size)
}

private func shown(_ h: Harness) -> Bool {
    h.effects.contains { if case .showPanel = $0 { true } else { false } }
}

/// 轻点后按住的确认期（D38）：第二下停留满 `P.tapHoldDelayMs` 才打开面板
@Suite struct ArmedTests {
    @Test func t1ArmsOnSecondTouchAfterTap() {
        let h = run(.tapHold(until: 0.15), until: 0.15)
        #expect(h.effects == [.policy(TapPolicy(mode: .armed)), .cursor(.arm), .armed(.builtIn)])
        #expect(h.firstTime { $0 == .armed(.builtIn) } == 0.1)
        guard case .armed(let ctx) = h.machine.state else { Issue.record("not armed"); return }
        #expect(ctx.contactID == 2 && ctx.startedAt == 0.1 && ctx.trigger == .tapHold)
        #expect(ctx.entry == CGPoint(x: 0.5, y: 0.5) && ctx.origin == ctx.entry && ctx.latest == ctx.entry)
    }

    @Test func t1IgnoresSecondTouchesThatCannotArm() {
        var suspended = SessionEnvironment.test
        suspended.suspended = true
        var noLayout = SessionEnvironment.test
        noLayout.panels = []
        // 第二下太晚、太远、两指同时落下
        let late = Gesture(device: .builtIn).touch(id: 1, at: Spot.gap, t: 0).lift(id: 1, t: 0.05)
            .touch(id: 2, at: Spot.gap, t: 0.5).hold(id: 2, until: 0.9)
        let far = Gesture(device: .builtIn).touch(id: 1, at: Spot.gap, t: 0).lift(id: 1, t: 0.05)
            .touch(id: 2, at: Spot.close, t: 0.1).hold(id: 2, until: 0.5)
        let two = Gesture.tapHold(until: 0.5).touch(id: 3, at: Spot.a, t: 0.1).hold(id: 3, until: 0.5)
        let wrongDevice = Gesture(device: .external).touch(id: 1, at: Spot.gap, t: 0).lift(id: 1, t: 0.05)
            .touch(id: 2, at: Spot.gap, t: 0.1).hold(id: 2, until: 0.5)
        for h in [run(late), run(far), run(two), run(wrongDevice), run(.tapHold(until: 0.5), environment: suspended),
                  run(.tapHold(until: 0.5), environment: noLayout),
                  run(.tapHold(until: 0.5), tuning: { var t = Tuning.test; t.tapHold = false; return t }())] {
            #expect(h.effects.isEmpty)
            #expect(h.machine.state == .idle)
        }
    }

    @Test func t2EntersActiveAfterDelayAndShowsPanelAtOnce() throws {
        // AC-1（修订：见 decisions.md D38）
        let h = run(.tapHold(at: Spot.close, until: 0.4), until: 0.4)
        #expect(h.isActive)
        let entered = try #require(h.firstTime { $0 == .policy(TapPolicy(mode: .active)) })
        #expect(entered >= Gesture.panelOpensAt && entered < Gesture.panelOpensAt + 1 / rate)
        // 光标在确认期开始时已记录冻结点，进入激活只锁定
        #expect(h.effects.filter { $0 == .cursor(.arm) }.count == 1)
        let i = try #require(h.effects.firstIndex(of: .policy(TapPolicy(mode: .active))))
        #expect(h.effects[i + 1] == .cursor(.lock))
        guard case .showPanel(let s) = h.effects[i + 2] else { Issue.record("panel not shown"); return }
        #expect(s.hovered == "close" && s.pointer != nil && s.size == CGSize(width: 600, height: 400))
        guard case .active(let ctx) = h.machine.state else { return }
        #expect(ctx.pointer?.id == 2)
    }

    @Test func t2ZeroDelayEntersOnLanding() throws {
        var tuning = Tuning.test
        tuning.tapHoldDelayMs = 0
        let h = run(.tapHold(until: 0.3), tuning: tuning, until: 0.3)
        let entered = try #require(h.firstTime { $0 == .policy(TapPolicy(mode: .active)) })
        #expect(entered == 0.1)
        #expect(!h.effects.contains(.armed(.builtIn)) && !h.policies.contains { $0.mode == .armed })
        #expect(Array(h.effects.prefix(3)) == [.policy(TapPolicy(mode: .active)), .cursor(.arm), .cursor(.lock)])
        #expect(h.firstTime { if case .showPanel = $0 { true } else { false } } == entered)
    }

    @Test func t2EntersOnTickWhenNoFrameArrives() throws {
        // 30 Hz：确认期满（0.22）时还没有下一帧，由 tick 进入
        var h = Harness()
        h.run(Gesture.tapHold(until: 0.4).frames(rate: 30), until: 0.4)
        let entered = try #require(h.firstTime { $0 == .policy(TapPolicy(mode: .active)) })
        #expect(entered >= 0.22 && entered < 0.22 + Harness.tickInterval)
        #expect(h.isActive)
    }

    @Test func t3MovementAbandonsButSmallJitterDoesNot() {
        // 板宽 150 mm：0.02 → 3 mm ≥ 2 mm；0.01 → 1.5 mm
        let moved = run(Gesture.tapHold(until: 0.12).move(id: 2, to: (0.52, 0.5), over: 0.05).hold(id: 2, until: 0.4))
        #expect(moved.failures == [.moved] && !shown(moved))
        #expect(Array(moved.effects.suffix(3)) == [.cursor(.compensate), .policy(TapPolicy(mode: .idle)), .armFailed(.moved)])
        let jitter = run(Gesture.tapHold(until: 0.12).move(id: 2, to: (0.51, 0.5), over: 0.05).hold(id: 2, until: 0.4), until: 0.4)
        #expect(jitter.failures.isEmpty && jitter.isActive)
    }

    @Test func t4PhysicalPressAbandons() {
        let h = run(.tapHold(until: 0.4), events: [(0.15, .physicalPress)])
        #expect(h.failures == [.pressed])
        #expect(!h.effects.contains(.cursor(.lock)) && h.machine.state == .idle)
    }

    @Test func t5SecondTouchAbandons() {
        let h = run(Gesture.tapHold(until: 0.4).touch(id: 3, at: Spot.a, t: 0.15))
        #expect(h.failures == [.secondTouch] && !shown(h))
    }

    @Test func t6LiftBeforeDelayIsJustATap() {
        let h = run(Gesture.tapHold(until: 0.15).lift(id: 2, t: 0.15))
        #expect(h.failures == [.lifted] && !shown(h))
        #expect(h.machine.state == .idle && h.policies.last?.mode == .idle)
    }

    @Test func t7PalmAbandons() {
        let g = secondDown(size: Tuning.defaultPalmSize).hold(id: 2, until: 0.4)
        #expect(run(g).failures == [.palm])
    }

    @Test func longerDelayWaitsLonger() throws {
        var tuning = Tuning.test
        tuning.tapHoldDelayMs = 300
        let early = run(Gesture.tapHold(until: 0.35).lift(id: 2, t: 0.35), tuning: tuning)
        #expect(early.failures == [.lifted] && !shown(early))
        let late = run(.tapHold(until: 0.6), tuning: tuning, until: 0.6)
        let entered = try #require(late.firstTime { $0 == .policy(TapPolicy(mode: .active)) })
        #expect(entered >= 0.4 && entered < 0.4 + 1 / rate)
    }

    @Test func t19AbortsArmedWithoutFailureReason() {
        for event in [SessionEvent.deviceRemoved(.builtIn), .tapDisabled, .forceCancel("lock")] {
            let h = run(.tapHold(until: 0.4), events: [(0.15, event)])
            #expect(h.failures.isEmpty)
            #expect(Array(h.effects.suffix(2)) == [.cursor(.compensate), .policy(TapPolicy(mode: .idle))])
            #expect(!h.effects.contains(.cursor(.lock)) && !shown(h))
        }
        let other = run(.tapHold(until: 0.4), events: [(0.15, .deviceRemoved(.external)), (0.16, .escapeKey)], until: 0.4)
        #expect(other.isActive)
    }

    @Test func otherDeviceDoesNotDisturbConfirmation() {
        // FR-4.4：另一台设备上的触摸不算第二根手指
        var env = SessionEnvironment.test
        env.devices[.external] = TrackpadDevice(id: .external, isBuiltIn: false, displayName: "妙控板",
                                                surfaceSizeMM: CGSize(width: 156, height: 110))
        let g = Gesture.tapHold(until: 0.4).touch(id: 3, at: Spot.a, t: 0.15, device: .external).hold(id: 3, until: 0.4, device: .external)
        let h = run(g, environment: env, until: 0.4)
        #expect(h.failures.isEmpty && h.isActive)
    }

    @Test func panelsRemovedDuringConfirmationAbort() {
        var h = Harness()
        var empty = SessionEnvironment.test
        empty.panels = []
        h.run(Gesture.tapHold(until: 0.4).frames(rate: rate), events: [(0.15, .environment(empty))], until: 0.4)
        #expect(h.machine.state == .idle && !shown(h) && h.failures.isEmpty)
        #expect(Array(h.effects.suffix(2)) == [.cursor(.compensate), .policy(TapPolicy(mode: .idle))])
    }
}

@Suite struct ActiveTests {
    @Test func t8T9T11SelectAndCommitOnLift() throws {
        // AC-4
        let g = Gesture.tapHold(until: 0.3).move(id: 2, to: Spot.close, over: 0.2).hold(id: 2, until: 0.7).lift(id: 2, t: 0.7)
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

    @Test func t9PanelFollowsPointer() throws {
        let g = Gesture.tapHold(until: 0.3).move(id: 2, to: Spot.close, over: 0.3).hold(id: 2, until: 0.9)
        let h = run(g, until: 0.9)
        let updates = h.effects.compactMap { if case .updatePanel(let s) = $0 { s } else { nil } }
        #expect(!updates.isEmpty)
        let last = try #require(updates.last)
        #expect(last.hovered == "close")
        let pointer = try #require(last.pointer)
        #expect(abs(pointer.x - 533.333) < 0.01 && abs(pointer.y - 44.444) < 0.01)
    }

    @Test func t8NewPointerMustStartInsideMargin() {
        // 面板开着、没有指点指：落在四周边缘的接触不成为指点指
        let edge = Gesture.fourFingerTap().touch(id: 5, at: (0.97, 0.5), t: 0.3).move(id: 5, to: Spot.close, over: 0.2).lift(id: 5, t: 0.6)
        let h = run(edge, until: 0.9)
        #expect(h.actions.isEmpty && h.isActive)
        let inside = Gesture.fourFingerTap().touch(id: 5, at: Spot.gap, t: 0.3).move(id: 5, to: Spot.close, over: 0.2).lift(id: 5, t: 0.6)
        #expect(run(inside).actions.map(\.action) == [close])
    }

    @Test func t12PressRepeatsWithoutLeavingAndLiftOnlyCloses() {
        // AC-7（修订：见 decisions.md D18，连续触发改为按压）
        let g = Gesture.tapHold(at: Spot.vol, until: 0.9).lift(id: 2, t: 0.9)
        let h = run(g, events: [(0.4, .physicalPress), (0.55, .physicalPress), (0.7, .physicalPress)])
        #expect(h.actions.map(\.action) == Array(repeating: .system(.volumeUp), count: 3))
        #expect(h.effects.filter { $0 == .flashSlot("vol") }.count >= 2)
        #expect(h.ends == [.liftAfterPress])
    }

    @Test func liftOnAnySlotExecutesOnceAndCloses() {
        let h = run(Gesture.tapHold(at: Spot.vol, until: 0.4).lift(id: 2, t: 0.4))
        #expect(h.actions.map(\.action) == [.system(.volumeUp)])
        #expect(h.ends == [.committed("vol")])
    }

    @Test func t13GapLiftCloses() {
        // AC-5（修订：见 decisions.md D37，在空白处抬起与取消相同）
        let h = run(Gesture.tapHold(at: Spot.gap, until: 0.4).lift(id: 2, t: 0.4))
        #expect(h.actions.isEmpty)
        #expect(h.ends == [.cancelSlot])
    }

    @Test func liftOnCancelSlotClosesWithoutAction() {
        // D17
        let h = run(Gesture.tapHold(at: Spot.null, until: 0.4).lift(id: 2, t: 0.4))
        #expect(h.actions.isEmpty)
        #expect(h.ends == [.cancelSlot])
    }

    @Test func t16EscapeCancels() {
        let h = run(.tapHold(until: 0.6), events: [(0.3, .escapeKey)])
        #expect(h.ends == [.escape])
    }

    @Test func t17FrameTimeoutCancels() {
        // 帧在 0.3 s 后停止，指点指未抬起
        let h = run(.tapHold(until: 0.3), until: 1.0)
        #expect(h.ends == [.frameTimeout])
        let t = h.firstTime { $0 == .sessionEnded(.frameTimeout) } ?? 0
        #expect(t > 0.8 && t < 0.8 + 2 * Harness.tickInterval)
    }

    @Test func t18MaxDurationCancels() {
        var tuning = Tuning.test
        tuning.maxSessionSec = 0.5
        let h = run(.tapHold(until: 1.0), tuning: tuning)
        #expect(h.ends == [.maxDuration])
    }

    @Test func t19AbortsActiveImmediatelyToIdle() {
        let cases: [(SessionEvent, SessionEnd)] = [(.deviceRemoved(.builtIn), .deviceRemoved), (.tapDisabled, .tapDisabled),
                                                   (.forceCancel("lock"), .forced("lock"))]
        for (event, end) in cases {
            let h = run(.tapHold(until: 0.6), events: [(0.3, event)], until: 0.31)
            #expect(h.ends == [end])
            #expect(h.machine.state == .idle)
            #expect(Array(h.effects.suffix(4)) == [.hidePanel, .cursor(.restore), .policy(TapPolicy(mode: .idle)), .sessionEnded(end)])
        }
        let other = run(.tapHold(until: 0.6), events: [(0.3, .deviceRemoved(.external))], until: 0.6)
        #expect(other.isActive)
    }

    @Test func liftStabilizerCommitsWhereFingerRested() {
        // FR-6.10：抬起前 30 ms 滑到下方槽位，仍提交原槽位
        let g = Gesture.tapHold(at: Spot.close, until: 0.6).move(id: 2, to: Spot.vol, over: 0.03).lift(id: 2, t: 0.633)
        #expect(run(g).actions.map(\.action) == [close])
    }

    @Test func outsideMappingRectHoversNothingAndLiftCloses() {
        // 映射区 0.6（0.2–0.8）：右上方映射区之外不选中"关闭"，在那里抬起即关闭面板（decisions.md D21，修订 D9）
        var tuning = Tuning.test
        tuning.mappingScale = 0.6
        let h = run(Gesture.tapHold(at: (0.9, 0.9), until: 0.4).lift(id: 2, t: 0.4), tuning: tuning)
        #expect(h.actions.isEmpty)
        #expect(h.ends == [.liftOutside])
        #expect(!h.effects.contains { if case .updatePanel(let s) = $0 { s.hovered != nil } else { false } })
        // 从映射区内移到映射区外：悬停清空
        let out = Gesture.tapHold(at: (0.75, 0.75), until: 0.3).move(id: 2, to: (0.9, 0.9), over: 0.1).hold(id: 2, until: 0.6)
        guard case .active(let ctx) = run(out, tuning: tuning, until: 0.6).machine.state else { Issue.record("not active"); return }
        #expect(ctx.hovered == nil && ctx.pointer != nil)
    }

    @Test func pointerOnAnotherDeviceIsIgnored() {
        // AC-13、FR-4.4
        var env = SessionEnvironment.test
        env.devices[.external] = TrackpadDevice(id: .external, isBuiltIn: false, displayName: "妙控板",
                                                surfaceSizeMM: CGSize(width: 156, height: 110))
        let g = Gesture.tapHold(until: 0.9)
            .touch(id: 3, at: Spot.close, t: 0.3, device: .external).lift(id: 3, t: 0.5, device: .external)
        let h = run(g, environment: env, until: 0.9)
        #expect(h.actions.isEmpty && h.isActive)
    }

    @Test func vanishedPointerIsDroppedWithoutCommit() {
        var h = Harness()
        h.run(Gesture.tapHold(at: Spot.close, until: 0.5).frames(rate: rate), until: 0.5)
        let cancelled = TouchFrame(device: .builtIn, timestamp: 0.52, contacts: [
            Contact(id: 2, phase: .cancelled, position: CGPoint(x: 0.85, y: 0.85), velocity: .zero, size: 1, pressure: 0),
        ])
        h.send(.frame(cancelled), at: 0.52)
        #expect(h.actions.isEmpty && h.isActive)
        guard case .active(let ctx) = h.machine.state else { return }
        #expect(ctx.pointer == nil && ctx.hovered == nil)
    }
}

@Suite struct CooldownTests {
    @Test func t20ReturnsToIdleKeepingMomentumSuppression() throws {
        let h = run(Gesture.tapHold(at: Spot.close, until: 0.4).lift(id: 2, t: 0.4))
        #expect(h.machine.state == .idle)
        let last = try #require(h.policies.last)
        #expect(last.mode == .idle && abs(last.momentumUntil - 1.6) < 1e-9)
        let idleAt = try #require(h.firstTime { $0 == .policy(last) })
        #expect(idleAt >= 0.55 && idleAt < 0.55 + Harness.tickInterval)
    }

    @Test func t21IgnoresNewContactsDuringCooldownThenArmsAgain() {
        // 抬起 0.4，宽限期过后（约 0.5）进入冷却，截止 0.55
        let g = Gesture.tapHold(at: Spot.close, until: 0.4).lift(id: 2, t: 0.4)
            .touch(id: 3, at: Spot.gap, t: 0.52).lift(id: 3, t: 0.54)      // 冷却期内的轻点：不算第一下
            .touch(id: 4, at: Spot.gap, t: 0.6).hold(id: 4, until: 1.0).lift(id: 4, t: 1.0)
            .tapHold(at: Spot.gap, id: 6, tapID: 5, t: 1.2, until: 1.6)     // 冷却结束后
        let h = run(g, until: 1.6)
        #expect(h.failures.isEmpty)
        #expect(h.effects.filter { $0 == .armed(.builtIn) }.count == 2)
        #expect(h.isActive)
    }

    @Test func tuningChangesWaitUntilIdle() {
        var h = Harness()
        h.run(Gesture.tapHold(until: 0.3).frames(rate: rate), until: 0.3)
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
        h.run(Gesture.tapHold(until: 0.4).frames(rate: rate))
        #expect(h.effects.isEmpty)
        #expect(h.machine.environment.suspended)
    }
}
