import CoreGraphics
import Foundation
import Testing
@testable import TouchOSCore

// 交互实验（decisions.md D12、D13、D23）：扇区、滑杆、按压动作、面板开着时的指点指

private let rate = 90.0

private func key(_ code: UInt16, _ mods: Set<Modifier>, _ label: String) -> Action {
    .keyboardShortcut(KeyCombo(keyCode: code, modifiers: mods, displayLabel: label))
}

private let closeTab = key(13, [.command], "⌘W")
private let selectAll = key(0, [.command], "⌘A")

private func sector(_ center: Double, inner: Double, outer: Double?) -> SlotShape {
    .sector(Sector(innerRadius: inner, outerRadius: outer, startAngle: center - 45, endAngle: center + 45))
}

/// 4 个 90° 扇区 + 中心取消圆盘（半径 0.3）
private let radial = Layout(id: "radial", name: "环形", slots: [
    Slot(id: "up", shape: sector(0, inner: 0.3, outer: nil), title: "上", symbol: "", action: selectAll),
    Slot(id: "right", shape: sector(90, inner: 0.3, outer: nil), title: "右", symbol: "", action: selectAll),
    Slot(id: "down", shape: sector(180, inner: 0.3, outer: 0.6), title: "下", symbol: "", action: selectAll),
    Slot(id: "left", shape: sector(270, inner: 0.3, outer: nil), title: "左", symbol: "", action: selectAll),
    Slot(id: "cancel", shape: .sector(Sector(innerRadius: 0, outerRadius: 0.3, startAngle: 0, endAngle: 360)),
         title: "取消", symbol: "", action: .none),
])

/// 上半：左"关闭"（⌘W）、右"普通"（⌘A）；下半：横向音量滑杆
private let experiment = Layout(id: "exp", name: "实验", slots: [
    Slot(id: "dual", shape: .rect(CGRect(x: 0, y: 0, width: 0.5, height: 0.5)), title: "关闭", symbol: "", action: closeTab),
    Slot(id: "plain", shape: .rect(CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)), title: "普通", symbol: "", action: selectAll),
    Slot(id: "slider", shape: .rect(CGRect(x: 0, y: 0.5, width: 1, height: 0.5)), title: "音量", symbol: "",
         action: .none, slider: .volume),
])

private enum ExpSpot {
    static let dual = (0.2, 0.85)
    static let plain = (0.8, 0.85)
    static let sliderLeft = (0.2, 0.2)
    static let sliderRight = (0.8, 0.2)
}

private func environment(_ panels: [Layout], bindings: [PanelTrigger: String] = [:]) -> SessionEnvironment {
    var env = SessionEnvironment.test
    env.panels = panels
    env.bindings = bindings
    return env
}

private func run(_ g: Gesture, environment: SessionEnvironment = environment([experiment]), tuning: Tuning = .test,
                 events: [(TimeInterval, SessionEvent)] = [], until: TimeInterval) -> Harness {
    var h = Harness(tuning: tuning, environment: environment)
    h.run(g.frames(rate: rate), events: events, until: until)
    return h
}

/// 轻点后按住在 `p` 打开面板，手指 2 是指点指，按住到 `until`（0.22 打开）
private func pointing(at p: (Double, Double), until: TimeInterval) -> Gesture {
    .tapHold(at: p, until: until)
}

private func activeLayout(_ h: Harness) -> String? {
    if case .active(let ctx) = h.machine.state { ctx.layout.id } else { nil }
}

@Suite struct SectorGeometryTests {
    // 面板 600 × 400：圆心 (300, 200)，单位半径 200 pt，空隙 6 pt
    let tester = HitTester(layout: radial, panelSize: CGSize(width: 600, height: 400), slotGap: 6, hysteresis: 0.02)

    @Test func angleIsClockwiseFromUp() {
        #expect(tester.angle(of: CGPoint(x: 300, y: 0)) == 0)
        #expect(tester.angle(of: CGPoint(x: 500, y: 200)) == 90)
        #expect(tester.angle(of: CGPoint(x: 100, y: 200)) == 270)
    }

