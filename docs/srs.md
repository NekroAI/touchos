# 开发需求规格（SRS）

Oct 28, 2026 · @Aurnxt

本规格可直接交给 AI 开发代理按章节实现；竞品调研、可行性论证与决策依据见 `research.md`；对本规格的后续修订及理由见 `decisions.md`。

## 0. 文档约定

**本规格是实现的唯一依据：与背景调研页冲突时以本页为准；本页未写明的行为，实现方不得自行扩展，应记为待决问题。**

### 0.1 读者与使用方式

- 读者是 AI 开发代理及审阅它的人类开发者。
- 按第 15 章的任务顺序逐项实现；每个任务完成时，必须满足该任务引用的需求编号及第 14 章对应的验收标准。
- 项目名暂定为 **TouchOS**，用于工程名、Bundle ID 前缀和代码命名空间，正式名称确定后统一替换。（修订：仓库 `NekroAI/touchos`、Bundle ID `ai.nekro.touchos`，见 decisions.md D1）

### 0.2 需求等级

| 关键词 | 含义 |
| --- | --- |
| 必须（MUST） | 不满足即视为未完成 |
| 应当（SHOULD） | 默认实现；如有充分理由可不做，但须在代码注释与提交说明中写明原因 |
| 可以（MAY） | 可选，列入后续版本 |

### 0.3 编号规则

- 功能需求：`FR-<章号>.<序号>`，例如 `FR-6.3`。
- 非功能需求：`NFR-<序号>`。
- 验收用例：`AC-<序号>`，每条写明对应的需求编号。
- 可调参数：`P.<名称>`，默认值以附录参数总表为准，代码中所有阈值必须从配置读取，禁止硬编码魔法数。

### 0.4 术语

| 术语 | 代码命名 | 定义 |
| --- | --- | --- |
| 锚指 | `anchorTouch` | 在锚定区落下并满足驻留条件、持续按住以维持激活态的手指 |
| 指点指 | `pointerTouch` | 激活态下第一根落在映射区的新手指，用于选择槽位 |
| 锚定区 | `anchorZone` | 允许锚定手势发生的触控板区域（归一化坐标矩形） |
| 映射区 | `mappingZone` | 触控板去掉四周边距后的矩形，与面板线性绝对映射（修订：居中、占触控板 `P.mappingScale` 比例的矩形，区外坐标钳制到面板边缘，见 decisions.md D9；区外不再命中，抬起即关闭，见 D21） |
| 激活态 | `Active` | 锚指保持期间的准模式；锚指抬起即结束 |
| 浮层面板 | `OverlayPanel` | 激活态下显示的不抢焦点悬浮窗口 |
| 面板布局 | `Layout` | 一组槽位及其几何位置 |
| 槽位 | `Slot` | 面板上的一个可选区域，绑定一个动作 |
| 安全区 | `NullSlot` | 在此提交不执行任何动作 |
| 动作 | `Action` | 槽位绑定的可执行内容 |
| 提交 | `commit` | 确认选择并执行动作 |
| 取消 | `cancel` | 结束激活态且不执行动作 |
| 设备 | `TrackpadDevice` | 一块物理触控板（内置或外接妙控板） |

### 0.5 坐标系约定

- **触控板坐标**：归一化，x 与 y 均在 0–1，原点在左下角，y 向上（与私有框架一致）。
- **面板坐标**：单位点（pt），原点在面板左上角，y 向下（与 SwiftUI 一致）。
- **屏幕坐标**：使用 AppKit 全局坐标；与 Quartz 坐标转换时必须经过统一的工具函数，禁止在业务代码里手写翻转。

## 1. 产品概述与范围（修订：见 decisions.md D25、D38，唤起改为轻点后按住，不再有锚指）

**TouchOS 是一款免费开源的 macOS 菜单栏工具：用户用一根手指按住触控板角落唤起浮层面板，另一根手指在触控板上绝对定位选择槽位，抬起即执行快捷动作。**

### 1.1 目标

- 用"看着选"替代"记手势"：用户只需记住一个锚定手势。
- 零干扰：激活态之外，不改变任何触控板、鼠标、键盘的系统行为。
- 低冲突：只占用一个角落；激活态内屏蔽所有双指衍生事件。
- 可定制：面板布局、槽位动作、按应用切换面板均可配置。

### 1.2 主循环

1. 用户正常使用触控板，TouchOS 只旁听原始触点。
2. 用户一指（通常是拇指）按住锚定区并静止驻留，进入激活态：光标冻结，浮层面板出现。
3. 用户另一指在映射区移动，面板实时显示指示点与高亮槽位。
4. 指点指在某槽位抬起，执行该槽位动作；在安全区抬起不执行。
5. 锚指抬起，激活态结束，一切恢复原状。

### 1.3 非目标（v1 不做，实现方不得自行加入）

- 鼠标手势、键盘快捷键触发、绘图手势。
- 窗口吸附、剪贴板管理、情景模式等 BetterAndBetter 其他模块。
- 三指及以上的任何手势识别。
- 云同步、账号体系、遥测统计。
- Mac App Store 版本。

### 1.4 版本划分

| 版本 | 目标 | 包含 |
| --- | --- | --- |
| M0 技术原型 | 证明关键技术可行 | 触点读取、状态机、事件拦截、光标冻结、最简浮层（固定 3×3 网格，动作写死）、调试叠层 |
| M1 MVP | 可日常使用的首个公开版 | 网格布局编辑器、全局面板 + 按应用面板、动作类型：快捷键 / 打开应用 / 打开 URL / Shell / AppleScript / 快捷指令 / 系统控制、抬起提交、安全区、连续触发、触觉反馈、多设备、引导、3 套预置模板（修订：4 套，见 decisions.md D8）、JSON 导入导出 |
| M2 | 增强 | 按压提交、自由矩形布局、宏、文本片段、窗口管理、浏览器专用动作、子面板 |

本规格完整描述 M0 与 M1；标注"M2"的条目仅作接口预留，M1 阶段不实现。

### 1.5 运行环境

- 支持：Apple Silicon 与 Intel Mac；内置力度触控板、妙控板（第二代及以后）。
- 最低系统 macOS 14（Sonoma）；必须在 macOS 14、15、26 上通过验收。（修订：加入 macOS 27，M0 闸门先以 macOS 27 为准，见 decisions.md D7）
- 不支持：妙控鼠标、第三方触控板、通过远程桌面的输入。

## 2. 技术栈与工程结构

**Swift + AppKit 负责输入、事件与浮层，SwiftUI 负责设置界面；核心逻辑放在不依赖 AppKit 的 Swift Package 中，以便用合成数据做单元测试。**

### 2.1 技术选型

| 项 | 要求 |
| --- | --- |
| 语言 | Swift 6，开启严格并发检查 |
| 构建 | Xcode 16 及以上；Swift Package Manager 管理依赖（修订：根目录单一 SwiftPM 包 + `scripts/build-macos.sh`，不建 Xcode 工程，见 decisions.md D6） |
| UI | 浮层面板：AppKit `NSPanel` + SwiftUI 内容视图；设置窗口：SwiftUI |
| 原始触点 | 运行时 `dlopen` 加载 `/System/Library/PrivateFrameworks/MultitouchSupport.framework`，用 `dlsym` 取符号；禁止编译期链接私有框架 |
| 事件拦截 | `CGEvent.tapCreate`（公开 API） |
| 自动更新 | Sparkle 2（修订：只提示新版本，不引入 Sparkle，见 decisions.md D5） |
| 应用形态 | 菜单栏应用（`LSUIElement = YES`），无 Dock 图标 |
| 签名分发 | Developer ID + Hardened Runtime + 公证；非沙盒；GitHub Releases 与 Homebrew Cask（修订：固定自签名证书、不公证、GitHub Releases 发 DMG，见 decisions.md D3、D4） |
| 许可证 | MIT（待项目方最终确认）（修订：GPL-3.0-or-later，见 decisions.md D2） |
| 第三方依赖 | 仅允许 Sparkle；其他依赖须先列入待决问题（修订：v1 零第三方依赖，见 decisions.md D5） |

