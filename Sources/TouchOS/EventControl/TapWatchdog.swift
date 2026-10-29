import ApplicationServices
import Foundation
import OSLog
import TouchOSCore

/// 拦截失效检测与恢复（SRS 7.5）。运行在主线程。
@MainActor
final class TapWatchdog {
    /// FR-7.11：检查间隔与连续失败上限
    static let interval: TimeInterval = 2
    static let maxFailures = 3

    enum Status: Equatable {
        case ok
        /// 拦截反复重新启用失败（FR-7.11）
        case tapUnavailable
        /// 失去辅助功能权限（FR-7.12）
        case permissionMissing
    }

    private let log = Logger(subsystem: TouchOSCore.logSubsystem, category: "tap")
    private let tap: EventTapController
    private var timer: Timer?
    private var failures = 0
    private(set) var status = Status.ok

    var onStatusChange: ((Status) -> Void)?

    init(tap: EventTapController) {
        self.tap = tap
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func check() {
        let next: Status
        if !AXIsProcessTrusted() {
            next = .permissionMissing
        } else if tap.isEnabled {
            failures = 0
            next = .ok
        } else {
            tap.reenable()
            failures = tap.isEnabled ? 0 : failures + 1
            if failures > 0 { log.error("event tap re-enable failed (\(self.failures, privacy: .public))") }
            next = failures >= Self.maxFailures ? .tapUnavailable : status
        }
        if next != status {
            status = next
            onStatusChange?(next)
        }
    }
}