    @Test func hitsSectorsByAngleAndRadius() {
        #expect(tester.hit(CGPoint(x: 300, y: 20)) == "up")
        #expect(tester.hit(CGPoint(x: 290, y: 20)) == "up")  // 跨 0° 的扇区
        #expect(tester.hit(CGPoint(x: 590, y: 10)) == "right")  // 向外无限延伸到面板角落
        #expect(tester.hit(CGPoint(x: 300, y: 230)) == "cancel")
        #expect(tester.hit(CGPoint(x: 300, y: 290)) == "down")
        #expect(tester.hit(CGPoint(x: 300, y: 390)) == nil)  // 超出"下"的外半径
        #expect(tester.hit(CGPoint(x: 300, y: 262)) == nil)  // 取消圆盘与内环之间的空隙
        #expect(tester.hit(CGPoint(x: 400, y: 100)) == nil)  // 45° 分界线上的空隙
        #expect(tester.visualRect(of: radial.slots[0]) == nil)
        #expect(tester.rect(of: radial.slots[0]) == nil)
    }

    @Test func sectorHysteresisWidensCurrentSlot() {
        // 半径 150 处空隙 6 pt 约 2.3°，"上"可命中到 42.7°；外扩封顶为空隙一半（D31），到 43.9°
        let p = CGPoint(x: 300 + 150 * sin(43.5 * Double.pi / 180), y: 200 - 150 * cos(43.5 * Double.pi / 180))
        #expect(tester.hit(p) == nil)
        #expect(tester.hit(p, current: "up") == "up")
    }

    @Test func sliderValueFollowsLongAxis() {
        let horizontal = HitTester(layout: experiment, panelSize: CGSize(width: 600, height: 400), slotGap: 6, hysteresis: 0)
        let slider = experiment.slots[2]
        #expect(horizontal.sliderValue(of: slider, at: CGPoint(x: 6, y: 300)) == 0)
        #expect(horizontal.sliderValue(of: slider, at: CGPoint(x: 300, y: 300)) == 0.5)
        #expect(horizontal.sliderValue(of: slider, at: CGPoint(x: 700, y: 300)) == 1)
        #expect(horizontal.sliderValue(of: experiment.slots[0], at: .zero) == nil)

        let vertical = Layout(id: "v", name: "v", slots: [
            Slot(id: "v", shape: .rect(CGRect(x: 0, y: 0, width: 0.2, height: 1)), title: "", symbol: "", action: .none, slider: .demo),
        ])
        let t = HitTester(layout: vertical, panelSize: CGSize(width: 600, height: 400), slotGap: 0, hysteresis: 0)
        #expect(t.sliderValue(of: vertical.slots[0], at: CGPoint(x: 50, y: 100)) == 0.75)  // 从下往上
    }
}

@Suite struct PressTests {
    @Test func pressExecutesAndKeepsPanel() {
        // D18：按压执行一次并保留，可以连按
        let g = pointing(at: ExpSpot.dual, until: 1.0)
        let h = run(g, events: [(0.6, .physicalPress), (0.75, .physicalPress)], until: 1.0)
        #expect(h.actions.map(\.action) == [closeTab, closeTab])
        #expect(h.ends.isEmpty)
        #expect(h.isActive)
    }

    @Test func liftAfterPressOnSameSlotClosesWithoutExecuting() {
        let g = pointing(at: ExpSpot.dual, until: 0.8).lift(id: 2, t: 0.8)
        let h = run(g, events: [(0.65, .physicalPress)], until: 1.0)
        #expect(h.actions.map(\.action) == [closeTab])
        #expect(h.ends == [.liftAfterPress])
    }

    @Test func movingToAnotherSlotAfterPressCommitsOnLift() {
        let g = pointing(at: ExpSpot.dual, until: 0.7)
            .move(id: 2, to: ExpSpot.plain, over: 0.1).hold(id: 2, until: 0.9).lift(id: 2, t: 0.9)
        let h = run(g, events: [(0.6, .physicalPress)], until: 1.1)
        #expect(h.actions.map(\.action) == [closeTab, selectAll])
        #expect(h.ends == [.committed("plain")])
    }

