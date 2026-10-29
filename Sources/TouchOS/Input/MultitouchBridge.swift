import CoreGraphics
import Foundation
import TouchOSCore

/// 一台已枚举的设备：私有框架的 MTDeviceRef 加上解析出的设备信息。
/// MTDeviceRef 只在主线程上启动 / 停止，回调线程只读它的地址。
struct DeviceHandle: @unchecked Sendable {
    let ref: UnsafeMutableRawPointer
    let device: TrackpadDevice
}

/// 运行时加载私有框架 MultitouchSupport，把接触帧回调转成 `RawContact` 数组（SRS 4.1）。
/// 禁止编译期链接：所有符号经 `dlopen` / `dlsym` 解析，缺少必需符号时 `load()` 失败，由调用方进入"输入不可用"降级。
final class MultitouchBridge: Sendable {
    static let frameworkPath = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

    enum LoadError: Error, CustomStringConvertible {
        case frameworkMissing
        case symbolMissing(String)

        var description: String {
            switch self {
            case .frameworkMissing: "无法加载 MultitouchSupport 私有框架"
            case .symbolMissing(let name): "私有框架缺少符号 \(name)"
            }
        }
    }

    // 函数签名以 OpenMultitouchSupport、MiddleDrag 等开源实现为准
    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias Register = @convention(c) (UnsafeMutableRawPointer, FrameCallback) -> Void
    private typealias DeviceStart = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
    private typealias DeviceStop = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias IsBuiltIn = @convention(c) (UnsafeMutableRawPointer) -> Bool
    private typealias SurfaceDimensions = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32
    private typealias GetDeviceID = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
    /// (设备, 接触数组, 接触数, 时间戳（秒）, 帧号) -> 忽略的返回值
    typealias FrameCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, Int32, Double, Int32) -> Int32

    private let createList: CreateList
    private let register: Register
    private let unregister: Register
    private let deviceStart: DeviceStart
    private let deviceStop: DeviceStop
    private let isBuiltIn: IsBuiltIn?
    private let surfaceDimensions: SurfaceDimensions?
    private let getDeviceID: GetDeviceID?

    /// 回调线程上收到的每一帧：(设备 ID, 时间戳, 原始接触)
    private let deliver: @Sendable (TrackpadDeviceID, TimeInterval, [RawContact]) -> Void

    /// 私有框架回调是 C 函数指针，无法携带上下文，只能通过全局引用找到桥接对象；加载后只写一次。
    nonisolated(unsafe) private static var current: MultitouchBridge?

    private init(handle: UnsafeMutableRawPointer,
                 deliver: @escaping @Sendable (TrackpadDeviceID, TimeInterval, [RawContact]) -> Void) throws(LoadError) {
        func required<T>(_ name: String, _: T.Type) throws(LoadError) -> T {
            guard let sym = dlsym(handle, name) else { throw .symbolMissing(name) }
            return unsafeBitCast(sym, to: T.self)
        }
        func optional<T>(_ name: String, _: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        // FR-4.1 必需符号：任一缺失即降级
        createList = try required("MTDeviceCreateList", CreateList.self)
        register = try required("MTRegisterContactFrameCallback", Register.self)
        unregister = try required("MTUnregisterContactFrameCallback", Register.self)
        deviceStart = try required("MTDeviceStart", DeviceStart.self)
        deviceStop = try required("MTDeviceStop", DeviceStop.self)
        // FR-4.1 可选符号：缺失时用替代值（见 makeDevice）
        isBuiltIn = optional("MTDeviceIsBuiltIn", IsBuiltIn.self)
        surfaceDimensions = optional("MTDeviceGetSensorSurfaceDimensions", SurfaceDimensions.self)
        // 不在 FR-4.1 列表中：用于取得稳定的设备 ID（与 ioreg 中的 Multitouch ID 一致）；缺失时退回设备对象地址
        getDeviceID = optional("MTDeviceGetDeviceID", GetDeviceID.self)
        self.deliver = deliver
    }

    /// 加载私有框架。`deliver` 在私有框架的回调线程上调用，必须立即返回（SRS 2.3）。
    static func load(deliver: @escaping @Sendable (TrackpadDeviceID, TimeInterval, [RawContact]) -> Void) throws(LoadError) -> MultitouchBridge {
        if let current { return current }
        guard let handle = dlopen(frameworkPath, RTLD_NOW) else { throw .frameworkMissing }
        let bridge = try MultitouchBridge(handle: handle, deliver: deliver)
        current = bridge
        return bridge
    }

    /// 枚举当前连接的触控设备（MTDeviceCreateList）。
    func devices() -> [DeviceHandle] {
        guard let list = createList()?.takeRetainedValue() as? [AnyObject] else { return [] }
        return list.map { obj in
            // 列表元素是 CF 对象；保留一次，与设备的整个注册周期同寿命，避免列表释放后地址失效
            let ref = Unmanaged.passRetained(obj).toOpaque()
            return DeviceHandle(ref: ref, device: makeDevice(ref))
        }
    }

    func start(_ handle: DeviceHandle) {
        register(handle.ref, contactFrameCallback)
        _ = deviceStart(handle.ref, 0)
    }

    func stop(_ handle: DeviceHandle) {
        unregister(handle.ref, contactFrameCallback)
        _ = deviceStop(handle.ref)
        release(handle)
    }

    /// 释放 `devices()` 返回但未启动的设备（例如被配置停用的设备）。
    func release(_ handle: DeviceHandle) {
        Unmanaged<AnyObject>.fromOpaque(handle.ref).release()
    }

    private func makeDevice(_ ref: UnsafeMutableRawPointer) -> TrackpadDevice {
        let id = deviceID(ref)
        // MTDeviceIsBuiltIn 缺失时无法可靠区分，按外接设备处理
        let builtIn = isBuiltIn?(ref) ?? false
        var size = Self.fallbackSurfaceMM
        if let surfaceDimensions {
            var w: Int32 = 0, h: Int32 = 0
            // 单位为 1/100 毫米（2026-10-29 在妙控板上实测为 15600 × 11040，即 156 × 110.4 mm）
            if surfaceDimensions(ref, &w, &h) == 0, w > 0, h > 0 {
                size = CGSize(width: Double(w) / 100, height: Double(h) / 100)
            }
        }
        return TrackpadDevice(id: id, isBuiltIn: builtIn, displayName: builtIn ? "内置触控板" : "妙控板", surfaceSizeMM: size)
    }

    /// 尺寸接口缺失时的默认值：妙控板第二代的感应区尺寸（实测值）。
    /// SPEC-QUESTION: FR-4.1 要求"型号默认尺寸表"，但在尺寸接口缺失时也拿不到型号；目前只有这一个默认值。
    static let fallbackSurfaceMM = CGSize(width: 156, height: 110.4)

    fileprivate func deviceID(_ ref: UnsafeMutableRawPointer) -> TrackpadDeviceID {
        var raw: UInt64 = 0
        if let getDeviceID, getDeviceID(ref, &raw) == 0 { return TrackpadDeviceID(raw: raw) }
        return TrackpadDeviceID(raw: UInt64(UInt(bitPattern: ref)))
    }

    fileprivate func receive(device: UnsafeMutableRawPointer, touches: UnsafeRawPointer?, count: Int, timestamp: Double) {
        var contacts: [RawContact] = []
        if let touches, count > 0 {
            contacts.reserveCapacity(count)
            for i in 0..<count {
                contacts.append(MTTouchLayout.read(touches + i * MTTouchLayout.stride))
            }
        }
        deliver(deviceID(device), timestamp, contacts)
    }
}

