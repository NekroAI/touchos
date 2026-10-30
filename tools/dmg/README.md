# DMG 安装窗口

决定见 `docs/decisions.md` D46。`scripts/package-macos.sh` 把 `Resources/dmg/` 下的内容放进 DMG。

- `Resources/dmg/.background/background.tiff`：背景（1x + 2x），由 `render-background.swift` 生成后用 `tiffutil -cathidpicheck` 合并。
- `Resources/dmg/DS_Store`：窗口大小、图标位置与背景引用，由 `make-ds-store.sh` 生成：挂载一个卷名相同的临时磁盘映像，让访达排好后取出。卷名或背景图文件名变了要重新生成。
