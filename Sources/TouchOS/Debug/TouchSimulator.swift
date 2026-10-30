import Foundation
import OSLog
import notify
import TouchOSCore

/// 调试用的浮层预演（只在调试叠层可用时注册）：收到 Darwin 通知后，用一份独立的状态机跑一段合成触点帧，
/// 只把面板的显示、更新、退场交给浮层，用来在没有手指操作时录屏检查视觉与动效。
/// 不经过真实会话：不冻结光标、不改拦截策略、不执行任何动作，也不受同时发生的真实触摸干扰。
/// 用法：`notifyutil -p ai.nekro.touchos.simulate.cancel`（另有 `.taphold`、`.idle`、`.commit`、`.press`、`.outside`、`.toggle`、`.navigate`、`.overview`、`.hold`、`.demo`）。
@MainActor
final class TouchSimulator {
    /// 合成帧间隔：与妙控板实测帧率相同（m0-report.md）
    static let frameInterval: TimeInterval = 0.015
    private static let prefix = "ai.nekro.touchos.simulate."
    /// 脚本编写时假定的映射区大小与指点指编号
    private static let scriptMappingScale = 0.6
    private static let pointerID = 9
    /// 演示脚本结束后，场景再停留多久
    private static let demoTail: TimeInterval = 1
    nonisolated static let log = Logger(subsystem: TouchOSCore.logSubsystem, category: "simulator")

    /// 虚拟设备：与真实设备的 ID 不冲突
    private static let device = TrackpadDevice(id: TrackpadDeviceID(raw: 0x5349_4D), isBuiltIn: false, displayName: "模拟",
                                               surfaceSizeMM: CGSize(width: 156, height: 110.4))

    private let driver: SessionDriver
    private let overlay: OverlayController
    private var tokens: [Int32] = []
    private var timer: Timer?
    private var playback: Playback?
    private let backdrop = DemoBackdrop()

    /// 一次预演的进度
    private struct Playback {
        var machine: SessionStateMachine
        let frames: [(t: TimeInterval, frame: TouchFrame)]
        var presses: [TimeInterval]
        let start: TimeInterval
        let end: TimeInterval
        var index = 0
        /// 演示场景（`demo`）撤下的时刻
        var backdropUntil: TimeInterval?
    }

