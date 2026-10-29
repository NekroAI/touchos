// swift-tools-version:6.0
import PackageDescription

// 单一 SwiftPM 包，不建 Xcode 工程；.app 由 scripts/build-macos.sh 组装（docs/decisions.md D6）。
// swift-tools-version 6.0 默认使用 Swift 6 语言模式与完整的严格并发检查。
let package = Package(
    name: "TouchOS",
    platforms: [.macOS(.v14)],
    targets: [
        // 状态机与算法：不得引用 AppKit、CoreGraphics 事件或私有框架类型（SRS FR-3.2）
        .target(name: "TouchOSCore"),
        // 事件拦截回调用的无锁原子变量（SRS FR-7.2）
        .target(name: "TouchOSAtomics"),
        .executableTarget(name: "TouchOS", dependencies: ["TouchOSCore", "TouchOSAtomics"]),
        .testTarget(name: "TouchOSCoreTests", dependencies: ["TouchOSCore"]),
    ]
)
