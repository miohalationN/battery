#!/bin/bash
# 本地门禁（CLT-only 环境；完整 SwiftUI build+test 由 GitHub Build 承担）：
#   1. 全源 swiftc -parse
#   2. 非视图 Swift 源 + 全部测试 合成单模块 -typecheck -swift-version 6
#      （测试文件的 @testable import 行被剥除——同一模块内直接可见）
#   3. Helper 构建（swift build --target BatteryBarHelper，不安装、不触碰系统服务）
set -euo pipefail
cd "$(dirname "$0")/.."

CLT_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
CLT_TESTING_PLUGIN="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"

echo "== 1/3 swiftc -parse（全部源与测试） =="
find Sources Tests -name '*.swift' -print0 | xargs -0 swiftc -parse

echo "== 2/3 Swift 6 typecheck（非视图源 + 测试 单模块） =="
NON_VIEW_SOURCES=$(find Sources/TelemetryCore Sources/BatteryBar \
    -name '*.swift' ! -path '*/Views/*' ! -path '*/MenuBar/*' ! -path '*/App/*' | sort)
APP_BRAND="Sources/BatteryBar/App/AppBrand.swift"
TEST_SOURCES=$(find Tests -name '*.swift' | sort)

STRIPPED_DIR=".build/gate-stripped-tests"
rm -rf "$STRIPPED_DIR"
mkdir -p "$STRIPPED_DIR"
for f in $TEST_SOURCES; do
    grep -v -e '^@testable import ' -e '^import TelemetryCore$' "$f" > "$STRIPPED_DIR/$(basename "$f")"
done

# shellcheck disable=SC2086
swiftc -typecheck -swift-version 6 \
    -F "$CLT_FRAMEWORKS" \
    $( [ -f "$CLT_TESTING_PLUGIN" ] && echo "-load-plugin-library $CLT_TESTING_PLUGIN" ) \
    $NON_VIEW_SOURCES $APP_BRAND \
    "$STRIPPED_DIR"/*.swift

echo "== 2b/3 Release 级编译（WMO 触发 SIL 独占访问等诊断，与 CI 同口径） =="
mkdir -p .build/gate-obj && rm -f .build/gate-obj/*.o
# shellcheck disable=SC2086
swiftc -emit-object -O -whole-module-optimization -swift-version 6 \
    -F "$CLT_FRAMEWORKS" \
    $( [ -f "$CLT_TESTING_PLUGIN" ] && echo "-load-plugin-library $CLT_TESTING_PLUGIN" ) \
    $NON_VIEW_SOURCES $APP_BRAND \
    "$STRIPPED_DIR"/*.swift \
    -o .build/gate-obj/gate-nonview-O.o

echo "== 3/3 Helper build（不安装） =="
swift build --target BatteryBarHelper

echo "本地门禁全部通过"
