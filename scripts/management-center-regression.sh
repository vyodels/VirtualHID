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
inventory_text_start = source.index("var templateInventoryText: String")
inventory_text_end = source.index("var analysisText: String", inventory_text_start)
inventory_text = source[inventory_text_start:inventory_text_end]
update_status_start = source.index("private func updateControls()")
update_status_end = source.index("private func position(panel:", update_status_start)
update_status = source[update_status_start:update_status_end]

assert "templates.prefix(" not in source, "管理中心不允许截断能力模板列表"
assert "private let learningInspectLimit = 200" in source, "管理中心必须请求足够的模板库存"
assert ".prefix(" not in inventory_text, "能力模板库存文本必须枚举全部模板，不能在源头截断"
assert "templates.enumerated().map" in inventory_text, "能力模板库存文本必须保留完整序号和详情"
assert "NSScrollView()" in templates_section, "能力模板库存必须放在可滚动容器内"
assert "hasVerticalScroller = true" in templates_section, "能力模板库存滚动容器必须开启纵向滚动条"
assert "autohidesScrollers = false" in templates_section, "能力模板库存滚动条必须常显，避免误判只有少量模板"
assert "NSTextView" in templates_section, "能力模板库存必须使用 NSTextView 作为滚动内容，避免 NSTextField 在 NSScrollView 中裁剪长库存"
assert "templateInventoryLabel?.stringValue = lastLearningState.templateInventoryText" not in update_status, "能力模板库存不能写入 NSTextField.stringValue；应写入 NSTextView.string"
assert (
    re.search(r"templateInventory\w*\?\.string\s*=\s*lastLearningState\.templateInventoryText", update_status)
    or "text: lastLearningState.templateInventoryText" in update_status
), "能力模板库存刷新必须写入 NSTextView.string"

print("management-center source invariants OK")
PY

echo "management-center-regression OK"
