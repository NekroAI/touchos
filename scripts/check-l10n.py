"""见 scripts/check-l10n.sh。"""
import json, pathlib, plistlib, re, subprocess, sys

root, strings = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])

keys = set()
debug = {p.stem for p in (root / "Sources/TouchOS/Debug").glob("*.swift")}  # 调试界面不翻译
for path in strings.rglob("*.stringsdata"):
    if path.stem in debug:
        continue
    data = json.loads(path.read_text())
    for table in data.get("tables", {}).values():
        keys.update(item["key"] for item in table)

table = plistlib.loads(subprocess.check_output(["plutil", "-convert", "xml1", "-o", "-", str(root / "Resources/en.lproj/Localizable.strings")]))
problems = [f"缺英文译文：{k}" for k in sorted(keys - set(table))]
problems += [f"英文表里多余的键：{k}" for k in sorted(set(table) - keys)]

# 含中文的字面量：把插值替换成占位符后，核对是否被提取
literal = re.compile(r'"((?:[^"\\]|\\.)*[一-鿿](?:[^"\\]|\\.)*)"')
extracted = {re.sub(r"%(?:\d+\$)?(?:lld|ld|d|@|f|\.\df)", "\0", k).replace("%%", "%") for k in keys}  # %% 是字面百分号
for path in sorted((root / "Sources").rglob("*.swift")):
    if "Debug" in path.parts:
        continue
    for n, line in enumerate(path.read_text().splitlines(), 1):
        code = line.split(" // ")[0]
        if "l10n-ignore" in line or code.lstrip().startswith("//") or re.search(r"\blog\.|Logger|fatalError|precondition", code):
            continue
        for text in literal.findall(code):
            normalized = re.sub(r"\\\((?:[^()]|\([^()]*\))*\)", "\0", text)
            if normalized not in extracted:
                problems.append(f"{path.relative_to(root)}:{n} 未进本地化：{text}")

print("\n".join(problems) or f"本地化检查通过：{len(keys)} 个键")
sys.exit(1 if problems else 0)
