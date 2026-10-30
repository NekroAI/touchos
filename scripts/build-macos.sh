#!/usr/bin/env bash
# 构建 macOS 应用：SwiftPM → 组装 .app → 签名（docs/decisions.md D3、D6）。
#
# 环境变量：
#   ARCH           arm64（默认，与本机一致）或 x86_64
#   SIGN_IDENTITY  签名证书名；默认使用本机开发证书 "TouchOS Dev"（scripts/dev-cert.sh），CI 中默认 ad-hoc
#   SIGN_KEYCHAIN  签名证书所在钥匙串；与 SIGN_IDENTITY 一起设置
#   DIST           输出目录，默认 dist/
# 产物：$DIST/TouchOS.app
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="${DIST:-$ROOT/dist}"
# 与 Info.plist 的 LSMinimumSystemVersion 一致
MIN_MACOS=14.0

ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in
  arm64|x86_64) ;;
  *) echo "不支持的 ARCH：$ARCH" >&2; exit 1 ;;
esac
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
echo "==> TouchOS $VERSION ($BUILD_NUMBER) · $ARCH"

echo "==> SwiftPM"
# 零编译警告（SRS NFR-15）
SWIFT_FLAGS=(--triple "$ARCH-apple-macosx$MIN_MACOS" -Xswiftc -warnings-as-errors)
swift build -c release --package-path "$ROOT" --product TouchOS "${SWIFT_FLAGS[@]}"
BIN="$(swift build -c release --package-path "$ROOT" "${SWIFT_FLAGS[@]}" --show-bin-path)"

echo "==> 组装"
APP="$DIST/TouchOS.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/TouchOS" "$APP/Contents/MacOS/TouchOS"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD_NUMBER" \
  "$APP/Contents/Info.plist"

echo "==> 签名"
if [ -z "${SIGN_IDENTITY:-}" ] && [ -n "${CI:-}" ]; then
  # CI 的开发构建只验证能否构建，不涉及辅助功能授权，使用 ad-hoc 签名
  SIGN_IDENTITY="-"
elif [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY="TouchOS Dev"
  SIGN_KEYCHAIN="$HOME/Library/Keychains/touchos-dev.keychain-db"
  "$ROOT/scripts/dev-cert.sh" >/dev/null
  security unlock-keychain -p touchos-dev "$SIGN_KEYCHAIN"
fi
codesign --force --sign "$SIGN_IDENTITY" ${SIGN_KEYCHAIN:+--keychain "$SIGN_KEYCHAIN"} "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "^(Identifier|Authority)=" || true
lipo -archs "$APP/Contents/MacOS/TouchOS"
echo "完成：$APP"
