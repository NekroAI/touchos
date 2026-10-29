#!/usr/bin/env bash
# 正式打包：构建 + DMG（TouchOS.app 与「应用程序」快捷方式），见 docs/decisions.md D3、D4。
#   ARCH=arm64|x86_64 SIGN_IDENTITY=… SIGN_KEYCHAIN=… scripts/package-macos.sh
# 产物：dist/release/TouchOS-<版本>-macOS-<arm64|x64>.dmg
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="${ARCH:-$(uname -m)}"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
OUT="$ROOT/dist/release"
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT

DIST="$STAGE/build" ARCH="$ARCH" "$ROOT/scripts/build-macos.sh"

case "$ARCH" in arm64) LABEL=arm64 ;; x86_64) LABEL=x64 ;; *) echo "不支持的架构：$ARCH" >&2; exit 1 ;; esac
mkdir -p "$OUT" "$STAGE/dmg"
DMG="$OUT/TouchOS-$VERSION-macOS-$LABEL.dmg"
rm -f "$DMG"
cp -R "$STAGE/build/TouchOS.app" "$STAGE/dmg/"
ln -s /Applications "$STAGE/dmg/Applications"
hdiutil create -volname "Nekro TouchOS $VERSION" -srcfolder "$STAGE/dmg" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
# DMG 本身不签名：没有 Developer ID 时 Gatekeeper 仍会拦截一次；应用本体已用发布证书签名
shasum -a 256 "$DMG"
echo "完成：$DMG"
