<h1 align="center">Nekro TouchOS</h1>

<p align="center">
  <strong>触控板上的可视化快捷面板。唤起面板，手指在触控板上的位置直接指向按钮，抬起即执行。</strong>
</p>

<p align="center">
  <a href="https://github.com/NekroAI/touchos/releases/latest">下载</a> ·
  <a href="docs/install.md#安装-nekro-touchos">安装说明</a> ·
  <a href="README.md">English</a>
</p>

<p align="center">
  <a href="https://github.com/NekroAI/touchos/actions/workflows/ci.yml"><img src="https://github.com/NekroAI/touchos/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey" alt="Platform: macOS 14+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0--or--later-blue" alt="License: GPL-3.0-or-later"></a>
</p>

> **状态：0.0.1 预览版。** 可以日常使用，但目前只在妙控板 + macOS 27 上测试过。内置触控板、Intel Mac、较旧的 macOS 尚未测试，欢迎反馈。

## 为什么

触控板手势工具要你记几十种划法。TouchOS 把按钮直接摆在眼前：触控板与屏幕上的面板一一对应，看着选，不用记。

## 用法

1. **单指轻点一下，紧接着按住**：第二下落下时，屏幕中央就出现一组悬浮按钮，光标停在原处。
2. **不松手，移动这根手指**：手指在触控板上的位置直接对应面板，高亮所在按钮。熟练之后，触控板上的位置就是按钮本身。
3. **抬起即执行**；或者按下触控板执行并保留面板，接着再选。移到面板外抬起则取消。

面板打开时：

- **双指上下滑动**：在多个面板之间切换，跟手、可中途打断。
- **双指捏合**：总览全部面板，指向一个后抬起即打开。
- **在正中的关闭按钮上按住**：圆环充满后进入编辑。

除此之外，TouchOS 只旁听，不改变触控板、鼠标、键盘的任何行为。

## 功能

- **自己设计面板**：面板数量不限，网格排布（按钮可占 1×1、2×1、1×2、2×2）或环形。在设置中可视化编辑：点空格添加，拖动移动或互换，拖右下角调整大小。格子大小固定，行列少的面板在屏幕上更小，在触控板上占的范围也更小。
- **动作**：快捷键、输入任意文字或符号、打开应用 / 网址 / 文件、Shell 命令、AppleScript、快捷指令、媒体与系统控制（音量、亮度、锁屏、调度中心、截屏）、窗口摆放；横向或竖向的滑杆，滑动时实时生效，在滑杆上抬起保留，移开则恢复。
- **唤起方式**：轻点后按住（默认）、四指轻点（默认）、三指轻点、一指按住或轻点两下触控板的某个角，可以同时开启多种，每种打开各自绑定的面板。设置里按实际比例画出触控板分区，调整时实时预览。建议关闭系统的「轻点来点按」，否则轻点后按住的第一下会先点一次鼠标。
- **主题**：玻璃圆钮（默认）、液态光斑、全息线框；强调色自选；面板切换动画可选深度堆叠或立体滚筒，自由组合。
- **纯文本配置**：`~/Library/Application Support/TouchOS/config.json`，自动备份、校验、导入导出；导入的脚本会逐条展示，确认后才生效。
- **排除应用**：指定应用在前台时自动暂停。

## 安装

在 [Releases](https://github.com/NekroAI/touchos/releases/latest) 下载 DMG：Apple 芯片选 `macOS-arm64`，Intel 芯片选 `macOS-x64`。打开后把 **TouchOS** 拖进「应用程序」。需要 macOS 14 及以上，以及力度触控板（内置，或妙控板第二代及以后）。

TouchOS 未经 Apple 公证，首次打开会被拦截：到 **系统设置 → 隐私与安全性** 点 **仍要打开**。随后跟随引导授予「辅助功能」权限。详见[安装说明](docs/install.md#安装-nekro-touchos)。

## 隐私

TouchOS 通过 macOS 私有框架读取触控板原始触点。触点只在内存中处理，从不记录、存储或上传；TouchOS 不发起任何网络请求。

## 从源码构建

见 [CONTRIBUTING.md](CONTRIBUTING.md)。设计文档在 [`docs/`](docs/README.md)。

## 许可证

[GPL-3.0-or-later](LICENSE)
