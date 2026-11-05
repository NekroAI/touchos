import Foundation
import Testing
@testable import TouchOSCore

// D59：剪贴板内容的判定与 {clipboard} 占位

@Suite struct ActionInputTests {
    private let search = "https://www.google.com/search?q={clipboard}"

    private func target(_ text: String?, files: [URL] = [], search: String? = nil, exists: Set<String> = []) -> OpenTarget? {
        ClipboardSnapshot(fileURLs: files, text: text).openTarget(searchURL: search, fileExists: { exists.contains($0) })
    }

    @Test func copiedFilesComeFirst() {
        let file = URL(fileURLWithPath: "/tmp/a.txt")
        #expect(target("a.txt", files: [file]) == .files([file]))
    }

    @Test func linksOpenAsURLs() {
        #expect(target("  https://example.com/a?b=1\n") == .url(URL(string: "https://example.com/a?b=1")!))
        #expect(target("www.example.com") == .url(URL(string: "https://www.example.com")!))
        #expect(target("mailto:a@example.com") == .url(URL(string: "mailto:a@example.com")!))
        #expect(target("obsidian://open?vault=x") == .url(URL(string: "obsidian://open?vault=x")!))
    }

    @Test func pathsMustExist() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(target("/Users/x/a.pdf", exists: ["/Users/x/a.pdf"]) == .files([URL(fileURLWithPath: "/Users/x/a.pdf")]))
        #expect(target("~/Downloads", exists: [home + "/Downloads"]) == .files([URL(fileURLWithPath: home + "/Downloads")]))
        #expect(target("file:///Users/x/a.pdf", exists: ["/Users/x/a.pdf"]) == .files([URL(fileURLWithPath: "/Users/x/a.pdf")]))
        #expect(target("/Users/x/missing.pdf") == nil)
        #expect(target("file:///Users/x/missing.pdf") == nil)
    }

    @Test func otherTextUsesSearchOrFails() {
        #expect(target("hello world") == nil)
        #expect(target("note:abc") == nil)
        #expect(target("a.txt") == nil)
        #expect(target("hello world & more", search: search) == .url(URL(string: "https://www.google.com/search?q=hello%20world%20%26%20more")!))
        #expect(target("two\nlines /tmp", search: search) == .url(URL(string: "https://www.google.com/search?q=two%0Alines%20%2Ftmp")!))
        #expect(target("hello", search: "not a link {clipboard}") == nil)
        #expect(target(nil, search: search) == nil)
        #expect(target("   ", search: search) == nil)
    }

    @Test func snapshotTextAndEmptiness() {
        #expect(ClipboardSnapshot().isEmpty && ClipboardSnapshot(text: " \n").isEmpty && !ClipboardSnapshot(text: "a").isEmpty)
        let files = [URL(fileURLWithPath: "/a b"), URL(fileURLWithPath: "/c")]
        #expect(ClipboardSnapshot(fileURLs: files, text: "a b").plainText == "/a b\n/c")
        #expect(ClipboardSnapshot(text: "x").plainText == "x" && ClipboardSnapshot().plainText == "")
    }

    @Test func placeholderFillsEncodedOrRaw() {
        #expect(Placeholder.fill("{clipboard}", with: "https://a.com/?x=1") == "https://a.com/?x=1")
        #expect(Placeholder.fill("https://s.com/?q={clipboard}", with: "a+b=c#d") == "https://s.com/?q=a%2Bb%3Dc%23d")
        let normalized = URL(string: "https://s.com/?q={clipboard}")!.absoluteString
        #expect(Placeholder.contains(normalized) && Placeholder.display(normalized) == "https://s.com/?q={clipboard}")
        #expect(Placeholder.fill(normalized, with: "中文") == "https://s.com/?q=%E4%B8%AD%E6%96%87")
        #expect(!Placeholder.contains("https://s.com/"))
    }

    @Test func actionsReadClipboardOnlyWhenTheyUseIt() {
        let ask = URL(string: "https://s.com/?q={clipboard}")!
        #expect(Action.openWith(bundleID: "a", input: .clipboard, searchURL: nil).input == .clipboard)
        #expect(Action.openURL(url: ask, browserBundleID: nil).input == .clipboard)
        #expect(Action.openURL(url: URL(string: "https://s.com")!, browserBundleID: nil).input == nil)
        #expect(Action.shell(command: "open \"$TOUCHOS_CLIPBOARD\"", timeoutSec: 1, notifyOutput: false).input == .clipboard)
        #expect(Action.shell(command: "echo hi", timeoutSec: 1, notifyOutput: false).input == nil)
        #expect(Action.appleScript(source: "system attribute \"TOUCHOS_CLIPBOARD\"", language: .appleScript).input == .clipboard)
        #expect(Action.appleScript(source: "beep", language: .appleScript).input == nil)
        #expect(Action.textSnippet("x").input == nil)
    }

    @Test func appBundleIDAndFlags() {
        let openWith = Action.openWith(bundleID: "b", input: .clipboard, searchURL: nil)
        #expect(Action.openApp(bundleID: "a").appBundleID == "a" && openWith.appBundleID == "b")
        #expect(Action.openURL(url: URL(string: "https://s.com")!, browserBundleID: "c").appBundleID == nil)
        #expect(!openWith.repeatsWhileHeld && !openWith.runsCode && openWith.typeName == "openWith")
    }

    @Test func ringKeepsAppIcon() {
        let item = Slot(id: "f", shape: .rect(.zero), title: "F", symbol: "globe", appIcon: "org.mozilla.firefox", action: .none)
        let center = Slot(id: "c", shape: .rect(.zero), title: "C", symbol: "xmark", appIcon: "x", action: .none)
        let ring = Layout.ring(id: "r", name: "R", items: [item], center: center)
        #expect(ring.slot("f")?.appIcon == "org.mozilla.firefox" && ring.slot("c")?.appIcon == "x")
    }
}
