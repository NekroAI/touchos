import Foundation
import Testing
@testable import TouchOSCore

@Test func logSubsystemMatchesBundleID() {
    #expect(TouchOSCore.logSubsystem == "ai.nekro.touchos")
}

@Test func trackpadDeviceKeepsItsProperties() {
    let device = TrackpadDevice(id: .external, isBuiltIn: false, displayName: "妙控板",
                                surfaceSizeMM: CGSize(width: 160, height: 115))
    #expect(device.id == TrackpadDeviceID(raw: 2))
    #expect(!device.isBuiltIn)
    #expect(device.displayName == "妙控板")
    #expect(device.surfaceSizeMM == CGSize(width: 160, height: 115))
}
