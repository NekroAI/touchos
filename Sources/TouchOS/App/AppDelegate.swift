import AppKit
import OSLog
import TouchOSCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: TouchOSCore.logSubsystem, category: "app")
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = AppCoordinator()
        self.coordinator = coordinator
        coordinator.start()
        log.info("launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 退出前先恢复光标并停止拦截（SRS 5.5、NFR-7）
        coordinator?.shutdown()
    }
}
