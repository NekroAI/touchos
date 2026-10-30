import AppKit
import SwiftUI

/// 界面语言（D45，NFR-12）：默认跟随系统，也可以固定为其中一种。语言在进程启动时定下，改动后要重启应用才生效；
/// 选择只存在本机（系统的 `AppleLanguages` 应用级覆盖），不进配置文件，也就不随 iCloud 同步
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, zhHans = "zh-Hans", en

    var id: String { rawValue }

    /// 语言自己的名字，不翻译
    var nativeName: String {
        switch self {
        case .system: String(localized: "跟随系统")
        case .zhHans: "简体中文"  // l10n-ignore
        case .en: "English"
        }
    }

    private static let overrideKey = "AppleLanguages"

    /// 设置里当前选中的一项。读应用自己的域，`UserDefaults.standard` 会带上系统全局的值
    static var selected: AppLanguage {
        let domain = Bundle.main.bundleIdentifier.flatMap(UserDefaults.standard.persistentDomain(forName:))
        let pinned = (domain?[overrideKey] as? [String])?.first
        return allCases.first { $0.rawValue == pinned } ?? .system
    }

    static func select(_ language: AppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: overrideKey)
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: overrideKey)
        }
    }

    /// 这个进程正在使用的语言
    static var running: AppLanguage {
        Bundle.main.preferredLocalizations.first == zhHans.rawValue ? .zhHans : .en
    }

    /// 系统语言对应的选项：中文系统选简体中文，其余选英文
    static var systemDefault: AppLanguage {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true ? .zhHans : .en
    }

    /// 起一个新进程后退出当前进程
    @MainActor
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// 首次启动选语言（D45）：在写入配置之前显示，因为预置面板的名字按此时的语言写入配置。
/// 默认选中系统语言；选的语言与当前进程不同时重启应用，用新语言继续首次启动
@MainActor
final class LanguagePickerController {
    /// 重启后跳过这一步（配置文件那时还不存在）
    private static let answeredKey = "languagePickerAnswered"
    private var window: NSWindow?

    /// 这次启动要不要询问。读取一次"已回答"标记即清除：之后删掉配置（恢复默认）还会再问
    static func shouldAsk(isFirstLaunch: Bool) -> Bool {
        let answered = UserDefaults.standard.bool(forKey: answeredKey)
        UserDefaults.standard.removeObject(forKey: answeredKey)
        return isFirstLaunch && !answered
    }

    func show(onContinue: @escaping () -> Void) {
        let view = LanguagePickerView { [weak self] language in
            self?.window?.close()
            self?.window = nil
            guard language != AppLanguage.running else {
                onContinue()
                return
            }
            AppLanguage.select(language)
            UserDefaults.standard.set(true, forKey: Self.answeredKey)
            AppLanguage.relaunch()
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Nekro TouchOS"
        window.styleMask = [.titled, .fullSizeContentView]  // 没有关闭按钮：这一步必须有结果才能往下走
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

private struct LanguagePickerView: View {
    let choose: (AppLanguage) -> Void
    @State private var language = AppLanguage.systemDefault

    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            Text(verbatim: "选择语言 / Choose Language")  // l10n-ignore.font(.title3.weight(.semibold))
            Picker(selection: $language) {
                Text(verbatim: AppLanguage.zhHans.nativeName).tag(AppLanguage.zhHans)
                Text(verbatim: AppLanguage.en.nativeName).tag(AppLanguage.en)
            } label: {
                EmptyView()
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Button {
                choose(language)
            } label: {
                Text(verbatim: language == .zhHans ? "继续" : "Continue").frame(minWidth: 120)  // l10n-ignore
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(width: 340)
    }
}
