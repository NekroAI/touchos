import AppKit

// 菜单栏应用（LSUIElement），无 Dock 图标（SRS 2.1）
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
