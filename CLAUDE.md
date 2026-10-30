# Nekro TouchOS

macOS 菜单栏工具：在触控板上轻点后按住唤起浮层面板，手指在触控板上的位置绝对定位选择槽位，抬起即执行快捷动作。"看着选"替代"记手势"。开源（GPL-3.0-or-later），仓库 `NekroAI/touchos`，Bundle ID `ai.nekro.touchos`。工程与发布惯例对齐同组织的 `NekroAI/qantrip`（`../qantrip`）。

## 当前阶段

**0.1.5 已发布（2026-10-31，D52 默认隐藏光标并统一调试入口、D49 / D52 设备时钟重新对齐、D51 诊断日志；崩溃恢复与内置板时钟待实测；D47、D48 排查光标用；GitHub Releases 正式版，arm64 / x64 DMG，发布证书签名；仓库转公开由负责人操作；CI 的 Swift 6.3.3 对具体类型的 `Binding(get:set:)` 会编译崩溃，设置页一律用 `makeBinding`）：D23 产品形态（多面板、双指切换、捏合总览、按住关闭进入编辑、可切换主题）+ D25 轻点后按住（默认唤起方式）+ D26 唤起方式多选、各自绑定面板、触控板分区实时预览 + D27 动作发往指针下的窗口 + D28 浮层性能第一阶段 + D29 默认面板「常用」、拖动互换、滑杆实时生效与竖向、面板随网格伸缩 + D30 输入文字动作、数字键盘与符号面板 + D31 按钮判定区间隙 2.5 mm + D32 双指切换自然滚动（后面的面板排在下方）、刻度文字衬底 + D33 按住按钮连续触发 + D34 全息深色底板、液态光斑柔光选中 + D35 iCloud 同步配置 + D36 抬起防抖 100 ms + D37 空白处抬起即关闭、面板可停用 + D38 去掉锚指、八方位轻点后按住、第二下确认 120 ms、默认面板（常用 / 数字 / 媒体 / 环形窗口） + D39 面板外提示减轻 + D40 接入 iCloud 时选用哪一份 + D41 默认配置打磨（常用 / 窗口 / 媒体 / 数字，四指轻点开窗口，快捷键按钮显示按键组合，面板可设屏幕位置、数字居右，读不到值的滑杆不可用、亮度跟随唤起屏幕） + D42 全息环形面板正圆雷达表盘、默认立体滚筒、会话上限按活动续期 + D43 品牌标志「笔触」（规范见 `docs/brand.md`） + D44 更新提示 + D45 中英双语（`scripts/check-l10n.sh` 检查；首次启动先选语言） + D46 DMG 安装窗口 + K8 配置存储、K9 动作、K12 设置窗口与面板编辑器、K13 精简引导、K16 发布流程。未在本机实测：窗口摆放、媒体键、失败通知、登录项、引导页授权流程、内置板 / Intel / 旧系统。下一步（发布 0.1.0 前，负责人 2026-10-30 定）：① 打磨默认配置（D41 已完成，待负责人实际试用）；② 品牌化设计（图标、logo、菜单栏已完成 D43；DMG 背景与官网视觉待做）；③ 开源前准备（演示动图与文档已完成，发布与公开仓库待负责人决定）。其后：K10 视觉与性能收尾、K11 按应用面板、K14 模板、K15 无障碍。** 任务顺序与完成条件见 `docs/srs.md` 第 15 章。

