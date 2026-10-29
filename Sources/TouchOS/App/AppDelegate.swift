import AppKit
import OSLog
import TouchOSCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: TouchOSCore.logSubsystem, category: "app")
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController()
        log.info("launched")
    }
}