    @Test func pressOnSliderAppliesPreviewAndKeepsIt() {
        var env = environment([experiment])
        env.sliderValues[.volume] = 0.3
        let g = pointing(at: ExpSpot.sliderRight, until: 0.7)
            .move(id: 2, to: ExpSpot.plain, over: 0.1).hold(id: 2, until: 1.0)
        let h = run(g, environment: env, events: [(0.6, .physicalPress)], until: 1.0)
        let applied = h.effects.compactMap { if case .slider(.volume, let v) = $0 { v } else { nil } }
        #expect(applied.count == 1 && abs(applied[0] - 0.84) < 0.011)
        #expect(h.isActive)
        // 移出滑杆后显示新设定的值，而不是进入时的 0.3
        let last = h.effects.compactMap { if case .updatePanel(let s) = $0 { s } else { nil } }.last
        #expect(last?.sliderValues["slider"] == applied[0])
    }

    @Test func pressOnCancelOrWithoutPointerDoesNothing() {
        let cancel = pointing(at: Spot.null, until: 0.9)
        let single = Gesture.fourFingerTap()
        for h in [run(cancel, environment: .test, events: [(0.6, .physicalPress)], until: 1.0),
                  run(single, environment: .test, events: [(0.6, .physicalPress)], until: 1.0)] {
            #expect(h.actions.isEmpty)
            #expect(h.isActive)
        }
    }

    @Test func pressWithoutPointerNoLongerFlipsPanels() {
        // D23：去掉按压翻页，改为双指切换
        let h = run(.fourFingerTap(), environment: environment([experiment, radial]), events: [(0.3, .physicalPress)], until: 0.5)
        #expect(activeLayout(h) == "exp")
    }
}

/// 面板随网格伸缩（D29）
@Suite struct PanelGeometryTests {
    let geometry = PanelGeometry(group: CGSize(width: 600, height: 400), mappingScale: 0.6, referenceRows: 3, referenceCols: 5,
                                 limit: CGSize(width: 900, height: 900))

    private func grid(rows: Int, cols: Int) -> Layout {
        Layout(id: "g", name: "g", rows: rows, cols: cols, slots: [
            Slot(id: "g.a", cell: GridCell(row: 0, col: 0), title: "A", symbol: "", action: .none),
        ])
    }

    @Test func cellsKeepTheirSize() {
        #expect(geometry.size(of: grid(rows: 3, cols: 5)) == CGSize(width: 600, height: 400))
        #expect(geometry.mapping(of: grid(rows: 3, cols: 5)) == CGSize(width: 0.6, height: 0.6))
        let narrow = grid(rows: 3, cols: 3)
        #expect(abs(geometry.size(of: narrow).width - 360) < 1e-9 && geometry.size(of: narrow).height == 400)
        #expect(abs(geometry.mapping(of: narrow).width - 0.36) < 1e-9)
        #expect(abs(geometry.frame(of: narrow).minX - 120) < 1e-9 && geometry.frame(of: narrow).minY == 0)
        // 没有格子的布局按参考大小
        #expect(geometry.size(of: PresetPanels.window) == CGSize(width: 600, height: 400))
    }

    @Test func oversizedGridShrinksToTheLimit() {
        // 宽 2 倍：屏幕上限 900 pt 先到，整体缩到 0.75
        let wide = grid(rows: 3, cols: 10)
        #expect(abs(geometry.size(of: wide).width - 900) < 1e-9 && abs(geometry.size(of: wide).height - 300) < 1e-9)
        #expect(abs(geometry.mapping(of: wide).width - 0.9) < 1e-9 && abs(geometry.mapping(of: wide).height - 0.45) < 1e-9)
        // 映射区不超过整块触控板
        let big = PanelGeometry(group: CGSize(width: 600, height: 400), mappingScale: 0.9, referenceRows: 3, referenceCols: 5,
                                limit: CGSize(width: 5000, height: 5000))
        #expect(abs(big.mapping(of: grid(rows: 3, cols: 10)).width - 1) < 1e-9)
    }

