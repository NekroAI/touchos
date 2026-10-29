import AppKit
import ApplicationServices
import OSLog
import TouchOSCore

/// 组装各模块并决定启动顺序（SRS 2.2）。
@MainActor
final class AppCoordinator {
    /// FR-12.2：等待辅助功能授权时的检查间隔
    static let permissionPollInterval: TimeInterval = 2
    /// AC-17 调试：点菜单后留给用户唤起面板的时间
    static let debugStallDelay: TimeInterval = 5

    private let log = Logger(subsystem: TouchOSCore.logSubsystem, category: "app")
    private let tuning = Tuning()  // K8 起从配置读取
    private let menuBar = MenuBarController()
    private let appearanceMenu = AppearanceMenu()
    private let queue = DispatchQueue(label: "ai.nekro.touchos.input", qos: .userInteractive)
    private var driver: SessionDriver!
    private var pipeline: InputPipeline!
    private var tap: EventTapController!
    private var watchdog: TapWatchdog!
    private var deviceManager: DeviceManager?
    private var debugOverlay: DebugOverlayController?
    private var simulator: TouchSimulator?
    private var permissionTimer: Timer?

    // 降级原因（任一存在即不接受锚定）
    private var inputUnavailable: String?
    private var tapStatus = TapWatchdog.Status.permissionMissing

    func start() {
        // 拦截回调与输入回调都只异步投递到 input.queue（SRS 2.3）
        let ref = DriverRef()
        tap = EventTapController(measure: DebugOverlayController.isAvailable, onPhysicalPress: { ref.driver?.send(.physicalPress) },
                                 onEscape: { ref.driver?.send(.escapeKey) },
                                 onDisabled: { ref.driver?.send(.tapDisabled) })
        tap.onPhysicalRelease = { ref.driver?.send(.physicalRelease) }
        let overlay = OverlayController(slotGap: tuning.slotGap, trailMs: tuning.trailMs)
        let driver = SessionDriver(queue: queue, tuning: tuning, tap: tap, cursor: CursorLock(tap: tap),
                                   executor: ActionExecutor(), overlay: overlay)
        ref.driver = driver
        self.driver = driver
        driver.updateEnvironment { $0.panels = PresetPanels.all }
        menuBar.appearanceItem = appearanceMenu.item

        pipeline = InputPipeline(
            queue: queue,
            onFrame: { frame in driver.handle(.frame(frame)) },
            onLayoutMismatch: { [weak self] in
                DispatchQueue.main.async { self?.setInputUnavailable("触点数据格式与本机系统不符") }
            })

        if DebugOverlayController.isAvailable {
            let debug = DebugOverlayController(pipeline: pipeline, tap: tap)
            debugOverlay = debug
            simulator = TouchSimulator(driver: driver, overlay: overlay)
            menuBar.onToggleDebugOverlay = { [weak self] in
                debug.toggle()
                self?.menuBar.debugOverlayVisible = debug.isVisible
            }
            driver.onDebug = { line in DispatchQueue.main.async { debug.model.log(line) } }
            appearanceMenu.onChange = { a in
                debug.model.log("外观：\(a.theme.title) · \(a.nav.title) · 强调色 \(a.accentHex ?? "自动")（下一次唤起生效）")
            }
            driver.onLatency = { sample in debug.model.record(sample) }
            let tap = self.tap!
            let base = tuning
            let percents = { (values: [Double]) in values.map { (label: "\(Int(($0 * 100).rounded()))%", value: $0) } }
            menuBar.debugChoices = [
                .init(title: "面板大小（占屏幕）", key: SessionDriver.panelScaleKey, options: percents([0.3, 0.35, 0.4, 0.5, 0.6])) {
                    UserDefaults.standard.object(forKey: SessionDriver.panelScaleKey) as? Double ?? base.panelScale
                },
                .init(title: "映射区大小（占触控板）", key: SessionDriver.mappingScaleKey,
                      options: percents([0.3, 0.4, 0.5, 0.6, 0.8, 1.0])) {
                    UserDefaults.standard.object(forKey: SessionDriver.mappingScaleKey) as? Double ?? base.mappingScale
                },
            ]
            menuBar.debugToggles = [
                .init(title: "常驻模式", key: SessionDriver.stickyPanelKey) { on in
                    debug.model.log(on ? "常驻模式：开（下一次唤起生效）" : "常驻模式：关")
                },
                .init(title: "背景压暗", key: OverlayController.dimKey) { on in
                    debug.model.log(on ? "背景压暗：开（下一次唤起生效）" : "背景压暗：关")
                },
            ] + SessionDriver.triggers.map { trigger in
                .init(title: "唤起：\(trigger.title)", key: trigger.key) { on in
                    debug.model.log("唤起：\(trigger.title) \(on ? "开" : "关")（下一次触摸生效）")
                }
            }
            tap.onPressureDebug = { stage, pressure in
                DispatchQueue.main.async { debug.model.pressure = (stage, pressure) }
            }
            menuBar.onDebugStall = {
                tap.scheduleDebugStall(after: Self.debugStallDelay)
                debug.model.log("已预约：\(Int(Self.debugStallDelay)) 秒后阻塞拦截")
            }
        }

        watchdog = TapWatchdog(tap: tap)
        watchdog.onStatusChange = { [weak self] status in
            self?.tapStatus = status
            if status != .ok { driver.send(.tapDisabled) }
            self?.refreshStatus()
        }
        startTap(prompt: true)
        startInput()
        observeSystem()
        refreshStatus()
    }

