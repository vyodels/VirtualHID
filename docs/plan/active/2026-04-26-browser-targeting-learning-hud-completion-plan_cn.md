# VirtualHID 收口计划 · 浏览器目标激活 / 二次坐标 / 证据回声 / 长期学习 / HUD / 中文输入

> **状态**：🟡 active
> **创建日期**：2026-04-26
> **承接文档**：`docs/plan/active/2026-04-24-targeting-and-replay-plan_cn.md`
> **目标**：把 2026-04-24 计划里仍为 `[~]` 的能力拆成可执行、可验证、可归档的收口任务。

---

## 0. 当前结论

这些能力**没有全部完成**。当前已完成的是基础 contract、纯策略、坐标基础映射、action 事件证据、HUD contract smoke、ReplayTraceStore 基础指纹和 replay-aware 分析；未完成的是实机浏览器激活、滚动后二次采样、observer/语义回声、长期样本自动调参闭环、中文输入路径，以及真实 GUI HUD 视觉验收闭环。

### 0.1 已完成基线

- `TargetResolverV2`：已有候选匹配、置信度和歧义报错策略。
- `ViewportMapper`：已有 `viewport/document -> screen` 基础换算，且 primitive 坐标、`PrimitiveProfile.origin`、`landingZone` 会统一映射。
- `ExecutionPlanner`：已有 activation/scroll/action 的结构化 plan，以及 scroll-before-action 计划层表达。
- `OutcomeVerifier`：已有注入事件数、最终指针、期望指针、焦点确认等基础证据。
- `ReplayTraceStore`：已有 compact trace 指纹、路径骨架、节奏片段、retention 和 summary。
- `humanization_analysis.py`：已有 replay-aware report 和调参建议输出。
- HUD：已有 VirtualHID 自有 overlay、低层 contract smoke、真实 UI smoke 入口；当前缺真实可截图 GUI 会话下的最终视觉验收。

### 0.2 未完成项

- `TargetResolverV2` 还没有闭环真实 Chrome / Edge / Safari 的 `windowId / tabId / host` 激活。
- `ExecutionPlanner` 还没有完成“滚动到目标后重新解析 viewport/frame，再重新换算坐标，再执行”的实机链路。
- `OutcomeVerifier` 还没有接入 `PassiveObserver` 回声，也没有和 Agent/browser 页面语义确认形成统一结果模型。
- `ReplayTraceStore` 还没有在 daemon 内自动生成并持久化真实执行 compact trace，也缺真实长期样本验证。
- `Codex Analysis Loop v2` 还没有完成“长期样本 -> 自动调 profile -> 再执行验证”的闭环。
- 中文输入仍未实现 `pasteText` fallback 或 `imePinyin` 采集/回放。
- HUD 还没有完成真实目标窗口上的最终视觉验收：透明穿透浮层、窗口范围裁剪、轨迹/落点/事件效果、截图证据和人工可见性。

---

## 1. 不可破坏的边界

- VirtualHID 不访问 DOM、不解析 HTML、不发网络请求。
- VirtualHID 不决定业务按钮、站点流程或元素语义；目标选择仍由 Agent / browser-mcp 完成。
- browser 不提供屏幕坐标权威；VirtualHID 负责从 macOS AX/CG/目标窗口证据解析 viewport/window 并换算到 screen。
- 调用方只能提供目标身份、页面坐标、目标锚点、可选 `landingZone` 和可追溯页面证据；实际落点、实际轨迹和 HUD 显示数据只能由 VirtualHID 产生。
- HUD 是观察层，不是数据源；禁用 HUD 时 action 结果必须完全一致。
- 中文输入不能按业务文案硬编码拼音序列；`imePinyin` 必须基于通用输入法行为建模。

---

## 2. 收口阶段

### W1. 真实浏览器目标激活

目标：让 `TargetResolverV2` 从纯匹配策略升级到真实浏览器可执行激活。

当前进展（2026-04-26）：

- 已新增 `BrowserPageResolver`，用通用 browser adapter 枚举 Chrome / Chromium / Edge / Safari 的窗口和 tab。
- 已接入 `BrowserResolver`：当 action target 带 `windowId / tabId / host` 时，先做 page 级解析和激活，再回到 AX/CG 解析真实窗口与 viewport。
- `targetApp` evidence 已返回 `browserWindowId / tabId / host / url`，便于上游核对目标归因。
- host-only 多候选会返回 ambiguous，不再因为 active/frontmost 加分而猜一个 tab。
- 单元测试与 smoke 已通过；真实浏览器 live activation smoke 仍待执行。
- 当前机器探测到 Chrome / Safari 进程存在，但 AppleScript 可见窗口数为 0；因此本轮没有可复用的真实 tab 做 live activation 验收，后续需要创建或复用一个明确测试 tab。

