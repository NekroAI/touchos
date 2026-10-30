import AppKit
import Foundation
import OSLog
import TouchOSCore

/// 直接驱动触控板的触觉马达（FR-6.14）。
/// `NSHapticFeedbackManager` 只在系统认为用户正在使用触控板时才震动：面板开着、单指移动时，
/// 指针事件全部被拦截丢弃，系统不再播放（负责人实测）。这里改用 MultitouchSupport 的 `MTActuator*` 按设备直接震动。
/// 只在 input.queue 上使用。
final class TrackpadHaptics: @unchecked Sendable {
    enum Strength {
        /// 悬停槽位切换、翻页
        case light
        /// 提交确认（D16）
        case strong
    }

    // 私有框架 MultitouchSupport 的触觉接口（与 MultitouchBridge 同一框架，运行时 dlsym，SRS 2.1）。
    // 降级：任一符号缺失、设备没有触觉马达或打开失败时，退回 NSHapticFeedbackManager。
    private typealias CreateFromDeviceID = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
    private typealias Open = @convention(c) (CFTypeRef) -> Int32
    private typealias Close = @convention(c) (CFTypeRef) -> Int32
    private typealias Actuate = @convention(c) (CFTypeRef, Int32, UInt32, Float, Float) -> Int32

    /// 震动波形编号与参数：取自开源项目 HapticKey 的实测值，含义未见官方文档
    private static let lightActuation: Int32 = 3
    private static let strongActuation: Int32 = 6
    private static let actuationArg1: UInt32 = 0
    private static let actuationArg2: Float = 0
    private static let actuationArg3: Float = 2

    private let log = Logger(subsystem: TouchOSCore.logSubsystem, category: "haptics")
    private let create: CreateFromDeviceID?
    private let open: Open?
    private let close: Close?
    private let actuate: Actuate?
    /// 已打开的马达；值为 nil 表示该设备打开失败，不再重试
    private var actuators: [TrackpadDeviceID: CFTypeRef?] = [:]

    init() {
        let handle = dlopen(MultitouchBridge.frameworkPath, RTLD_NOW)
        func symbol<T>(_ name: String, _: T.Type) -> T? {
            handle.flatMap { dlsym($0, name) }.map { unsafeBitCast($0, to: T.self) }
        }
        create = symbol("MTActuatorCreateFromDeviceID", CreateFromDeviceID.self)
        open = symbol("MTActuatorOpen", Open.self)
        close = symbol("MTActuatorClose", Close.self)
        actuate = symbol("MTActuatorActuate", Actuate.self)
    }

    deinit {
        guard let close else { return }
        for case let actuator? in actuators.values { _ = close(actuator) }
    }

    func perform(_ strength: Strength, on device: TrackpadDeviceID?) {
        if let device, let actuator = actuator(for: device), let actuate {
            let id = strength == .strong ? Self.strongActuation : Self.lightActuation
            if actuate(actuator, id, Self.actuationArg1, Self.actuationArg2, Self.actuationArg3) == 0 { return }
        }
        let pattern: NSHapticFeedbackManager.FeedbackPattern = strength == .strong ? .levelChange : .alignment
        DispatchQueue.main.async {
            NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        }
    }

    private func actuator(for device: TrackpadDeviceID) -> CFTypeRef? {
        if let cached = actuators[device] { return cached }
        var result: CFTypeRef?
        if let create, let open, let ref = create(device.raw)?.takeRetainedValue() {
            if open(ref) == 0 { result = ref }
        }
        actuators[device] = .some(result)
        log.info("actuator for device \(device.raw, privacy: .public): \(result == nil ? "unavailable, falling back" : "opened", privacy: .public)")
        return result
    }
}
