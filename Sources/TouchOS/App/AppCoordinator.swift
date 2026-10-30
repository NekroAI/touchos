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
    private let updates = UpdateChecker()
    private let configs = ConfigController()
    private var appearanceMenu: AppearanceMenu!
    private var settings: SettingsWindowController!
    private let welcome = WelcomeWindowController()
    private lazy var cloud = CloudSyncController(configs: configs)
    private var frontmost: String?
    private let queue = DispatchQueue(label: "ai.nekro.touchos.input", qos: .userInteractive)
    private var driver: SessionDriver!
    private var pipeline: InputPipeline!
    private var tap: EventTapController!
    private var watchdog: TapWatchdog!
    private var deviceManager: DeviceManager?
    private var debugOverlay: DebugOverlayController?
    private var simulator: TouchSimulator?
    private var permissionTimer: Timer?

    // 降级原因（任一存在即不接受唤起）
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
        let executor = ActionExecutor()
        let cursor = CursorLock(tap: tap, stallLimit: tuning.cursorStallLimitMs / 1000)
        let driver = SessionDriver(queue: queue, tuning: tuning, tap: tap, cursor: cursor,
                                   executor: executor, overlay: overlay)
        ref.driver = driver
        self.driver = driver
        let configs = self.configs
        appearanceMenu = AppearanceMenu(read: { Appearance(configs.config.appearance) },
                                        write: { a in configs.update { $0.appearance = a.config } })
        menuBar.appearanceItem = appearanceMenu.item
        settings = SettingsWindowController(configs: configs, executor: executor, cloud: cloud)
        menuBar.onOpenSettings = { [weak self] in self?.settings.show() }
        updates.onChange = { [weak self] release in self?.menuBar.availableUpdate = release }
        updates.enabled = configs.config.general.checkUpdates
        menuBar.onToggleEnabled = { configs.update { $0.general.enabled.toggle() } }
        driver.onOpenEditor = { [weak self] panelID in self?.settings.show(editing: panelID) }
        configs.observe { [weak self] c in
            driver.apply(c)
            executor.focusesPointerWindow = c.general.focusPointerWindow
            overlay.appearance = Appearance(c.appearance)
            overlay.dim = c.general.dimBackground
            overlay.showTrail = c.general.showTrail
            self?.appearanceMenu?.rebuild()
            self?.menuBar.enabled = c.general.enabled
            self?.updates.enabled = c.general.checkUpdates
            self?.refreshStatus()
        }

        pipeline = InputPipeline(
            queue: queue,
            clockResyncThreshold: tuning.clockResyncMs / 1000,
            onFrame: { frame in driver.handle(.frame(frame)) },
            onLayoutMismatch: { [weak self] in
                DispatchQueue.main.async { self?.setInputUnavailable(String(localized: "触点数据格式与本机系统不符")) }
            })

        if DebugOverlayController.isAvailable {
            let debug = DebugOverlayController(pipeline: pipeline, tap: tap, cursor: cursor)
            debugOverlay = debug
            simulator = TouchSimulator(driver: driver, overlay: overlay)
            menuBar.onToggleDebugOverlay = { [weak self] in
                debug.toggle()
                self?.menuBar.debugOverlayVisible = debug.isVisible
            }
            driver.onDebug = { line in DispatchQueue.main.async { debug.model.log(line) } }
            driver.onLatency = { sample in debug.model.record(sample) }
            let tap = self.tap!
            tap.onPressureDebug = { stage, pressure in
                DispatchQueue.main.async { debug.model.pressure = (stage, pressure) }
            }
            menuBar.onDebugStall = {
                tap.scheduleDebugStall(after: Self.debugStallDelay)
                debug.model.log("已预约：\(Int(Self.debugStallDelay)) 秒后阻塞拦截")  // l10n-ignore
            }
        }

        watchdog = TapWatchdog(tap: tap)
        watchdog.onStatusChange = { [weak self] status in
            self?.tapStatus = status
            if status != .ok { driver.send(.tapDisabled) }
            self?.refreshStatus()
        }
        // K13：首次启动或缺少辅助功能权限时显示引导，由引导页带用户去授权（不再直接弹系统提示）
        cloud.start()
        // 新装的 Mac：iCloud 云盘里已有配置时先问是否接入（D35）
        if configs.isFirstLaunch { cloud.offerToJoin() }
        let needsWelcome = configs.isFirstLaunch || !AXIsProcessTrusted()
        welcome.onOpenSettings = { [weak self] in self?.settings.show() }
        startTap(prompt: !needsWelcome)
        if needsWelcome { welcome.show() }
        startInput()
        observeSystem()
        refreshStatus()
    }

    func openSettings() {
        settings.show()
    }

    func shutdown() {
        driver?.cancelNow("quit")
        configs.flush()
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
        workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            driver.updateEnvironment { $0.frontmostBundleID = id }
            MainActor.assumeIsolated {
                self?.frontmost = id
                self?.refreshStatus()  // 黑名单
            }
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        self.frontmost = frontmost
        driver.updateEnvironment { $0.frontmostBundleID = frontmost }
        // SRS 5.2 forceCancel：屏幕锁定、快速用户切换；睡眠与关屏时也不留着断开关联的光标（D50）
        workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { _ in
            driver.send(.forceCancel("session resigned"))
        }
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            driver.send(.forceCancel("will sleep"))
        }
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
            driver.send(.forceCancel("screens slept"))
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
        debugOverlay?.model.status = "输入不可用：\(reason)"  // l10n-ignore
        refreshStatus()
    }

    private func refreshStatus() {
        let text: String?
        if let inputUnavailable {
            text = String(localized: "输入不可用（\(inputUnavailable)）")
        } else {
            switch tapStatus {
            case .ok: text = nil
            case .permissionMissing: text = String(localized: "缺少辅助功能权限")
            case .tapUnavailable: text = String(localized: "拦截不可用")
            }
        }
        let general = configs.config.general
        let paused = !general.enabled
        let blocked = frontmost.map { general.blacklist.contains($0) } ?? false
        menuBar.setStatus(text ?? (paused ? String(localized: "已暂停") : blocked ? String(localized: "当前应用已排除") : String(localized: "正常")), warning: text != nil, paused: text == nil && paused)
        let suspended = text != nil || paused || blocked
        driver.updateEnvironment { $0.suspended = suspended }
    }
}

/// 拦截回调需要引用尚未创建的 SessionDriver；创建后只写一次
private final class DriverRef: @unchecked Sendable {
    var driver: SessionDriver?
}
