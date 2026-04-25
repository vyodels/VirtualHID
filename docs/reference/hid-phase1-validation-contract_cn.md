# VirtualHID Phase-1 验证契约

## 1. Phase-1 Sufficiency

Phase-1 的目标不是覆盖真实招聘站点写入，而是把 VirtualHID 收敛成 Autonomous Agent 模拟环境任务执行的受控写入层。当前已经足够支撑这一阶段，因为仓库已具备目标锚点原语、可选 `landingZone`、拟人化轨迹与节律、`dryRun` 写入计划、样本回写与长期分析入口，以及 frontmost / postMode / kill switch / 串行执行约束。

因此，Phase-1 已足够用于目标锚点模拟点击、拖拽、滚动、输入，以及“人工样本 vs HID 计划”的拟人化差异比较。若调用方提供 `landingZone`，实际落点必须由 VirtualHID 选择并通过 `events` / `verification.finalPointer` 返回。Phase-1 不覆盖多窗口多 tab 精准激活、真实滚动后二次坐标换算、完整 observer 回声、回放级 compact trace 持久化闭环。

## 2. Minimum Validation Contract

建议只依赖这些稳定且可程序消费的表面：

- `hid_state`
  输入：无。
  输出最少消费：`busy`、`post.default`、`post.lastUsed`、`targetApp.frontmost`、`killSwitch.active`。
- `hid_action` with `options.dryRun=true`
  输入：`id`、目标锚点 `primitives`、可选 `profile.landingZone`、白名单 `context`。
  `primitives` 必须非空，且必须由上游 browser snapshot `clickPoint`、允许落点区域或等价观察证据构造；只传 `target/context` 属于契约错误，应返回 `E_PRIMITIVES_REQUIRED`。
  `context` 只允许稳定使用：`host / element.sig / element.role / taskId / stage / hints.urgency`。
  当目标是网页时，必须携带 host 归因语义；host 应来自 browser active tab、tab list、snapshot URL 或调用方已规范化的 `browser_target.host`，可出现在 `target.host` 或 `context.host`，进入 VirtualHID 内部后作为 profile / trace / learning 归因键。非网页桌面目标可使用其它稳定 target/context 归因字段，不强制套用网页 host。
  输出最少消费：`id`、`ok`、`error`、`events[]`、`elapsedMs`、`post.used`、`verification.finalPointer`。
- `hid_trace_commit`
  输入最少：`eventId`、`elementSig`、`host`；可附带 synthetic payload。网页目标的 `host` 必须沿用对应 observe / action 的 browser-derived host，不能在 trace 回写阶段后补编造。
- `GET /analysis/report`
  输出最少消费：`history.records`、`history.groups`、`overall.recommendedProfile`、`overall.recommendedAdjustments`、`groups[].divergence`。

观测点：`hid_state`、`hid_action(dryRun).events`、`hid_trace_commit`、`analysis/report`。
HUD / visualization 是可选观察层，不是额外数据源；开启后只能展示 `hid_action` 的 VirtualHID events 与 verification，关闭时不得影响 action 结果。验收细节见 `docs/reference/hid-hud-visualization-acceptance_cn.md`。
失败信号：`E_PRIMITIVES_REQUIRED`、`E_PRIMITIVE_INVALID`、`E_CONTEXT_REQUIRED`、`E_FIXED_POINT_ONLY`、`E_NOT_FRONTMOST`、`E_POST_MODE_UNSUPPORTED`、`E_NO_TARGET`、`E_KILL_SWITCH`、`E_DAEMON_UNREACHABLE`。

## 3. Responsibility Split With Browser / Recruit-Agent

属于 VirtualHID：动作原语、实际 HID 落点选择、拟人化轨迹/节律、`dryRun` 事件流、frontmost / postMode / kill switch / 串行执行约束、trace 存储、长期分析输出、执行层错误码。

必须由 browser / recruit-agent 做：DOM 读取、元素发现、signature 生成、业务任务推理与执行编排、目标锚点/允许区域求解、页面语义成功判断、招聘站点特有规则、下载链接发现、下载记录 / artifact 本地路径定位与业务完成判断。它们不得生成或补造实际 HID 轨迹。

边界原则：VirtualHID 负责“怎么执行”；browser / recruit-agent 负责“点谁、为什么点、业务上是否成功”。

host 边界：VirtualHID 可以使用 host 做目标匹配、学习隔离、profile 查询和 trace 过滤，但不能根据 host 做“某站点特殊流程”之类业务判断。host 也不能由 demo 脚本或 Agent runtime 分支按站点名称硬编码，必须能追溯到 browser 原始 URL / tab / snapshot。`target.host` 与 `context.host` 同时出现时必须一致；不一致应视为契约错误。

## 4. Standalone Validation Project Decision

当前不建议拆独立验证项目。现有验证面仍强依赖 VirtualHID 自身的 daemon 方法、错误码、`dryRun` 事件结构与分析结果；同时第二阶段缺口还未收敛，包括目标激活、坐标换算、结果证据化、回放级指纹。更合理的顺序是先冻结本文件定义的 machine-consumable contract，等第二阶段接口稳定后，再评估是否把 fixture / replay / harness 抽成独立项目。
