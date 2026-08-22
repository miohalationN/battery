#!/usr/bin/env python3
"""从 xctrace 产物中提取可读证据摘要（在 CI runner 上运行）。

用法：profile_digest.py <trace> <output-digest.txt>

策略（对 Instruments 表 schema 名称不做事先假设）：
1. xctrace export --toc 列出全部表；
2. 逐个 schema 尝试导出（多种 xpath 模板兜底）；
3. 在导出的 XML 中统计 SwiftUI 视图 body 求值相关行、hitch 行；
4. 汇总视图名计数与 hitch 数量/时长。
"""
import re
import subprocess
import sys
from collections import Counter

trace = sys.argv[1]
out_path = sys.argv[2]

VIEW_NAMES = [
    "UsageTab", "PowerTab", "StatusHero", "SessionTrendCard", "SessionChartPlot",
    "HealthMetricsGrid", "BatteryDetailSection", "LiveReadoutsRow",
    "PowerLoadHero", "ComponentBreakdownCard", "PowerChartPlot",
    "AdvancedSamplingCard", "CycleTab", "PopoverView",
]

XPATH_TEMPLATES = [
    '/trace-toc/run[@number="1"]/data/table[@schema="{s}"]',
    '/trace-toc/run/data/table[@schema="{s}"]',
    '//table[@schema="{s}"]',
]


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, errors="replace")


lines = []
lines.append(f"== trace: {trace} ==")

toc = run(["xcrun", "xctrace", "export", "--input", trace, "--toc"])
lines.append("-- toc (head) --")
lines.extend(toc.stdout.splitlines()[:60])
if toc.returncode != 0:
    lines.append(f"toc stderr: {toc.stderr[:2000]}")

schemas = sorted(set(re.findall(r'schema="([A-Za-z0-9_.-]+)"', toc.stdout)))
lines.append(f"-- schemas ({len(schemas)}) --")
lines.append(", ".join(schemas))

interesting = Counter()
hitch_rows = []
body_rows_total = 0

for s in schemas:
    exported = ""
    for tpl in XPATH_TEMPLATES:
        xp = tpl.format(s=s)
        r = run(["xcrun", "xctrace", "export", "--input", trace, "--xpath", xp])
        if r.returncode == 0 and len(r.stdout) > 200:
            exported = r.stdout
            break
    if not exported:
        continue

    tag = f"table:{s}"
    n = len(exported)
    lines.append(f"[{tag}] exported {n} bytes")

    low = exported.lower()
    if "hitch" in s.lower() or "hitch" in low:
        # 抽取含 hitch 的行，带时间/时长属性
        for m in re.finditer(r"<row[^>]*>.*?</row>|<row[^>]*/>", exported, re.S):
            row = m.group(0)
            if "hitch" in row.lower():
                hitch_rows.append(row[:500])
    for view in VIEW_NAMES:
        c = exported.count(view)
        if c:
            interesting[f"{view}@{s}"] = c
    if any(k in s.lower() for k in ("swiftui", "view", "body")):
        body_rows_total += exported.count("<row")

lines.append("-- view name occurrences (view@schema -> count) --")
for k, v in sorted(interesting.items()):
    lines.append(f"{k}: {v}")
lines.append(f"approx total rows in view-ish tables: {body_rows_total}")

lines.append(f"-- hitch rows captured: {len(hitch_rows)} --")
for h in hitch_rows[:80]:
    lines.append(h)

with open(out_path, "w") as f:
    f.write("\n".join(lines))
print(f"digest written to {out_path}, lines={len(lines)}")
