# Changelog

All notable changes to this project are documented here. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.5] - 2026-10-31

### Changed
- The cursor is now hidden while a panel is open, with the panel's pointer dot standing in for it. A new General setting can keep it visible instead, though it may then follow your finger on some Macs.
- Debug tools now have a single switch, Debug Mode, at the bottom of General. It takes effect immediately and shows the debug overlay, which holds all debug actions; the menu bar no longer has debug items.

### Fixed
- The on-screen cursor could follow the finger while a panel was open. The fix in 0.1.3 only worked while TouchOS was the frontmost app.
- Lift timing could be off on built-in trackpads, a side effect of the clock fix in 0.1.3.

## [0.1.4] - 2026-10-30

### Added
- Debug Tools: an in-memory diagnostic log with clear, mark and copy commands in the menu. It contains no touch or cursor coordinates.

### Known issues
- The on-screen cursor can still follow the finger while a panel is open; the 0.1.3 fix does not hold in all cases. Still under investigation.

## [0.1.3] - 2026-10-30

### Fixed
- The on-screen cursor could follow the finger while a panel was open. The cursor is now disassociated from the mouse during a session and restored afterwards, including when input stalls or the Mac sleeps.
- Panels could close immediately on every summon until the app was restarted, after the trackpad's clock fell out of step (seen after switching a KVM).

## [0.1.2] - 2026-10-30

### Added
- Debug Tools: choose how the cursor is frozen while a panel is open, to diagnose a report of the on-screen cursor still following the finger.

## [0.1.1] - 2026-10-30

### Added
- Debug Tools switch on the About page, with cursor diagnostics in the debug overlay.

### Fixed
- Empty panel thumbnails in the Settings sidebar.
- The cursor check now also uses the on-screen cursor position; a report of the cursor moving while a panel is open is still under investigation.

## [0.1.0] - 2026-10-30

### Added
- English and Simplified Chinese interface; language is chosen on first launch and can be changed in Settings.
- Update notice: a once-a-day check of GitHub Releases, shown in the menu. Can be turned off in Settings.
- Menu bar icon dims while paused.
- Drag-to-install window in the DMG.
- Project skeleton: menu bar app, `TouchOSCore` package, CI with tests and a coverage gate.