    func shutdown() {
        driver?.cancelNow("quit")
    }

    // MARK: 启动各部分

    /// 创建事件拦截；没有辅助功能权限时请求授权并轮询，授权后 2 秒内自动生效（FR-12.2）
    private func startTap(prompt: Bool) {
        if tap.start() {
            permissionTimer?.invalidate()
            permissionTimer = nil
            tapStatus = .ok
            watchdog.start()
            refreshStatus()
            return
        }
        tapStatus = .permissionMissing
        if prompt {
            // kAXTrustedCheckOptionPrompt 的值；该全局变量在严格并发检查下不可直接引用
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: Self.permissionPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if AXIsProcessTrusted() { self?.startTap(prompt: false) }
            }
        }
    }

    private func startInput() {
        let pipeline = self.pipeline!
        do {
            let bridge = try MultitouchBridge.load { device, timestamp, raw in
                pipeline.enqueue(device: device, timestamp: timestamp, raw: raw)
            }
            let manager = DeviceManager(bridge: bridge, pipeline: pipeline)
            manager.onChange = { [weak self] devices, removed in
                self?.debugOverlay?.model.setDevices(devices)
                let map = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
                self?.driver.updateEnvironment { $0.devices = map }
                for id in removed { self?.driver.send(.deviceRemoved(id)) }  // FR-4.5
            }
            deviceManager = manager
            manager.start()
        } catch {
            setInputUnavailable(error.description)
        }
    }

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        let driver = self.driver!
        // 前台应用：动作上下文与按应用布局（K11）
        workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            driver.updateEnvironment { $0.frontmostBundleID = id }
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        driver.updateEnvironment { $0.frontmostBundleID = frontmost }
        // SRS 5.2 forceCancel：屏幕锁定、快速用户切换
        workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { _ in
            driver.send(.forceCancel("session resigned"))
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            driver.send(.forceCancel("screen locked"))
        }
    }

    // MARK: 状态

    private func setInputUnavailable(_ reason: String) {
        log.error("input unavailable: \(reason, privacy: .public)")
        inputUnavailable = reason
        pipeline.setActiveDevices([])
        debugOverlay?.model.status = "输入不可用：\(reason)"
        refreshStatus()
    }

    private func refreshStatus() {
        let text: String?
        if let inputUnavailable {
            text = "输入不可用（\(inputUnavailable)）"
        } else {
            switch tapStatus {
            case .ok: text = nil
            case .permissionMissing: text = "缺少辅助功能权限"
            case .tapUnavailable: text = "拦截不可用"
            }
        }
        menuBar.setStatus(text ?? "正常", warning: text != nil)
        let suspended = text != nil
        driver.updateEnvironment { $0.suspended = suspended }
    }
}

/// 拦截回调需要引用尚未创建的 SessionDriver；创建后只写一次
private final class DriverRef: @unchecked Sendable {
    var driver: SessionDriver?
}
