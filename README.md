<h1 align="center">Nekro TouchOS</h1>

<p align="center">
  <strong>A visual shortcut panel for your Mac trackpad. Summon a panel, point at a button by where your finger is on the trackpad, lift to run it.</strong>
</p>

<p align="center">
  <a href="https://github.com/NekroAI/touchos/releases/latest">Download</a> ·
  <a href="docs/install.md">Install guide</a> ·
  <a href="README.zh-CN.md">中文</a>
</p>

<p align="center">
  <a href="https://github.com/NekroAI/touchos/actions/workflows/ci.yml"><img src="https://github.com/NekroAI/touchos/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey" alt="Platform: macOS 14+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0--or--later-blue" alt="License: GPL-3.0-or-later"></a>
</p>

> **Status: 0.0.1 preview.** Usable day to day, but so far tested only on a Magic Trackpad with macOS 27. Built-in trackpads, Intel Macs and older macOS versions are untested — reports welcome.

## Why

Trackpad gesture tools make you memorize dozens of swipes. TouchOS shows you the buttons instead: the trackpad becomes an absolute map of the panel on screen, so you look and pick rather than recall.

## How it works

1. **Tap the trackpad with four fingers.** A panel of floating buttons appears in the middle of the screen and the cursor stays put.
2. **Move one finger.** Its position on the trackpad maps directly onto the panel and highlights a button.
3. **Lift to run it.** Or click (press the trackpad) to run it and keep the panel open for another. Lift outside the panel to cancel.

Inside an open panel:

- **Two fingers up / down** switch between your panels, following your fingers one to one with springy, interruptible motion.
- **Pinch** shows every panel at once; point at one and lift to open it.
- **Press and hold the close button** in the middle until the ring fills to open the editor.

Outside that gesture TouchOS only listens: it never changes how your trackpad, mouse or keyboard behave.

## Features

- **Panels you design** — any number of panels, laid out as a grid with 1×1, 2×1, 1×2 and 2×2 buttons, or as a ring. Edit them visually in Settings: click an empty cell to add, drag to move, drag the corner to resize.
- **Actions** — keyboard shortcuts, open an app / URL / file, shell commands, AppleScript, Shortcuts, media and system controls (volume, brightness, lock, Mission Control, screenshots), window placement, and live sliders.
- **Triggers** — four-finger tap (default), three-finger tap, or holding / double-tapping a trackpad corner. Each trigger opens the panel you bind to it.
- **Themes** — Glass orbs (default), Liquid lens or Holo wireframe, with your own accent color and a depth-stack or drum transition — mix freely.
- **Plain JSON config** — `~/Library/Application Support/TouchOS/config.json`, with automatic backups, validation and import / export. Imported scripts are shown to you before anything runs.
- **Exclude apps** — pause TouchOS while specific apps are in front.

## Install

Download the DMG from [Releases](https://github.com/NekroAI/touchos/releases/latest) — `macOS-arm64` for Apple silicon, `macOS-x64` for Intel — open it and drag **TouchOS** into Applications. Requires macOS 14 or later and a Force Touch trackpad (built-in, or Magic Trackpad 2 or later).

TouchOS isn't notarized by Apple, so macOS blocks the first launch: open **System Settings → Privacy & Security** and click **Open Anyway**. The welcome guide then walks you through allowing Accessibility. Details in the [install guide](docs/install.md).

## Privacy

TouchOS reads raw trackpad contacts through a private macOS framework. Contacts are processed in memory only — never logged, stored or uploaded. TouchOS makes no network requests.

## Build from source

See [CONTRIBUTING.md](CONTRIBUTING.md). Design documents (in Chinese) live in [`docs/`](docs/README.md).

## License

[GPL-3.0-or-later](LICENSE)