任务：

- 为 Chrome / Edge / Safari 建立 browser adapter，能力包含列出窗口、列出 tab、按 `windowId/tabId/host` 定位候选。
- 对 `tabId` 使用强匹配；对 `host` 使用弱匹配兜底；多候选必须返回 ambiguous，不允许猜。
- 激活后用 AX/NSRunningApplication/前台应用状态确认 `frontmost == true`。
- action 响应里返回 `targetApp.windowId/tabId/host/windowTitle/viewportFrame/viewportSource` 证据。

验收：

- 指定真实 Chrome `windowId + tabId + host` 能激活到目标 tab。
- 指定 Edge/Safari host 能匹配唯一 tab；多 tab 同 host 返回歧义。
- 目标浏览器不存在、tab 不存在、host 不一致都返回结构化错误。

### W2. 滚动后二次坐标换算

目标：完成“目标不在 viewport 内 -> 滚动 -> 重新解析 viewport/window -> 重新换算 -> 执行”的闭环。

当前进展（2026-04-26）：

- `ExecutionPlanV2` 已能显式标记 `requiresViewportResample`。
- 当前 action 遇到目标不在 viewport 内时会返回 `E_VIEWPORT_RESAMPLE_REQUIRED`，禁止继续用滚动前旧 screen 坐标盲点。
- 这仍不是完整自动二次采样闭环；最终闭环需要上游 browser/Agent 在滚动后重新提供 scrollOffset/pageScale/viewport 证据，再由 VirtualHID 执行更新后的目标。

任务：

- 在 `ExecutionPlanner` 中把 scroll-before-action 从单次计划升级为可重采样阶段。
- action 执行滚动后调用 resolver 重新读取目标窗口/viewport frame。
- 使用最新 `viewportFrame + scrollOffset/pageScale/viewportSize` 重新映射 primitive、origin、landingZone。
- 如果重采样后目标仍不可见，返回 `targetNotVisibleAfterScroll`，不继续盲点。

验收：

- 目标在首屏外时，响应里能看到 scroll 阶段、resample 阶段和最终 click 阶段。
- 窗口移动、页面缩放、滚动后仍点中 `landingZone`。
- 不能只复用滚动前旧 screen 坐标。

### W3. OutcomeVerifier + PassiveObserver + 语义确认模型

目标：把“事件发出”升级成分层执行证据。

当前进展（2026-04-26）：

- `verification` 已增加 `injection / pointer / focus / observer / semantic` 分层证据。
- `observer` 会区分 `dryRunNotObserved / notEnabled / echoed / notObserved`，不会把 VirtualHID 自己打标并被过滤的 CGEvent 误判成人工输入。
- `semantic` 默认 `notProvided`；只有上游 Agent/browser 明确传入 `semantic` 或 `semanticConfirmation` 时才会标记为 verified/rejected。

任务：

- 将 `PassiveObserver` 的最近事件窗口接入 action 执行结果，生成 observer echo。
- 对 move/click/drag/scroll/type 分别定义最低回声标准。
- 在 response 中区分 `injection`, `pointer`, `focus`, `observer`, `semantic` 五层证据。
- `semantic` 不由 VirtualHID 判断 DOM，只接收 Agent/browser 的语义确认结果或标记为 `notProvided`。

验收：

- HID 事件投递成功但 observer 未看到回声时，结果不能是无条件成功。
- observer 有回声但 browser/Agent 未确认页面变化时，结果标为 `semanticNotVerified`。
- browser/Agent 提供语义确认后，最终结果可升级为 `verified`。

### W4. ReplayTraceStore daemon 持久化与真实长期样本

目标：让 compact trace 不只存在于测试/分析脚本，而是在 daemon 执行链路里自然生成和积累。

当前进展（2026-04-26）：

- `ProfileStore` 已新增 SQLite `replay_fingerprints` 持久化表、retention/overflow 清理、list 与 summary 查询。
- `ControlService.action` 已能把 HID action events 自动转成 `TraceInput` 和 `ReplayTraceFingerprint`，并返回 `daemonLearning` 证据。
- 敏感 role 不写入 daemon learning。
- 仍缺真实长期样本回归；当前只完成自动生成、持久化与单元验收。

任务：

- action 完成后按 `instructionKey` 自动生成 compact trace fingerprint。
- 将 trace 持久化到 ProfileStore/ReplayTraceStore，而不是只写临时 JSON。
- 加入敏感字段过滤、大小限制、retention 和低质量样本淘汰。
- 为真实样本建立最小回归集：人工样本、HID 样本、replay fingerprint、聚合 profile。

验收：

