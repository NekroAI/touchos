import AppKit
import IOKit
import OSLog
import TouchOSCore

/// 按设备类别启用 / 停用（SRS FR-4.6）；K8 起由配置 `devices` 段提供。
struct DeviceFilter: Equatable {
    var builtIn = true
    var external = true

    func allows(_ device: TrackpadDevice) -> Bool { device.isBuiltIn ? builtIn : external }
}

/// 设备枚举、热插拔与休眠唤醒后的重新注册（SRS 4.3）。运行在主线程。
/// 任何变化都整体重新枚举：停止所有设备 → 重新枚举 → 只启动被启用的设备。
@MainActor
final class DeviceManager {
    /// 设备接入后等待初始化再枚举；FR-4.5 要求 1 秒内完成
    static let attachSettleDelay: TimeInterval = 0.5
    /// 唤醒后等待设备恢复再枚举；FR-4.5 要求 2 秒内完成
    static let wakeSettleDelay: TimeInterval = 1.0

    private let log = Logger(subsystem: TouchOSCore.logSubsystem, category: "devices")
    private let bridge: MultitouchBridge
    private let pipeline: InputPipeline
    private var running: [DeviceHandle] = []
    private var notifyPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var pendingRefresh: DispatchWorkItem?

    var filter = DeviceFilter() {
        didSet { if filter != oldValue { refresh() } }
    }
    /// 启用中的设备变化时调用：(当前设备, 被移除的设备 ID)
    var onChange: (([TrackpadDevice], [TrackpadDeviceID]) -> Void)?

    var devices: [TrackpadDevice] { running.map(\.device) }

    init(bridge: MultitouchBridge, pipeline: InputPipeline) {
        self.bridge = bridge
        self.pipeline = pipeline
    }

    func start() {
        refresh()
        observeHotplug()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.scheduleRefresh(after: Self.wakeSettleDelay, reason: "wake") }
        }
    }

    func refresh() {
        pendingRefresh?.cancel()
        pendingRefresh = nil
        let before = Set(running.map(\.device.id))
        running.forEach(bridge.stop)
        running = []

        for handle in bridge.devices() {
            if filter.allows(handle.device) {
                bridge.start(handle)
                running.append(handle)
            } else {
                bridge.release(handle)
            }
        }
        let after = Set(running.map(\.device.id))
        pipeline.setActiveDevices(after)
        for d in devices {
            log.info("device \(d.id.raw, privacy: .public) \(d.isBuiltIn ? "built-in" : "external", privacy: .public) \(d.surfaceSizeMM.width, format: .fixed(precision: 1), privacy: .public)x\(d.surfaceSizeMM.height, format: .fixed(precision: 1), privacy: .public)mm")
        }
        onChange?(devices, Array(before.subtracting(after)))
    }

    private func scheduleRefresh(after delay: TimeInterval, reason: StaticString) {
        log.info("refresh scheduled: \(reason, privacy: .public)")
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// IOKit 设备接入 / 移除通知（AppleMultitouchDevice）。移除立即重新枚举，接入稍等设备初始化。
    private func observeHotplug() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            log.error("IONotificationPortCreate failed; hot-plug detection disabled")
            return
        }
        notifyPort = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for (type, callback) in [(kIOFirstMatchNotification, deviceAttached), (kIOTerminatedNotification, deviceDetached)] {
            var iterator: io_iterator_t = 0
            guard IOServiceAddMatchingNotification(port, type, IOServiceMatching("AppleMultitouchDevice"),
                                                   callback, refcon, &iterator) == KERN_SUCCESS else { continue }
            Self.drain(iterator)  // 取空迭代器才会开始接收通知；已存在的设备由 refresh() 处理
            iterators.append(iterator)
        }
    }

    fileprivate func hotplug(attached: Bool) {
        scheduleRefresh(after: attached ? Self.attachSettleDelay : 0, reason: attached ? "attached" : "detached")
    }

    /// IOKit 回调运行在主线程 RunLoop 上；refcon 以地址传入，避免把非 Sendable 指针带进隔离域
    fileprivate nonisolated static func onMain(_ refcon: UnsafeMutableRawPointer, _ body: @MainActor (DeviceManager) -> Void) {
        let address = UInt(bitPattern: refcon)
        MainActor.assumeIsolated {
            body(Unmanaged<DeviceManager>.fromOpaque(UnsafeRawPointer(bitPattern: address)!).takeUnretainedValue())
        }
    }

    fileprivate nonisolated static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }
}

// IOKit 回调在主线程的 RunLoop 上执行
private let deviceAttached: IOServiceMatchingCallback = { refcon, iterator in
    DeviceManager.drain(iterator)
    guard let refcon else { return }
    DeviceManager.onMain(refcon) { $0.hotplug(attached: true) }
}

private let deviceDetached: IOServiceMatchingCallback = { refcon, iterator in
    DeviceManager.drain(iterator)
    guard let refcon else { return }
    DeviceManager.onMain(refcon) { $0.hotplug(attached: false) }
}
