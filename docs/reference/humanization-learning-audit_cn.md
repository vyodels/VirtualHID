# VirtualHID 拟人化 / 长期学习 / Replay 审计

日期：2026-04-27

## 结论

VirtualHID 已具备可用于 mock recruiting workflow 后续评估的通用拟人化与学习基础：轨迹、节律、落点采样、键鼠输入学习分析、聚焦采集、profile 聚合、执行时 profile 应用、daemon replay 指纹持久化、长期分析入口、replay-aware report 和受控 profile patch apply 都已经存在。当前缺口不再是“没有拟人化/没有学习”，而是真实长期人工/HID 样本质量还没有闭环验收，`imePinyin` 逐字中文输入也尚未实现。

本审计只收敛通用 HID 能力，不引入招聘站点规则。上游 browser / recruit-agent 仍只负责目标选择、DOM 发现、业务语义确认；实际 screen 坐标换算、HID 落点、轨迹和节奏必须由 VirtualHID 产生。

核心约束：学习效果必须体现在 VirtualHID 执行策略本身，而不是通过管理中心、demo 页面、mock 页面或 MCP shim 写死更慢的播放、更固定的时长或预构造轨迹来“看起来像”。管理中心效果演示只能触发同一套 `action -> applyProfiles -> ActionExecutor -> HumanizationKit` 链路；起点/终点可随机或显式复用，但轨迹、总时长、阶段节奏、点击/双击/拖拽/滚动/键盘时序必须由已学习 profile 或默认策略采样生成。

## 已具备能力

- 拟人化执行：`Sources/HumanizationKit/HumanizationKit.swift` 已提供 `WindMouse` / `BezierMouse`、`HumanTimingCurve`、`BehaviorBlend`、`MotionProfile`、`KeystrokeRhythm`；执行层在 `Sources/InjectorCore/ActionCore.swift` 中把 click / drag / move / type 转成完整事件流，并支持 `landingZone` 内 HID 自采样落点。
- 学习闭环：`Sources/ProfileStore/ProfileStore.swift` 已支持 rich `TracePayload`、SQLite trace/template、retention、`profiles.rebuild` 聚合和 `LearnedMotionTemplate` 输出；`Sources/ControlServer/ControlService.swift` 会在 action 前按 `host + sig + taskId + actionType` 查询并应用 profile。
- 键鼠输入学习分析：`Sources/Supervisor/PassiveLearning.swift` 会在用户显式开启后从真实鼠标、滚动、拖拽、键盘事件流提取 compact `PassiveGestureSample`，只保存路径骨架、节奏、停顿、hold/inter-click、dwell/inter-key、速度和形状特征，不保存 DOM、截图、业务文本或完整原始轨迹。
- 聚焦采集：`learning.session.start/stop` 支持给一段练习窗口打范围标签；样本会实时自动进入 `ProfileStore`，stop 只结束窗口，不再作为手动保存入口。
- Replay 指纹：`Sources/ProfileStore/ReplayTraceStore.swift` 已支持 compact `ReplayTraceFingerprint`、路径骨架、节奏片段、质量分、retention 和 summary；`ControlService.action` 会自动把 HID action events 转为 daemon replay fingerprint 并持久化。
- 长期分析入口：`scripts/humanization_analysis.py` 可读 `results/humanization-history.jsonl`，按 `instructionKey` 聚合人工/HID 差异，并消费 `replayFingerprint / compactTrace` 输出 replay-aware tuning 和 `profilePatchProposal`；`scripts/report_server.py` 通过 `GET /analysis/report` 暴露报告，并通过 `POST /analysis/apply-profile-patch?confirm=true` 提供受控 apply 入口。

## 已安全补齐