    @Test func narrowPanelHasNarrowerMapping() {
        // 参考 3×3、映射区 0.9；2 列面板的映射区宽 0.6（0.2–0.8）。x = 0.1 在 3×3 面板里有效，这里落在映射区之外
        let narrow = Layout(id: "n", name: "n", rows: 3, cols: 2, slots: [
            Slot(id: "n.a", cell: GridCell(row: 0, col: 0), title: "A", symbol: "", action: selectAll),
            Slot(id: "n.b", cell: GridCell(row: 0, col: 1), title: "B", symbol: "", action: closeTab),
        ])
        let outside = pointing(at: (0.1, 0.85), until: 0.9).lift(id: 2, t: 0.9)
        let h = run(outside, environment: environment([narrow]), until: 1.1)
        #expect(h.ends == [.liftOutside] && h.actions.isEmpty)
        // 映射区左半对应左边一列
        let inside = pointing(at: (0.3, 0.85), until: 0.9).lift(id: 2, t: 0.9)
        let k = run(inside, environment: environment([narrow]), until: 1.1)
        #expect(k.actions.map(\.action) == [selectAll])
        // 面板在参考坐标里居中
        let shown = k.effects.compactMap { if case .updatePanel(let s) = $0 { s } else { nil } }.last
        #expect(shown.map { abs($0.area.midX - $0.size.width / 2) < 1e-9 && $0.area.width < $0.size.width } == true)
        #expect(shown.map { $0.frames.count == 1 && $0.frames[0] == $0.area } == true)
    }
}

@Suite struct SliderTests {
    @Test func sliderWithoutKnownValueIsUnavailable() {
        // 读不到实际值（如外接屏不支持调亮度）：不悬停、不预览、不送值，抬起按空白处理即关闭（D41）
        let g = pointing(at: ExpSpot.sliderLeft, until: 0.5).move(id: 2, to: ExpSpot.sliderRight, over: 0.2)
            .hold(id: 2, until: 0.8).lift(id: 2, t: 0.8)
        let h = run(g, until: 1.0)
        #expect(!h.effects.contains { if case .slider = $0 { true } else { false } })
        let hovered = h.effects.compactMap { if case .updatePanel(let s) = $0 { s.hovered } else { nil } }
        #expect(hovered.isEmpty)
        #expect(h.actions.isEmpty && h.ends == [.cancelSlot])
        // 按压也不做任何事
        let pressed = run(pointing(at: ExpSpot.sliderLeft, until: 0.8), events: [(0.6, .physicalPress)], until: 1.0)
        #expect(!pressed.effects.contains { if case .slider = $0 { true } else { false } } && pressed.actions.isEmpty)
    }

    @Test func sliderAppliesLiveAndLeavingRestores() {
        var env = environment([experiment])
        env.sliderValues[.volume] = 0.3
        let g = pointing(at: ExpSpot.sliderLeft, until: 0.5).move(id: 2, to: ExpSpot.sliderRight, over: 0.2)
            .move(id: 2, to: ExpSpot.plain, over: 0.2).hold(id: 2, until: 1.0).lift(id: 2, t: 1.0)
        let h = run(g, environment: env, until: 1.2)
        let applied = h.effects.compactMap { if case .slider(.volume, let v) = $0 { v } else { nil } }
        // D29：移动中逐步送出预览值，离开滑杆恢复为唤起时的值
        #expect(applied.count > 5 && applied.dropLast() == applied.dropLast().sorted())
        #expect(applied.last == 0.3 && applied.dropLast().max()! > 0.8)
        let last = h.effects.compactMap { if case .updatePanel(let s) = $0 { s } else { nil } }.last
        #expect(last?.sliderValues["slider"] == 0.3 && last?.sliderBase["slider"] == 0.3)
        #expect(h.actions.map(\.action) == [selectAll])
    }

