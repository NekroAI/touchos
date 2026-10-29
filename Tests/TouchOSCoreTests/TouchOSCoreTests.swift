import Testing
@testable import TouchOSCore

@Test func logSubsystemMatchesBundleID() {
    #expect(TouchOSCore.logSubsystem == "ai.nekro.touchos")
}