    init(driver: SessionDriver, overlay: OverlayController) {
        self.driver = driver
        self.overlay = overlay
        for (name, script) in Self.scripts {
            var token: Int32 = 0
            let status = notify_register_dispatch(Self.prefix + name, &token, .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    Self.log.info("simulate \(name, privacy: .public)")
                    self?.run(script, presses: Self.presses[name] ?? [], demo: name == "demo" ? .en : name == "demo.zh" ? .zh : nil)
                }
            }
            Self.log.info("simulator registered \(name, privacy: .public): \(status)")
            tokens.append(token)
        }
    }

    /// 关键帧：时刻（秒）与此刻板上各手指的位置（触控板归一化坐标，原点左下）。相邻关键帧之间线性插值
    typealias Script = [(t: TimeInterval, fingers: [Int: CGPoint])]

    private static let tap: Script = [
        (0, [1: CGPoint(x: 0.42, y: 0.5), 2: CGPoint(x: 0.47, y: 0.52), 3: CGPoint(x: 0.52, y: 0.52), 4: CGPoint(x: 0.57, y: 0.5)]),
        (0.1, [1: CGPoint(x: 0.42, y: 0.5), 2: CGPoint(x: 0.47, y: 0.52), 3: CGPoint(x: 0.52, y: 0.52), 4: CGPoint(x: 0.57, y: 0.5)]),
        (0.11, [:]),
    ]

    /// 各脚本中物理按压的时刻
    private static let presses: [String: [TimeInterval]] = ["press": [1.3, 1.7, 2.1], "hold": [1.3]]

    /// 双指在 `t` 时刻落下，0.25 秒内竖直移动约四分之一板高后抬起
    private static func swipe(at t: TimeInterval, up: Bool) -> Script {
        let from = up ? 0.35 : 0.6, to = up ? 0.6 : 0.35
        return [
            (t, [:]),
            (t + 0.01, [5: CGPoint(x: 0.45, y: from), 6: CGPoint(x: 0.55, y: from)]),
            (t + 0.26, [5: CGPoint(x: 0.45, y: to), 6: CGPoint(x: 0.55, y: to)]),
            (t + 0.27, [:]),
        ]
    }

    /// README 演示动图（配合 DemoBackdrop，时间与其时间表对应）：轻点后按住选「拷贝」；四指轻点打开环形「窗口」选右半屏；
    /// 再打开一次，双指切到媒体与靠右的数字面板，捏合总览，四指轻点关闭
    private static let demoScript: Script = [
        (0, [1: CGPoint(x: 0.5, y: 0.5)]),
        (0.08, [1: CGPoint(x: 0.5, y: 0.5)]),
        (0.09, [:]),
        (0.2, [9: CGPoint(x: 0.5, y: 0.5)]),
        (0.9, [9: CGPoint(x: 0.5, y: 0.5)]),
        (1.7, [9: CGPoint(x: 0.38, y: 0.5)]),
        (2.9, [9: CGPoint(x: 0.38, y: 0.5)]),
        (2.91, [:]),
    ] + tap.map { (4.2 + $0.t, $0.fingers) } + [
        (5.1, [:]),
        (5.11, [9: CGPoint(x: 0.5, y: 0.5)]),
        (5.8, [9: CGPoint(x: 0.68, y: 0.5)]),
        (6.8, [9: CGPoint(x: 0.68, y: 0.5)]),
        (6.81, [:]),
    ] + tap.map { (8.2 + $0.t, $0.fingers) } + swipe(at: 9.3, up: true) + swipe(at: 10.6, up: true) + [
        (12.0, [:]),
        (12.01, [5: CGPoint(x: 0.3, y: 0.5), 6: CGPoint(x: 0.7, y: 0.5)]),
        (12.26, [5: CGPoint(x: 0.45, y: 0.5), 6: CGPoint(x: 0.55, y: 0.5)]),
        (12.27, [:]),
    ] + tap.map { (13.8 + $0.t, $0.fingers) }

    private static let scripts: [String: Script] = [
        // 轻点后按住（D25）：中心轻点一下，紧接着按住，第二次落下即出面板，滑到左上按钮后抬起
        "taphold": [
            (0, [1: CGPoint(x: 0.5, y: 0.5)]),
            (0.08, [1: CGPoint(x: 0.5, y: 0.5)]),
            (0.09, [:]),
            (0.2, [9: CGPoint(x: 0.5, y: 0.5)]),
            (0.7, [9: CGPoint(x: 0.36, y: 0.62)]),
            (1.4, [9: CGPoint(x: 0.36, y: 0.62)]),
            (1.41, [:]),
        ],
        "demo": demoScript,
        "demo.zh": demoScript,
        // 唤起后单指绕一圈经过各按钮，回到中心的取消上抬起：弹开、悬停、收拢
        "cancel": tap + [
            (0.8, [:]),
            (0.81, [9: CGPoint(x: 0.25, y: 0.75)]),
            (1.4, [9: CGPoint(x: 0.75, y: 0.75)]),
            (2.0, [9: CGPoint(x: 0.75, y: 0.25)]),
            (2.6, [9: CGPoint(x: 0.25, y: 0.25)]),
            (3.2, [9: CGPoint(x: 0.5, y: 0.5)]),
            (3.6, [9: CGPoint(x: 0.5, y: 0.5)]),
            (3.61, [:]),
        ],
        // 唤起后不动：5 秒无触摸超时
        "idle": tap,
        // 在触控板左下方轻点唤起：唤起点在面板之外，检查弹开动画的起点
        "offset": tap.map { k in (k.t, k.fingers.mapValues { CGPoint(x: $0.x - 0.3, y: $0.y - 0.3) }) },
        // 从按钮上移到按钮组之外停住再抬起：取消样式的指示点，抬起关闭（D21、D22）
        "outside": tap + [
            (0.8, [:]),
            (0.81, [9: CGPoint(x: 0.6, y: 0.6)]),
            (1.6, [9: CGPoint(x: 0.95, y: 0.85)]),
            (3.0, [9: CGPoint(x: 0.95, y: 0.85)]),
            (3.01, [:]),
        ],
        // 唤起后再四指轻点一次：轻点完成后关闭（D22）
        "toggle": tap + tap.map { (1.5 + $0.t, $0.fingers) },
        // 连续唤起与关闭：收拢途中再次唤起，隐藏后再唤起
        "reopen": tap + [1.0, 1.12, 2.0, 2.6].flatMap { t in tap.map { (t + $0.t, $0.fingers) } },
        // 停在左上按钮上按压三次（显示 ×N 计数与回弹），再到中心的取消上抬起。动作不会执行
        "press": tap + [
            (0.8, [:]),
            (0.81, [9: CGPoint(x: 0.25, y: 0.75)]),
            (2.6, [9: CGPoint(x: 0.25, y: 0.75)]),
            (3.0, [9: CGPoint(x: 0.5, y: 0.5)]),
            (3.3, [9: CGPoint(x: 0.5, y: 0.5)]),
            (3.31, [:]),
        ],
        // 在"常用"面板右侧的竖向音量滑杆上移动后抬起，看提交动效（预演不执行动作，音量不变）
        "commit": tap + [
            (0.8, [:]),
            (0.81, [9: CGPoint(x: 0.74, y: 0.3)]),
            (1.6, [9: CGPoint(x: 0.74, y: 0.65)]),
            (2.0, [9: CGPoint(x: 0.74, y: 0.65)]),
            (2.01, [:]),
        ],
        // 双指上推两次再下拉一次：面板 1 → 2 → 3 → 2（D23、D32）
        "navigate": tap + swipe(at: 1.0, up: true) + swipe(at: 2.0, up: true) + swipe(at: 3.0, up: false),
        // 双指捏合进入总览，再单指在左下缩略图上抬起选中（D23）
        "overview": tap + [
            (1.0, [:]),
            (1.01, [5: CGPoint(x: 0.3, y: 0.5), 6: CGPoint(x: 0.7, y: 0.5)]),
            (1.26, [5: CGPoint(x: 0.45, y: 0.5), 6: CGPoint(x: 0.55, y: 0.5)]),
            (1.27, [:]),
            (2.2, [:]),
            (2.21, [9: CGPoint(x: 0.6, y: 0.6)]),
            (2.8, [9: CGPoint(x: 0.35, y: 0.35)]),
            (3.4, [9: CGPoint(x: 0.35, y: 0.35)]),
            (3.41, [:]),
        ],
        // 在正中的关闭上按下并一直按住：圆环充满后进入编辑（D23；预演不打开编辑器）
        "hold": tap + [
            (0.8, [:]),
            (0.81, [9: CGPoint(x: 0.5, y: 0.5)]),
            (3.0, [9: CGPoint(x: 0.5, y: 0.5)]),
            (3.01, [:]),
        ],
    ]

    /// 用当前的布局与参数（打开轻点唤起与轻点后按住、关闭方位分区）跑一段脚本
    private func run(_ script: Script, presses: [TimeInterval], demo: DemoBackdrop.Language? = nil) {
        timer?.invalidate()
        var environment = driver.environmentSnapshot
        environment.devices = [Self.device.id: Self.device]
        environment.suspended = false
        // 真实会话在手指落下时读取滑杆的实际值，预演没有真实触摸，这里补读（只读，预演不改系统音量与亮度）
        environment.sliderValues[.volume] = SystemVolume.get()
        environment.sliderValues[.brightness] = DisplayBrightness.get()
        var tuning = driver.tuningSnapshot
        tuning.fourFingerTap = true
        tuning.tapHold = true
        tuning.zoneTapHold = []
        let machine = SessionStateMachine(tuning: tuning, environment: environment)
        var previous: [Int: CGPoint] = [:]
        let start = ProcessInfo.processInfo.systemUptime
        let end = (script.last?.t ?? 0) + tuning.stickyIdleMs / 1000 + 1
        var t = 0.0
        var frames: [(TimeInterval, TouchFrame)] = []
        // 脚本中的指点指（编号 9）按映射区 0.6 编写，换算到当前映射区，保证落点相对按钮的位置不变
        let k = tuning.mappingScale / Self.scriptMappingScale
        while t <= end {
            let fingers = Self.interpolate(script, at: t).reduce(into: [Int: CGPoint]()) { result, item in
                result[item.key] = item.key == Self.pointerID
                    ? CGPoint(x: 0.5 + (item.value.x - 0.5) * k, y: 0.5 + (item.value.y - 0.5) * k) : item.value
            }
            var contacts = fingers.map { id, p in
                Contact(id: id, phase: previous[id] == nil ? .began : .moved, position: p, velocity: .zero, size: 1, pressure: 0)
            }
            contacts += previous.keys.filter { fingers[$0] == nil }.map { id in
                Contact(id: id, phase: .ended, position: previous[id]!, velocity: .zero, size: 1, pressure: 0)
            }
            // 板上没有手指时没有帧（与真实设备一致），只发 tick
            if !contacts.isEmpty { frames.append((t, TouchFrame(device: Self.device.id, timestamp: start + t, contacts: contacts))) }
            previous = fingers
            t += Self.frameInterval
        }
        playback = Playback(machine: machine, frames: frames, presses: presses, start: start, end: end,
                            backdropUntil: demo == nil ? nil : start + (script.last?.t ?? 0) + Self.demoTail)
        if let demo { backdrop.show(language: demo) }
        let timer = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 按真实时间送出到点的帧、按压与 tick
    private func step() {
        guard var p = playback else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var effects: [SessionEffect] = []
        while p.index < p.frames.count, p.start + p.frames[p.index].t <= now {
            let frame = p.frames[p.index].frame
            effects += p.machine.handle(.frame(frame))
            if p.backdropUntil != nil {
                backdrop.update(fingers: Dictionary(uniqueKeysWithValues: frame.contacts.filter(\.isTouching).map { ($0.id, $0.position) }))
            }
            p.index += 1
        }
        while let press = p.presses.first, p.start + press <= now {
            effects += p.machine.handle(.physicalPress)
            p.presses.removeFirst()
        }
        if p.machine.needsTicks { effects += p.machine.handle(.tick(now)) }
        if p.backdropUntil != nil { backdrop.advance(to: now - p.start) }
        if let until = p.backdropUntil, now > until {
            backdrop.hide()
            p.backdropUntil = nil
        }
        playback = p
        apply(effects)
        if now - p.start > p.end {
            timer?.invalidate()
            playback = nil
        }
    }

    private func apply(_ effects: [SessionEffect]) {
        let end = effects.lazy.compactMap { if case .sessionEnded(let e) = $0 { e } else { nil } }.first
        for effect in effects {
            switch effect {
            case .showPanel(let s): overlay.show(s)
            case .updatePanel(let s): overlay.update(s)
            case .hidePanel: overlay.dismiss(SessionDriver.dismissal(for: end))
            case .flashSlot(let id): overlay.flash(id)
            case .sessionEnded(let e): Self.log.info("simulated session ended: \(String(describing: e), privacy: .public)")
            default: break
            }
        }
    }

    private static func interpolate(_ script: Script, at t: TimeInterval) -> [Int: CGPoint] {
        guard let i = script.lastIndex(where: { $0.t <= t }) else { return [:] }
        let a = script[i]
        guard i + 1 < script.count else { return a.fingers }
        let b = script[i + 1]
        let k = (t - a.t) / max(b.t - a.t, 1e-6)
        return a.fingers.reduce(into: [:]) { result, item in
            let q = b.fingers[item.key] ?? item.value
            result[item.key] = CGPoint(x: item.value.x + (q.x - item.value.x) * k, y: item.value.y + (q.y - item.value.y) * k)
        }
    }
}
