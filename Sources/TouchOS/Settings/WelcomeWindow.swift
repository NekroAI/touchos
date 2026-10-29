import AppKit
import ApplicationServices
import Combine
import SwiftUI

/// 首次启动引导（K13、SRS 12.2）：辅助功能授权与基本手势。首次启动或缺少权限时显示
@MainActor
final class WelcomeWindowController {
    private var window: NSWindow?
    var onOpenSettings: (() -> Void)?

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let view = WelcomeView(openSettings: { [weak self] in self?.onOpenSettings?() },
                               close: { [weak self] in self?.window?.close() })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "欢迎使用 TouchOS"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

private struct WelcomeView: View {
    let openSettings: () -> Void
    let close: () -> Void
    @State private var trusted = AXIsProcessTrusted()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "hand.point.up.left.fill").font(.system(size: 40)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nekro TouchOS").font(.title.weight(.semibold))
                    Text("看着选，不用记手势。").foregroundStyle(.secondary)
                }
            }
            Step(number: 1, title: "允许辅助功能", done: trusted) {
                Text("TouchOS 需要辅助功能权限来暂停光标、发送快捷键。触点只在内存中处理，从不记录或上传。")
                if !trusted {
                    Button("打开系统设置") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }
            Step(number: 2, title: "四指轻点触控板", done: false) {
                Text("面板出现在屏幕中央。手指在触控板上的位置直接对应面板上的按钮：移到想要的按钮上，抬起即执行。")
                Text("按下（物理按压）也会执行，面板保留，可以连按。移到面板外抬起则取消。")
            }
            Step(number: 3, title: "切换与编辑", done: false) {
                Text("双指上下滑动切换面板，双指捏合查看全部面板。")
                Text("在正中的关闭按钮上按住，圆环充满后进入编辑。")
            }
            HStack {
                Button("打开设置…", action: openSettings)
                Spacer()
                Button("开始使用", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 520)
        .onReceive(timer) { _ in trusted = AXIsProcessTrusted() }
    }
}

private struct Step<Content: View>: View {
    let number: Int
    let title: String
    let done: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Color.accentColor).frame(width: 24, height: 24)
                if done {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.callout.weight(.semibold)).foregroundStyle(.white)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                content.font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
