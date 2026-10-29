# Contributing to TouchOS

Thanks for your interest! TouchOS is a small project, so the process is light.

## Before you start

- **Bugs:** open an issue with the [bug report template](https://github.com/NekroAI/touchos/issues/new?template=bug_report.yml). Include your macOS version, chip, trackpad model and TouchOS version.
- **Features:** open an issue first so we can agree on the approach. The specification is [`docs/srs.md`](docs/srs.md); decisions and their reasoning are in [`docs/decisions.md`](docs/decisions.md) — please read the relevant entries before proposing a change to something already decided.
- **Security issues:** do not open a public issue. See [SECURITY.md](SECURITY.md).

## Setting up

Requirements: macOS 14+ and the Xcode Command Line Tools (Swift 6). A full Xcode is not required; open `Package.swift` in Xcode if you want Instruments or SwiftUI previews.

```sh
swift test                 # unit tests (TouchOSCore)
scripts/coverage.sh        # tests + line coverage gate for TouchOSCore (≥ 85%)
scripts/build-macos.sh     # dist/TouchOS.app, signed with a local dev certificate
```

`scripts/build-macos.sh` creates a dedicated keychain with a self-signed "TouchOS Dev" certificate so macOS keeps the Accessibility permission across rebuilds. It never touches your login keychain.

## Making changes

- **Keep the core pure.** The state machine and algorithms live in `Sources/TouchOSCore/` and must not import AppKit, CoreGraphics events or private framework types, so they can be tested with synthetic touch frames.
- **No magic numbers.** Every threshold comes from configuration; defaults are listed in the SRS appendix.
- **No new dependencies** without discussing them first.
- **Match the surrounding code.** Design documents in `docs/` are written in Chinese; code comments follow the file you are editing.

## Commits and pull requests

- Write commit messages that say what changed and why.
- One logical change per pull request; include tests for behavior changes.
- CI must pass: build with warnings as errors, tests and the coverage gate.
- By contributing, you agree that your contributions are licensed under GPL-3.0-or-later.

## Code of conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md).