    @Test func liftOutsideRestoresAndLiftOnSliderKeeps() {
        var env = environment([experiment])
        env.sliderValues[.volume] = 0.3
        let outside = pointing(at: ExpSpot.sliderLeft, until: 0.5).move(id: 2, to: ExpSpot.sliderRight, over: 0.2)
            .move(id: 2, to: (0.99, 0.01), over: 0.1).hold(id: 2, until: 1.0).lift(id: 2, t: 1.0)
        let h = run(outside, environment: env, until: 1.2)
        let applied = h.effects.compactMap { if case .slider(.volume, let v) = $0 { v } else { nil } }
        #expect(applied.last == 0.3 && h.ends == [.liftOutside])
        // 在滑杆上抬起：最终值送出后不再恢复
        let keep = pointing(at: ExpSpot.sliderLeft, until: 0.5).move(id: 2, to: ExpSpot.sliderRight, over: 0.2)
            .hold(id: 2, until: 0.8).lift(id: 2, t: 0.8)
        let k = run(keep, environment: env, until: 1.0)
        let kept = k.effects.compactMap { if case .slider(.volume, let v) = $0 { v } else { nil } }
        #expect(abs(kept.last! - 0.84) < 0.011 && k.ends == [.committed("slider")])
        // 收起前送出新基准，参考线滑到生效的位置
        let accepted = k.effects.compactMap { if case .updatePanel(let s) = $0 { s.sliderBase["slider"] } else { nil } }.last
        #expect(accepted == kept.last)
    }

    @Test func unknownValueOnlyPreviews() {
        // 读不到实际值：没有可恢复的基准，移动时不送出，离开也不恢复
        let g = pointing(at: ExpSpot.sliderLeft, until: 0.5).move(id: 2, to: ExpSpot.sliderRight, over: 0.2)
            .move(id: 2, to: ExpSpot.plain, over: 0.2).hold(id: 2, until: 1.0).lift(id: 2, t: 1.0)
        let h = run(g, until: 1.2)
        #expect(!h.effects.contains { if case .slider = $0 { true } else { false } })
    }

    @Test func abortRestoresSlider() {
        var env = environment([experiment])
        env.sliderValues[.volume] = 0.3
        let g = pointing(at: ExpSpot.sliderRight, until: 0.8)
        let h = run(g, environment: env, events: [(0.7, .tapDisabled)], until: 0.8)
        let applied = h.effects.compactMap { if case .slider(.volume, let v) = $0 { v } else { nil } }
        #expect(applied.count == 2 && applied.last == 0.3)
    }

    @Test func panelStartsWithEnvironmentSliderValue() {
        var env = environment([experiment])
        env.sliderValues[.volume] = 0.4
        let h = run(.fourFingerTap(), environment: env, until: 0.6)
        let shown = h.effects.compactMap { if case .showPanel(let s) = $0 { s } else { nil } }
        #expect(shown.first?.sliderValues["slider"] == 0.4)
    }
}

/// 面板开着时的指点指：四指轻点打开（没有指点指），之后落下的手指成为指点指
@Suite struct OpenPanelTests {
    private func runOpen(_ g: Gesture, tuning: Tuning = .test, environment: SessionEnvironment = .test,
                         events: [(TimeInterval, SessionEvent)] = [], until: TimeInterval) -> Harness {
        var h = Harness(tuning: tuning, environment: environment)
        h.run(g.frames(rate: rate), events: events, until: until)
        return h
    }

    /// 四指轻点在 0.12 打开面板，板上不留手指
    private func tapOpened() -> Gesture {
        .fourFingerTap()
    }

    @Test func fingerNearACornerCanBeThePointer() {
        // 角落附近（边缘以内）落下的手指也可以成为指点指，复用已抬起手指的 ID 也可以
        let g = tapOpened().touch(id: 1, at: (0.06, 0.07), t: 0.8).move(id: 1, to: Spot.close, over: 0.2)
            .hold(id: 1, until: 1.2).lift(id: 1, t: 1.2)
        let h = runOpen(g, until: 1.4)
        #expect(h.actions.map(\.action) == [closeTab])
        #expect(h.ends == [.committed("close")])
    }