### 2.2 目录结构

（修订：实际目录按 decisions.md D6 映射到 SwiftPM 布局，下图保留为模块划分参考。）

```text
TouchOS/
├── App/                      # 应用入口、菜单栏、生命周期
│   ├── TouchOSApp.swift
│   ├── MenuBarController.swift
│   └── AppCoordinator.swift  # 组装各模块、启动顺序
├── Packages/TouchOSCore/      # 纯逻辑，无 AppKit 依赖，可单测
│   ├── Model/                # TouchFrame、Contact、Layout、Slot、Action、Config
│   ├── StateMachine/         # SessionStateMachine、事件与转移
│   ├── Algorithms/           # AnchorDetector、Mapper、HitTester、LiftStabilizer
│   └── Config/               # 编解码、校验、版本迁移
├── Input/
│   ├── MultitouchBridge.swift   # 私有框架动态加载与回调
│   └── DeviceManager.swift      # 设备枚举、热插拔、休眠唤醒
├── EventControl/
│   ├── EventTapController.swift # 拦截与丢弃策略
│   ├── CursorLock.swift         # 光标冻结与校正
│   └── TapWatchdog.swift        # 拦截失效检测与恢复
├── Overlay/
│   ├── OverlayPanel.swift       # NSPanel 子类
│   └── PanelView.swift          # SwiftUI 渲染
├── Actions/
│   ├── ActionExecutor.swift     # 调度与错误处理
│   └── Executors/               # 每种动作一个文件
├── Settings/                    # 设置窗口、布局编辑器
├── Onboarding/                  # 权限引导
├── Resources/Templates/         # 预置面板模板 JSON
└── Tests/
    ├── TouchOSCoreTests/         # 单元测试
    └── Fixtures/                # 合成触点帧序列
```

### 2.3 线程模型

- 私有框架回调运行在其私有线程：回调内只做拷贝，把帧放入无锁队列后立即返回，禁止在回调内加锁等待或调用 UI。
- 状态机运行在一个专用串行队列 `input.queue`，所有状态变更只在此队列发生。
- 事件拦截回调运行在专用线程的 RunLoop 上；它只读取状态机发布的原子快照 `TapPolicy` 决定放行或丢弃，耗时必须低于 1 ms。
- 浮层渲染与设置界面在主线程；状态机通过主线程派发更新面板。
- 动作执行在独立的后台队列，不得阻塞上述任何队列。

## 3. 系统架构

**数据单向流动：触点帧 → 状态机 → 三路输出（拦截策略、面板视图模型、动作请求）；只有状态机持有会话状态，其他模块都是它的从属。**

&#91;embedded content: 系统架构 · 3 个输入模块、状态机、三路输出\]

事件拦截是唯一的双向模块：它按策略处理系统事件，同时把物理按压与 Esc 回报给状态机。

| 模块 | 职责 | 输入 | 输出 |
| --- | --- | --- | --- |
| `MultitouchBridge` | 动态加载私有框架、注册帧回调、把 C 结构拷贝为 `TouchFrame` | 私有框架回调 | `TouchFrame` 流 |
| `DeviceManager` | 枚举设备、识别内置/外接、热插拔与休眠唤醒后重新注册、按配置停用设备 | IOKit 通知、系统休眠通知 | 可用设备列表 |
| `SessionStateMachine` | 唯一的会话状态持有者；按第 5 章转移；调用各算法 | `TouchFrame`、物理按压事件、按键 Esc、定时器 | `TapPolicy`、`PanelViewModel`、`ActionRequest` |
| `AnchorDetector` | 候选期判定（第 6.1 节） | 帧序列 | 成立 / 放弃及原因 |
| `Mapper` | 触控板坐标 → 面板坐标（第 6.2 节） | 归一化坐标、设备、面板尺寸 | 面板坐标 |
| `HitTester` | 命中槽位与滞回（第 6.3 节） | 面板坐标、布局 | 当前悬停槽位 |
| `LiftStabilizer` | 抬起去抖（第 6.4 节） | 指点指历史位置 | 提交坐标 |
| `EventTapController` | 按 `TapPolicy` 放行或丢弃系统事件；把物理按压、Esc 回报给状态机 | 系统事件流 | 放行 / 丢弃 |
| `CursorLock` | 冻结、累计位移、补位、退出校正（第 7.4 节） | `TapPolicy`、指针事件 | 光标位置 |
| `TapWatchdog` | 发现拦截被系统停用时恢复，并强制结束会话 | 拦截停用事件、心跳 | 恢复 / 强制取消 |
| `OverlayPanel` | 显示、隐藏、渲染面板 | `PanelViewModel` | 屏幕画面 |
| `ActionExecutor` | 执行动作、超时与错误通知 | `ActionRequest` | 执行结果 |
| `ConfigStore` | 读写、校验、迁移配置；变更时广播 | 配置文件、设置界面 | `AppConfig` 快照 |
| `ProfileResolver` | 按前台应用选择面板布局 | 前台应用 Bundle ID、配置 | `Layout` |

**FR-3.1（必须）** 各模块之间只通过上表列出的类型通信；`SessionStateMachine` 以外的模块不得保存会话状态。

**FR-3.2（必须）** `TouchOSCore` 包内的状态机与算法不得引用 AppKit、CoreGraphics 事件或私有框架类型，以保证可用合成帧做确定性测试。

## 4. 输入层：设备与原始触点

**输入层只做一件事：把私有框架的回调可靠地转成 `TouchFrame` 流，并按设备隔离；它不做任何手势判断。**

### 4.1 私有框架加载

- **FR-4.1（必须）** 启动时用 `dlopen` 加载私有框架，用 `dlsym` 解析下列符号；任一必需符号缺失时，进入"输入不可用"降级状态：菜单栏图标显示警告，设置页说明原因，其他功能不崩溃。
- 必需符号：`MTDeviceCreateList`、`MTRegisterContactFrameCallback`、`MTUnregisterContactFrameCallback`、`MTDeviceStart`、`MTDeviceStop`。
- 可选符号（缺失时用替代值）：`MTDeviceIsBuiltIn`（缺失则按设备 ID 规则判断）、`MTDeviceGetSensorSurfaceDimensions`（缺失则用型号默认尺寸表）。
- 接触结构体布局以主流开源实现（OpenMultitouchSupport、MiddleDrag）为准；启动时做自检：若连续 30 帧出现归一化坐标落在 0–1 以外，判定布局不符，进入降级状态。

### 4.2 数据模型

```swift
public struct TrackpadDeviceID: Hashable, Sendable { public let raw: UInt64 }

public struct TrackpadDevice: Sendable {
    public let id: TrackpadDeviceID
    public let isBuiltIn: Bool
    public let displayName: String      // "内置触控板" / "妙控板"
    public let surfaceSizeMM: CGSize    // 物理宽高，单位毫米
}

public enum ContactPhase: Sendable { case began, moved, stationary, ended, cancelled }

public struct Contact: Sendable {
    public let id: Int                  // 同一手指在接触期间保持不变
    public let phase: ContactPhase
    public let position: CGPoint        // 归一化 0–1，原点左下
    public let velocity: CGVector       // 归一化单位/秒
    public let size: Float              // 接触面积（框架原始单位）
    public let pressure: Float          // 力度触控板可用，否则为 0
}

public struct TouchFrame: Sendable {
    public let device: TrackpadDeviceID
    public let timestamp: TimeInterval  // 设备单调时钟，单位秒，只用于算间隔
    public let contacts: [Contact]
}
```

- **FR-4.2（必须）** 私有框架的原始状态码按下表映射；未列出的状态码视为不存在的接触（不放入 `contacts`）。

| 原始状态 | 含义 | 映射为 |
| --- | --- | --- |
| 3 | 开始接触 | `began` |
| 4 | 接触中 | 与上一帧比较位移：超过 0.001 为 `moved`，否则 `stationary` |
| 5 | 结束接触 | `ended` |
| 1、2、6、7 | 悬停、离开感应范围等 | 忽略 |

