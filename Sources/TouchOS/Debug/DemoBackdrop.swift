import AppKit
import SwiftUI

/// 录制 README 演示动图用的场景（只在调试叠层可用时存在）：盖住指针所在屏幕，一个示例窗口、一块跟随合成触点的
/// 触控板、一行说明。预演不执行真实动作，这里按时间表让示例窗口做出相应反应。不接收鼠标
@MainActor
final class DemoBackdrop {
    /// 说明文字的语言，对应预演脚本 `demo`（英文）与 `demo.zh`
    enum Language { case en, zh }

    /// 时间表：预演开始后第几秒换说明、窗口做什么
    private static let timeline: [(t: TimeInterval, en: String, zh: String, change: (DemoBackdropModel) -> Void)] = [
        (0, "Tap, then hold", "轻点后按住", { _ in }),
        (0.9, "Your finger's position picks the button", "手指的位置直接指向按钮", { _ in }),
        (2.91, "Lift to run it", "抬起即执行", { $0.copied = true }),
        (4.2, "Each gesture can open its own panel", "每种唤起方式可以打开不同面板", { $0.copied = false }),
        (5.8, "Ring panels make direction the choice", "环形面板，方向就是选择", { _ in }),
        (6.81, "Snapped to the right half", "窗口贴到右半屏", { $0.snapped = true }),
        (8.2, "Swipe two fingers to switch panels", "双指滑动切换面板", { _ in }),
        (12.0, "Pinch for an overview", "捏合查看全部面板", { _ in }),
        (13.8, "", "", { $0.snapped = false }),
    ]

    private let model = DemoBackdropModel()
    private var panel: NSPanel?
    private var language = Language.en
    private var next = 0

    func show(language: Language) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        self.language = language
        model.copiedText = language == .zh ? "已拷贝" : "Copied"
        next = 0
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)  // 盖住菜单栏，在浮层之下
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: DemoBackdropView(model: model))
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
        self.panel?.close()
        self.panel = panel
    }

    func hide() {
        panel?.close()
        panel = nil
        model.reset()
    }

    /// 推进时间表
    func advance(to elapsed: TimeInterval) {
        while next < Self.timeline.count, Self.timeline[next].t <= elapsed {
            let step = Self.timeline[next]
            model.caption = language == .zh ? step.zh : step.en  // 不做渐变：新旧文字叠在一起时看不清
            withAnimation(.spring(duration: 0.45, bounce: 0.12)) { step.change(model) }
            next += 1
        }
    }

    /// 板上的手指（触控板归一化坐标，原点左下）
    func update(fingers: [Int: CGPoint]) {
        withAnimation(.easeOut(duration: 0.12)) { model.fingers = fingers }
    }
}

@MainActor @Observable
private final class DemoBackdropModel {
    var fingers: [Int: CGPoint] = [:]
    var caption = ""
    var copied = false
    var copiedText = ""
    var snapped = false

    func reset() {
        fingers = [:]
        caption = ""
        copied = false
        snapped = false
    }
}

private struct DemoBackdropView: View {
    let model: DemoBackdropModel

