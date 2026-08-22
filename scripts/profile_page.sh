#!/bin/bash
# 在 CI runner 上对一个页面做 Instruments 采样：
#   scripts/profile_page.sh usage|power
# 每个页面产出两份 trace：
#   <page>-swiftui.trace  —— SwiftUI 模板（视图 body 求值证据）
#   <page>-hitches.trace  —— Animation Hitches / Core Animation（掉帧证据）
# 时间线：启动 → 静止采样窗(~12s，验证每秒采样不重建根/Chart) → 自动滚动(~50s)。
set -euo pipefail

PAGE="$1"
OUT="/tmp"
TEMPLATES=$(xcrun xctrace list templates 2>/dev/null || true)
echo "$TEMPLATES"

pick_template() {
  # 按候选顺序挑第一个存在的模板
  for candidate in "$@"; do
    if echo "$TEMPLATES" | grep -q "$candidate"; then
      echo "$candidate"
      return
    fi
  done
  echo ""
}

SWIFTUI_TPL=$(pick_template "SwiftUI" "Time Profiler")
HITCH_TPL=$(pick_template "Animation Hitches" "Hitches" "Core Animation FPS" "Time Profiler")
echo "swiftui template: $SWIFTUI_TPL ; hitches template: $HITCH_TPL"

launch_app() {
  killall BatteryBar 2>/dev/null || true
  sleep 2
  defaults delete com.batterybar.app BatteryBarProfileSection 2>/dev/null || true
  if [ "$PAGE" = "power" ]; then
    defaults write com.batterybar.app BatteryBarProfileSection -string "power"
  fi
  defaults write com.batterybar.app BatteryBarProfileAutoScroll -bool true
  open ~/Applications/BatteryBar.app
  sleep 6
}

record() {
  local tpl="$1" limit="$2" out="$3"
  if [ -z "$tpl" ]; then
    echo "!! no template available, skip $out" && return 0
  fi
  xcrun xctrace record --template "$tpl" --attach BatteryBar --time-limit "${limit}s" --output "$out" 2>&1 | tail -3 || true
}

# ---- 第一遍：SwiftUI body 求值（含静止窗 + 滚动窗）----
launch_app
record "$SWIFTUI_TPL" 75 "$OUT/$PAGE-swiftui.trace"

# ---- 第二遍：掉帧/hitch ----
launch_app
record "$HITCH_TPL" 65 "$OUT/$PAGE-hitches.trace"

killall BatteryBar 2>/dev/null || true
ls -la "$OUT"/$Page-*.trace 2>/dev/null || ls -la "$OUT" | grep trace || true
