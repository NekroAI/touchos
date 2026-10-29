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

    /// 已在运行时再次打开应用（访达双击、`open`）：显示设置窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator?.openSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 退出前先恢复光标并停止拦截（SRS 5.5、NFR-7）
        coordinator?.shutdown()
    }
}