- **FR-4.3（必须）** 若某接触 ID 未经 `ended` 就从帧中消失，输入层补发一个该 ID 的 `cancelled`。

### 4.3 设备管理

- **FR-4.4（必须）** 每块设备独立注册回调，帧带上设备 ID；状态机按设备隔离处理（锚指与指点指必须来自同一设备）。
- **FR-4.5（必须）** 监听 IOKit 设备接入/移除与系统休眠/唤醒：唤醒后 2 秒内、设备接入后 1 秒内重新枚举并注册；设备移除时，若该设备正处于会话中，状态机执行强制取消。
- **FR-4.6（必须）** 配置中被停用的设备不注册回调。
- **FR-4.7（必须）** 输入层不得把任何坐标写入日志或磁盘；调试叠层（第 14 章）只在内存中显示。

## 5. 交互状态机（修订：见 decisions.md D38，候选态改为轻点后按住的确认期，没有锚指）

**会话只有四个持久状态：空闲、候选、激活、冷却；"执行动作"是转移上的副作用，不是状态。** 状态机是纯函数式的：`(state, event) -> (state, [effect])`，副作用由外层执行。

### 5.1 状态定义

```swift
public enum SessionState: Sendable {
    case idle
    case armed(ArmedContext)        // 候选：锚指已落下，驻留判定中
    case active(ActiveContext)      // 激活态
    case cooldown(until: TimeInterval)
}

public struct ArmedContext: Sendable {
    let device: TrackpadDeviceID
    let anchorID: Int
    let anchorOrigin: CGPoint       // 落点
    let startedAt: TimeInterval
    var suppressedCursorDelta: CGVector  // 候选期被拦下的光标位移
}

public struct ActiveContext: Sendable {
    let device: TrackpadDeviceID
    let anchorID: Int
    let enteredAt: TimeInterval
    let layout: Layout
    var pointer: PointerTrack?      // 当前指点指，可能为空
    var hoveredSlot: SlotID?
    var panelVisible: Bool
    var lastFrameAt: TimeInterval
}
```

### 5.2 事件

| 事件 | 来源 | 说明 |
| --- | --- | --- |
| `frame(TouchFrame)` | 输入层 | 每一帧触点 |
| `physicalPress` | 事件拦截 | 物理按下（左键按下事件，来源为触控板） |
| `escapeKey` | 事件拦截 | Esc 键按下 |
| `tick(now)` | 定时器 | 每 16 ms 一次，仅在非空闲状态运行，用于驻留、延迟显示、冷却、超时 |
| `deviceRemoved(id)` | 设备管理 | 设备断开 |
| `tapDisabled` | 看门狗 | 系统停用了事件拦截 |
| `forceCancel(reason)` | 系统 | 屏幕锁定、快速用户切换、应用退出、配置被停用 |

### 5.3 转移表

| 编号 | 当前状态 | 触发条件 | 副作用 | 新状态 |
| --- | --- | --- | --- | --- |
| T1 | 空闲 | 某启用设备上出现新接触，落点在锚定区内，且该设备上没有其他接触，且前台应用不在黑名单 | 开始拦截指针移动（策略 `armedPolicy`） | 候选 |
| T2 | 候选 | 锚指 ID 已驻留 ≥ `P.dwellMs`，期间位移 < `P.stillThresholdMM`（修订：统一参数名，见 decisions.md D8），未发生 `physicalPress`，接触面积 < `P.palmSize` | 见 5.4 进入激活 | 激活 |
| T3 | 候选 | 锚指位移 ≥ `P.stillThresholdMM` | 补位光标；恢复放行 | 空闲 |
| T4 | 候选 | 收到 `physicalPress` | 补位光标；放行该按压；恢复放行 | 空闲 |
| T5 | 候选 | 同设备出现第二个接触 | 补位光标；恢复放行 | 空闲 |
| T6 | 候选 | 锚指抬起 | 补位光标；恢复放行 | 空闲 |
| T7 | 候选 | 接触面积 ≥ `P.palmSize` | 补位光标；恢复放行 | 空闲 |
| T8 | 激活 | 同设备新接触落在映射区，且当前无指点指（修订：落在边缘以内即可，见 decisions.md D9） | 记为指点指，开始跟踪 | 激活 |
| T9 | 激活 | 指点指移动 | 更新映射坐标、命中槽位；槽位变化时触发触觉 | 激活 |
| T10 | 激活 | 距进入 ≥ `P.panelDelayMs` 且面板未显示 | 显示面板 | 激活 |
| T11 | 激活 | 指点指抬起，提交坐标命中普通槽位，槽位未开连续触发（修订：见 decisions.md D18） | 见 5.5 退出；发出 `ActionRequest` | 冷却 |
| T12 | 激活 | 指点指抬起，命中开启连续触发的槽位（修订：见 decisions.md D18） | 发出 `ActionRequest`；面板闪烁该槽位；清空指点指 | 激活 |
| T13 | 激活 | 指点指抬起，命中安全区或空隙（修订：见 decisions.md D17） | 清空指点指（不退出，允许重新选择） | 激活 |
| T14 | 激活 | 锚指抬起 | 见 5.5 退出（取消） | 冷却 |
| T15 | 激活 | 同设备接触数 ≥ 3（修订：见 decisions.md D22，只限锚指仍按着时；常驻状态下多指按轻点 / 移动区分） | 见 5.5 退出（取消）；冷却期内对三指及以上事件一律放行 | 冷却 |
| T16 | 激活 | `escapeKey` | 吞掉该按键；退出（取消） | 冷却 |
| T17 | 激活 | 距上一帧 > `P.frameTimeoutMs` | 退出（取消） | 冷却 |
| T18 | 激活 | 激活总时长 > `P.maxSessionSec`（修订：见 decisions.md D42，从最后一次活动算起） | 退出（取消） | 冷却 |
| T19 | 候选或激活 | `deviceRemoved`（本设备）、`tapDisabled`、`forceCancel` | 立即退出（取消），光标校正，停止所有拦截 | 空闲 |
| T20 | 冷却 | 当前时间 ≥ 冷却截止 | 停止冷却期拦截 | 空闲 |
| T21 | 冷却 | 任何新接触 | 忽略（不能开始新的候选） | 冷却 |

说明：T13 的设计意图是"在安全区抬起 = 放弃本次选择"，用户可直接再落指重选；想完全退出则抬起锚指（T14）。这是对"安全区"语义的明确化。

### 5.4 进入激活（T2 的副作用，按顺序）

1. 切换拦截策略为 `activePolicy`（第 7 章）。
2. `CursorLock` 记录当前光标位置为冻结点（候选期已在拦截，光标未移动）。
3. `ProfileResolver` 依前台应用解析布局，写入 `ActiveContext.layout`。
4. 若 `P.panelDelayMs = 0` 立即显示面板，否则等待 T10。

### 5.5 退出激活（按顺序，任何一步失败都必须继续后续步骤）

1. 隐藏面板（无动画，立即隐藏）。
2. 光标校正到冻结点。
3. 切换拦截策略为 `cooldownPolicy`，冷却截止 = 现在 + `P.cooldownMs`。
4. 若有 `ActionRequest`，在面板隐藏后至少 `P.actionDelayMs` 再执行，确保按键事件发往原前台应用。

## 6. 核心算法

**所有算法都是 `TouchOSCore` 内的纯函数，输入帧与参数，输出确定结果；距离阈值一律用毫米表达，再按设备物理尺寸换算成归一化值，保证不同尺寸的触控板手感一致。**

### 6.1 锚定判定（AnchorDetector）（修订：见 decisions.md D38，已去掉，改为方位分区）

锚定区按配置的角落生成归一化矩形。以左下角为例，宽 `P.anchorZoneW`、高 `P.anchorZoneH`（触控板比例）：

```latex
Z_{anchor} = [0, w_a] \times [0, h_a]
```

其他三角按镜像生成；"左边缘""右边缘"选项为整条边：宽 `P.anchorZoneW`、高 0–1。

