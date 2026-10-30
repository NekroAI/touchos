/// 面板打开时怎么处理屏幕上的光标（D52）
public enum CursorFreeze: String, Codable, CaseIterable, Sendable {
    /// 隐藏：屏幕上看不到光标，关闭面板后在原处出现
    case hide
    /// 保持显示：只靠丢弃指针事件，部分 Mac 上屏幕光标仍会跟手
    case keep
}
