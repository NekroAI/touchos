import CoreGraphics
import Foundation
import OSLog
import TouchOSCore

/// 主显示器亮度（0–1），供亮度滑杆使用。
/// 私有框架 DisplayServices：`DisplayServicesGetBrightness` / `DisplayServicesSetBrightness`（运行时 dlopen / dlsym，
/// 符号见系统 /System/Library/PrivateFrameworks/DisplayServices.framework，社区工具 brightness、MonitorControl 同样使用）。
/// 降级：框架或符号缺失、显示器不支持软件调光（多数外接显示器）时读返回 nil、写忽略，滑杆仍可显示但不生效。
enum DisplayBrightness {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let log = Logger(subsystem: TouchOSCore.logSubsystem, category: "brightness")
    private static let queue = DispatchQueue(label: "ai.nekro.touchos.brightness", qos: .userInitiated)
    private static let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"

    private static let symbols: (get: Get?, set: Set?) = {
        guard let handle = dlopen(path, RTLD_NOW) else { return (nil, nil) }
        return (dlsym(handle, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: Get.self) },
                dlsym(handle, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: Set.self) })
    }()

    static func get() -> Double? {
        guard let get = symbols.get else { return nil }
        var value = Float(0)
        guard get(CGMainDisplayID(), &value) == 0 else { return nil }
        return Double(value)
    }

    /// 异步设置，不阻塞输入队列
    static func set(_ value: Double) {
        queue.async {
            guard let set = symbols.set else { return log.info("brightness unavailable") }
            let status = set(CGMainDisplayID(), Float(min(max(value, 0), 1)))
            if status != 0 { log.info("set brightness failed: \(status)") }
        }
    }
}
