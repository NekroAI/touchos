import Foundation
import Testing
@testable import TouchOSCore

private func approx(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool { abs(a - b) <= tolerance }

private func contact(_ frame: TouchFrame, _ id: Int) -> Contact? {
    frame.contacts.first { $0.id == id }
}

/// SRS 14.1 的示例手势
@Suite struct SpecExampleGesture {
    let frames = Gesture(device: .builtIn)
        .touch(id: 1, at: (0.05, 0.06), t: 0)
        .hold(id: 1, until: 0.25)
        .touch(id: 2, at: (0.5, 0.5), t: 0.30)
        .move(id: 2, to: (0.8, 0.8), over: 0.20)
        .lift(id: 2, t: 0.55)
        .lift(id: 1, t: 0.70)
        .frames(rate: 90)

    @Test func samplesAtFixedRateUntilLastLift() {
        #expect(frames.count == 64)  // 0…0.70 s，90 Hz
        #expect(frames.allSatisfy { $0.device == .builtIn })
        for (k, f) in frames.enumerated() {
            #expect(approx(f.timestamp, Double(k) / 90))
        }
    }

    @Test func restingFingerIsStationaryBetweenBeganAndEnded() {
        let phases = frames.compactMap { contact($0, 1)?.phase }
        #expect(phases.count == 64)
        #expect(phases.first == .began)
        #expect(phases.last == .ended)
        #expect(phases.dropFirst().dropLast().allSatisfy { $0 == .stationary })
        #expect(frames.allSatisfy { contact($0, 1)?.position == CGPoint(x: 0.05, y: 0.06) })
    }

    @Test func pointerBeganAtFirstSampleAfterTouch() throws {
        let first = try #require(frames.firstIndex { contact($0, 2) != nil })
        #expect(first == 27)
        #expect(contact(frames[first], 2)?.phase == .began)
        #expect(contact(frames[first], 2)?.velocity == .zero)
    }

    @Test func pointerIsInterpolatedWhileMoving() throws {
        let mid = try #require(contact(frames[36], 2))  // t = 0.40，移动到一半
        #expect(mid.phase == .moved)
        #expect(approx(mid.position.x, 0.65) && approx(mid.position.y, 0.65))
        #expect(approx(mid.velocity.dx, 1.5, 1e-6) && approx(mid.velocity.dy, 1.5, 1e-6))
    }

    @Test func pointerIsStationaryAfterMoveAndEndsAtLiftSample() throws {
        #expect(contact(frames[46], 2)?.phase == .stationary)
        #expect(contact(frames[46], 2)?.velocity == .zero)
        let last = try #require(frames.lastIndex { contact($0, 2) != nil })
        #expect(last == 50)  // 0.55 s 向后取整到采样点
        #expect(contact(frames[last], 2)?.phase == .ended)
        #expect(contact(frames[last], 2)?.position == CGPoint(x: 0.8, y: 0.8))
    }
}

@Test func tapWithinOneSampleStillHasBeganAndEnded() {
    let frames = Gesture(device: .builtIn)
        .touch(id: 1, at: (0.5, 0.5), t: 0)
        .lift(id: 1, t: 0.001)
        .frames(rate: 90)
    #expect(frames.map { $0.contacts.map(\.phase) } == [[.began], [.ended]])
}

@Test func noFramesWhileNothingTouchesAndIDsCanBeReused() {
    let frames = Gesture(device: .builtIn)
        .touch(id: 1, at: (0.2, 0.2), t: 0)
        .lift(id: 1, t: 0.1)
        .touch(id: 1, at: (0.7, 0.7), t: 0.5)
        .lift(id: 1, t: 0.6)
        .frames(rate: 90)
    #expect(frames.count == 20)
    #expect(approx(frames[9].timestamp, 0.1) && frames[9].contacts[0].phase == .ended)
    #expect(approx(frames[10].timestamp, 0.5) && frames[10].contacts[0].phase == .began)
    #expect(frames[10].contacts[0].position == CGPoint(x: 0.7, y: 0.7))
}

@Test func eachDeviceGetsItsOwnFrame() {
    let frames = Gesture(device: .builtIn)
        .touch(id: 1, at: (0.1, 0.1), t: 0)
        .touch(id: 1, at: (0.5, 0.5), t: 0, device: .external)
        .lift(id: 1, t: 0.1, device: .external)
        .hold(id: 1, until: 0.2)
        .frames(rate: 90)
    // 手指 ID 按设备区分：两台设备上的 1 号手指互不影响
    #expect(frames.prefix(2).map(\.device) == [.builtIn, .external])
    #expect(frames.prefix(2).allSatisfy { approx($0.timestamp, 0) && $0.contacts.count == 1 })
    #expect(frames.filter { $0.device == .external }.last?.contacts[0].phase == .ended)
    #expect(frames.filter { $0.device == .builtIn }.count == 19)
    #expect(frames.filter { $0.device == .builtIn }.allSatisfy { $0.contacts[0].phase != .ended })
}

@Test func fingerNotLiftedEndsStationary() {
    let frames = Gesture(device: .builtIn)
        .touch(id: 1, at: (0.3, 0.3), t: 0.2)
        .hold(id: 1, until: 0.3)
        .frames(rate: 100)
    #expect(frames.count == 11)
    #expect(approx(frames[0].timestamp, 0.2))
    #expect(frames.last?.contacts[0].phase == .stationary)
}

@Test func sizeAndPressureArePassedThrough() {
    let frames = Gesture(device: .builtIn)
        .touch(id: 1, at: (0.1, 0.1), t: 0, size: 9, pressure: 0.4)
        .lift(id: 1, t: 0.05)
        .frames(rate: 90)
    #expect(frames.allSatisfy { $0.contacts[0].size == 9 && $0.contacts[0].pressure == 0.4 })
}

@Test func smallJitterBelowThresholdIsStationary() {
    let frames = Gesture(device: .builtIn)
        .touch(id: 1, at: (0.5, 0.5), t: 0)
        .move(id: 1, to: (0.5 + ContactPhase.movementThreshold / 2, 0.5), over: 1 / 90)
        .lift(id: 1, t: 0.1)
        .frames(rate: 90)
    #expect(frames[1].contacts[0].phase == .stationary)
}