    @Test func gapAndCancelBothClose() {
        // D37：空白处抬起与取消相同
        let gap = tapOpened().touch(id: 2, at: Spot.gap, t: 0.8).hold(id: 2, until: 1.0).lift(id: 2, t: 1.0)
        let h1 = runOpen(gap, until: 1.5)
        #expect(h1.ends == [.cancelSlot] && h1.actions.isEmpty)
        let cancel = tapOpened().touch(id: 2, at: Spot.null, t: 0.8).hold(id: 2, until: 1.0).lift(id: 2, t: 1.0)
        let h2 = runOpen(cancel, until: 1.2)
        #expect(h2.ends == [.cancelSlot])
        #expect(h2.actions.isEmpty)
    }

    // 测试环境 1 mm ≈ 触控板宽 0.0067：右列从 x 0.65 开始，按钮间隙 2.5 mm 每侧 1.25 mm，判定区从 0.658 开始；
    // 右外沿 0.95，判定区到 0.942 为止（D31）
    @Test func liftInHitGapClosesWithoutAction() {
        for x in [0.654, 0.946] {
            let g = tapOpened().touch(id: 2, at: (x, Spot.close.1), t: 0.8).hold(id: 2, until: 1.0).lift(id: 2, t: 1.0)
            let h = runOpen(g, until: 1.3)
            #expect(h.ends == [.cancelSlot] && h.actions.isEmpty)
        }
        // 间隙为 0：同一点命中"关闭"
        var tight = Tuning.test
        tight.hitGapMM = 0
        let h = runOpen(tapOpened().touch(id: 2, at: (0.654, Spot.close.1), t: 0.8).hold(id: 2, until: 1.0).lift(id: 2, t: 1.0),
                        tuning: tight, until: 1.3)
        #expect(h.actions.map(\.action) == [closeTab])
    }

    @Test func liftFiresTheHighlightedSlot() {
        // 从按钮滑进间隙的一小段仍保持高亮，抬起执行的就是高亮的那个（D31，修订 FR-6.11）
        let g = tapOpened().touch(id: 2, at: Spot.close, t: 0.8).hold(id: 2, until: 1.0)
            .move(id: 2, to: (0.656, Spot.close.1), over: 0.2).hold(id: 2, until: 1.4).lift(id: 2, t: 1.4)
        let h = runOpen(g, until: 1.6)
        #expect(h.actions.map(\.action) == [closeTab])
        // 直接落在同一点：还在间隙里，不执行
        let fresh = tapOpened().touch(id: 2, at: (0.656, Spot.close.1), t: 0.8).hold(id: 2, until: 1.4).lift(id: 2, t: 1.4)
        #expect(runOpen(fresh, until: 1.6).actions.isEmpty)
    }

    @Test func holdingPressRepeatsUntilRelease() {
        // D33：按住 0.5 秒后每 83 ms 触发一次（tick 16 ms 一次：1.504、1.584、1.68、1.76），松开即停；之后在同一按钮抬起只关闭
        let g = tapOpened().touch(id: 2, at: Spot.vol, t: 0.8).hold(id: 2, until: 2.2).lift(id: 2, t: 2.2)
        let h = runOpen(g, events: [(1.0, .physicalPress), (1.8, .physicalRelease)], until: 2.4)
        #expect(h.actions.count == 5 && h.actions.allSatisfy { $0.action == .system(.volumeUp) })
        #expect(h.ends == [.liftAfterPress])
    }

    @Test func repeatStopsWhenLeavingAndSkipsCommandShortcuts() {
        // 移出按钮即停止，移回来也不恢复
        let away = tapOpened().touch(id: 2, at: Spot.vol, t: 0.8).hold(id: 2, until: 1.6)
            .move(id: 2, to: Spot.gap, over: 0.05).move(id: 2, to: Spot.vol, over: 0.05).hold(id: 2, until: 2.4)
        #expect(runOpen(away, events: [(1.0, .physicalPress)], until: 2.4).actions.count == 3)
        // 带 ⌘ 的快捷键只触发一次
        let command = tapOpened().touch(id: 2, at: Spot.close, t: 0.8).hold(id: 2, until: 2.4)
        #expect(runOpen(command, events: [(1.0, .physicalPress)], until: 2.4).actions.count == 1)
    }

