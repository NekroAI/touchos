#!/usr/bin/env bash
# 运行单元测试并检查 TouchOSCore 行覆盖率（SRS NFR-15：≥ 85%）。
#   MIN_COVERAGE  覆盖率下限（百分比），默认 85
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MIN_COVERAGE="${MIN_COVERAGE:-85}"

swift test --package-path "$ROOT" --enable-code-coverage -Xswiftc -warnings-as-errors
REPORT="$(swift test --package-path "$ROOT" --show-codecov-path)"

python3 -I - "$REPORT" "$MIN_COVERAGE" <<'PY'
import json, sys
report, minimum = sys.argv[1], float(sys.argv[2])
files = [f for f in json.load(open(report))["data"][0]["files"] if "/Sources/TouchOSCore/" in f["filename"]]
count = sum(f["summary"]["lines"]["count"] for f in files)
covered = sum(f["summary"]["lines"]["covered"] for f in files)
if not files:
    # 报告只列出含可执行代码的文件；TouchOSCore 有了可执行代码后这里必须能匹配到
    print("TouchOSCore 尚无可执行代码，跳过覆盖率检查")
    sys.exit(0)
pct = 100.0 * covered / count
print(f"TouchOSCore 行覆盖率：{pct:.1f}%（{covered}/{count} 行，{len(files)} 个文件），下限 {minimum:g}%")
sys.exit(0 if pct >= minimum else 1)
PY
