# VirtualHID 拟人化 / 长期学习 / Replay 审计

日期：2026-04-25

## 结论

VirtualHID 已具备可用于 mock recruiting workflow 后续评估的通用拟人化与学习基础：轨迹、节律、落点采样、profile 聚合、执行时 profile 应用、长期分析入口和 replay-aware report 都已经存在。当前缺口不再是“没有拟人化/没有学习”，而是 replay 指纹还没有从 daemon trace 自动落成长期持久样本，真实长期样本质量还没有闭环验收。

本审计只收敛通用 HID 能力，不引入招聘站点规则。上游 browser / recruit-agent 仍只负责目标选择、DOM 发现、业务语义确认；实际 screen 坐标换算、HID 落点、轨迹和节奏必须由 VirtualHID 产生。

## 已具备能力

- 拟人化执行：`Sources/HumanizationKit/HumanizationKit.swift` 已提供 `WindMouse` / `BezierMouse`、`HumanTimingCurve`、`BehaviorBlend`、`MotionProfile`、`KeystrokeRhythm`；执行层在 `Sources/InjectorCore/ActionCore.swift` 中把 click / drag / move / type 转成完整事件流，并支持 `landingZone` 内 HID 自采样落点。
- 学习闭环：`Sources/ProfileStore/ProfileStore.swift` 已支持 rich `TracePayload`、SQLite trace/template、retention、`profiles.rebuild` 聚合和 `LearnedMotionTemplate` 输出；`Sources/ControlServer/ControlService.swift` 会在 action 前按 `host + sig + taskId + actionType` 查询并应用 profile。
- Replay 指纹：`Sources/ProfileStore/ReplayTraceStore.swift` 已支持 compact `ReplayTraceFingerprint`、路径骨架、节奏片段、质量分、retention 和 summary；`Tests/ProfileStoreTests/ReplayTraceStoreTests.swift` 覆盖基础 fingerprint 与 retention/summary。
- 长期分析入口：`scripts/humanization_analysis.py` 可读 `results/humanization-history.jsonl`，按 `instructionKey` 聚合人工/HID 差异，并消费 `replayFingerprint / compactTrace` 输出 replay-aware tuning；`scripts/report_server.py` 通过 `GET /analysis/report` 暴露相同报告。

## 已安全补齐

- `scripts/humanization_analysis.py` 现在会把 Swift 风格 top-level `segmentMs / hesitationMs / clickHoldMs / interClickMs / dwellMs / interKeyMs` 归一化为 `recommendedProfile.preferredRhythm`，避免 replay-aware report 检测到 compact trace 但推荐 profile 里丢失节奏片段。
- 新增 `docs/reference/fixtures/humanization-replay-history.jsonl`，用于快速验证 replay-aware report 不依赖真实站点或业务语义。
- `docs/TODO_cn.md` 已更新为“基础 replay-aware 能力已存在，缺 daemon 自动持久化和真实长期样本验收”，避免后续 worker 误判为完全未实现。

## 仍缺能力与验收标准

- G1：daemon 自动 compact trace 持久化尚未闭环。
  验收：`trace.commit` 或 action 结果中的 rich payload 能自动生成 compact replay 指纹并持久保存；重启 daemon 后 retention 仍生效；`GET /analysis/report` 不依赖手工写入 JSONL 也能看到 `groups[].replay.available == true`。
- G2：真实长期样本质量尚未验收。
  验收：同一通用 `instructionKey` 至少采集 10 组人工/HID 对照样本；报告显示 `overall.replay.available == true`，`recommendedProfile.preferredPathSkeleton` 非空，`recommendedProfile.preferredRhythm.segmentMs` 非空，并能解释速度、直线度、停顿、点数差异是否收敛。
- G3：profile 从 replay 指纹到执行参数仍以摘要聚合为主。
  验收：高质量 compact trace 能以分布方式影响 move/click/drag/type 的路径骨架、分段节奏、hold/inter-click/dwell/inter-key 参数；低置信度或低质量样本必须回退到基础先验，不固定复读单条轨迹。
- G4：执行结果证据仍需 observer/Agent 协同完善。
  验收：VirtualHID action 响应稳定区分注入层、指针层、焦点层、observer 回声层；页面语义成功仍由 browser / Agent 判断并回写，不由 VirtualHID 解析 DOM 或硬编码业务规则。
- G5：中文/IME 输入仍是独立缺口。
  验收：若需要中文输入，先实现可靠 `pasteText` fallback，再设计 IME 拼音采集/回放；不能把中文文本硬拆成业务特定按键序列。

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
env DEVELOPER_DIR=/tmp/OldXcode.app \
  CLANG_MODULE_CACHE_PATH=/tmp/virtualhid-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/tmp/virtualhid-swiftpm-cache \
  xcrun swift build --disable-sandbox --scratch-path /tmp/virtualhid-spm-build \
  --target HumanizationKit --target ProfileStore
```

HUD / daemon 编译面干净后，再补跑：

```bash
env DEVELOPER_DIR=/tmp/OldXcode.app \
  CLANG_MODULE_CACHE_PATH=/tmp/virtualhid-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/tmp/virtualhid-swiftpm-cache \
  xcrun swift test --disable-sandbox --scratch-path /tmp/virtualhid-spm-build --filter HumanizationKit

env DEVELOPER_DIR=/tmp/OldXcode.app \
  CLANG_MODULE_CACHE_PATH=/tmp/virtualhid-profile-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/tmp/virtualhid-profile-swiftpm-cache \
  xcrun swift test --disable-sandbox --scratch-path /tmp/virtualhid-profile-spm-build --filter ProfileStoreTests
```
