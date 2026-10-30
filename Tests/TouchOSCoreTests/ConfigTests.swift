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
        #expect(config.panels.map(\.id) == ["common", "window", "media", "numpad"])
        // 四指轻点默认打开「窗口」；数字面板默认在屏幕右侧，其余居中（D41）
        #expect(config.binding(for: .fourFingerTap) == "window" && config.bindings.count == 1)
        #expect(config.panels.map(\.placement) == [.center, .center, .center, .right])
    }

    @Test func placementRoundTripsAndDefaultsToCenter() throws {
        var config = AppConfig.default
        config.panels[0].placement = .left
        let data = try config.encoded()
        #expect(try AppConfig.decode(data).panels[0].placement == .left)
        // 居中不写入文件，旧文件没有这个键时按居中读
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.components(separatedBy: "\"placement\"").count - 1 == 2)
    }

    @Test func everyActionTypeRoundTrips() throws {
        let actions: [Action] = [
            .none,
            .keyboardShortcut(KeyCombo(keyCode: 17, modifiers: [.command, .shift], displayLabel: "⇧⌘T")),
            .openApp(bundleID: "com.apple.Notes"),
            .openURL(url: URL(string: "https://example.com/a?b=1")!, browserBundleID: "com.apple.Safari"),
            .openURL(url: URL(string: "mailto:a@example.com")!, browserBundleID: nil),
            .textSnippet("→ ✓ 😀"),
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
        #expect(try roundTrip(PresetPanels.window) == PresetPanels.window)
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
        #expect(PanelTrigger.all.count == 3 + TriggerZone.allCases.count && Set(PanelTrigger.all.map(\.key)).count == PanelTrigger.all.count)
        for t in PanelTrigger.all { #expect(PanelTrigger(key: t.key) == t) }
        #expect(PanelTrigger.zoneTapHold(.topLeft).key == "tapHold.topLeft")
        for bad in ["hold.bottomLeft", "doubleTap.topLeft", "tapHold.middle", "tapHold.top.x", "fourFingerTap.x", "swipe", ""] {
            #expect(PanelTrigger(key: bad) == nil)
        }
    }

    @Test func partialFileUsesDefaultsForMissingSections() throws {
        let config = try AppConfig.decode(Data(#"{"schemaVersion":1,"general":{"enabled":false,"haptics":true,"showTrail":true,"stickyPanel":true,"dimBackground":false,"blacklist":["com.x"]}}"#.utf8))
        #expect(!config.general.enabled && config.general.blacklist == ["com.x"])
        #expect(config.panels == PresetPanels.all && config.triggers == AppConfig.Triggers())
    }

    @Test func appliesToTuningWithClamping() {
        var config = AppConfig()
        config.triggers.set(.zoneTapHold(.bottomLeft), true)
        config.triggers.set(.zoneTapHold(.topRight), true)
        config.triggers.set(.fourFingerTap, false)
        config.sizes.panelScale = 5
        config.sizes.mappingScale = 0
        config.sizes.hitGapMM = 9
        config.bindings = [.init(trigger: .threeFingerTap, panel: "media"), .init(trigger: .fourFingerTap, panel: "edit")]
        config.bindings.append(AppConfig.Binding(trigger: .zoneTapHold(.topLeft), panel: "window"))
        var t = Tuning()
        config.apply(to: &t)
        #expect(t.zoneTapHold == [.topRight, .bottomLeft] && t.tapHold && !t.fourFingerTap && !t.threeFingerTap)
        #expect(t.panelScale == Tuning.panelScaleRange.upperBound && t.mappingScale == Tuning.mappingScaleRange.lowerBound)
        #expect(t.hitGapMM == Tuning.hitGapRange.upperBound)
        // 旧文件没有按钮间隙：取默认值
        let old = try? JSONDecoder().decode(AppConfig.Sizes.self, from: Data(#"{"panelScale":0.5,"mappingScale":0.4}"#.utf8))
        #expect(old?.hitGapMM == Tuning().hitGapMM && old?.panelScale == 0.5)
        #expect(config.bindingMap == [.threeFingerTap: "media", .fourFingerTap: "edit", .zoneTapHold(.topLeft): "window"])
    }

    @Test func generalFieldsAddedLaterDefaultWhenMissing() throws {
        let config = try AppConfig.decode(Data(#"{"schemaVersion":1,"general":{"haptics":false}}"#.utf8))
        #expect(!config.general.haptics && config.general.enabled && config.general.focusPointerWindow)
        var changed = AppConfig()
        changed.general.focusPointerWindow = false
        #expect(try AppConfig.decode(try changed.encoded()).general == changed.general)
    }

    @Test func defaultTriggersAreTapHoldAndFourFingerTap() {
        #expect(AppConfig().triggers.list == [.tapHold, .fourFingerTap])
    }

    @Test func triggerListKeepsOrderAndUnknownEntries() throws {
        var triggers = AppConfig.Triggers()
        triggers.enabled = ["swipe", "fourFingerTap"]
        triggers.set(.zoneTapHold(.bottomLeft), true)
        triggers.set(.tapHold, true)
        #expect(triggers.enabled == ["tapHold", "fourFingerTap", "tapHold.bottomLeft", "swipe"])
        triggers.set(.tapHold, false)
        #expect(!triggers.isOn(.tapHold) && triggers.list == [.fourFingerTap, .zoneTapHold(.bottomLeft)])
        var config = AppConfig()
        config.triggers = triggers
        #expect(config.validate().map(\.kind) == [.unknownBinding("swipe")])
        let decoded = try AppConfig.decode(try config.encoded())
        #expect(decoded.triggers == triggers)
    }

    @Test func legacyTriggerSwitchesMigrate() throws {
        // D26 之前：开关加一个角落，迁移后加上轻点后按住（D25）。一指按住去掉、角落轻点两下换成同一方位的分区（D38）
        let json = #"{"schemaVersion":1,"triggers":{"hold":true,"anchorCorner":"topRight","fourFingerTap":false,"threeFingerTap":true},"bindings":[{"trigger":"hold.topLeft","panel":"media"},{"trigger":"doubleTap.bottomRight","panel":"media"}]}"#
        let config = try AppConfig.decode(Data(json.utf8))
        #expect(config.triggers.list == [.tapHold, .threeFingerTap])
        #expect(config.bindingMap == [.zoneTapHold(.bottomRight): "media"])
        // 开着轻点两下：所在的角与绑定了面板的其他角都开启
        let doubleTap = #"{"schemaVersion":1,"triggers":{"anchorCorner":"leftEdge","cornerDoubleTap":true},"bindings":[{"trigger":"doubleTap.bottomRight","panel":"media"},{"trigger":"hold.topLeft","panel":"media"}]}"#
        let migrated = try AppConfig.decode(Data(doubleTap.utf8))
        #expect(migrated.triggers.list == [.tapHold, .fourFingerTap, .zoneTapHold(.left), .zoneTapHold(.bottomRight)])
        let defaultCorner = try AppConfig.decode(Data(#"{"schemaVersion":1,"triggers":{"cornerDoubleTap":true}}"#.utf8))
        #expect(defaultCorner.triggers.list == [.tapHold, .fourFingerTap, .zoneTapHold(.bottomLeft)])
        let defaults = try AppConfig.decode(Data(#"{"schemaVersion":1,"triggers":{}}"#.utf8))
        #expect(defaults.triggers.list == [.tapHold, .fourFingerTap])
    }

    @Test func legacyTriggerKeysMigrate() throws {
        // D38：`hold.*` 去掉，`doubleTap.*` 换成同一方位，原来的左右边缘对应左右两边的中段；重复的合并
        let json = #"{"schemaVersion":1,"triggers":{"enabled":["hold.bottomLeft","doubleTap.topRight","doubleTap.rightEdge","tapHold.topRight","threeFingerTap","doubleTap.middle","wave"]},"bindings":[{"trigger":"hold.bottomLeft","panel":"media"},{"trigger":"doubleTap.leftEdge","panel":"window"},{"trigger":"fourFingerTap","panel":"numpad"}]}"#
        let config = try AppConfig.decode(Data(json.utf8))
        #expect(config.triggers.enabled == ["threeFingerTap", "tapHold.topRight", "tapHold.right", "wave"])
        #expect(config.bindings == [.init(trigger: .zoneTapHold(.left), panel: "window"), .init(trigger: .fourFingerTap, panel: "numpad")])
        // 原来只开了一指按住：至少保留轻点后按住，面板仍能唤起；本来就全部关闭的保持关闭
        let holdOnly = try AppConfig.decode(Data(#"{"schemaVersion":1,"triggers":{"enabled":["hold.bottomLeft","hold.topRight"]}}"#.utf8))
        #expect(holdOnly.triggers.list == [.tapHold])
        let none = try AppConfig.decode(Data(#"{"schemaVersion":1,"triggers":{"enabled":[]}}"#.utf8))
        #expect(none.triggers.enabled.isEmpty)
        #expect(PanelTrigger.migrated(key: "hold.topLeft") == nil && PanelTrigger.migrated(key: "doubleTap.nowhere") == nil)
        #expect(PanelTrigger.migrated(key: "doubleTap.leftEdge") == "tapHold.left")
        #expect(PanelTrigger.migrated(key: "doubleTap.bottom") == "tapHold.bottom")
        for key in ["tapHold", "tapHold.top", "fourFingerTap", "hold", "swipe"] { #expect(PanelTrigger.migrated(key: key) == key) }
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
        for p in PresetPanels.templates { #expect(AppConfig.gridIssues(p).isEmpty) }
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

    @Test func movingSwapsDisplacedSlots() {
        func cell(_ l: Layout?, _ id: SlotID) -> GridCell? {
            if case .cell(let c)? = l?.slot(id)?.shape { c } else { nil }
        }
        // 空位直接移动
        #expect(cell(grid.moving("g.b", to: GridCell(row: 1, col: 0)), "g.b") == GridCell(row: 1, col: 0))
        #expect(grid.moving("g.b", to: GridCell(row: 1, col: 2)) == grid)
        // 压住 A：A 平移到 B 空出的位置会越界，放不下
        #expect(grid.moving("g.b", to: GridCell(row: 0, col: 0)) == nil)
        // 同尺寸互换
        let two = Layout(id: "t", name: "t", rows: 1, cols: 3, slots: [
            Slot(id: "t.a", cell: GridCell(row: 0, col: 0), title: "A", symbol: "", action: .none),
            Slot(id: "t.b", cell: GridCell(row: 0, col: 2), title: "B", symbol: "", action: .none),
        ])
        let swapped = two.moving("t.a", to: GridCell(row: 0, col: 2))
        #expect(cell(swapped, "t.a") == GridCell(row: 0, col: 2) && cell(swapped, "t.b") == GridCell(row: 0, col: 0))
        // 越界、未知按钮
        #expect(two.moving("t.a", to: GridCell(row: 0, col: 3)) == nil && two.moving("x", to: GridCell(row: 0, col: 1)) == nil)
        // 宽按钮压到两个小按钮：两个一起平移
        let wide = Layout(id: "w", name: "w", rows: 2, cols: 2, slots: [
            Slot(id: "w.a", cell: GridCell(row: 0, col: 0, colSpan: 2), title: "A", symbol: "", action: .none),
            Slot(id: "w.b", cell: GridCell(row: 1, col: 0), title: "B", symbol: "", action: .none),
            Slot(id: "w.c", cell: GridCell(row: 1, col: 1), title: "C", symbol: "", action: .none),
        ])
        let down = wide.moving("w.a", to: GridCell(row: 1, col: 0, colSpan: 2))
        #expect(cell(down, "w.b") == GridCell(row: 0, col: 0) && cell(down, "w.c") == GridCell(row: 0, col: 1))
    }

    @Test func ringItemsReorder() {
        let ring = PresetPanels.window
        let moved = ring.movingRingItem("window.top", to: 3)
        #expect(moved.ringItems.map(\.id.raw).prefix(4) == ["window.fullscreen", "window.right", "window.closeWindow", "window.top"])
        #expect(moved.ringCenter?.id == "window.close" && moved.isRing)
        #expect(ring.movingRingItem("window.top", to: 99).ringItems.last?.id == "window.top")
        #expect(ring.movingRingItem("x", to: 0) == ring)
    }

    @Test func resizingRejectsCuttingSlots() {
        #expect(grid.resized(rows: 3, cols: 4)?.cols == 4)
        #expect(grid.resized(rows: 1, cols: 3) == nil)
        #expect(grid.resized(rows: 2, cols: 9) == nil)
    }

    @Test func ringRebuildKeepsCenter() {
        let ring = PresetPanels.window
        #expect(ring.ringItems.count == 8 && ring.ringCenter?.id == "window.close")
        let fewer = ring.rebuiltRing(items: Array(ring.ringItems.prefix(3)))
        #expect(fewer.ringItems.count == 3 && fewer.ringCenter?.id == "window.close" && fewer.isRing)
        #expect(ring.rebuiltRing(items: ring.ringItems, center: .some(nil)).ringCenter == nil)
        // 停用状态与屏幕位置跟着走（D37、D41）
        var custom = ring
        custom.isEnabled = false
        custom.placement = .left
        let rebuilt = custom.rebuiltRing(items: custom.ringItems)
        #expect(!rebuilt.isEnabled && rebuilt.placement == .left)
    }

    @Test func resetRestoresTemplateAndKeepsIDAndBindings() {
        var config = AppConfig()
        config.panels.append(config.duplicate(PresetPanels.common))
        config.bind(.tapHold, to: "common-2")
        let n = PresetPanels.all.count
        config.panels[n].name = "改过"
        config.panels[n].slots.removeAll()
        config.resetPanel("common-2", to: PresetPanels.common)
        let reset = config.panels[n]
        #expect(reset.id == "common-2" && reset.name == "常用" && reset.slots.count == PresetPanels.common.slots.count)
        #expect(reset.slots.allSatisfy { $0.id.raw.hasPrefix("common-2.") })
        #expect(config.binding(for: .tapHold) == "common-2" && config.validate().isEmpty)
        config.resetPanel("missing", to: PresetPanels.media)
        #expect(config.panels.count == n + 1)
    }

    @Test func presetOriginFollowsCopies() {
        #expect(PresetPanels.origin(of: "browser")?.id == "browser")
        #expect(PresetPanels.origin(of: "browser-2-3")?.id == "browser")
        #expect(PresetPanels.origin(of: "window-2")?.id == "window" && PresetPanels.origin(of: "edit-2") == nil)
        #expect(PresetPanels.origin(of: "browsers") == nil && PresetPanels.origin(of: "panel-2") == nil)
        #expect(PresetPanels.origin(of: "browser-x") == nil)
    }

    @Test func duplicateRemoveAndBind() {
        var config = AppConfig()
        let copy = config.duplicate(PresetPanels.common)
        #expect(copy.id == "common-2" && copy.name == "常用 副本")
        #expect(copy.slots.first?.id == "common-2.quit")
        config.panels.append(copy)
        #expect(config.validate().isEmpty)
        config.bind(.threeFingerTap, to: "common-2")
        config.bind(.threeFingerTap, to: "media")
        #expect(config.binding(for: .threeFingerTap) == "media" && config.bindings.count == 2)
        config.bind(.fourFingerTap, to: "common-2")
        config.removePanel("common-2")
        #expect(config.binding(for: .fourFingerTap) == nil && config.panels.count == PresetPanels.all.count)
        config.bind(.threeFingerTap, to: nil)
        #expect(config.bindings.isEmpty)
        var single = AppConfig()
        single.panels = [PresetPanels.media]
        single.removePanel("media")
        #expect(single.panels.count == 1)
        #expect(AppConfig.uniqueID("x", existing: ["x", "x-2"]) == "x-3")
    }
}

@Suite struct PanelEnableTests {
    @Test func disabledPanelsAreLeftOutButKept() throws {
        var c = AppConfig()
        c.panels[1].isEnabled = false
        #expect(c.activePanels.count == c.panels.count - 1)
        #expect(!c.activePanels.contains { $0.id == c.panels[1].id })
        // 只在停用时写出 disabled，读回来保持
        let back = try AppConfig.decode(c.encoded())
        #expect(!back.panels[1].isEnabled && back.panels[0].isEnabled)
        #expect(!String(decoding: try JSONEncoder().encode(c.panels[0]), as: UTF8.self).contains("disabled"))
        // 全部停用：退回第一个
        for i in c.panels.indices { c.panels[i].isEnabled = false }
        #expect(c.activePanels.map(\.id) == [c.panels[0].id])
    }
}