- **FR-6.1（必须）** 候选成立的全部条件：落点在锚定区内；落下时同设备无其他接触；从 `began` 起驻留 ≥ `P.dwellMs`；驻留期内相对落点的最大位移 < `P.stillThresholdMM`；接触面积始终 < `P.palmSize`；期间无物理按下。
- **FR-6.2（必须）** 判定失败时返回原因枚举（`moved`、`pressed`、`secondTouch`、`lifted`、`palm`），供调试叠层显示。
- **FR-6.3（必须）** 激活后，锚指只需保持接触；离开锚定区、移动都不影响激活态。

### 6.2 坐标映射（Mapper）

映射区为每边内缩 `P.mappingMargin`（比例 m）后的矩形。（修订：映射区改为居中、边长为触控板 `P.mappingScale` 倍的矩形，下式中 m 相应替换为 (1 − scale)/2；`P.mappingMargin` 只表示不接受指点指落下的边缘，见 decisions.md D9）指点指归一化坐标 (x, y) 先归一到映射区并钳制：

```latex
u = \mathrm{clamp}\left(\frac{x - m}{1 - 2m}, 0, 1\right), \quad v = \mathrm{clamp}\left(\frac{y - m}{1 - 2m}, 0, 1\right)
```

再转成面板坐标（面板宽 W、高 H，原点左上，y 向下）：

```latex
p_x = u \cdot W, \quad p_y = (1 - v) \cdot H
```

- **FR-6.4（必须）**（修订：见 decisions.md D29） 面板宽高比固定等于该设备映射区的物理宽高比（物理宽 × (1 − 2m) : 物理高 × (1 − 2m)），用户不可拉伸；面板尺寸只按屏幕大小整体缩放（见第 8 章）。
- **FR-6.5（必须）** 落在锚定区内的新接触不得成为指点指；指点指移动进入锚定区时照常映射。
- **FR-6.6（应当）** 指示点做一阶低通平滑：`p = p_prev + α × (p_raw − p_prev)`，α = `P.smoothing`；平滑只用于显示，命中判定用原始坐标。

### 6.3 命中与滞回（HitTester）

- 槽位几何以面板归一化坐标存储（0–1，原点左上），渲染与命中都先乘以面板宽高。
- **FR-6.7（必须）** 无当前槽位时：命中点所在的槽位即为当前槽位；不在任何槽位内则为"空隙"（等同安全区）。
- **FR-6.8（必须）** 已有当前槽位时：只有当点离开"当前槽位矩形向外扩 `P.hysteresis`"的区域后，才重新计算命中。
- **FR-6.9（必须）** 槽位矩形不得重叠（编辑器保证）；若读到重叠配置，按 z 序（数组顺序）取最后一个。

### 6.4 抬起去抖（LiftStabilizer）

- **FR-6.10（必须）** 为指点指保留最近 200 ms 的位置历史。收到 `ended` 时，提交坐标取时间戳 ≤ (抬起时刻 − `P.liftLookbackMs`) 的最近一个样本；若历史不足，取最早样本。
- **FR-6.11（必须）** 提交槽位按提交坐标做一次不带滞回的命中；若与当前悬停槽位不同，以提交坐标的结果为准。（修订：见 decisions.md D31）

### 6.5 面板延迟显示与盲选（修订：见 decisions.md D38，面板立即显示）

- **FR-6.12（必须）** 面板未显示时，指点指的跟踪、命中、提交照常进行；盲选提交与可见提交行为一致。
- **FR-6.13（必须）** 面板显示前出现的轨迹不回放，显示时直接从当前位置开始绘制。

### 6.6 触觉反馈

- **FR-6.14（应当）**（实现修订：见 decisions.md D18） 当前槽位变化（含进入、离开空隙）时调用公开的触觉反馈接口（对齐类型）；两次触发间隔不少于 40 ms；设备不支持时静默跳过。
- **FR-6.15（应当）** 连续触发每次提交时触发一次触觉反馈。

## 7. 事件拦截与光标控制

**用一个常驻的事件拦截按当前策略放行或丢弃；光标冻结完全靠丢弃指针移动加校正实现，不使用"断开鼠标与光标关联"接口，这样即使应用崩溃，系统行为也会立即恢复。**（修订：见 decisions.md D52，激活态默认隐藏光标）

### 7.1 拦截点

- **FR-7.1（必须）** 在 HID 层创建一个可修改的事件拦截（头部插入），监听下表所有事件类型，包括 AppKit 手势类事件的原始类型值（手势 29、捏合 30、轻扫 31、旋转 18、开始手势 19、结束手势 20、智能缩放 32、查询 33、压力 34）。
- **FR-7.2（必须）** 回调只读取状态机发布的原子快照 `TapPolicy` 并做查表决策；禁止加锁、分配大对象或同步调用其他队列。
- **FR-7.3（必须）** TouchOS 自己合成的事件，在事件源用户数据字段写入固定魔数；回调见到魔数一律放行。

### 7.2 策略表

| 事件类型 | 空闲 | 候选 | 激活 | 冷却 |
| --- | --- | --- | --- | --- |
| 指针移动 | 放行 | **丢弃并累计位移** | 丢弃 | 放行 |
| 左/右/其他键按下、抬起、拖动 | 放行 | 左键按下：上报 `physicalPress` 后放行；其余放行 | 丢弃 | 丢弃（触控板来源），截止后放行 |
| 滚动 | 放行 | 放行 | 丢弃 | 丢弃带惯性阶段的滚动，至 `P.momentumSuppressMs` |
| 手势类（29–34、18–20） | 放行 | 放行 | 丢弃 | 丢弃，截止后放行 |
| 键盘 Esc | 放行 | 放行 | 上报 `escapeKey` 并丢弃 | 放行 |
| 其他键盘事件 | 放行 | 放行 | 放行 | 放行 |

- **FR-7.4（必须）** 激活态丢弃所有来源（含外接鼠标）的指针与滚动事件，保证光标绝对静止。
- **FR-7.5（必须）** 因 T15（三指）进入的冷却，手势类事件改为放行，避免吞掉用户紧接着的系统三指手势。

### 7.3 已知无法拦截的行为

三、四指系统手势与"右边缘双指左滑"通知中心手势可能由 Dock 私有消费，拦截不可靠。规格通过 T15（三指即取消）和映射区边距规避，实现方无需尝试拦截它们；若测试发现双指场景下仍有系统行为漏出，记录到附录"待实测项"。

### 7.4 光标控制（CursorLock）

- **FR-7.6（必须）** 候选期：丢弃指针移动并累计其位移；判定失败（T3–T7）时，把光标移到"冻结点 + 累计位移"（钳制在屏幕内），使光标看起来只是晚了一点开始移动。
- **FR-7.7（必须）** 激活态：每次 `tick` 校验光标位置，偏离冻结点超过 0.5 pt 时移回冻结点。移动光标前把本地事件抑制间隔设为 0，避免移动后约 0.25 秒的输入冻结。
- **FR-7.8（必须）** 退出激活：光标精确回到冻结点，然后才切换策略。
- **FR-7.9（必须）** 候选期不隐藏系统光标；激活期默认隐藏，可在通用设置改为保持显示（修订：见 decisions.md D52）。

### 7.5 看门狗（TapWatchdog）

- **FR-7.10（必须）** 收到"拦截因超时/用户输入被停用"通知时：立即重新启用，并向状态机发 `tapDisabled`（T19）。
- **FR-7.11（必须）** 每 2 秒检查拦截是否仍启用；连续 3 次重新启用失败，进入"拦截不可用"降级：停止接受锚定，菜单栏显示警告。
- **FR-7.12（必须）** 失去辅助功能权限时同样进入降级，并在设置页引导重新授权。

## 8. 浮层面板

**面板是一个永不获得焦点、鼠标穿透、出现在所有桌面和全屏应用之上的窗口；它只渲染视图模型，不处理任何输入。**

### 8.1 窗口属性

