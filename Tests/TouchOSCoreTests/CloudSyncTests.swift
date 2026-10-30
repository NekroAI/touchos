import Foundation
import Testing
@testable import TouchOSCore

@Suite struct CloudSyncTests {
    @Test func payloadLeavesOutLocalSettings() throws {
        var a = AppConfig()
        a.general.enabled = false
        a.sizes.panelScale = 0.7
        a.sync.iCloud = true
        let json = try #require(try JSONSerialization.jsonObject(with: CloudSync.payload(a)) as? [String: Any])
        #expect(json["sizes"] == nil && json["sync"] == nil)
        #expect((json["general"] as? [String: Any])?["enabled"] == nil)
        #expect(json["panels"] != nil)
        // 只改本机设置：内容不变
        var b = AppConfig()
        b.sizes.hitGapMM = 4
        #expect(try CloudSync.payload(a) == CloudSync.payload(b))
        // 改同步的设置：内容变化
        b.appearance.theme = "holo"
        #expect(try CloudSync.payload(a) != CloudSync.payload(b))
    }

    @Test func mergeKeepsLocalSettings() throws {
        var local = AppConfig()
        local.general.enabled = false
        local.sizes.mappingScale = 0.8
        local.sync.iCloud = true
        var cloud = AppConfig()
        cloud.appearance.theme = "lens"
        cloud.general.dimBackground = true
        let merged = CloudSync.merge(cloud: try AppConfig.decode(CloudSync.payload(cloud)), into: local)
        #expect(merged.appearance.theme == "lens" && merged.general.dimBackground)
        #expect(!merged.general.enabled && merged.sizes.mappingScale == 0.8 && merged.sync.iCloud)
    }

    @Test func newRiskyActionsAreOnlyTheUnknownOnes() {
        let script = Action.shell(command: "echo hi", timeoutSec: 5, notifyOutput: false)
        var cloud = AppConfig()
        cloud.panels[0].slots.append(Slot(id: "sh", cell: GridCell(row: 2, col: 2), title: "脚本", symbol: "terminal", action: script))
        let risky = CloudSync.newRiskyActions(cloud: cloud, local: AppConfig())
        #expect(risky.map(\.slot) == ["脚本"])
        #expect(CloudSync.newRiskyActions(cloud: cloud, local: cloud).isEmpty)
    }

    @Test func decisions() {
        let a = Data("a".utf8), b = Data("b".utf8), c = Data("c".utf8)
        #expect(CloudSync.decide(cloud: nil, local: a, synced: nil, cloudIsNewer: false) == .upload)
        #expect(CloudSync.decide(cloud: a, local: a, synced: b, cloudIsNewer: true) == .none)
        #expect(CloudSync.decide(cloud: b, local: a, synced: a, cloudIsNewer: false) == .download)
        #expect(CloudSync.decide(cloud: a, local: b, synced: a, cloudIsNewer: true) == .upload)
        #expect(CloudSync.decide(cloud: b, local: c, synced: a, cloudIsNewer: true) == .conflict(keepCloud: true))
        #expect(CloudSync.decide(cloud: b, local: c, synced: nil, cloudIsNewer: false) == .conflict(keepCloud: false))
    }

    @Test func syncFlagRoundTripsAndDefaultsOff() throws {
        var a = AppConfig()
        a.sync.iCloud = true
        #expect(try AppConfig.decode(a.encoded()).sync.iCloud)
        #expect(try !AppConfig.decode(Data(#"{"schemaVersion":1}"#.utf8)).sync.iCloud)
        #expect(try !AppConfig.decode(Data(#"{"schemaVersion":1,"sync":{}}"#.utf8)).sync.iCloud)
    }

    @Test func keepBackupAddsToBackups() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("touchos-sync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(directory: dir)
        try store.keepBackup(Data("{}".utf8))
        #expect(store.backups().count == 1)
    }
}