- 构建：`scripts/build-macos.sh`（产物 `dist/TouchOS.app`，本机开发证书「TouchOS Dev」签名，重新构建不丢辅助功能授权）
- 测试：`swift test`；覆盖率闸门：`scripts/coverage.sh`（`TouchOSCore` 行覆盖率 ≥ 85%，NFR-15）
- 合成帧：测试中用 `Gesture`（`Tests/TouchOSCoreTests/Support/Gesture.swift`，FR-14.1）按时间与位置描述手势再采样成帧
- 演示动图：`notifyutil -p ai.nekro.touchos.simulate.demo`（中文 `demo.zh`），场景见 `Sources/TouchOS/Debug/DemoBackdrop.swift`；在 iPad 副屏录制，录制前先告知负责人
- CI：私有仓库 macOS 构建有额度限制。推送前先在本地跑 `scripts/coverage.sh` 与 `scripts/build-macos.sh`；提交攒到阶段节点再推送，不零散触发 CI
- 调试模式：通用设置最底下的开关（D52，等同 `defaults write ai.nekro.touchos showDebugOverlayMenu -bool true`），立即生效并显示调试叠层；指针诊断、诊断日志的清除 / 标记 / 复制、AC-17 都在叠层上（直接运行 `.build/release/TouchOS` 时 defaults 域为 `TouchOS`）
- 外观：菜单栏「外观」子菜单（主题、切换动画、强调色，D23），存在 UserDefaults `overlayTheme` / `overlayNav` / `overlayAccent`，下一次唤起生效
- 配置：`~/Library/Application Support/TouchOS/config.json`（schema v1，自动备份 5 份，D24）；开启 iCloud 同步后另有 iCloud 云盘「Nekro TouchOS/config.json」（D35）；唤起方式、常驻、背景压暗、主题等都在设置窗口（菜单栏「设置…」⌘,），原调试菜单开关与 UserDefaults 键已废弃
- 浮层预演（调试模式开启时）：`notifyutil -p ai.nekro.touchos.simulate.cancel`（另有 `taphold`（轻点后按住）、`idle`、`offset`（偏离中心轻点）、`reopen`（连续唤起与关闭）、`press`、`commit`、`outside`、`toggle`、`navigate`、`overview`、`hold`），只驱动浮层、不碰真实输入，配合 `screencapture -v -V 5 out.mov` 录屏逐帧检查视觉
- 发布：改 `VERSION` → 推送 `v<版本>` 标签，`release.yml` 构建 arm64 / x64 DMG 并发布（标签带 `-` 时为预发布版）；本地打包 `ARCH=x86_64 scripts/package-macos.sh`。发布证书「Nekro TouchOS Release」的 p12 在 `~/.touchos-release/`（`scripts/release-cert.sh` 一次性创建并写入 Actions Secrets），不得更换（D3）
- 性能：`scripts/perf.sh <预演脚本> [--profile]`（如 `navigate`、`reopen`；默认测卡顿与合成耗时，`--profile` 测主线程），基线数据见 decisions.md D28；脚本结束（含中断）时自动删除本次录制在 `$TMPDIR` 留下的约 6 GB `instruments*.ktrace`，不要直接调用 `xctrace record`
- 排查：`applicationDidFinishLaunching` 中的 ObjC 异常会被 AppKit 静默吞掉；启动"没反应"时用 lldb 在 `objc_exception_throw` 下断点。日志命令见 `docs/m0-report.md`
- 开发机：Mac mini M4 + macOS 27 + 蓝牙妙控板，没有内置触控板（D7）。内置板、双设备、macOS 14/15/26 相关验收不能在本机声称通过。

## 文档

| 文件 | 内容 |
|---|---|
| `docs/srs.md` | 开发需求规格，实现的唯一依据。需求编号 FR / NFR / AC / T / K / `P.` 参数均以此为准 |
| `docs/decisions.md` | 已做决定（D 编号，含对 SRS 的修订）、待决事项、未验证假设 |
| `docs/research.md` | 背景：竞品、术语、可行性与可用性风险 |
| `docs/m0-report.md` | M0 实测数据与验收结果 |

开始任何设计或实现工作前，先读 `docs/decisions.md`，SRS 中带"（修订：见 decisions.md Dn）"标记的条目以对应决定为准。

## 工作规则（摘自 SRS 第 15 章）

- 每个任务开始前复述引用的需求编号与完成条件；结束时逐条说明如何满足，并更新本文件的"当前阶段"。
- 规格有歧义或无法实现时停下，在代码中留 `// SPEC-QUESTION:` 注释并在任务总结中列出，同时记入 `decisions.md` 待决事项；不得自行发明行为。
- 阈值一律从配置读取，禁止字面量魔法数（SRS 0.3）；参数默认值见 SRS 附录。
- 零第三方依赖（D5）。
- 私有 API 的每个调用点注释符号来源与失败时的降级路径。
- 实测结果写入 `docs/m0-report.md`；推翻规格的发现写入 `docs/decisions.md`。

## 关键约束速览

- 激活态之外绝不改变系统输入行为；任何异常都以恢复系统默认行为收场（NFR-7）。光标冻结靠丢弃事件、校正加激活态隐藏光标（D52，可在通用设置改为保持显示）；隐藏后所有退出路径都必须恢复，由看门狗兜底。不用「断开鼠标与光标关联」接口（后台调用无效）。
- `TouchOSCore` 不得引用 AppKit、CoreGraphics 事件或私有框架类型（FR-3.2），用合成帧做确定性测试。
- 私有框架 MultitouchSupport 只能运行时 `dlopen` / `dlsym`，禁止编译期链接（SRS 2.1）。
- 不记录、不上传任何触点坐标或轨迹（FR-4.7、NFR-10）。
- Swift 6 语言模式 + 严格并发，零编译警告（D6、NFR-15）。
- 不使用 Developer ID：开发与发布各用一张固定的自签名证书，不得更换（D3）。