- **FR-8.1（必须）** 使用非激活型 `NSPanel`：不成为主窗口或关键窗口；显示时不改变前台应用与键盘焦点。
- **FR-8.2（必须）** 忽略鼠标事件；窗口层级高于全屏应用与菜单栏（使用屏保层级或等效层级）；出现在所有桌面，并能叠加在全屏应用上。
- **FR-8.3（必须）** 不出现在窗口列表、Mission Control 与截图的窗口选择中；可被普通截屏捕获。
- **FR-8.4（必须）** 面板窗口在应用启动时创建并保持隐藏，激活时只切换可见性，避免首次显示的延迟。

### 8.2 位置与尺寸

- **FR-8.5（必须）**（修订：见 decisions.md D20，居中于整块屏幕） 显示在冻结光标所在的屏幕，居中于该屏幕的可见区域。
- **FR-8.6（必须）**（修订：见 decisions.md D20、D29） 面板宽高比按 FR-6.4 固定；尺寸 = 能放入"屏幕可见区域 × `P.panelScale`"的最大矩形。
- **FR-8.7（应当）** 屏幕配置变化时（接入/拔出显示器、分辨率变化）重新计算尺寸。

### 8.3 视觉元素（修订：见 decisions.md D20）

| 元素 | 规格 |
| --- | --- |
| 背景 | 半透明毛玻璃，圆角 16 pt；跟随系统浅色/深色 |
| 槽位 | 圆角 10 pt 的卡片：图标（居中偏上，32 pt）+ 名称（13 pt，最多两行，超出省略）；可设置强调色 |
| 安全区 | 虚线描边、无填充，中央显示"取消"图标；颜色比普通槽位更淡 |
| 悬停高亮 | 槽位放大至 104%，强调色描边 2 pt，背景加亮；动画 80 ms |
| 指示点 | 直径 14 pt 的实心圆，强调色，带白色描边以保证在任何背景上可见 |
| 轨迹 | 最近 `P.trailMs` 内的路径，线宽 3 pt，透明度从 0.6 渐隐到 0；可在设置中关闭 |
| 连续触发反馈 | 提交时该槽位闪烁一次（背景亮度脉冲 150 ms） |
| 首次使用提示 | 前 `P.onboardingHintCount` 次激活时，面板顶部显示"移动另一根手指选择，抬起执行；抬起拇指取消" |
| 当前面板名 | 面板左上角小字显示布局名称（如"Safari"或"全局"） |

### 8.4 动画与性能

- **FR-8.8（必须）** 显示：透明度 0→1，120 ms；隐藏：立即，无动画（见 5.5）。（修订：见 decisions.md D16、D20）
- **FR-8.9（必须）** 指示点更新跟随屏幕刷新率（使用显示链接驱动），在 120 Hz 屏上每帧更新；触点帧率低于刷新率时，在两帧间线性插值。
- **FR-8.10（必须）** 遵循系统"减少动态效果"设置：开启时取消缩放与闪烁动画。

## 9. 动作系统

**每种动作是一个可编码的值类型加一个执行器；执行在串行后台队列上进行，失败只通知、不重试、不影响下一次会话。**

### 9.1 协议

```swift
public enum Action: Codable, Sendable, Equatable {
    case none                                   // 安全区
    case keyboardShortcut(KeyCombo)
    case openApp(bundleID: String)
    case openURL(url: URL, browserBundleID: String?)
    case openFile(path: String)
    case shell(command: String, timeoutSec: Double, notifyOutput: Bool)
    case appleScript(source: String, language: ScriptLanguage) // .appleScript / .javaScript
    case shortcut(name: String)                 // 系统"快捷指令"
    case system(SystemCommand)
    // M2 预留：macro([Action])、textSnippet(String)、windowManagement(WindowCommand)、subPanel(LayoutID)
}

public struct KeyCombo: Codable, Sendable, Equatable {
    public let keyCode: UInt16                  // 虚拟键码，与键盘布局无关
    public let modifiers: Set<Modifier>         // command / option / control / shift / function
    public let displayLabel: String             // 编辑器显示用，如 "⌘W"
}

public enum SystemCommand: String, Codable, Sendable {
    case volumeUp, volumeDown, mute
    case brightnessUp, brightnessDown
    case playPause, nextTrack, previousTrack
    case lockScreen, missionControl, showDesktop, launchpad
    case screenshotArea, screenshotWindow
}

public protocol ActionRunner: Sendable {
    func run(_ action: Action, context: ActionContext) async throws
}

public struct ActionContext: Sendable {
    public let frontmostBundleID: String?       // 会话开始时的前台应用
    public let cursorLocation: CGPoint          // 冻结点（屏幕坐标）
}
```

### 9.2 各动作执行规格

| 动作 | 执行方式 | 要求 |
| --- | --- | --- |
| 模拟快捷键 | 合成键盘按下/抬起事件，带修饰键标志，投递到 HID 层；事件带 FR-7.3 魔数 | 修饰键必须先按下后抬起，保证顺序；按下与抬起间隔 8 ms |
| 打开应用 | 按 Bundle ID 打开；已运行则激活 | 找不到应用时通知"未安装 X" |
| 打开 URL | 用系统默认或指定浏览器打开 | URL 必须合法；只允许 http、https、mailto 及用户已安装应用注册的协议 |
| 打开文件/文件夹 | 用默认应用打开 | 路径不存在时通知 |
| Shell | 子进程执行 `/bin/zsh -c <command>`，工作目录为用户主目录 | 超过 `timeoutSec`（默认 10 秒）终止进程；`notifyOutput` 为真时把标准输出前 200 字作为通知 |
| AppleScript / JXA | 子进程执行系统脚本命令 `osascript` | 同 Shell 的超时规则；首次控制某应用时系统会弹自动化授权，失败时通知并附设置入口 |
| 快捷指令 | 子进程执行 `shortcuts run <name>` | 名称不存在时通知 |
| 系统控制 | 媒体键事件（音量、亮度、播放）；锁屏、调度中心等用对应的系统快捷键 | 必须在外接显示器与内置屏上都生效（亮度在外接屏上不支持时静默） |

### 9.3 调度与错误

- **FR-9.1（必须）** 所有动作进入一个串行队列；队列中待执行超过 5 个时丢弃最旧的（防止连续触发堆积）。
- **FR-9.2（必须）** 动作失败时发送一条系统通知：动作名 + 一句原因；不弹模态窗口，不重试。
- **FR-9.3（必须）** 模拟快捷键执行前确认当前前台应用与会话开始时一致；不一致时仍执行，但写入调试日志（不含坐标）。（修订：见 decisions.md D27，默认先把焦点切到指针下的窗口）
- **FR-9.4（必须）** Shell 与脚本动作首次被添加到槽位时，编辑器显示一次风险提示："该动作会以你的用户权限运行命令"。
- **FR-9.5（必须）** 导入的配置包含 Shell 或脚本动作时，导入前列出这些动作供用户逐条确认。

## 10. 配置数据模型与持久化

**全部配置存在一个带版本号的 JSON 文件里；布局用网格单元描述，与设备尺寸无关，渲染时再按设备宽高比展开。**

### 10.1 存储

- **FR-10.1（必须）** 路径：`~/Library/Application Support/TouchOS/config.json`。写入采用"写临时文件 + 原子替换"；每次成功写入前把旧文件轮转到 `backups/`，保留最近 5 份。
- **FR-10.2（必须）** 启动时校验失败（解析错误、版本过高、字段非法）：不覆盖原文件，改为加载内置默认配置并在设置页提示"配置已损坏，可从备份恢复"。
- **FR-10.3（必须）** 设置变更 300 ms 防抖后写盘；状态机读取的是不可变快照，配置变更只影响下一次会话。
- **FR-10.4（必须）** 每个结构带 `schemaVersion`；版本升级时按顺序执行迁移函数，迁移函数须有单元测试。

### 10.2 结构示例