    @Test func repeatableActions() {
        #expect(Action.textSnippet("1").repeatsWhileHeld)
        #expect(Action.keyboardShortcut(KeyCombo(keyCode: 51, modifiers: [], displayLabel: "⌫")).repeatsWhileHeld)
        #expect(Action.keyboardShortcut(KeyCombo(keyCode: 123, modifiers: [.shift], displayLabel: "⇧←")).repeatsWhileHeld)
        #expect(!Action.keyboardShortcut(KeyCombo(keyCode: 13, modifiers: [.command], displayLabel: "⌘W")).repeatsWhileHeld)
        #expect(Action.system(.brightnessDown).repeatsWhileHeld && !Action.system(.lockScreen).repeatsWhileHeld)
        #expect(!Action.openApp(bundleID: "com.apple.finder").repeatsWhileHeld)
    }

    @Test func liftWaitsForGraceBeforeCommitting() throws {
        // D36：抬起 100 ms 后才执行
        let g = tapOpened().touch(id: 2, at: Spot.close, t: 0.8).hold(id: 2, until: 1.0).lift(id: 2, t: 1.0)
        let h = runOpen(g, until: 1.4)
        #expect(h.actions.map(\.action) == [closeTab])
        let at = try #require(h.firstTime { if case .action = $0 { true } else { false } })
        #expect(at >= 1.1 && at < 1.12)
    }

    @Test func fingerReturningNearbyContinues() {
        // 宽限期内在 1.5 mm 外落回：接着移动到音量上再抬起，只执行音量
        let g = tapOpened().touch(id: 2, at: Spot.close, t: 0.8).hold(id: 2, until: 1.0).lift(id: 2, t: 1.0)
            .touch(id: 3, at: (0.86, 0.85), t: 1.05).move(id: 3, to: Spot.vol, over: 0.2).hold(id: 3, until: 1.5).lift(id: 3, t: 1.5)
        let h = runOpen(g, until: 1.8)
        #expect(h.actions.map(\.action) == [.system(.volumeUp)])
        #expect(h.ends == [.committed("vol")])
    }

    @Test func fingerLandingFarIsANewTouch() {
        // 落在 15 mm 以外：原来的抬起立即执行
        let g = tapOpened().touch(id: 2, at: Spot.close, t: 0.8).hold(id: 2, until: 1.0).lift(id: 2, t: 1.0)
            .touch(id: 3, at: Spot.a, t: 1.05).hold(id: 3, until: 1.3)
        let h = runOpen(g, until: 1.3)
        #expect(h.actions.map(\.action) == [closeTab])
        #expect((h.firstTime { if case .action = $0 { true } else { false } } ?? 0) < 1.07)
    }

    @Test func gapLiftIsForgivenWhenTheFingerReturns() {
        // 在空白处抬起会关闭，但宽限期内在附近落回就接着选
        let g = tapOpened().touch(id: 2, at: Spot.gap, t: 0.8).hold(id: 2, until: 1.0).lift(id: 2, t: 1.0)
            .touch(id: 3, at: (0.51, 0.5), t: 1.05).move(id: 3, to: Spot.close, over: 0.2).hold(id: 3, until: 1.5).lift(id: 3, t: 1.5)
        let h = runOpen(g, until: 1.8)
        #expect(h.actions.map(\.action) == [closeTab])
    }

