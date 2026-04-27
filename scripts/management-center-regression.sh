#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUILD_PATH="${SWIFT_BUILD_PATH:-/tmp/virtualhid-management-center-regression-spm-build}"
CLANG_CACHE="${CLANG_MODULE_CACHE_PATH:-/tmp/virtualhid-management-center-regression-clang-cache}"
SWIFTPM_CACHE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/virtualhid-management-center-regression-swiftpm-cache}"

run_swift_test() {
  local filter="$1"
  CLANG_MODULE_CACHE_PATH="$CLANG_CACHE" \
    SWIFTPM_MODULECACHE_OVERRIDE="$SWIFTPM_CACHE" \
    xcrun swift test --disable-sandbox --scratch-path "$BUILD_PATH" --filter "$filter"
}

run_swift_test "HIDOverlayTrackingTests/testTrailPointsIncludeFinalActualPointWithoutDuplicate"
run_swift_test "HIDOverlayTrackingTests/testPersistentDryRunHistoryKeepsCompletedFrameAcrossReplayPrefixesUntilClear"
run_swift_test "ControlServiceTests/testLearningDemoStepClickFocusIsClickSpecificAndReturnsFullEventChainEvidence"
run_swift_test "ControlServiceTests/testLearningInspectReturnsAllTemplateSummariesForThirteenLearnedTemplates"

CLANG_MODULE_CACHE_PATH="$CLANG_CACHE" \
  SWIFTPM_MODULECACHE_OVERRIDE="$SWIFTPM_CACHE" \
  xcrun swift build --disable-sandbox --scratch-path "$BUILD_PATH" --target VirtualHIDTray

python3 - <<'PY'
from pathlib import Path

source = Path("Sources/VirtualHIDTray/main.swift").read_text()
analysis_start = source.index("private func makeAnalysisSection()")
analysis_end = source.index("private func metricCard", analysis_start)
analysis = source[analysis_start:analysis_end]

controls_pos = analysis.index("controls.addContent(controlsContent)")
analysis_label_pos = analysis.index("learningAnalysisLabel = analysis")
demo_status_pos = analysis.index("learningDemoStatusLabel = demoStatus")
assert controls_pos < analysis_label_pos < demo_status_pos, "效果分析按钮区必须固定在分析/状态长文案之前"

assert "templates.prefix(" not in source, "管理中心不允许截断能力模板列表"
assert "private let learningInspectLimit = 200" in source, "管理中心必须请求足够的模板库存"

print("management-center source invariants OK")
PY

echo "management-center-regression OK"
