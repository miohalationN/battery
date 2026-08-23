#!/bin/bash
# 在带完整 Xcode 的 macOS runner 上打开两页 Animation Hitches trace，
# 保存可供 assurance agent 人工判读的 Instruments 屏幕截图。
#
# 用法：capture_trace_review.sh [trace-root] [output-root]
# 默认读取 /tmp/{usage,power}-hitches.trace，输出到 /tmp/trace-review。
set -euo pipefail

TRACE_ROOT="${1:-/tmp}"
OUTPUT_ROOT="${2:-/tmp/trace-review}"
INSTRUMENTS_APP="/Applications/Xcode.app/Contents/Applications/Instruments.app"

if [ ! -d "$INSTRUMENTS_APP" ]; then
  echo "Instruments.app not found: $INSTRUMENTS_APP" >&2
  exit 1
fi

mkdir -p "$OUTPUT_ROOT"

capture_page() {
  local page="$1"
  local trace="$TRACE_ROOT/${page}-hitches.trace"
  if [ ! -e "$trace" ]; then
    echo "required trace missing: $trace" >&2
    return 1
  fi

  killall Instruments 2>/dev/null || true
  open -na "$INSTRUMENTS_APP" "$trace"

  local ready=false
  for _ in $(seq 1 30); do
    if pgrep -x Instruments >/dev/null; then
      ready=true
      break
    fi
    sleep 1
  done
  if [ "$ready" != true ]; then
    echo "Instruments failed to launch for $trace" >&2
    return 1
  fi

  # 大 trace 初次打开需完成索引/分析。分时截图既保留加载现场，也提高拿到
  # 完整 Hitches 表格的概率；任一截图失败都视为本页视觉取证失败。
  local delay
  for delay in 15 30 45; do
    sleep 15
    osascript -e 'tell application "Instruments" to activate' || true
    local shot="$OUTPUT_ROOT/${page}-instruments-${delay}s.png"
    /usr/sbin/screencapture -x "$shot"
    test -s "$shot"
    sips -g pixelWidth -g pixelHeight "$shot" | tail -n 2
  done

  killall Instruments 2>/dev/null || true
}

capture_page usage
capture_page power

ls -lh "$OUTPUT_ROOT"/*.png
