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
        // 从触控板手势打开时本应用不在前台，系统可以拒绝激活（macOS 14 起为协作式激活），
        // 只 makeKeyAndOrderFront 窗口会落在当前应用后面；orderFrontRegardless 保证它出现在最前
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
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
    /// 系统「轻点来点按」开着时多出一步（D41）：轻点后按住的第一下会先点一次鼠标。关掉后这一步打勾，不消失
    @State private var tapToClick = TapToClick.isOn
    @State private var showsTapStep = TapToClick.isOn
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
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
            if showsTapStep {
                Step(number: 2, title: "关闭系统的「轻点来点按」", done: !tapToClick) {
                    Text("TouchOS 用「轻点一下，紧接着按住」唤起面板。系统的「轻点来点按」开着时，第一下轻点会先在光标处点一次鼠标，可能点到不该点的东西。")
                    Text("关掉后改用按压来点按。关掉之前，可以先用四指轻点打开面板。")
                    if tapToClick {
                        Button("打开触控板设置") { NSWorkspace.shared.open(TapToClick.settingsURL) }
                    }
                }
            }
            Step(number: showsTapStep ? 3 : 2, title: "轻点一下，紧接着按住", done: false) {
                Text("第二下按住片刻，面板就出现在屏幕中央。不松手，手指在触控板上的位置直接对应面板上的按钮：滑到想要的按钮上，抬起即执行。")
                Text("按下（物理按压）也会执行，面板保留，可以连按。在按钮之间、空格或面板外抬起则关闭。四指轻点打开「窗口」面板，唤起方式可在设置里增减。")
            }
            Step(number: showsTapStep ? 4 : 3, title: "切换与编辑", done: false) {
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
        .onReceive(timer) { _ in
            trusted = AXIsProcessTrusted()
            tapToClick = TapToClick.isOn
        }
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
