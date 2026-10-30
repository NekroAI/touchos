#!/usr/bin/env bash
# 生成 Resources/dmg/DS_Store。会打开一个访达窗口，首次运行时系统会询问是否允许控制访达。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"; trap 'hdiutil detach "/Volumes/Nekro TouchOS" -quiet 2>/dev/null || true; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/src/TouchOS.app/Contents"
cp -R "$ROOT/Resources/dmg/.background" "$WORK/src/"
ln -s /Applications "$WORK/src/Applications"
hdiutil create -volname "Nekro TouchOS" -srcfolder "$WORK/src" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg" >/dev/null
hdiutil attach "$WORK/rw.dmg" -quiet
osascript <<'APPLESCRIPT'
tell application "Finder"
  tell disk "Nekro TouchOS"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 200, 860, 628}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "TouchOS.app" of container window to {170, 190}
    set position of item "Applications" of container window to {490, 190}
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT
sleep 1
cp "/Volumes/Nekro TouchOS/.DS_Store" "$ROOT/Resources/dmg/DS_Store"
echo "完成：Resources/dmg/DS_Store"
