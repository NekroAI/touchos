/// 面板对应触控板的哪个位置（D55）
public enum PanelAnchor: String, Codable, CaseIterable, Sendable {
    /// 跟随落点：手指落下的位置就是面板中心，同一个按钮总是同样的方向和距离
    case landing
    /// 固定在中央：映射区固定在触控板正中，手指的绝对位置对应按钮（D9）
    case center
}