```json
{
  "schemaVersion": 1,
  "general": {
    "enabled": true,
    "launchAtLogin": true,
    "commitMode": "lift",
    "showTrail": true,
    "haptics": true,
    "blacklist": ["com.valvesoftware.steam", "com.microsoft.rdc.macos"]
  },
  "devices": {
    "builtIn":  { "enabled": true },
    "external": { "enabled": true }
  },
  "anchor": {
    "corner": "bottomLeft",
    "zoneWidth": 0.12,
    "zoneHeight": 0.15
  },
  "tuning": {
    "dwellMs": 200, "stillThresholdMM": 2.0, "palmSize": null,
    "mappingMargin": 0.05, "hysteresis": 0.02, "liftLookbackMs": 60,
    "panelDelayMs": 200, "cooldownMs": 150, "momentumSuppressMs": 1200,
    "panelScale": 0.6, "smoothing": 0.5
  },
  "layouts": [
    {
      "id": "global",
      "name": "全局",
      "grid": { "rows": 3, "cols": 4 },
      "slots": [
        {
          "id": "s-close",
          "cell": { "row": 0, "col": 3, "rowSpan": 1, "colSpan": 1 },
          "title": "关闭",
          "icon": { "kind": "sfSymbol", "name": "xmark" },
          "color": "#E5484D",
          "repeat": false,
          "action": { "type": "keyboardShortcut", "keyCode": 13, "modifiers": ["command"], "displayLabel": "⌘W" }
        },
        {
          "id": "s-null",
          "cell": { "row": 2, "col": 0, "rowSpan": 1, "colSpan": 1 },
          "title": "取消",
          "icon": { "kind": "sfSymbol", "name": "nosign" },
          "repeat": false,
          "action": { "type": "none" }
        }
      ]
    }
  ],
  "profiles": [
    { "bundleID": "*", "layoutID": "global" },
    { "bundleID": "com.apple.Safari", "layoutID": "browser-safari", "inherit": "global", "overrides": ["s-close"] }
  ]
}
```

### 10.3 规则

- **FR-10.5（必须）** 网格单元换算为面板归一化矩形：`x = col / cols`，`y = row / rows`，`w = colSpan / cols`，`h = rowSpan / rows`；槽位之间在渲染时各内缩 `P.slotGap`（pt），内缩部分即"空隙"。
- **FR-10.6（必须）** 槽位不得重叠、不得越出网格；违反时编辑器拒绝保存，加载时按 FR-6.9 处理并在设置页警告。
- **FR-10.7（必须）** 布局解析：精确匹配前台 Bundle ID → 否则 `*`。设置 `inherit` 时，以继承布局为底，`overrides` 列出的槽位 ID 及本布局新增的槽位覆盖底层同位置单元。
- **FR-10.8（必须）** `palmSize` 为 null 表示使用首次引导中校准得到的值；未校准时使用内置默认值。
- **FR-10.9（必须）** 导出单个布局或全部配置为 `.touchos.json`；导入时校验结构、版本并执行 FR-9.5。

## 11. 设置界面与布局编辑器

**设置窗口分五页：通用、面板、锚定与手感、设备、关于；核心是"面板"页的所见即所得网格编辑器。** 示例 JSON 中 `browser-safari` 布局省略未列出。

### 11.1 菜单栏

- **FR-11.1（必须）** 菜单项：启用/暂停 TouchOS（快捷切换）、当前状态（正常 / 输入不可用 / 拦截不可用 / 缺少权限）、打开设置、检查更新、退出。
- **FR-11.2（必须）** 暂停时拦截保持安装但全部放行，不接受锚定，不显示面板。

### 11.2 通用页

- 开机启动、提交方式（M1 只有"抬起提交"可选，"按压提交"灰显标注 M2）、轨迹显示、触觉反馈、应用黑名单（从运行中应用或 /Applications 选择）、导入/导出配置、从备份恢复。

### 11.3 面板页（布局编辑器）

- **FR-11.3（必须）** 左栏：布局列表（全局置顶）+ 新建、复制、删除；每个布局可绑定一个或多个应用。
- **FR-11.4（必须）** 中栏：按当前设备宽高比显示的面板预览；网格行列数可调（1–6 行、1–8 列）；点击空单元格新建槽位，拖动边缘合并单元格，拖动槽位移动。
- **FR-11.5（必须）** 右栏：选中槽位的属性：名称、图标（SF Symbols 选择器 / 应用图标 / 本地图片）、颜色、连续触发开关（修订：见 decisions.md D18）、动作类型及参数。
- **FR-11.6（必须）** 快捷键录制控件：点击后录制下一个组合键（录制期间暂停 TouchOS 的 Esc 处理）；显示为 "⌘⇧T" 形式。
- **FR-11.7（必须）** "测试"按钮：立即执行所选槽位动作（延迟 1 秒，以便用户切到目标应用）。
- **FR-11.8（必须）** 实时校验并在预览上标红：槽位单元格少于 `P.minSlotMM` 的物理尺寸；槽位覆盖锚定区所在角（提示"该位置可能被拇指挡住"）。
- **FR-11.9（必须）** 布局继承：继承全局的布局中，被继承槽位显示为半透明并带"继承"角标，点击后可选择"在此覆盖"。
- **FR-11.10（应当）** 实时试用：编辑器打开时进行锚定，面板显示正在编辑的布局（带"试用中"标记，提交不执行动作，只在编辑器里高亮命中的槽位）。
- **FR-11.11（必须）**（修订：见 decisions.md D29） 预置模板：新建布局时可选择"浏览器""代码编辑器""媒体控制""窗口与桌面"，模板 JSON 存于资源目录。

### 11.4 锚定与手感页（修订：见 decisions.md D26、D38，改为唤起与手感页）

- 锚定位置（四角 + 左右边缘）的可视化选择；锚定区大小滑块；驻留时长、静止阈值、面板显示延迟、映射区边距、滞回、冷却期滑块，每项旁有"恢复默认"。
- 手掌校准：引导用户把拇指平放按住 3 秒，记录接触面积，取 1.5 倍作为 `palmSize`。
- 实时诊断区：显示最近一次候选失败的原因（FR-6.2）与当前帧率。

### 11.5 设备页

- 列出已连接的触控板：名称、内置/外接、物理尺寸、每设备启用开关、实时触点预览（仅显示圆点，不记录）。

### 11.6 关于页

- 版本、开源许可证、项目主页、私有框架使用说明（"TouchOS 读取触控板原始触点，仅在内存中处理，从不记录或上传"）。

## 12. 权限、首次启动与引导

**TouchOS 只强制要求一项权限：辅助功能；其余权限按动作需要时由系统弹出。没有辅助功能权限时，应用可以打开设置，但不接受锚定。**

### 12.1 权限清单

| 权限 | 用途 | 何时请求 | 缺失时行为 |
| --- | --- | --- | --- |
| 辅助功能 | 事件拦截与修改、合成按键 | 首次启动引导第 2 步 | 降级：不接受锚定，菜单栏警告 |
| 自动化（按目标应用） | AppleScript 控制其他应用 | 首次执行相关动作时由系统弹出 | 该动作失败并通知，附系统设置入口 |
| 通知 | 动作失败提示 | 首次需要通知时 | 失败时静默，写入调试日志 |

- **FR-12.1（必须）** 不请求屏幕录制、输入监控、完全磁盘访问。
- **FR-12.2（必须）** 启动与每次从后台回到设置窗口时检查辅助功能授权；授权状态变化后 2 秒内自动生效，无需重启应用。
- **FR-12.3（必须）** 检测到"应用已在列表中但未生效"（常见于签名变化后），提示用户在列表中先关闭再打开 TouchOS。

### 12.2 首次启动流程

1. **欢迎**：一句话说明"按住左下角，看着选，抬起执行"，配一段动画演示。
2. **授权辅助功能**：按钮打开系统设置对应页面；窗口持续检测，授权后自动进入下一步。
3. **检查冲突**：若系统设置中开启了"点按左下角/右下角作为辅助点按"，且与锚定角相同，提示改用其他角或关闭该项；若检测到 BetterTouchTool 或 BetterAndBetter 正在运行，提示关闭它们在同一角落的手势。
4. **手掌校准**（可跳过）：见 11.4。
5. **选择模板**：从 4 个预置模板中选一个作为全局面板。
6. **练习**：引导用户完成 3 次完整操作——唤起、选择"练习槽位"、抬起；再练一次"抬起拇指取消"。练习中的动作只显示成功提示，不执行真实动作。
7. **完成**：提示菜单栏图标位置与设置入口。