    @Test func farTouchDuringGraceInOverviewBecomesThePointer() {
        // 总览里在空白处抬起不关闭（只有选中缩略图才离开总览）；宽限期内落到远处的新手指接着当指点指
        var h = Harness(tuning: .test, environment: environment([Layout.test, radial]))
        let pinch = tapOpened().touch(id: 2, at: (0.3, 0.5), t: 0.8).touch(id: 3, at: (0.7, 0.5), t: 0.8)
            .move(id: 2, to: (0.45, 0.5), over: 0.2).move(id: 3, to: (0.55, 0.5), over: 0.2).lift(id: 2, t: 1.05).lift(id: 3, t: 1.05)
        let g = pinch.touch(id: 4, at: (0.5, 0.95), t: 1.8).hold(id: 4, until: 2.0).lift(id: 4, t: 2.0)
            .touch(id: 5, at: (0.2, 0.2), t: 2.05).hold(id: 5, until: 2.3)
        h.run(g.frames(rate: rate), until: 2.3)
        #expect(h.isActive)
        if case .active(let ctx) = h.machine.state { #expect(ctx.pointer?.id == 5) }
    }

    @Test func idleTimeoutClosesOnlyWithoutFingers() {
        let idle = runOpen(tapOpened(), until: 6.0)
        #expect(idle.ends == [.idleTimeout])
        let closedAt = idle.firstTime { $0 == .sessionEnded(.idleTimeout) } ?? 0
        #expect(closedAt > 5.12 && closedAt < 5.12 + 2 * Harness.tickInterval)
        // 指点指一直停在空隙上：没有超时
        let resting = tapOpened().touch(id: 2, at: Spot.gap, t: 0.5).hold(id: 2, until: 7)
        #expect(runOpen(resting, until: 7).isActive)
    }

    @Test func threeFingerMovementOrRestHandsOffToSystem() {
        // D22：三指以上停留超过轻点时限，或开始移动，才交还系统手势
        let three = { (g: Gesture) in g.touch(id: 2, at: (0.4, 0.5), t: 0.8).touch(id: 3, at: (0.5, 0.5), t: 0.8)
            .touch(id: 4, at: (0.6, 0.5), t: 0.8) }
        let resting = three(tapOpened()).hold(id: 2, until: 1.3).hold(id: 3, until: 1.3).hold(id: 4, until: 1.3)
        let h = runOpen(resting, until: 1.3)
        #expect(h.ends == [.handoff])
        #expect(h.policies.contains { $0.mode == .cooldown && $0.passGestures })
        let swipe = three(tapOpened()).move(id: 2, to: (0.3, 0.5), over: 0.1).move(id: 3, to: (0.4, 0.5), over: 0.1)
            .move(id: 4, to: (0.5, 0.5), over: 0.1)
        #expect(runOpen(swipe, until: 1.0).ends == [.handoff])
        // 两指停留不交还：面板保留（D23 双指用于切换面板）
        let two = tapOpened().touch(id: 2, at: Spot.gap, t: 0.8).touch(id: 3, at: Spot.a, t: 0.81).hold(id: 2, until: 1.4)
            .hold(id: 3, until: 1.4)
        #expect(runOpen(two, until: 1.4).isActive)
    }

    @Test func pressOnGapDoesNothing() {
        let env = environment([Layout.test, radial])
        let g = tapOpened().touch(id: 2, at: Spot.gap, t: 0.8).hold(id: 2, until: 1.2)
        let h = runOpen(g, environment: env, events: [(1.0, .physicalPress)], until: 1.2)
        #expect(activeLayout(h) == "test" && h.actions.isEmpty)
    }
}

@Suite struct OverscanTests {
    @Test func pointerIsNotClampedForDisplay() {
        let m = Mapper(margin: 0.05, scale: 0.6)
        let size = CGSize(width: 600, height: 400)
        let p = m.unclampedPanelPoint(CGPoint(x: 0.95, y: 0.05), panelSize: size)
        #expect(abs(p.x - 750) < 1e-9 && abs(p.y - 500) < 1e-9)
        #expect(m.panelPoint(CGPoint(x: 0.95, y: 0.05), panelSize: size) == CGPoint(x: 600, y: 400))
        let o = m.overscan(panelSize: size)
        #expect(abs(o.width - 200) < 1e-9 && abs(o.height - 133.333) < 0.001)
    }
}