    private static let padSize = CGSize(width: 228, height: 160)
    private static let barHeight: CGFloat = 26
    private static let stripHeight: CGFloat = 196
    private static let margin: CGFloat = 40
    // 品牌渐变（docs/brand.md）
    private static let amber = Color(red: 1, green: 0.76, blue: 0.48)
    private static let violet = Color(red: 0.6, green: 0.3, blue: 1)

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                wallpaper
                menuBar
                window(in: geo.size)
                HStack(alignment: .center) {
                    Text(model.caption)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    trackpad
                }
                .padding(.horizontal, Self.margin)
                .frame(width: geo.size.width, height: Self.stripHeight)
                .offset(y: geo.size.height - Self.stripHeight)
            }
        }
        .ignoresSafeArea()
    }

    private var wallpaper: some View {
        ZStack {
            Color(red: 0.05, green: 0.04, blue: 0.09)
            RadialGradient(colors: [Self.violet.opacity(0.55), .clear], center: UnitPoint(x: 0.82, y: 0.12), startRadius: 0, endRadius: 760)
            RadialGradient(colors: [Self.amber.opacity(0.32), .clear], center: UnitPoint(x: 0.08, y: 0.92), startRadius: 0, endRadius: 620)
        }
    }

    private var menuBar: some View {
        HStack(spacing: 16) {
            Image(nsImage: BrandMark.menuBarImage(description: "TouchOS"))
                .renderingMode(.template)
            Spacer()
            Text("9:41").font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 16)
        .frame(height: Self.barHeight)
        .background(.black.opacity(0.28))
    }

    /// 示例窗口：全屏可用区域内居中，或贴到右半屏
    private func window(in size: CGSize) -> some View {
        let area = CGRect(x: Self.margin, y: Self.barHeight + 24, width: size.width - 2 * Self.margin,
                          height: size.height - Self.barHeight - 24 - Self.stripHeight)
        let width = model.snapped ? area.width / 2 : area.width
        return windowContent
            .frame(width: width, height: area.height)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.13, green: 0.13, blue: 0.16)))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
            .offset(x: area.maxX - width, y: area.minY)
            .offset(x: model.snapped ? 0 : -(area.width - width) / 2)
    }

    private var windowContent: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Circle().fill(Color(red: 1, green: 0.37, blue: 0.34))
                    Circle().fill(Color(red: 1, green: 0.74, blue: 0.18))
                    Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.25))
                }
                .frame(width: 60, height: 12)
                .padding(.bottom, 14)
                ForEach(Array([0.8, 0.55, 0.7, 0.45, 0.62].enumerated()), id: \.offset) { i, w in
                    GeometryReader { p in
                        RoundedRectangle(cornerRadius: 4).fill(.white.opacity(i == 1 ? 0.4 : 0.14)).frame(width: p.size.width * w, height: 9)
                    }
                    .frame(height: 9)
                }
                Spacer()
            }
            .padding(18)
            .frame(width: 180)
            .background(.white.opacity(0.04))
            VStack(alignment: .leading, spacing: 16) {
                RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.55)).frame(width: 240, height: 16).padding(.bottom, 10)
                ForEach(Array([0.94, 0.86, 0.9, 0.62, 0.92, 0.78, 0.88, 0.5].enumerated()), id: \.offset) { i, w in
                    GeometryReader { p in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(i == 3 ? AnyShapeStyle(LinearGradient(colors: [Self.amber, Self.violet], startPoint: .leading, endPoint: .trailing))
                                         : AnyShapeStyle(.white.opacity(0.13)))
                            .frame(width: p.size.width * w, height: 10)
                    }
                    .frame(height: 10)
                }
                Spacer()
            }
            .padding(30)
            .overlay(alignment: .topTrailing) {
                if model.copied {
                    Label(model.copiedText, systemImage: "checkmark")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(.white.opacity(0.16)))
                        .padding(26)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
        }
    }

    private var trackpad: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 18)
                .fill(LinearGradient(colors: [Color(red: 0.3, green: 0.3, blue: 0.34), Color(red: 0.19, green: 0.19, blue: 0.22)],
                                     startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.2))
            ForEach(model.fingers.keys.sorted(), id: \.self) { id in
                if let p = model.fingers[id] {
                    Circle()
                        .fill(RadialGradient(colors: [.white, Self.amber], center: .center, startRadius: 2, endRadius: 15))
                        .frame(width: 26, height: 26)
                        .shadow(color: Self.amber.opacity(0.8), radius: 12)
                        .position(x: p.x * Self.padSize.width, y: (1 - p.y) * Self.padSize.height)
                        .transition(.opacity.combined(with: .scale(scale: 1.5)))
                }
            }
        }
        .frame(width: Self.padSize.width, height: Self.padSize.height)
        .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
    }
}
