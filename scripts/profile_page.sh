#!/bin/bash
# 在 CI runner 上对一个页面做 Instruments 采样：
#   scripts/profile_page.sh usage|power
#
# 产物与验收语义：
#   <page>-hitches.trace  —— 必需取证：不可读/零 schema 视为步骤失败（非零退出）
#   <page>-swiftui.trace  —— 尽力取证：失败仅告警，不阻断
#
# trace 有效判定（两条件同时满足）：
#   1) 路径存在（Instruments trace 是目录包，用 -e 而不是 -f）；
#   2) `xcrun xctrace export --input <trace> --toc` 命令成功且输出含 ≥1 个 schema=" 条目。
# 无效 trace 删除后重试（最多 3 次）；必需取证三次仍失败 → 非零返回，不固定成功。
set -euo pipefail

PAGE="${1:-}"
case "$PAGE" in
  usage|power) ;;
  *) echo "usage: $0 usage|power" >&2; exit 2 ;;
esac

OUT_ROOT="/tmp"

# 允许清理的路径白名单：必须位于 /tmp 且文件名完全匹配预期产物
is_managed_trace_path() {
  case "$1" in
    /tmp/usage-swiftui.trace|/tmp/usage-hitches.trace|\
/tmp/power-swiftui.trace|/tmp/power-hitches.trace) return 0 ;;
    *) return 1 ;;
  esac
}

remove_stale_trace() {
  local p="$1"
  if ! is_managed_trace_path "$p"; then
    echo "!! refusing to remove unexpected path: $p" >&2
    exit 2
  fi
  rm -rf -- "$p"
}

# trace 有效性：存在（目录包）且 toc 导出成功且包含 schema
validate_trace() {
  local p="$1"
  [ -e "$p" ] || return 1
  local toc
  toc="$(mktemp)"
  local rc=1
  if xcrun xctrace export --input "$p" --toc > "$toc" 2>/dev/null \
     && grep -q 'schema="' "$toc"; then
    rc=0
  fi
  rm -f "$toc"
  return $rc
}

pick_template() {
  local templates="$1"
  shift
  local candidate
  for candidate in "$@"; do
    if echo "$templates" | grep -q "$candidate"; then
      echo "$candidate"
      return
    fi
  done
  echo ""
}

launch_app() {
  killall BatteryBar 2>/dev/null || true
  sleep 2
  defaults delete com.batterybar.app BatteryBarProfileSection 2>/dev/null || true
  if [ "$PAGE" = "power" ]; then
    defaults write com.batterybar.app BatteryBarProfileSection -string "power"
  fi
  defaults write com.batterybar.app BatteryBarProfileAutoScroll -bool true
  open ~/Applications/BatteryBar.app
  # 等待进程真正可 attach，最多 15s
  for _ in $(seq 1 15); do
    pgrep -x BatteryBar >/dev/null && break
    sleep 1
  done
  sleep 8
}

# 单次录制：xctrace 偶发挂起（attach 或保存阶段），看门狗限时强杀
record_once() {
  local tpl="$1" limit="$2" out="$3"
  xcrun xctrace record --template "$tpl" --attach BatteryBar --time-limit "${limit}s" --output "$out" &
  local pid=$!
  (
    sleep $((limit + 180))
    kill -9 "$pid" 2>/dev/null || true
  ) &
  local watchdog=$!
  set +e
  wait "$pid"
  local rc=$?
  set -e
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  return $rc
}

# record <template> <time_limit_s> <kind> <required>
# kind ∈ swiftui|hitches；产物路径固定为 /tmp/<PAGE>-<kind>.trace
record() {
  local tpl="$1" limit="$2" kind="$3" required="$4"
  local out="${OUT_ROOT}/${PAGE}-${kind}.trace"
  if ! is_managed_trace_path "$out"; then
    echo "!! unexpected product path: $out" >&2
    return 2
  fi
  if [ -z "$tpl" ]; then
    echo "!! no usable template for $kind"
    [ "$required" = "required" ] && return 1 || return 0
  fi

  remove_stale_trace "$out"
  local attempt
  for attempt in 1 2 3; do
    echo "--- record attempt $attempt: $tpl -> $out ---"
    launch_app
    record_once "$tpl" "$limit" "$out" || echo "recording exited rc=$?"
    if validate_trace "$out"; then
      echo "trace accepted: $out"
      return 0
    fi
    echo "trace invalid: $out (missing/unreadable/no schema), removing and retrying"
    remove_stale_trace "$out"
    pkill -9 xctrace 2>/dev/null || true
  done

  if [ "$required" = "required" ]; then
    echo "!! REQUIRED trace failed after 3 attempts: $out" >&2
    return 1
  fi
  echo "best-effort trace unavailable after 3 attempts: $out (tolerated)"
  return 0
}

main() {
  local templates
  templates="$(xcrun xctrace list templates 2>/dev/null || true)"
  echo "$templates"
  local swiftui_tpl hitches_tpl
  swiftui_tpl="$(pick_template "$templates" "SwiftUI" "Time Profiler")"
  # 必需的 Hitches 取证不得回退到通用采样模板（如 Time Profiler）：
  # 那样产物不含 hitch/FPS 表，却能在“存在任意 schema”校验下绿色通过。
  # 候选仅限真正的 hitch 模板；不可用则 record 对必需语义返回非零。
  hitches_tpl="$(pick_template "$templates" "Animation Hitches" "Hitches" "Core Animation FPS")"
  echo "swiftui template: $swiftui_tpl ; hitches template: ${hitches_tpl:-<none>}"

  # 尽力取证：SwiftUI body 求值
  record "$swiftui_tpl" 75 "swiftui" best-effort
  # 必需取证：掉帧/hitch
  if ! record "$hitches_tpl" 65 "hitches" required; then
    echo "!! page [$PAGE] failed: required hitches trace could not be produced" >&2
    exit 1
  fi

  killall BatteryBar 2>/dev/null || true
  ls -la "$OUT_ROOT"/"$PAGE"-*.trace 2>/dev/null || true
}

# 仅直接执行时运行 main；被测试 harness source 时不执行
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
