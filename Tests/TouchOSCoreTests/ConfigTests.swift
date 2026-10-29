import CoreGraphics
import Foundation
import Testing
@testable import TouchOSCore

// K8：配置编解码、迁移、校验、存储（SRS 第 10 章、AC-19）

private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    try JSONDecoder().decode(T.self, from: try JSONEncoder().encode(value))
}

private func temporaryStore() -> ConfigStore {
    ConfigStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("touchos-\(UUID().uuidString)"))
}

@Suite struct ConfigCodingTests {
    @Test func defaultConfigRoundTripsAndIsValid() throws {
        let config = AppConfig.default
        #expect(try AppConfig.decode(try config.encoded()) == config)
        #expect(config.validate().isEmpty)
        #expect(config.panels.map(\.id) == ["browser", "media", "window", "edit"])
    }

    @Test func everyActionTypeRoundTrips() throws {
        let actions: [Action] = [
            .none,
            .keyboardShortcut(KeyCombo(keyCode: 17, modifiers: [.command, .shift], displayLabel: "⇧⌘T")),
            .openApp(bundleID: "com.apple.Notes"),
            .openURL(url: URL(string: "https://example.com/a?b=1")!, browserBundleID: "com.apple.Safari"),
            .openURL(url: URL(string: "mailto:a@example.com")!, browserBundleID: nil),
            .openFile(path: "~/Downloads"),
            .shell(command: "echo hi", timeoutSec: 5, notifyOutput: true),
            .appleScript(source: "beep", language: .appleScript),
            .appleScript(source: "1+1", language: .javaScript),
            .shortcut(name: "整理桌面"),
            .system(.windowLeftHalf),
        ]
        for a in actions { #expect(try roundTrip(a) == a) }
        #expect(actions.filter(\.runsCode).count == 3)
    }

    @Test func everyShapeRoundTrips() throws {
        let slots = [
            Slot(id: "a", shape: .cell(GridCell(row: 1, col: 2, rowSpan: 2, colSpan: 1)), title: "A", symbol: "a", action: .none),
            Slot(id: "b", shape: .rect(CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)), title: "B", symbol: "b", action: .none,
                 slider: .volume),
            Slot(id: "c", shape: .sector(Sector(innerRadius: 0.3, outerRadius: nil, startAngle: -45, endAngle: 45)), title: "C",
                 symbol: "c", action: .none, widget: .nowPlaying),
        ]
        for s in slots { #expect(try roundTrip(s) == s) }
        #expect(try roundTrip(PresetPanels.editing) == PresetPanels.editing)
    }

    @Test func srsExampleSlotDecodes() throws {
        // SRS 10.2 示例的写法：图标为对象、带颜色与连续触发等本版本不用的字段
        let json = """
        {"id":"s-close","cell":{"row":0,"col":3},"title":"关闭","symbol":"xmark","color":"#E5484D","repeat":false,
         "action":{"type":"keyboardShortcut","keyCode":13,"modifiers":["command"],"displayLabel":"⌘W"}}
        """
        let slot = try JSONDecoder().decode(Slot.self, from: Data(json.utf8))
        #expect(slot.shape == .cell(GridCell(row: 0, col: 3)))
        #expect(slot.action == .keyboardShortcut(KeyCombo(keyCode: 13, modifiers: [.command], displayLabel: "⌘W")))
    }

    @Test func malformedValuesAreRejected() {
        let cases = [
            #"{"id":"x","title":"x"}"#,
            #"{"id":"x","title":"x","cell":{"row":0,"col":0},"action":{"type":"teleport"}}"#,
            #"{"id":"x","title":"x","cell":{"row":0,"col":0},"action":{"type":"openURL","url":""}}"#,
        ]
        for json in cases { #expect(throws: (any Error).self) { try JSONDecoder().decode(Slot.self, from: Data(json.utf8)) } }
    }

    @Test func triggerKeysRoundTrip() {
        let all: [PanelTrigger] = AnchorCorner.allCases.flatMap { [.hold($0), .cornerDoubleTap($0)] } + [.threeFingerTap, .fourFingerTap]
        for t in all { #expect(PanelTrigger(key: t.key) == t) }
        for bad in ["hold", "hold.middle", "fourFingerTap.x", "swipe", ""] { #expect(PanelTrigger(key: bad) == nil) }
    }

    @Test func partialFileUsesDefaultsForMissingSections() throws {
        let config = try AppConfig.decode(Data(#"{"schemaVersion":1,"general":{"enabled":false,"haptics":true,"showTrail":true,"stickyPanel":true,"dimBackground":false,"blacklist":["com.x"]}}"#.utf8))
        #expect(!config.general.enabled && config.general.blacklist == ["com.x"])
        #expect(config.panels == PresetPanels.all && config.triggers == AppConfig.Triggers())
    }

    @Test func appliesToTuningWithClamping() {
        var config = AppConfig()
        config.triggers.hold = true
        config.triggers.anchorCorner = .topRight
        config.general.stickyPanel = true
        config.sizes.panelScale = 5
        config.sizes.mappingScale = 0
        config.bindings = [.init(trigger: .threeFingerTap, panel: "media"), .init(trigger: .fourFingerTap, panel: "edit")]
        config.bindings.append(AppConfig.Binding(trigger: .hold(.topLeft), panel: "window"))
        var t = Tuning()
        config.apply(to: &t)
        #expect(t.holdTrigger && t.anchorCorner == .topRight && t.stickyPanel && t.fourFingerTap)
        #expect(t.panelScale == Tuning.panelScaleRange.upperBound && t.mappingScale == Tuning.mappingScaleRange.lowerBound)
        #expect(config.bindingMap == [.threeFingerTap: "media", .fourFingerTap: "edit", .hold(.topLeft): "window"])
    }
}

@Suite struct ConfigMigrationTests {
    @Test func versionZeroMovesLayoutsToPanels() throws {
        let layout = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(PresetPanels.media))
        let v0: [String: Any] = ["layouts": [layout], "profiles": [["bundleID": "*", "layoutID": "media"]]]
        let migrated = try ConfigMigrator.migrate(v0)
        #expect(migrated["schemaVersion"] as? Int == 1)
        #expect(migrated["layouts"] == nil && migrated["profiles"] == nil)
        let config = try AppConfig.decode(try JSONSerialization.data(withJSONObject: v0))
        #expect(config.panels == [PresetPanels.media])
    }

    @Test func runsStepsInOrderAndRejectsGaps() throws {
        let steps: [Int: ConfigMigrator.Step] = [
            1: { var j = $0; j["trail"] = "1"; return j },
            2: { var j = $0; j["trail"] = (j["trail"] as? String ?? "") + "2"; return j },
        ]
        let out = try ConfigMigrator.migrate(["schemaVersion": 1], to: 3, steps: steps)
        #expect(out["trail"] as? String == "12" && out["schemaVersion"] as? Int == 3)
        #expect(throws: ConfigError.invalid("缺少从版本 0 迁移的步骤")) { try ConfigMigrator.migrate([:], to: 1, steps: steps) }
    }

    @Test func newerVersionIsRejected() {
        #expect(throws: ConfigError.newerVersion(99)) { try AppConfig.decode(Data(#"{"schemaVersion":99}"#.utf8)) }
        #expect(throws: ConfigError.notAnObject) { try AppConfig.decode(Data("[1]".utf8)) }
    }
}

@Suite struct ConfigValidationTests {
    private func panel(_ id: String, rows: Int = 2, cols: Int = 2, _ cells: [(String, GridCell)]) -> Layout {
        Layout(id: id, name: id, rows: rows, cols: cols, slots: cells.map { Slot(id: SlotID($0.0), cell: $0.1, title: $0.0, symbol: "", action: .none) })
    }

    @Test func reportsEveryKindOfProblem() {
        var config = AppConfig()
        config.panels = [
            panel("p", [("a", GridCell(row: 0, col: 0, colSpan: 2)), ("b", GridCell(row: 0, col: 1)), ("c", GridCell(row: 1, col: 1, rowSpan: 2))]),
            panel("p", [("a", GridCell(row: 0, col: 0))]),
            panel("big", rows: 9, cols: 2, [("z", GridCell(row: 0, col: 0))]),
        ]
        config.bindings = [.init(trigger: .threeFingerTap, panel: "nope")]
        config.bindings.append(AppConfig.Binding(trigger: .fourFingerTap, panel: "p"))
        config.bindings[1].trigger = "wave"
        let kinds = config.validate().map(\.kind)
        #expect(kinds.contains(.overlap(panel: "p", slots: ["a", "b"])))
        #expect(kinds.contains(.outsideGrid(panel: "p", slot: "c")))
        #expect(kinds.contains(.duplicatePanel("p")))
        #expect(kinds.contains(.duplicateSlot("a")))
        #expect(kinds.contains(.gridSize(panel: "big")))
        #expect(kinds.contains(.unknownPanel(trigger: "threeFingerTap", panel: "nope")))
        #expect(kinds.contains(.unknownBinding("wave")))
        #expect(config.validate().allSatisfy { !$0.description.isEmpty })
        config.panels = []
        #expect(config.validate().map(\.kind).contains(.noPanels))
    }

    @Test func presetsHaveNoProblems() {
        for p in PresetPanels.all { #expect(AppConfig.gridIssues(p).isEmpty) }
    }
}

@Suite struct ConfigStoreTests {
    @Test func firstLaunchIsNewAndSaveRoundTrips() throws {
        let store = temporaryStore()
        let first = store.load()
        #expect(first.isNew && first.problem == nil && first.config == .default)
        var config = AppConfig()
        config.general.haptics = false
        try store.save(config)
        #expect(store.load().config == config && !store.load().isNew)
    }

    @Test func damagedFileFallsBackAndIsKept() throws {
        // AC-19：手动破坏配置文件后启动：加载默认配置，原文件保留
        let store = temporaryStore()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        for broken in ["{not json", #"{"schemaVersion":42}"#, "[]", #"{"schemaVersion":1,"panels":[{"id":1}]}"#] {
            try Data(broken.utf8).write(to: store.fileURL)
            let loaded = store.load()
            #expect(loaded.config == .default && !loaded.isNew)
            guard case .damaged(let reason) = loaded.problem else { Issue.record("no problem reported"); continue }
            #expect(!reason.isEmpty)
            #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == broken)
        }
    }

    @Test func keepsFiveNewestBackupsAndRestores() throws {
        let store = temporaryStore()
        var config = AppConfig()
        for i in 0..<8 {
            config.sizes.panelScale = 0.3 + Double(i) * 0.05
            try store.save(config)
        }
        try store.save(config)  // 内容未变：不产生新备份
        let backups = store.backups()
        #expect(backups.count == ConfigStore.maxBackups)
        let restored = try store.restore(backups[0])
        #expect(restored.sizes.panelScale == 0.3 + 6 * 0.05)
        #expect(store.load().config == restored)
    }

    @Test func standardLocationIsApplicationSupport() {
        #expect(ConfigStore.standard.fileURL.path.hasSuffix("Application Support/TouchOS/config.json"))
        #expect(ConfigStore.stamp(Date(timeIntervalSince1970: 0)) == "19700101-000000-000")
    }
}

@Suite struct PanelEditingTests {
    let grid = Layout(id: "g", name: "g", rows: 2, cols: 3, slots: [
        Slot(id: "g.a", cell: GridCell(row: 0, col: 0, colSpan: 2), title: "A", symbol: "", action: .none),
        Slot(id: "g.b", cell: GridCell(row: 1, col: 2), title: "B", symbol: "", action: .none),
    ])

    @Test func placementRespectsBoundsAndOthers() {
        #expect(grid.canPlace(GridCell(row: 0, col: 2)))
        #expect(!grid.canPlace(GridCell(row: 0, col: 1)))
        #expect(grid.canPlace(GridCell(row: 0, col: 1), ignoring: "g.a"))
        #expect(!grid.canPlace(GridCell(row: 1, col: 2, colSpan: 2)))
        #expect(!grid.canPlace(GridCell(row: -1, col: 0)))
        #expect(grid.slot(atRow: 0, col: 1)?.id == "g.a" && grid.slot(atRow: 1, col: 0) == nil)
    }

    @Test func resizingRejectsCuttingSlots() {
        #expect(grid.resized(rows: 3, cols: 4)?.cols == 4)
        #expect(grid.resized(rows: 1, cols: 3) == nil)
        #expect(grid.resized(rows: 2, cols: 9) == nil)
    }

    @Test func ringRebuildKeepsCenter() {
        let ring = PresetPanels.editing
        #expect(ring.ringItems.count == 8 && ring.ringCenter?.id == "edit.close")
        let fewer = ring.rebuiltRing(items: Array(ring.ringItems.prefix(3)))
        #expect(fewer.ringItems.count == 3 && fewer.ringCenter?.id == "edit.close" && fewer.isRing)
        #expect(ring.rebuiltRing(items: ring.ringItems, center: .some(nil)).ringCenter == nil)
    }

    @Test func duplicateRemoveAndBind() {
        var config = AppConfig()
        let copy = config.duplicate(PresetPanels.browser)
        #expect(copy.id == "browser-2" && copy.name == "浏览器 副本")
        #expect(copy.slots.first?.id == "browser-2.new")
        config.panels.append(copy)
        #expect(config.validate().isEmpty)
        config.bind(.threeFingerTap, to: "browser-2")
        config.bind(.threeFingerTap, to: "media")
        #expect(config.binding(for: .threeFingerTap) == "media" && config.bindings.count == 1)
        config.bind(.fourFingerTap, to: "browser-2")
        config.removePanel("browser-2")
        #expect(config.binding(for: .fourFingerTap) == nil && config.panels.count == 4)
        config.bind(.threeFingerTap, to: nil)
        #expect(config.bindings.isEmpty)
        var single = AppConfig()
        single.panels = [PresetPanels.media]
        single.removePanel("media")
        #expect(single.panels.count == 1)
        #expect(AppConfig.uniqueID("x", existing: ["x", "x-2"]) == "x-3")
    }
}