- `scripts/humanization_analysis.py` 现在会把 Swift 风格 top-level `segmentMs / hesitationMs / clickHoldMs / interClickMs / dwellMs / interKeyMs` 归一化为 `recommendedProfile.preferredRhythm`，避免 replay-aware report 检测到 compact trace 但推荐 profile 里丢失节奏片段。
- `ActionCore` dry-run 已使用虚拟时间线推进 `sleep`，因此 click hold、inter-click 和 settle 节奏能在无真实 HID 投递时被测试和沉淀为 replay 指纹。
- `ProfileStore.lookupTemplate` 已增加全局键鼠能力模板 fallback：精确 host/sig/task/action 未命中时，可回退到 `__global__` 通用行为模板，避免把站点规则写入执行层。
- `VirtualHID.app` 管理中心已增加中文学习控制面：开启/关闭键鼠输入学习分析、开始/结束聚焦采集、展示系统事件监听状态、实时原始事件、动作片段、历史片段，并单独提供“能力模板”和“效果分析”页面。效果分析通过安全 dry-run 的 `learning.demo.run` 触发，让 HUD 分步展示 VirtualHID planned events 产生的未使用模板 / 使用模板轨迹差异，不真实点击页面。
- 新增 `docs/reference/fixtures/humanization-replay-history.jsonl`，用于快速验证 replay-aware report 不依赖真实站点或业务语义。
- 新增 `scripts/analysis-apply-smoke.sh`，构造 10 条长期样本，验证 `profilePatchProposal -> profiles.apply -> action profiles.applied`。
- `docs/TODO_cn.md` 已更新为“daemon replay/apply 通路已存在，缺真实长期样本验收”，避免后续 worker 误判为完全未实现。

## 仍缺能力与验收标准

- G1：真实长期样本质量尚未验收。
  验收：同一通用 `instructionKey` 至少采集 10 组人工/HID 对照样本；报告显示 `overall.replay.available == true`，`recommendedProfile.preferredPathSkeleton` 非空，`recommendedProfile.preferredRhythm.segmentMs` 非空，并能解释速度、直线度、停顿、点数差异是否收敛。
- G2：profile 从 replay 指纹到执行参数仍以摘要聚合为主。
  验收：高质量 compact trace 能以分布方式影响 move/click/drag/type 的路径骨架、分段节奏、hold/inter-click/dwell/inter-key 参数；低置信度或低质量样本必须回退到基础先验，不固定复读单条轨迹。
- G3：页面语义成功仍需 Agent/browser 协同确认。
  验收：VirtualHID action 响应稳定区分注入层、指针层、焦点层、observer 回声层和 semantic 层；页面语义成功仍由 browser / Agent 判断并回写，不由 VirtualHID 解析 DOM 或硬编码业务规则。
- G4：`imePinyin` 中文逐字输入仍是独立缺口。
  验收：`pasteText` fallback 已可用；IME 拼音采集/回放必须基于真实输入法行为建模，不能把中文文本硬拆成业务特定按键序列。

## 快速验证

```bash
python3 scripts/humanization_analysis.py \
  --history docs/reference/fixtures/humanization-replay-history.jsonl \
  --pretty
```

最低验收：

- `history.records == 2`
- `overall.replay.available == true`
- `overall.recommendedProfile.preferredPathSkeleton` 非空
- `overall.recommendedProfile.preferredRhythm.segmentMs` 非空

Swift 侧在 HUD / daemon 改动尚未收敛时，可先做 owned module build：

```bash
CLANG_MODULE_CACHE_PATH=/tmp/virtualhid-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/tmp/virtualhid-swiftpm-cache \
  xcrun swift build --disable-sandbox --scratch-path /tmp/virtualhid-spm-build \
  --target HumanizationKit --target ProfileStore
```

HUD / daemon 编译面干净后，再补跑：

```bash
CLANG_MODULE_CACHE_PATH=/tmp/virtualhid-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/tmp/virtualhid-swiftpm-cache \
  xcrun swift test --disable-sandbox --scratch-path /tmp/virtualhid-spm-build --filter HumanizationKit

CLANG_MODULE_CACHE_PATH=/tmp/virtualhid-profile-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/tmp/virtualhid-profile-swiftpm-cache \
  xcrun swift test --disable-sandbox --scratch-path /tmp/virtualhid-profile-spm-build --filter ProfileStoreTests

./scripts/analysis-apply-smoke.sh

./scripts/learning-smoke.sh
```
