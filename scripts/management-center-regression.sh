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
run_swift_test "HIDOverlayTrackingTests/testPersistentLiveHistoryKeepsCompletedFrameAcrossTransientClearsAndPrefixes"
run_swift_test "ControlServiceTests/testLearningDemoStepClickFocusIsClickSpecificAndReturnsFullEventChainEvidence"
run_swift_test "ControlServiceTests/testLearningInspectReturnsAllTemplateSummariesForThirteenLearnedTemplates"

CLANG_MODULE_CACHE_PATH="$CLANG_CACHE" \
  SWIFTPM_MODULECACHE_OVERRIDE="$SWIFTPM_CACHE" \
  xcrun swift build --disable-sandbox --scratch-path "$BUILD_PATH" --target VirtualHIDTray

python3 - <<'PY'
import re
from pathlib import Path

source = Path("Sources/VirtualHIDTray/main.swift").read_text()
analysis_start = source.index("private func makeAnalysisSection()")
analysis_end = source.index("private func metricCard", analysis_start)
analysis = source[analysis_start:analysis_end]

controls_pos = analysis.index("controls.addContent(controlsContent)")
analysis_label_pos = analysis.index("learningAnalysisLabel = analysis")
demo_status_pos = analysis.index("learningDemoStatusLabel = demoStatus")
assert controls_pos < analysis_label_pos < demo_status_pos, "效果分析按钮区必须固定在分析/状态长文案之前"

templates_start = source.index("private func makeTemplatesSection()")
templates_end = source.index("private func makeAnalysisSection()", templates_start)
templates_section = source[templates_start:templates_end]
inventory_list_start = source.index("private func updateTemplateInventoryList")
inventory_list_end = source.index("private func templateInventoryMessageRow", inventory_list_start)
inventory_list = source[inventory_list_start:inventory_list_end]
update_status_start = source.index("private func updateControls()")
update_status_end = source.index("private func position(panel:", update_status_start)
update_status = source[update_status_start:update_status_end]

assert "templates.prefix(" not in source, "管理中心不允许截断能力模板列表"
assert "private let learningInspectLimit = 200" in source, "管理中心必须请求足够的模板库存"
assert ".prefix(" not in inventory_list, "能力模板库存列表必须枚举全部模板，不能在源头截断"
assert "state.templates.enumerated()" in inventory_list, "能力模板库存列表必须保留完整序号和详情"
assert "NSScrollView()" in templates_section, "能力模板库存必须放在可滚动容器内"
assert "hasVerticalScroller = true" in templates_section, "能力模板库存滚动容器必须开启纵向滚动条"
assert "hasHorizontalScroller = true" in templates_section, "能力模板库存列表必须允许横向查看完整模板身份"
assert "autohidesScrollers = false" in templates_section, "能力模板库存滚动条必须常显，避免误判只有少量模板"
assert "templateInventoryListStack" in templates_section, "能力模板库存必须使用结构化列表，不允许退回纯文本"
assert "templateInventoryText" not in source, "能力模板库存不能退回纯文本拼接；必须使用结构化列表"
assert "updateTemplateInventoryList(templateInventoryListStack" in update_status, "能力模板库存刷新必须写入结构化列表"

print("management-center source invariants OK")
PY

echo "management-center-regression OK"
