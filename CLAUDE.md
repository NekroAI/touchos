# Nekro TouchOS

macOS 菜单栏工具：一指按住触控板角落唤起浮层面板，另一指在触控板上绝对定位选择槽位，抬起即执行快捷动作。"看着选"替代"记手势"。开源（GPL-3.0-or-later），仓库 `NekroAI/touchos`，Bundle ID `ai.nekro.touchos`。工程与发布惯例对齐同组织的 `NekroAI/qantrip`（`../qantrip`）。

## 当前阶段

**M0 的 K1–K7 已实现，交互实验（D12–D22）已收敛为 D23 的产品形态：多面板（预置浏览器 / 媒体 / 窗口 / 编辑四个）+ 唤起方式绑定面板、双指上下切换（弹簧跟手）、捏合总览、正中关闭按住进入编辑、可切换主题（玻璃圆钮默认，液态光斑 / 全息线框可选）+ 强调色 + 切换动画（深度堆叠 / 立体滚筒）。核心与浮层已完成；下一步 K8 配置存储与编辑器，然后 K9 动作、K13 引导、K16 发布 0.0.1。** 任务顺序与完成条件见 `docs/srs.md` 第 15 章；M0 闸门不通过，不开始 M1 的界面类任务。

- 构建：`scripts/build-macos.sh`（产物 `dist/TouchOS.app`，本机开发证书「TouchOS Dev」签名，重新构建不丢辅助功能授权）
- 测试：`swift test`；覆盖率闸门：`scripts/coverage.sh`（`TouchOSCore` 行覆盖率 ≥ 85%，NFR-15）
- 合成帧：测试中用 `Gesture`（`Tests/TouchOSCoreTests/Support/Gesture.swift`，FR-14.1）按时间与位置描述手势再采样成帧
- CI：私有仓库 macOS 构建有额度限制。推送前先在本地跑 `scripts/coverage.sh` 与 `scripts/build-macos.sh`；提交攒到阶段节点再推送，不零散触发 CI
- 调试叠层：发布构建中执行 `defaults write ai.nekro.touchos showDebugOverlayMenu -bool true` 后，菜单栏出现"调试叠层"（直接运行 `.build/release/TouchOS` 时 defaults 域为 `TouchOS`）
- 外观：菜单栏「外观」子菜单（主题、切换动画、强调色，D23），存在 UserDefaults `overlayTheme` / `overlayNav` / `overlayAccent`，下一次唤起生效
- 实验开关：调试菜单「常驻模式」（D14）、「背景压暗」（D20）、「唤起：…」四项（D19，默认只开四指轻点）
- 浮层预演（调试叠层可用时）：`notifyutil -p ai.nekro.touchos.simulate.cancel`（另有 `idle`、`press`、`commit`、`outside`、`toggle`、`navigate`、`overview`、`hold`），只驱动浮层、不碰真实输入，配合 `screencapture -v -V 5 out.mov` 录屏逐帧检查视觉
- 临时调节（K12 设置界面之前）：调试菜单「面板大小」「映射区大小」，或 `defaults write ai.nekro.touchos mappingScale -float 0.5`（`panelScale` 同理，D21），下一次唤起生效
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

- 激活态之外绝不改变系统输入行为；任何异常都以恢复系统默认行为收场（NFR-7）。光标冻结只靠丢弃事件加校正实现，不用"断开鼠标与光标关联"接口。
- `TouchOSCore` 不得引用 AppKit、CoreGraphics 事件或私有框架类型（FR-3.2），用合成帧做确定性测试。
- 私有框架 MultitouchSupport 只能运行时 `dlopen` / `dlsym`，禁止编译期链接（SRS 2.1）。
- 不记录、不上传任何触点坐标或轨迹（FR-4.7、NFR-10）。
- Swift 6 语言模式 + 严格并发，零编译警告（D6、NFR-15）。
- 不使用 Developer ID：开发与发布各用一张固定的自签名证书，不得更换（D3）。
