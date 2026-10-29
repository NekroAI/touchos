/// TouchOS 的纯逻辑部分：数据模型、会话状态机与核心算法（SRS 第 3、5、6 章）。
/// 不得引用 AppKit、CoreGraphics 事件或私有框架类型（SRS FR-3.2），用合成触点帧做确定性测试。
public enum TouchOSCore {
    /// 统一日志子系统（SRS NFR-11，按 docs/decisions.md D1 与 Bundle ID 一致）
    public static let logSubsystem = "ai.nekro.touchos"
}