- **FR-12.4（必须）** 引导可随时退出，下次打开设置时从未完成的步骤继续；设置中可重新运行引导。

## 13. 非功能需求

**最硬的约束是"绝不让用户的光标或点按卡住"：任何异常都必须以恢复系统默认行为收场。**

| 编号 | 类别 | 要求 | 测量方法 |
| --- | --- | --- | --- |
| NFR-1 | 延迟 | 指点指移动到面板指示点更新，p95 ≤ 25 ms（不含屏幕扫描） | 调试叠层记录帧时间戳与渲染时间戳之差 |
| NFR-2 | 拦截耗时 | 事件拦截回调 p99 ≤ 0.5 ms，最大 ≤ 1 ms | 回调内打点统计，Instruments 验证 |
| NFR-3 | 空闲开销 | 无会话时 CPU 平均 ≤ 1%（正常使用触控板期间），内存 ≤ 80 MB | 活动监视器，连续 10 分钟 |
| NFR-4 | 激活开销 | 激活态 CPU 峰值 ≤ 15%（单核） | Instruments |
| NFR-5 | 启动 | 冷启动到可接受锚定 ≤ 1.5 秒 | 计时日志 |
| NFR-6 | 稳定性 | 8 小时持续使用（含休眠唤醒 3 次、设备插拔 3 次）无崩溃、无光标卡住、无点按失效 | 手工浸泡测试 |
| NFR-7 | 故障安全 | 应用崩溃或被强制退出后，系统指针、点按、滚动立即恢复正常（由第 7 章设计保证） | `kill -9` 测试，激活态中执行 |
| NFR-8 | 误唤起 | 日常使用 1 小时，误唤起 ≤ 1 次（默认参数） | 20 人次测试，记录候选成立次数与用户确认 |
| NFR-9 | 选择准确 | 3×4 网格，抬起提交命中目标槽位 ≥ 97% | 随机目标练习，每人 100 次 |
| NFR-10 | 隐私 | 不记录、不上传任何触点坐标或轨迹；无网络请求（更新检查除外，可关闭；修订：见 decisions.md D5） | 代码审查 + 网络监控 |
| NFR-11 | 日志 | 使用系统统一日志，子系统 `app.touchos`（修订：`ai.nekro.touchos`，见 decisions.md D1）；只记录状态转移、失败原因、耗时，不含坐标 | 代码审查 |
| NFR-12 | 本地化 | 界面提供简体中文与英文，跟随系统语言；所有字符串走本地化表 | 切换系统语言检查 |
| NFR-13 | 无障碍 | 设置窗口全部控件支持 VoiceOver 与键盘操作 | VoiceOver 手工检查 |
| NFR-14 | 兼容 | macOS 14、15、26；Apple Silicon 与 Intel；内置板与妙控板 | 测试矩阵（第 14 章） |
| NFR-15 | 代码质量 | `TouchOSCore` 行覆盖率 ≥ 85%；无编译警告；严格并发检查无告警 | CI |

## 14. 测试与验收

**状态机与算法用合成帧做确定性单元测试；拦截、光标、浮层这类依赖系统的行为用手工测试矩阵覆盖；每个里程碑以本章验收用例全部通过为准。**

### 14.1 合成帧测试工具

- **FR-14.1（必须）** 在测试目标中提供帧序列构造器，用时间与位置描述手势，例如：

```swift
let frames = Gesture(device: .builtIn)
    .touch(id: 1, at: (0.05, 0.06), t: 0)        // 锚指落下
    .hold(id: 1, until: 0.25)                    // 驻留 250 ms
    .touch(id: 2, at: (0.5, 0.5), t: 0.30)       // 指点指落下
    .move(id: 2, to: (0.8, 0.8), over: 0.20)     // 200 ms 移到右上
    .lift(id: 2, t: 0.55)
    .lift(id: 1, t: 0.70)
    .frames(rate: 90)                            // 按 90 Hz 采样
```

- **FR-14.2（必须）** 状态机测试断言输出的副作用序列（策略切换、面板显示、`ActionRequest`），不依赖真实时间。
- **FR-14.3（必须）** 支持录制模式：在调试构建中把真实帧序列导出为测试夹具文件（仅开发者手动触发，导出前提示含有手部轨迹）。

### 14.2 调试叠层

- **FR-14.4（必须）** 调试构建提供一个可开关的半透明叠层：每台设备的实时触点、当前状态、候选失败原因、帧率、拦截耗时、最近 10 次状态转移。发布构建中该功能可通过隐藏开关打开，但永不写盘。

### 14.3 手工测试矩阵

（修订：增加 macOS 27 列，各场景均为必测；开发机缺少的硬件场景按 decisions.md D7 后补。）

| 场景 | macOS 14 | macOS 15 | macOS 26 |
| --- | --- | --- | --- |
| 内置板，单屏 | 必测 | 必测 | 必测 |
| 妙控板 + 内置板同时连接 | 必测 | 必测 | 必测 |
| 外接显示器 + 光标在外接屏 | 必测 | 必测 | 必测 |
| 全屏视频 / 全屏应用 | 必测 | 必测 | 必测 |
| 休眠唤醒、妙控板蓝牙断连重连 | 必测 | 必测 | 必测 |
| 与 BetterTouchTool 同时运行 | 抽测 | 必测 | 必测 |
| Intel Mac | 抽测 | 抽测 | 不适用 |

### 14.4 验收用例

| 编号 | 对应需求 | 步骤 | 期望 |
| --- | --- | --- | --- |
| AC-1 | FR-6.1、T2 | 拇指按住左下角静止 250 ms | 进入激活，光标不动，200 ms 后面板出现 |
| AC-2 | T3、FR-7.6 | 拇指落在左下角后立即滑动 | 不激活；光标随后移动，总位移与手指一致 |
| AC-3 | T4 | 拇指在左下角直接按下点击 | 不激活；点击正常生效 |
| AC-4 | T11 | 激活后另一指移到"关闭"槽位抬起 | 面板消失，前台窗口收到 ⌘W |
| AC-5 | T13 | 激活后在空隙抬起，再落指选中槽位抬起（修订：见 decisions.md D17） | 第一次无动作，第二次执行，激活态全程保持直到第二次提交 |
| AC-6 | T14 | 激活后指点指停在槽位上，先抬起拇指 | 取消，无动作 |
| AC-7 | T12 | 在开启连续触发的"音量 +"槽位反复落指抬起 3 次（修订：见 decisions.md D18） | 音量提升 3 档，面板保持 |
| AC-8 | T15、FR-7.5 | 激活后落下第三指 | 取消；随后三指手势正常 |
| AC-9 | FR-7.4 | 激活态中两指移动、轻点、捏合、双击 | 无滚动、无右键、无缩放、光标不动 |
| AC-10 | 5.5、FR-7.2 | 提交后立即双指滚动 | 惯性滚动不泄露；150 ms 后新的滚动正常 |
| AC-11 | FR-6.12 | 设置延迟 300 ms，在面板出现前完成选择抬起 | 正确执行动作 |
| AC-12 | FR-6.10 | 在两个槽位边界附近抬起 100 次 | 选错率 ≤ 3% |
| AC-13 | FR-4.4 | 锚指在内置板，指点指在妙控板 | 不成为指点指，无动作 |
| AC-14 | FR-4.6 | 设备页停用妙控板后在妙控板上锚定 | 不激活 |
| AC-15 | FR-10.7 | Safari 前台时激活 | 显示 Safari 布局，继承的槽位可用 |
| AC-16 | NFR-7 | 激活态中 `kill -9` 进程 | 光标、点按、滚动立即恢复 |
| AC-17 | FR-7.10 | 人为阻塞拦截回调使系统停用拦截 | 会话取消、拦截恢复、无卡死 |
| AC-18 | 第 8 章 | 在全屏应用中激活 | 面板显示在全屏应用之上，焦点不变 |
| AC-19 | FR-10.2 | 手动破坏配置文件后启动 | 加载默认配置，原文件保留，设置页提示 |
| AC-20 | 第 12 章 | 全新用户首次启动 | 按 7 步完成引导，可中途退出并继续 |

