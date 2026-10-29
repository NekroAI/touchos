import AppKit
import OSLog
import TouchOSCore

/// 组装各模块并决定启动顺序（SRS 2.2）。
@MainActor
final class AppCoordinator {
    enum InputStatus: Equatable {
        case normal
        /// 输入不可用（FR-4.1 降级）：私有框架或符号缺失、接触布局自检失败
        case unavailable(String)
    }

    private let log = Logger(subsystem: TouchOSCore.logSubsystem, category: "app")
    private let menuBar = MenuBarController()
    private var pipeline: InputPipeline!
    private var deviceManager: DeviceManager?
    private var debugOverlay: DebugOverlayController?

    func start() {
        pipeline = InputPipeline(
            onFrame: { _ in },  // K4 起交给 SessionStateMachine
            onLayoutMismatch: { [weak self] in
                DispatchQueue.main.async { self?.inputUnavailable("触点数据格式与本机系统不符") }
            })

        if DebugOverlayController.isAvailable {
            let overlay = DebugOverlayController(pipeline: pipeline)
            debugOverlay = overlay
            menuBar.onToggleDebugOverlay = { [weak self] in
                overlay.toggle()
                self?.menuBar.debugOverlayVisible = overlay.isVisible
            }
        }

        let pipeline = self.pipeline!
        do {
            let bridge = try MultitouchBridge.load { device, timestamp, raw in
                pipeline.enqueue(device: device, timestamp: timestamp, raw: raw)
            }
            let manager = DeviceManager(bridge: bridge, pipeline: pipeline)
            manager.onChange = { [weak self] devices, _ in
                self?.debugOverlay?.model.setDevices(devices)
            }
            deviceManager = manager
            manager.start()
            menuBar.inputStatus = .normal
        } catch {
            inputUnavailable(error.description)
        }
    }

    private func inputUnavailable(_ reason: String) {
        log.error("input unavailable: \(reason, privacy: .public)")
        pipeline.setActiveDevices([])
        menuBar.inputStatus = .unavailable(reason)
        debugOverlay?.model.status = "输入不可用：\(reason)"
    }
}
