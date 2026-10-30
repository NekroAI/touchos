import Foundation
import Testing
@testable import TouchOSCore

@Suite struct CursorFreezeConfigTests {
    private func decode(_ json: String) throws -> AppConfig.General {
        try JSONDecoder().decode(AppConfig.General.self, from: Data(json.utf8))
    }

    @Test func defaultsToHideAndRoundTrips() throws {
        #expect(try decode("{}").cursorFreeze == .hide)
        var general = AppConfig.General()
        general.cursorFreeze = .keep
        let data = try JSONEncoder().encode(general)
        #expect(try JSONDecoder().decode(AppConfig.General.self, from: data).cursorFreeze == .keep)
    }

    @Test func unknownValueFallsBackWithoutFailing() throws {
        #expect(try decode(#"{"cursorFreeze":"future","haptics":false}"#).cursorFreeze == .hide)
    }
}

@Suite struct DeviceClockAlignerTests {
    @Test func keepsDeviceIntervalsAcrossDeliveryJitter() {
        var c = DeviceClockAligner(resyncThreshold: 0.2)
        _ = c.align(deviceTime: 10, received: 100.005)
        // 第二帧送达更快：偏移取最小值
        #expect(abs(c.align(deviceTime: 10.01, received: 100.011).timestamp - 100.011) < 1e-9)
        // 第三帧送达较慢但没超过阈值：仍按设备时钟的间隔算
        let third = c.align(deviceTime: 10.02, received: 100.05)
        #expect(abs(third.timestamp - 100.021) < 1e-9)
        #expect(!third.resynced)
    }

    /// 0.1.2 的现场：设备时钟落后约 24.8 秒后，帧时间一直偏早，面板一打开就被判为帧超时
    @Test func resyncsAfterDeviceClockPauses() {
        var c = DeviceClockAligner(resyncThreshold: 0.2)
        _ = c.align(deviceTime: 10, received: 100)
        let paused = c.align(deviceTime: 10.01, received: 124.81)
        #expect(paused.resynced)
        #expect(abs(paused.timestamp - 124.81) < 1e-9)
        let next = c.align(deviceTime: 10.02, received: 124.82)
        #expect(!next.resynced)
        #expect(abs(next.timestamp - 124.82) < 1e-9)
    }

    /// 内置触控板：时钟每段触摸之间都落后一点，不到阈值也不能累积
    @Test func reanchorsWhenFingerComesDown() {
        var c = DeviceClockAligner(resyncThreshold: 0.2)
        _ = c.align(deviceTime: 10, received: 100)
        let touch = c.align(deviceTime: 20, received: 110.03, touchBegan: true)
        #expect(!touch.resynced)
        #expect(abs(touch.lag - 0.03) < 1e-9)
        #expect(abs(touch.timestamp - 110.03) < 1e-9)
        // 这段触摸接下来的帧不再偏早
        #expect(abs(c.align(deviceTime: 20.01, received: 110.04).timestamp - 110.04) < 1e-9)
    }

    @Test func resyncsAfterDeviceClockResets() {
        var c = DeviceClockAligner(resyncThreshold: 0.2)
        _ = c.align(deviceTime: 5000, received: 100)
        let reset = c.align(deviceTime: 1, received: 101)
        #expect(reset.resynced)
        #expect(abs(reset.timestamp - 101) < 1e-9)
    }

    @Test func followsDeviceClockJumpingForward() {
        var c = DeviceClockAligner(resyncThreshold: 0.2)
        _ = c.align(deviceTime: 10, received: 100)
        let jumped = c.align(deviceTime: 50, received: 100.01)
        #expect(!jumped.resynced)
        #expect(abs(jumped.timestamp - 100.01) < 1e-9)
    }
}
