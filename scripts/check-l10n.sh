#!/usr/bin/env bash
# 检查本地化（NFR-12，D45）：
#  1. 编译器提取到的每个键（LocalizedStringKey、String(localized:)）都有英文译文；英文表里没有多余的键
#  2. 代码里每个含中文的字符串字面量都进了提取结果，或者显式声明不翻译（行尾 // l10n-ignore），Debug 目录与日志除外
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
swift build --package-path "$ROOT" --scratch-path "$OUT/build" --product TouchOS \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT/strings" >/dev/null
python3 -I "$ROOT/scripts/check-l10n.py" "$ROOT" "$OUT/strings"