## 15. 开发任务拆分与里程碑

**按下表顺序逐项实现，每项一次提交（或一个 PR），完成条件全部满足才进入下一项；M0 闸门不通过，不得开始 M1 的界面类任务。**

| 任务 | 里程碑 | 内容 | 对应需求 | 完成条件 |
| --- | --- | --- | --- | --- |
| K1 | M0 | 工程骨架：菜单栏应用、`TouchOSCore` 包、CI（构建 + 单测 + 覆盖率） | 第 2 章、NFR-15 | CI 绿；空应用可启动并显示菜单栏图标 |
| K2 | M0 | 数据模型与合成帧构造器 | 4.2、14.1 | 构造器单测通过 |
| K3 | M0 | `MultitouchBridge` 与 `DeviceManager` | 第 4 章 | 调试叠层显示两块设备的实时触点；休眠唤醒后恢复 |
| K4 | M0 | 状态机全部转移（T1–T21） | 第 5 章 | 每条转移至少一个单测 |
| K5 | M0 | 锚定判定、映射、命中滞回、抬起去抖 | 第 6 章 | 单测覆盖所有失败原因与边界 |
| K6 | M0 | 事件拦截、策略表、光标控制、看门狗 | 第 7 章 | AC-2、AC-3、AC-9、AC-10、AC-16、AC-17 通过 |
| K7 | M0 | 最简浮层：固定 3×3 网格，动作写死为 9 个快捷键 | 第 8 章（仅 8.1、8.2） | AC-1、AC-4、AC-6、AC-18 通过 |
| **M0 闸门** | — | 技术可行性确认 | 背景页验证清单 | 上述 AC 在 macOS 15 与 26 上全部通过；实测帧率与延迟记入附录（修订：先以 macOS 27 为准，15/26 后补，见 decisions.md D7；实测记入 `m0-report.md`） |
| K8 | M1 | 配置存储、校验、迁移框架、默认配置 | 第 10 章 | AC-19 通过；迁移函数单测 |
| K9 | M1 | 动作系统全部 M1 类型 | 第 9 章 | 每类动作至少一个集成测试或手工用例通过 |
| K10 | M1 | 浮层完整视觉、显示延迟、轨迹、触觉、连续触发 | 第 8 章、6.5、6.6 | AC-5、AC-7、AC-11、AC-12 通过 |
| K11 | M1 | 按应用布局与继承、黑名单、多设备隔离与停用 | FR-10.7、FR-4.4、FR-4.6 | AC-13、AC-14、AC-15 通过 |
| K12 | M1 | 设置窗口与布局编辑器 | 第 11 章 | 可不改 JSON 完成全部配置 |
| K13 | M1 | 权限检测与首次引导、冲突检测 | 第 12 章 | AC-20 通过 |
| K14 | M1 | 预置模板 4 套、导入导出 | FR-11.11、FR-10.9、FR-9.5 | 模板可用；导入含脚本时逐条确认 |
| K15 | M1 | 本地化、无障碍、性能调优 | NFR-1 至 NFR-5、NFR-12、NFR-13 | 指标全部达标 |
| K16 | M1 | 签名、公证、Sparkle、Homebrew Cask、README（修订：发布证书、DMG 打包与发布流程、更新提示、README，见 decisions.md D3–D5） | 2.1 | 全新 Mac 上通过 Cask 安装并完成引导（修订：通过 DMG 安装） |
| **M1 发布闸门** | — | 公开发布 | 第 14 章 | AC-1 至 AC-20 全部通过；NFR-6、NFR-8、NFR-9 实测达标 |

**给 AI 开发代理的工作规则**

- 每个任务开始前，复述本任务引用的需求编号与完成条件；结束时逐条说明如何满足。
- 规格有歧义或无法实现时，停止该点的实现，在代码中留 `// SPEC-QUESTION:` 注释并在任务总结中列出，不得自行发明行为。
- 不得引入第 2.1 节以外的依赖；不得把任何阈值写成字面量（见 0.3）。
- 私有 API 的每个调用点都要有注释说明符号来源与失败时的降级路径。

## 附录：可调参数总表与待实测项

**下表默认值均为原型前的估计值，M0 闸门时按实测修正并回写本表；"用户可调"列为否的参数只存在于配置文件，不出现在设置界面。**

| 参数 | 默认值 | 允许范围 | 用户可调 | 用途 |
| --- | --- | --- | --- | --- |
| `P.anchorZoneW` | 0.12 | 0.05–0.30 | 是 | 锚定区宽（触控板比例） |
| `P.anchorZoneH` | 0.15 | 0.05–0.30 | 是 | 锚定区高 |
| `P.dwellMs` | 200 ms | 80–600 | 是 | 驻留时长 |
| `P.stillThresholdMM` | 2.0 mm | 0.5–6 | 是 | 驻留期允许位移 |
| `P.palmSize` | 校准值 × 1.5 | 由校准决定 | 校准 | 手掌判定阈值 |
| `P.mappingMargin` | 0.05 | 0–0.15 | 是 | 映射区每边边距（修订：不接受指点指落下的边缘宽度，见 decisions.md D9） |
| `P.mappingScale` | 0.6（修订：0.4，范围 0.3–1.0，见 decisions.md D21） | 0.4–1.0 | 是 | 映射区占触控板的比例，居中（新增，见 decisions.md D9） |
| `P.hysteresis` | 0.02 | 0–0.08 | 是 | 槽位滞回（面板比例） |
| `P.liftLookbackMs` | 60 ms | 0–150 | 否 | 抬起去抖回看时间 |
| `P.panelDelayMs` | 200 ms | 0–600 | 是 | 面板显示延迟 |
| `P.cooldownMs` | 150 ms | 50–500 | 是 | 冷却期 |
| `P.momentumSuppressMs` | 1200 ms | 0–2000 | 否 | 退出后屏蔽惯性滚动的时长 |
| `P.frameTimeoutMs` | 500 ms | 200–2000 | 否 | 激活态无新帧即取消 |
| `P.clockResyncMs` | 50 ms | 10–小于 `P.frameTimeoutMs` | 否 | 一段触摸中帧时间落后超过该值时重新对齐设备时钟（D49、D52） |
| `P.cursorStallLimitMs` | 2000 ms | 500–5000 | 否 | 激活态输入队列无响应超过该值即恢复光标（D50） |
| `P.maxSessionSec` | 30 s | 5–120 | 否 | 单次激活最长时长 |
| `P.actionDelayMs` | 30 ms | 0–200 | 否 | 面板隐藏到执行动作的间隔 |
| `P.smoothing` | 0.5 | 0–1 | 否 | 指示点平滑系数 α |
| `P.panelScale` | 0.6（修订：0.4，见 decisions.md D20、D21） | 0.3–0.9 | 是 | 面板占屏幕可见区域的比例 |
| `P.trailMs` | 300 ms | 0–1000 | 否 | 轨迹保留时长 |
| `P.onboardingHintCount` | 10 次 | 0–50 | 否 | 面板显示操作提示的次数 |
| `P.slotGap` | 6 pt | 0–20 | 否 | 槽位间空隙 |
| `P.minSlotMM` | 12 mm | 8–30 | 否 | 槽位最小物理尺寸（编辑器校验） |

### 待实测项（M0 期间填写结果）

- [ ] 内置板与妙控板持续触摸时的真实帧率
- [ ] 端到端延迟 p95（NFR-1）
- [ ] 后台丢弃指针移动能否完全冻结光标（FR-7.6、FR-7.7）
- [ ] 双指状态下是否有系统行为无法拦截（7.3）
- [ ] 右边缘双指左滑是否误触发通知中心
- [ ] 后台应用调用触觉反馈是否生效（FR-6.14）
- [ ] 与 BetterTouchTool 共存时的拦截顺序
- [ ] 各参数默认值的实测修正