- 连续执行同一 instruction 后，store 中能看到按 key 聚合的 replay fingerprints。
- report 能显示路径骨架、节奏片段、质量分、样本数和 retention 后结果。
- 不保存 DOM、页面文本、截图或完整原始轨迹。

### W5. Codex Analysis Loop v2 自动调参闭环

目标：从“分析并建议”升级到“长期样本驱动 profile 更新，并通过下一轮执行验证”。

任务：

- 让分析器输出机器可消费的 profile patch proposal。
- daemon 或 report server 提供受控 apply 入口，写入 profile store。
- 下一轮 action 自动应用更新后的 profile，并在 evidence 中标记 profile 来源与版本。
- 建立回归指标：速度分布、路径直线度、停顿、settle、overshoot、点击间隔是否向人工样本收敛。

验收：

- 至少 10 组同 instruction 的人工/HID 对照样本能产生 profile patch。
- 应用 patch 后的 HID 执行指标比应用前更接近人工区间。
- 低置信度样本不会覆盖高置信度 profile。

### W6. 中文输入

目标：先提供可靠中文输入 fallback，再推进拟人化 IME 回放。

任务：

- 实现 `pasteText` primitive：写入剪贴板、模拟 `Cmd+V`、恢复或记录原剪贴板策略。
- 在 response 里标明输入路径为 `pasteText`，不伪装成逐字键入。
- 设计 `imePinyin` contract：拼音序列、候选确认、退格修正、输入法状态检测、失败降级。
- 后续用真实中文输入样本训练 IME 节奏，而不是硬编码业务词。

验收：

- 中文、emoji、未映射符号不会被静默跳过。
- `pasteText` 能在普通文本框输入中文，并返回剪贴板处理证据。
- `imePinyin` 未完成前，中文逐字拟人化不得宣称已支持。

### W7. HUD / 可视化浮层最终验收

目标：把 HUD 从 contract smoke 推进到真实目标窗口可见、可截图、可审计的验收项。

任务：

- 真实 Chrome/Edge/Safari 目标窗口上显示透明、鼠标穿透 HUD。
- HUD 按 VirtualHID 当前 action context 绑定目标窗口，不根据网页内容判断展示。
- 显示 expected point、actual final point、最近几秒轨迹、click/double-click/drag/scroll/type 事件效果。
- 所有可视化数据只能来自 VirtualHID action events / verification / targetApp frame。
- `scripts/hud-manual-ui.sh` 在显示器睡眠、无截图权限、无 GUI session 时必须明确失败原因。
- 补充截图证据路径和 response JSON 路径，便于跨项目验收引用。

验收：

- 页面 JS 无法感知 HUD 存在、轨迹、落点或截图。
- 禁用 HUD 后 action response、事件投递、verification 不变化。
- 真实截图中能看到目标窗口框、轨迹、expected/final 标记和事件效果。
- 若 `IODisplayWrangler Current State 0`，验收标为环境阻塞，不得伪造通过。

---

## 3. 执行顺序

1. 先做 W7 HUD 真实视觉验收，因为它能快速暴露事件轨迹、落点、窗口绑定和显示器状态问题。
2. 并行推进 W1 浏览器目标激活和 W2 滚动后二次坐标，这两项共同决定真实网页能否点中。
3. W3 接上 observer/语义确认模型，避免“事件发出即成功”的假阳性。
4. W4/W5 在真实 action evidence 稳定后推进长期学习闭环。
5. W6 中文输入独立推进，先 `pasteText`，再 `imePinyin`。

---

## 4. 当前下一步

- 运行 `./scripts/hud-manual-ui.sh`，确认当前图形会话是否能截图；若显示器仍为 `IODisplayWrangler Current State 0`，先记录环境阻塞。
- 选一个真实浏览器目标窗口，补 `TargetResolverV2` 的真实 tab/window 激活 smoke。
- 为 scroll-resample 增加最小测试 fixture：目标初始在 viewport 外，滚动后必须重新解析 viewport，再执行 click。
- 定义 `OutcomeVerifier` 的 observer/semantic response schema，先写测试锁住合同。

---

## 5. 完成判定

本计划只有在以下条件全部满足后才能归档：

- 真实 Chrome / Edge / Safari 至少各有一条目标激活验收通过，或明确记录某浏览器的能力缺口。
- 滚动后二次坐标换算通过实机或 GUI harness 验收。
- response 能区分注入、指针、焦点、observer 和语义确认。
- daemon 能自动生成并持久化 compact trace，长期样本可驱动 profile 调整。
- 中文 `pasteText` fallback 可用；`imePinyin` 若未完成，必须继续列为后续项。
- HUD 真实 GUI 视觉验收有截图证据，或明确因物理显示器/权限阻塞而未完成。
