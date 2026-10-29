# 决策记录

记录已做决定、待决事项和未验证假设。`srs.md` 写"做什么"，本文写"为什么"；本文对 SRS 的修订已在 SRS 对应位置加了"（修订：见 decisions.md Dn）"标记。

---

## 背景

- 2026-10-28 形成 `research.md`（竞品调研、可行性与需求细化）与 `srs.md`（开发需求规格）。
- 2026-10-29 项目定为 NekroAI 组织下的开源项目，工程、签名、发布与文档惯例对齐同组织的 [`NekroAI/qantrip`](https://github.com/NekroAI/qantrip)。
- 当前阶段：**M0 技术原型**，任务 K1 起步。

---

## 已做决定

### D1 归属与命名（2026-10-29）

- **仓库：** `NekroAI/touchos`；**Bundle ID：** `ai.nekro.touchos`；**显示名：** Nekro TouchOS。
- 统一日志子系统同样使用 `ai.nekro.touchos`（修订 SRS NFR-11 的 `app.touchos`，与 Bundle ID 保持一致）。
- 产品名仍按 SRS 0.1 暂定，正式名确定后统一替换（见待决事项 1）。

### D2 开源许可证：GPL-3.0-or-later（2026-10-29）

- 修订 SRS 2.1 的"MIT（待确认）"。与 qantrip 客户端一致，防止被闭源分发。
- 社区贡献的面板模板随项目以同一许可证发布。

### D3 签名：不使用 Developer ID，开发与发布各用一张固定的自签名证书（2026-10-29）

- 修订 SRS 2.1 的"Developer ID + Hardened Runtime + 公证"。
- **开发期：** 本机自签名证书「TouchOS Dev」，放在独立钥匙串 `touchos-dev.keychain-db`，由 `scripts/dev-cert.sh` 创建。目的：重新构建后签名身份不变，辅助功能授权不失效（对事件拦截的调试至关重要）。
- **发布：** 自签名证书「Nekro TouchOS Release」，p12 存入仓库 Actions Secrets，做法同 qantrip D22；在 K16 创建。
- 不公证，安装说明如实写"首次打开到 隐私与安全性 点 仍要打开"。Hardened Runtime 在没有公证时没有实际收益，暂不开启。
- 将来改用 Developer ID 时，用户需要重新授权一次辅助功能。

### D4 分发：GitHub Releases 上的 DMG（2026-10-29）

- 修订 SRS 2.1 与 K16 的"GitHub Releases 与 Homebrew Cask"。未公证应用经 Cask 安装体验差，不做 Cask。
- 推送 `v*` 标签 → GitHub Actions 分别构建 arm64 与 x86_64、签名、打 DMG、发布；文件名 `TouchOS-<版本>-macOS-<arm64|x64>.dmg`（同 qantrip D38）。
- 根目录 `VERSION` 为版本号，构建号取 git 提交数。

### D5 更新：只提示新版本，不引入 Sparkle（2026-10-29）

- 修订 SRS 2.1 的"Sparkle 2"。改为读取 GitHub Releases 最新正式版本并在菜单栏提示（可复用 qantrip 的 `UpdateChecker`）。
- 结果：**v1 零第三方依赖**。将来需要自动安装时再评估 Sparkle（它不要求 Developer ID）。
- NFR-10 中"Sparkle 更新检查除外，可关闭"相应理解为"更新检查除外，可关闭"。

### D6 构建：根目录单一 SwiftPM 包 + 构建脚本，不建 Xcode 工程（2026-10-29）

- 修订 SRS 2.1 的"Xcode 16 及以上"与 2.2 的目录结构。只需命令行工具即可构建；需要 Instruments 或 SwiftUI 预览时用 Xcode 打开 `Package.swift`。
- `scripts/build-macos.sh` 负责编译、组装 `.app`、签名（同 qantrip）。
- 目录映射：SRS 2.2 的 `Packages/TouchOSCore/` → `Sources/TouchOSCore/`；`App/`、`Input/`、`EventControl/`、`Overlay/`、`Actions/`、`Settings/`、`Onboarding/` → `Sources/TouchOS/` 下同名子目录；`Tests/` 保持在根目录（SwiftPM 要求测试在包内）；`Resources/Templates/` 不变。
- 保持 SRS 要求的 Swift 6 语言模式与严格并发检查（qantrip 用 Swift 5 模式，此处不对齐）。CI 以 `-warnings-as-errors` 构建。

### D7 测试矩阵加入 macOS 27；M0 闸门先以 macOS 27 为准（2026-10-29）

- 修订 SRS 1.5、14.3 与 M0 闸门。开发机为 Mac mini M4 + macOS 27.2，只有一块蓝牙妙控板，没有内置触控板。
- M0 闸门在 macOS 27 + 妙控板上通过即可进入 M1；macOS 14/15/26、内置触控板、双设备（AC-13 等）在取得相应硬件后补测，结果记入 `m0-report.md`，M1 发布闸门前必须补齐。
- 2026-10-29 已确认：macOS 27.2 上 MultitouchSupport 可 `dlopen`，FR-4.1 的必需与可选符号全部存在，`MTDeviceCreateList` 能枚举到妙控板。

### D8 SRS 内部不一致的处理（2026-10-29）

- 预置模板数量：1.4 写 3 套，FR-11.11 / K14 写 4 套 → 以 **4 套** 为准。
- 静止阈值参数名：T2 写 `P.stillThreshold`，FR-6.1 与附录写 `P.stillThresholdMM` → 以 **`P.stillThresholdMM`**（毫米）为准。

---

## 待决事项

1. 正式产品名（替换 TouchOS 暂定名）。
2. 应用图标与菜单栏图标。
3. Intel Mac 实机测试来源（开发机未装 Rosetta，x86_64 版本只能在 CI 构建）。
4. SPEC-QUESTION（FR-4.2）：状态码为"接触中"、但此前没有该接触记录（例如注册回调时手指已在板上）时如何映射。当前按字面理解为 `stationary`，该接触没有 `began`，不会成为锚指或指点指。见 `ContactTracker`。
5. SPEC-QUESTION（FR-4.1）：尺寸接口缺失时要求查"型号默认尺寸表"，但此时也拿不到型号。当前只用妙控板实测尺寸一个默认值。见 `MultitouchBridge.fallbackSurfaceMM`。

---

## 未验证的假设（M0 期间实测，结果记入 `m0-report.md`）

| 假设 | 出处 | 验证方式 |
|---|---|---|
| 内置板与妙控板持续触摸时帧率足够（目标约 90 Hz） | SRS 附录、research 技术事实 3 | 调试工具记录帧间隔 |
| 端到端延迟 p95 ≤ 25 ms | NFR-1 | 调试叠层记录帧与渲染时间戳 |
| 后台丢弃指针移动能完全冻结光标 | FR-7.6、FR-7.7 | AC-2、AC-9 |
| 双指状态下没有系统行为漏出拦截 | SRS 7.3 | AC-9 |
| 右边缘双指左滑不会误触发通知中心 | SRS 7.3 | 手工测试 |
| 后台应用调用触觉反馈有效 | FR-6.14 | 妙控板实测 |
| 与 BetterTouchTool 共存时的拦截顺序 | research 风险表 | 手工测试 |
| 可修改的 HID 事件拦截只需辅助功能权限即可收到 Esc 键，不需要输入监控 | FR-12.1、7.2 | 只授予辅助功能后测试 T16 |
| 用固定自签名证书签名后，重新构建/更新不丢失辅助功能授权 | D3 | 授权 → 重新构建 → 检查授权 |
| 各参数默认值合适 | SRS 附录 | M0 闸门时按实测修正并回写 SRS 附录 |
