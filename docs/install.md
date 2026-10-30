# Install Nekro TouchOS

Requires macOS 14 or later and a Force Touch trackpad (built-in, or Magic Trackpad 2 or later).

1. Download the DMG: `TouchOS-<version>-macOS-arm64.dmg` for Apple silicon (M series), `TouchOS-<version>-macOS-x64.dmg` for Intel.
2. Open it and drag **TouchOS** into Applications.
3. TouchOS isn't notarized by Apple, so macOS blocks the first launch: open **System Settings → Privacy & Security** and click **Open Anyway** at the bottom.
4. Follow the welcome guide to allow **Accessibility**. TouchOS needs it to hold the cursor still while a panel is open and to send shortcuts.
5. Tap the trackpad with four fingers to open the panel. Settings are in the menu bar icon.

To update, download the new version and replace the app; your panels and permissions are kept. Settings live in `~/Library/Application Support/TouchOS/`.

**Early release:** tested only on a Magic Trackpad with macOS 27. Built-in trackpads, Intel Macs and macOS 14–26 have not been tested yet; please report problems in [Issues](https://github.com/NekroAI/touchos/issues).

---

# 安装 Nekro TouchOS

需要 macOS 14 及以上，以及力度触控板（内置，或妙控板第二代及以后）。

1. 下载安装包：Apple 芯片（M 系列）选 `TouchOS-<版本>-macOS-arm64.dmg`，Intel 芯片选 `TouchOS-<版本>-macOS-x64.dmg`。
2. 打开 DMG，把 **TouchOS** 拖进「应用程序」。
3. TouchOS 未经 Apple 公证，首次打开会被拦截：到 **系统设置 → 隐私与安全性**，在页面底部点 **仍要打开**。
4. 跟随引导授予「辅助功能」权限：面板打开时需要它让光标保持不动、发送快捷键。
5. 单指轻点一下、紧接着按住，面板出现；不松手滑到按钮上抬起即执行（四指轻点也可以）。设置在菜单栏图标中。建议在系统设置 › 触控板中关闭「轻点来点按」。

更新时下载新版本替换应用即可，面板与权限都会保留。配置位于 `~/Library/Application Support/TouchOS/`。

**早期版本：** 只在妙控板 + macOS 27 上测试过；内置触控板、Intel Mac、macOS 14–26 尚未测试，遇到问题请在 [Issues](https://github.com/NekroAI/touchos/issues) 反馈。
