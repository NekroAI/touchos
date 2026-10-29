# Nekro TouchOS

[简体中文](README.zh-CN.md)

**A visual shortcut panel for your Mac trackpad.** Rest one finger on a corner of the trackpad and a panel appears; move another finger to pick a slot by its position on the trackpad, and lift to run the action. You look and pick instead of memorizing gestures.

> **Status: early development (M0 technical prototype).** Nothing is ready to install yet.

## How it will work

1. Hold your thumb still in the bottom-left corner of the trackpad. The cursor freezes and the panel fades in.
2. Move another finger on the trackpad. Its position maps directly onto the panel and highlights a slot.
3. Lift that finger to run the slot's action — a keyboard shortcut, opening an app or URL, a shell command, AppleScript, a Shortcut or a system control. Lift your thumb first to cancel.

Outside that gesture, TouchOS only listens: it never changes how your trackpad, mouse or keyboard behave.

## Requirements

macOS 14 or later, with a Force Touch trackpad (built-in) or Magic Trackpad 2 or later.

## Privacy

TouchOS reads raw trackpad contacts through a private macOS framework. Contacts are processed in memory only — never logged, stored or uploaded.

## Documentation

Design documents live in [`docs/`](docs/README.md). To build from source, see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[GPL-3.0-or-later](LICENSE)
