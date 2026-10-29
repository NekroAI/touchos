import CoreGraphics
import Foundation
@testable import TouchOSCore

/// 状态机测试驱动：按时间顺序送入触点帧、额外事件与 16 ms 一次的 tick（仅在 `needsTicks` 时，与外层一致），
/// 记录每个副作用及其发生时刻（FR-14.2）。
struct Harness {
    static let tickInterval = 0.016

    var machine: SessionStateMachine
    private(set) var log: [(t: TimeInterval, effect: SessionEffect)] = []

    init(tuning: Tuning = .test, environment: SessionEnvironment = .test) {
        machine = SessionStateMachine(tuning: tuning, environment: environment)
    }

    var effects: [SessionEffect] { log.map(\.effect) }

    /// 送入帧序列与事件，tick 持续到 `until`（缺省为最后一帧后 0.5 秒）。
    mutating func run(_ frames: [TouchFrame], events: [(TimeInterval, SessionEvent)] = [], until: TimeInterval? = nil) {
        var timeline: [(t: TimeInterval, order: Int, event: SessionEvent)] =
            frames.map { ($0.timestamp, 0, .frame($0)) } + events.map { ($0.0, 1, $0.1) }
        timeline.sort { ($0.t, $0.order) < ($1.t, $1.order) }
        let start = timeline.first?.t ?? 0
        let end = until ?? ((frames.last?.timestamp ?? start) + 0.5)
        var nextTick = start + Self.tickInterval
        for item in timeline {
            tick(upTo: item.t, next: &nextTick)
            send(item.event, at: item.t)
        }
        tick(upTo: end, next: &nextTick)
    }

    mutating func send(_ event: SessionEvent, at t: TimeInterval) {
        for e in machine.handle(event) { log.append((t, e)) }
    }

    private mutating func tick(upTo t: TimeInterval, next: inout TimeInterval) {
        while next <= t {
            if machine.needsTicks { send(.tick(next), at: next) }
            next += Self.tickInterval
        }
    }

    // MARK: 查询

    var actions: [ActionRequest] {
        effects.compactMap { if case .action(let a) = $0 { a } else { nil } }
    }

    var ends: [SessionEnd] {
        effects.compactMap { if case .sessionEnded(let e) = $0 { e } else { nil } }
    }

    var failures: [AnchorFailure] {
        effects.compactMap { if case .armFailed(let f) = $0 { f } else { nil } }
    }

    var policies: [TapPolicy] {
        effects.compactMap { if case .policy(let p) = $0 { p } else { nil } }
    }

    func firstTime(_ match: (SessionEffect) -> Bool) -> TimeInterval? {
        log.first { match($0.effect) }?.t
    }

    var isActive: Bool { if case .active = machine.state { true } else { false } }
}

extension SessionEnvironment {
    /// 150 × 100 mm 的内置板；屏幕 1000 × 1000 → 面板 600 × 400 pt
    static var test: SessionEnvironment {
        var env = SessionEnvironment()
        env.devices = [.builtIn: TrackpadDevice(id: .builtIn, isBuiltIn: true, displayName: "内置触控板",
                                                surfaceSizeMM: CGSize(width: 150, height: 100))]
        env.layout = .test
        env.frontmostBundleID = "com.example.app"
        env.screenSize = CGSize(width: 1000, height: 1000)
        return env
    }
}

extension Tuning {
    /// 映射区 0.9：与边缘 0.05 重合，即 0.05–0.95 全部映射，便于用整数比例推算测试点
    static var test: Tuning {
        var t = Tuning()
        t.mappingScale = 0.9
        return t
    }
}

extension Layout {
    /// 3×3 网格：右上"关闭"、右中"音量 +"（连续触发）、左上 ⌘A、左下安全区，其余为空隙
    static let test = Layout(id: "test", name: "测试", rows: 3, cols: 3, slots: [
        Slot(id: "a", cell: GridCell(row: 0, col: 0), title: "全选", symbol: "a",
             action: .keyboardShortcut(KeyCombo(keyCode: 0, modifiers: [.command], displayLabel: "⌘A"))),
        Slot(id: "close", cell: GridCell(row: 0, col: 2), title: "关闭", symbol: "xmark",
             action: .keyboardShortcut(KeyCombo(keyCode: 13, modifiers: [.command], displayLabel: "⌘W"))),
        Slot(id: "vol", cell: GridCell(row: 1, col: 2), title: "音量 +", symbol: "speaker.plus", repeats: true,
             action: .system(.volumeUp)),
        Slot(id: "null", cell: GridCell(row: 2, col: 0), title: "取消", symbol: "nosign", action: .none),
    ])
}

/// 测试布局中各区域在触控板上的代表点（`Tuning.test`：映射区 0.05–0.95）
enum Spot {
    static let anchor = (0.05, 0.06)
    static let close = (0.85, 0.85)
    static let vol = (0.85, 0.5)
    static let null = (0.2, 0.2)
    static let gap = (0.5, 0.5)
    static let a = (0.2, 0.85)
}
