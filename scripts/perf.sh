#!/usr/bin/env bash
# 浮层性能测量（D28）：触发一段浮层预演并用 Instruments 录 6 秒，打印统计，然后删除录制产物。
#   scripts/perf.sh <预演脚本> [--profile]
#   预演脚本：navigate、reopen、cancel 等（见 CLAUDE.md「浮层预演」，需调试叠层可用、TouchOS 在运行）
#   默认模板 Animation Hitches：卡顿次数与每帧合成耗时；--profile 改用 Time Profiler：主线程忙碌毫秒数
#   SECONDS_LIMIT  录制时长（秒），默认 6；LEAD  开始录制到触发预演的间隔（秒），默认 1.5
# 每次录制会在 $TMPDIR 留下约 6 GB 的 instruments*.ktrace：只删除本次新增的，中断或出错也会删除
set -euo pipefail
SCRIPT="${1:?用法：scripts/perf.sh <预演脚本> [--profile]}"
KIND=hitch
TEMPLATE="Animation Hitches"
if [[ "${2:-}" == "--profile" ]]; then KIND=profile; TEMPLATE="Time Profiler"; fi
SECONDS_LIMIT="${SECONDS_LIMIT:-6}"
LEAD="${LEAD:-1.5}"
TMP="${TMPDIR:-/tmp}"
TMP="${TMP%/}"

pgrep -x TouchOS >/dev/null || { echo "TouchOS 没有运行" >&2; exit 1; }

WORK="$(mktemp -d "$TMP/touchos-perf.XXXXXX")"
BEFORE="$WORK/before.txt"
( shopt -s nullglob; for f in "$TMP"/instruments*.ktrace; do echo "$f"; done ) >"$BEFORE"

cleanup() {
    shopt -s nullglob
    for f in "$TMP"/instruments*.ktrace; do
        grep -qxF "$f" "$BEFORE" || rm -rf "$f"
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

TRACE="$WORK/run.trace"
( sleep "$LEAD"; notifyutil -p "ai.nekro.touchos.simulate.$SCRIPT" ) &
xcrun xctrace record --template "$TEMPLATE" --attach TouchOS --time-limit "${SECONDS_LIMIT}s" --output "$TRACE" >/dev/null 2>&1
wait

python3 -I - "$TRACE" "$KIND" "$SCRIPT" <<'PY'
import sys, subprocess, statistics as st, xml.etree.ElementTree as ET
trace, kind, script = sys.argv[1:4]

def table(schema):
    xml = subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath",
                          f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'],
                         capture_output=True, check=True).stdout
    root = ET.fromstring(xml)
    cols = [c.find("mnemonic").text for c in root.iter("col")]
    ids, rows = {}, []
    for r in root.iter("row"):
        row = {}
        for name, c in zip(cols, list(r)):
            for e in c.iter():
                if e.get("id"):
                    ids[e.get("id")] = e
            row[name] = ids.get(c.get("ref"), c) if c.get("ref") else c
        rows.append(row)
    return rows

def pct(values, p):
    return values[min(len(values) - 1, int(len(values) * p))]

if kind == "hitch":
    renders = sorted(int(r["duration"].text) / 1e6 for r in table("hitches-renders"))
    hitches = len(table("hitches"))
    if not renders:
        sys.exit("没有采到合成数据（预演是否触发？调试叠层是否可用？）")
    print(f"{script}: 卡顿 {hitches} | 合成 {len(renders)} 帧，中位 {st.median(renders):.1f} "
          f"p90 {pct(renders, .9):.1f} p99 {pct(renders, .99):.1f} ms")
else:
    rows = table("time-profile")
    main = sum(1 for r in rows if "Main Thread" in (r["thread"].get("fmt") or ""))
    print(f"{script}: 主线程 {main} ms | 全部采样 {len(rows)}")
PY