/// 私有框架的接触帧回调：运行在私有框架的线程上，只拷贝数据后立即返回（SRS 2.3）。
private let contactFrameCallback: MultitouchBridge.FrameCallback = { device, touches, count, timestamp, _ in
    if let device, let bridge = MultitouchBridge.currentForCallback {
        bridge.receive(device: device, touches: touches, count: Int(count), timestamp: timestamp)
    }
    return 0
}

extension MultitouchBridge {
    fileprivate static var currentForCallback: MultitouchBridge? { current }
}

/// MTTouch 结构体布局（共 96 字节），按偏移读取而不是声明 Swift 结构体，避免依赖 Swift 的布局规则。
/// 来源：OpenMultitouchSupport / MiddleDrag 的 MTTouch 定义；布局不符时由 LayoutSelfCheck 发现（FR-4.1）。
private enum MTTouchLayout {
    static let stride = 96
    static let identifier = 16      // int，同一手指接触期间不变
    static let state = 20           // int，原始状态码（FR-4.2）
    static let positionX = 32       // float，归一化坐标，原点左下
    static let positionY = 36
    static let velocityX = 40       // float，归一化单位/秒
    static let velocityY = 44
    static let size = 48            // float，接触面积（zTotal）
    static let pressure = 52        // float（zPressure）；含义待 M0 实测确认
    static let angle = 56           // float；以下四项只用于调试观察与交互实验，含义待实测确认
    static let majorAxis = 60
    static let minorAxis = 64
    static let density = 92         // float（zDensity）

    static func read(_ p: UnsafeRawPointer) -> RawContact {
        RawContact(
            id: Int(p.loadUnaligned(fromByteOffset: identifier, as: Int32.self)),
            state: Int(p.loadUnaligned(fromByteOffset: state, as: Int32.self)),
            position: CGPoint(x: Double(p.loadUnaligned(fromByteOffset: positionX, as: Float.self)),
                              y: Double(p.loadUnaligned(fromByteOffset: positionY, as: Float.self))),
            velocity: CGVector(dx: Double(p.loadUnaligned(fromByteOffset: velocityX, as: Float.self)),
                               dy: Double(p.loadUnaligned(fromByteOffset: velocityY, as: Float.self))),
            size: p.loadUnaligned(fromByteOffset: size, as: Float.self),
            pressure: p.loadUnaligned(fromByteOffset: pressure, as: Float.self),
            ellipse: ContactEllipse(angle: p.loadUnaligned(fromByteOffset: angle, as: Float.self),
                                    majorAxis: p.loadUnaligned(fromByteOffset: majorAxis, as: Float.self),
                                    minorAxis: p.loadUnaligned(fromByteOffset: minorAxis, as: Float.self),
                                    density: p.loadUnaligned(fromByteOffset: density, as: Float.self)))
    }
}
