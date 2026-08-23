#!/usr/bin/env python3
"""从 xctrace 产物中提取可读证据摘要（在 CI runner 上运行）。

用法：profile_digest.py <trace> <output-digest.txt>

退出语义（供 workflow gate 使用，调用方不得用 || true 吞掉非零）：
- trace 不存在：打印 SKIP，退出 0（best-effort 产物允许缺席；
  必需产物的缺席由 profile_page.sh 的非零退出负责）。
- trace 存在但 toc 导出失败或 schema 数为 0：视为损坏，退出 1。
- 正常：写 digest 并退出 0。

策略（对 Instruments 表 schema 名称不做事先假设）：
1. xctrace export --toc 列出全部表；
2. 逐个 schema 尝试导出（多种 xpath 模板兜底），取字节最多的变体；
3. 关键表（swiftui/hitch/tick/runloop）完整转储 XML——
   已知限制：本工具链的 export 只返回表结构不返回行，
   行级 hitch/求值指标需用 Instruments.app 人工打开 trace 判读。
"""
import os
import re
import subprocess
import sys

if len(sys.argv) != 3:
    print("usage: profile_digest.py <trace> <output-digest.txt>", file=sys.stderr)
    sys.exit(2)

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


def fail_unreadable(reason):
    """存在但不可读：写一份说明性 digest 并以非零退出，workflow 必须红。"""
    with open(out_path, "w") as f:
        f.write(f"== trace: {trace} ==\nINVALID: {reason}\n")
    print(f"digest: INVALID ({reason}) -> {out_path}", file=sys.stderr)
    sys.exit(1)


if not os.path.exists(trace):
    with open(out_path, "w") as f:
        f.write(f"== trace: {trace} ==\nSKIP: trace not produced (best-effort)\n")
    print(f"digest: SKIP (not produced) -> {out_path}")
    sys.exit(0)

lines = [f"== trace: {trace} =="]

toc = run(["xcrun", "xctrace", "export", "--input", trace, "--toc"])
lines.append("-- toc (head) --")
lines.extend(toc.stdout.splitlines()[:60])
if toc.returncode != 0:
    lines.append(f"toc stderr: {toc.stderr[:2000]}")

schemas = sorted(set(re.findall(r'schema="([A-Za-z0-9_.-]+)"', toc.stdout)))
lines.append(f"-- schemas ({len(schemas)}) --")
lines.append(", ".join(schemas))

if toc.returncode != 0 or len(schemas) == 0:
    fail_unreadable(f"toc rc={toc.returncode}, schemas={len(schemas)}")

# 优先导出与目标相关的表，控制导出耗时；找不到再退回全量
priority = [x for x in schemas if re.search(r"swiftui|hitch|animation|view|render", x, re.I)]
others = [x for x in schemas if x not in priority]
export_order = priority + (others if not priority else [])

interesting = {}
hitch_rows = []
body_rows_total = 0

for s in export_order[:16]:
    variants = [tpl.format(s=s) for tpl in XPATH_TEMPLATES]
    variants.append(f'/trace-toc/run[@number="1"]/data/table[@schema="{s}"]/row')
    variants.append(f'//table[@schema="{s}"]/row')
    best = ""
    best_xp = ""
    for xp in variants:
        r = run(["xcrun", "xctrace", "export", "--input", trace, "--xpath", xp])
        if r.returncode == 0 and len(r.stdout) > len(best):
            best = r.stdout
            best_xp = xp
    if not best:
        continue
    lines.append(f"[{s}] best xpath={best_xp} bytes={len(best)}")
    # 关键表直接完整转储（已知限制：本工具链只导出表结构不导出行）
    if re.search(r"swiftui|hitch|tick|runloop", s, re.I):
        lines.append(f"[{s}] FULL-BEGIN")
        lines.append(best[:24000])
        lines.append(f"[{s}] FULL-END")
    if "hitch" in s.lower():
        for m in re.finditer(r"<row[^>]*>.*?</row>|<row[^>]*/>", best, re.S):
            hitch_rows.append(m.group(0)[:500])
    for view in VIEW_NAMES:
        c = best.count(view)
        if c:
            interesting[f"{view}@{s}"] = c
    body_rows_total += best.count("<row")

lines.append("-- view name occurrences (view@schema -> count) --")
for k, v in sorted(interesting.items()):
    lines.append(f"{k}: {v}")
lines.append(f"approx total rows in view-ish tables: {body_rows_total}")

lines.append(f"-- hitch rows captured by CLI export: {len(hitch_rows)} "
             f"(行级指标需 Instruments.app 人工判读，见 HANDOFF 限制) --")
for h in hitch_rows[:80]:
    lines.append(h)

with open(out_path, "w") as f:
    f.write("\n".join(lines))
print(f"digest written to {out_path}, lines={len(lines)}, schemas={len(schemas)}")
sys.exit(0)
