import CoreGraphics
import Foundation
import Testing
@testable import TouchOSCore

private func raw(_ id: Int, _ state: Int, _ x: Double = 0.5, _ y: Double = 0.5, size: Float = 1) -> RawContact {
    RawContact(id: id, state: state, position: CGPoint(x: x, y: y), velocity: CGVector(dx: 0.1, dy: 0), size: size, pressure: 0)
}

@Suite struct ContactTrackerTests {
    @Test func mapsRawStatesToPhases() {
        var t = ContactTracker()
        let r1 = t.process([raw(1, 3)])
        #expect(r1.map(\.phase) == [.began])
        let r2 = t.process([raw(1, 4)])
        #expect(r2.map(\.phase) == [.stationary])
        let r3 = t.process([raw(1, 4, 0.6)])
        #expect(r3.map(\.phase) == [.moved])
        let r4 = t.process([raw(1, 5, 0.6)])
        #expect(r4.map(\.phase) == [.ended])
        let r5 = t.process([raw(1, 7, 0.6)])
        #expect(r5.isEmpty)
    }

    @Test func movementAtThresholdIsStationary() {
        var t = ContactTracker()
        _ = t.process([raw(1, 3)])
        let r6 = t.process([raw(1, 4, 0.5 + ContactPhase.movementThreshold / 2)])
        #expect(r6.map(\.phase) == [.stationary])
        // 与上一帧比较，而不是与落点比较
        let r7 = t.process([raw(1, 4, 0.5 + ContactPhase.movementThreshold * 3)])
        #expect(r7.map(\.phase) == [.moved])
    }

    @Test func ignoresHoverAndUnknownStates() {
        var t = ContactTracker()
        for state in [0, 1, 2, 6, 7, 8] {
            let r8 = t.process([raw(1, state)])
            #expect(r8.isEmpty)
        }
    }

    @Test func passesThroughRawFields() throws {
        var t = ContactTracker()
        let c = try #require(t.process([raw(2, 3, 0.2, 0.3, size: 4)]).first)
        #expect(c.id == 2 && c.position == CGPoint(x: 0.2, y: 0.3) && c.size == 4)
        #expect(c.velocity == CGVector(dx: 0.1, dy: 0))
    }

    @Test func vanishedContactIsCancelledOnce() {
        var t = ContactTracker()
        _ = t.process([raw(1, 3, 0.1, 0.1), raw(2, 3)])
        let out = t.process([raw(2, 4)])
        #expect(out.map(\.id) == [2, 1])
        #expect(out[1].phase == .cancelled && out[1].position == CGPoint(x: 0.1, y: 0.1) && out[1].velocity == .zero)
        let r9 = t.process([raw(2, 4)])
        #expect(r9.map(\.phase) == [.stationary])
    }

    @Test func contactTurningIntoIgnoredStateIsCancelled() {
        var t = ContactTracker()
        _ = t.process([raw(1, 3)])
        let r10 = t.process([raw(1, 6)])
        #expect(r10.map(\.phase) == [.cancelled])
    }

    @Test func endedContactIsNotCancelledLater() {
        var t = ContactTracker()
        _ = t.process([raw(1, 3)])
        _ = t.process([raw(1, 5)])
        let r11 = t.process([])
        #expect(r11.isEmpty)
    }

    @Test func touchingWithoutHistoryIsStationary() {
        var t = ContactTracker()
        let r12 = t.process([raw(1, 4)])
        #expect(r12.map(\.phase) == [.stationary])
    }
}

@Suite struct LayoutSelfCheckTests {
    @Test func flagsMismatchAfterConsecutiveOutOfRangeFrames() {
        var check = LayoutSelfCheck()
        for _ in 1..<LayoutSelfCheck.mismatchFrames {
            let r13 = check.observe([raw(1, 4, 3.2, -7)])
            #expect(!r13)
        }
        let r14 = check.observe([raw(1, 4, 3.2, -7)])
        #expect(r14)
    }

    @Test func inRangeFrameResetsCount() {
        var check = LayoutSelfCheck()
        for _ in 1..<LayoutSelfCheck.mismatchFrames { _ = check.observe([raw(1, 4, 1.5)]) }
        let r15 = check.observe([raw(1, 4, 0.5)])
        #expect(!r15)
        let r16 = check.observe([raw(1, 4, 1.5)])
        #expect(!r16)
    }

    @Test func framesWithoutValidContactsDoNotCount() {
        var check = LayoutSelfCheck()
        for _ in 0..<(LayoutSelfCheck.mismatchFrames * 2) {
            let r17 = check.observe([raw(1, 7, 9, 9)])
            #expect(!r17)
            let r18 = check.observe([])
            #expect(!r18)
        }
    }
}

@Suite struct FrameRateMeterTests {
    @Test func summarizesContinuousTouch() throws {
        var m = FrameRateMeter()
        for k in 0..<91 {
            let r19 = m.observe(timestamp: Double(k) / 90, hasContacts: true)
            #expect(r19 == nil)
        }
        let ended = m.observe(timestamp: 91.0 / 90, hasContacts: false)
        let s = try #require(ended)
        #expect(s.frames == 91)
        #expect(abs(s.duration - 1) < 1e-9)
        #expect(abs(s.meanHz - 90) < 1e-6)
        #expect(abs(s.p95Interval - 1.0 / 90) < 1e-9 && abs(s.maxInterval - 1.0 / 90) < 1e-9)
        #expect(m.summary == nil)
    }

    @Test func p95AndMaxReflectGaps() throws {
        var m = FrameRateMeter()
        var t = 0.0
        for k in 0..<101 {
            _ = m.observe(timestamp: t, hasContacts: true)
            t += k == 50 ? 0.1 : 0.01
        }
        let s = try #require(m.summary)
        #expect(abs(s.maxInterval - 0.1) < 1e-9)
        #expect(abs(s.p95Interval - 0.01) < 1e-9)
    }

    @Test func singleFrameHasNoSummary() {
        var m = FrameRateMeter()
        _ = m.observe(timestamp: 0, hasContacts: true)
        let r21 = m.observe(timestamp: 0.01, hasContacts: false)
        #expect(r21 == nil)
    }

    @Test func keepsOnlyRecentIntervals() throws {
        var m = FrameRateMeter()
        for k in 0...(FrameRateMeter.capacity + 10) {
            _ = m.observe(timestamp: Double(k), hasContacts: true)
        }
        let s = try #require(m.summary)
        #expect(abs(s.duration - Double(FrameRateMeter.capacity)) < 1e-9)
    }
}
