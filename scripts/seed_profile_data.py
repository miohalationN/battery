#!/usr/bin/env python3
"""为 UI 性能采样生成确定性的历史数据（仅在 CI runner 上使用）。

写入 ~/Library/Application Support/BatteryBar/snapshots.jsonl 与 cycles.json，
覆盖最近 24 小时、60s 一条，包含真实世界中出现过的全部形态：
- 明确离电的估算负载（可信，应保留）
- 接电充电段（wattage=0/不可用，batteryPower>0）
- v2 污染形态：无 externalConnected 键、level>=99、未充电、亮屏、估算 0-3W
  （接电满电保持被旧版误标为可用离电负载 —— 必须被 trustedSystemLoad 排除）
- 接电遥测实测负载（estimated=false，应保留）
- 接电无遥测（available=false，排除）

时间戳使用 JSONEncoder 默认的 timeIntervalSinceReferenceDate（epoch-978307200）。
"""
import json
import os
import random
import sys
import time

REF = 978307200  # epoch -> reference interval
random.seed(20260823)

out_dir = os.path.expanduser("~/Library/Application Support/BatteryBar")
os.makedirs(out_dir, exist_ok=True)
snapshots_path = os.path.join(out_dir, "snapshots.jsonl")
cycles_path = os.path.join(out_dir, "cycles.json")

now = time.time()


def ref(ts_epoch: float) -> float:
    return ts_epoch - REF


def make(ts_epoch, level, charging, wattage, battery_power, available,
         estimated, ext, screen=True, cpu=0.0, gpu=0.0):
    rec = {
        "id": str(__import__("uuid").uuid4()),
        "timestamp": ref(ts_epoch),
        "level": round(level, 2),
        "isCharging": charging,
        "wattage": round(wattage, 2),
        "batteryPower": round(battery_power, 2),
        "systemPowerAvailable": available,
        "systemPowerIsEstimated": estimated,
        "temperature": 30.0,
        "screenOn": screen,
        "cpuPower": cpu,
        "gpuPower": gpu,
        "displayPower": 0.0,
        "dramPower": 0.0,
        "dirty": True,
    }
    # v2 污染形态：externalConnected 键完全缺失；v3 显式写出
    if ext is not None:
        rec["externalConnected"] = ext
    return rec


records = []


def add_block(start_hours_ago, hours, fn):
    n = int(hours * 60)
    for i in range(n):
        ts = now - start_hours_ago * 3600 + i * 60
        if ts > now:
            break
        records.append(make(ts, *fn(i / max(1, n - 1))))


# 24h-20h：明确离电，88%→68%，估算负载 ~9W（可信，应保留）
add_block(24, 4, lambda f: (
    88 - 20 * f, False,
    9 + random.uniform(-1.5, 1.5), 9 + random.uniform(-1.5, 1.5),
    True, True, False))

# 20h-18.5h：接电充电，68%→93%，电池充入 ~28W，系统负载不可用
add_block(20, 1.5, lambda f: (
    68 + 25 * f, True,
    0.0, 28 + random.uniform(-3, 3),
    False, False, True))

# 18.5h-17h：v2 污染块 A（无 ext 键）：96%→99.5%，未充电亮屏，估算 0.5-3W
add_block(18.5, 1.5, lambda f: (
    96 + 3.5 * f, False,
    random.uniform(0.5, 3.0), random.uniform(0.5, 3.0),
    True, True, None))

# 17h-16h：涓流充满：99.5%→100%
add_block(17, 1, lambda f: (
    99.5 + 0.5 * f, True,
    0.0, 6.0,
    False, False, True))

# 16h-8h：v2 污染块 B（无 ext 键）：level=100 未充电亮屏 8 小时，估算 0-3W
# —— 真机上 1129 条误标记录的复刻；必须被 trustedSystemLoad 排除
add_block(16, 8, lambda f: (
    100.0, False,
    random.uniform(0.0, 3.0), random.uniform(0.0, 3.0),
    True, True, None))

# 8h-1h：接电遥测实测负载 ~11.5W（estimated=false，无论电源状态都保留）
add_block(8, 7, lambda f: (
    100.0, False,
    11.5 + random.uniform(-1.0, 1.0), 0.0,
    True, False, True))

# 1h-now：接电无遥测（available=false，排除）
add_block(1, 1.05, lambda f: (
    100.0, False,
    0.0, 0.0,
    False, False, True))

with open(snapshots_path, "w") as f:
    for r in records:
        f.write(json.dumps(r) + "\n")


def cycle(days_ago, dur_h, s_level, e_level):
    import uuid
    start = now - days_ago * 86400
    end = start + dur_h * 3600
    return {
        "id": str(uuid.uuid4()),
        "startDate": ref(start),
        "endDate": ref(end),
        "startLevel": s_level,
        "endLevel": e_level,
        "totalEnergy": s_level - e_level,
        "averageWattage": 8.5,
        "duration": dur_h * 3600,
        "dirty": True,
    }


with open(cycles_path, "w") as f:
    json.dump([
        cycle(2.2, 3.4, 92, 61),
        cycle(1.1, 2.6, 90, 66),
        cycle(0.3, 1.8, 91, 74),
    ], f)

summary = {
    "total_snapshots": len(records),
    "v2_pollution_like": sum(
        1 for r in records
        if "externalConnected" not in r and r["level"] >= 96
        and not r["isCharging"] and r["screenOn"] and r["systemPowerIsEstimated"]
    ),
    "trusted_load_points": sum(
        1 for r in records
        if r["systemPowerAvailable"] and r["wattage"] > 0
        and (not r["systemPowerIsEstimated"] or r.get("externalConnected") is False)
    ),
}
print(json.dumps(summary))
sys.exit(0)
