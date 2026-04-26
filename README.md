# VirtualHID

VirtualHID 是一个面向 macOS 的拟人化输入执行与学习仓库。它负责把上层 Agent 给出的目标锚点、允许落点区域和动作序列，转换成真实的鼠标/键盘事件流，并通过观察、聚合和长期分析不断调整自己的执行参数。

## 当前状态（2026-04-26）

已完成：

- M2-M7 主实施范围已经归档到 `docs/plan/completed/2026-04-23-virtualhid-impl_cn.md`
- 目标锚点 + `landingZone` 合同、完整点击前奏、非匀速时间曲线、全局串行动作执行
- `trace.commit -> profiles.rebuild -> applyProfiles` 学习闭环
- 长期拟人度分析脚本 / HTTP 接口 / Web 实验台导航
- `report_server.py` 对 `vhid-daemon` 的自动拉起、状态查看和重启控制

新增 / 进行中：

- `TargetResolverV2` 的通用匹配/确认策略已落地，真实浏览器 tab 激活仍依赖上游 browser-mcp 或后续 AX/AppleScript 执行适配。
- `BrowserPageResolver` 已增加 Chrome / Chromium / Edge / Safari 的 page 级枚举与激活适配；真实 live activation smoke 仍需在有目标浏览器窗口的 GUI 会话里跑完。
- `ViewportMapper` 已支持 `viewport/document -> screen` 几何换算，并能在 action 响应里返回执行 plan。
- `ReplayTraceStore` 已支持回放级 compact trace 指纹、retention 与摘要。
- `OutcomeVerifier` 已返回注入层、指针层、焦点层证据；页面语义成功仍由 Agent/browser 侧确认。
- `scripts/humanization_analysis.py` 已能消费 `replayFingerprint / compactTrace`，从摘要级分析升级为 replay-aware 分析。
- `docs/plan/active/2026-04-26-browser-targeting-learning-hud-completion-plan_cn.md` 已把真实浏览器激活、滚动后二次坐标、observer/semantic 证据、长期学习闭环、中文输入和 HUD 最终验收拆成后续收口任务。

## 当前能力

- `InjectorCore`：目标窗口解析、焦点控制、事件投递、动作原语执行
- `HumanizationKit`：轨迹生成、时间曲线、键盘节律、行为模式混合
- `Supervisor`：kill switch、被动观察、事件 tap
- `ProfileStore`：SQLite trace/template 存储、聚合、遗忘与 retention
- `ControlServer` + `InjectorDaemon`：Unix socket JSON-RPC 后端
- `mcp/`：MCP stdio shim，向 Agent 暴露 `hid_*` 工具，并按 FIFO 串行转发工具调用，避免多个键鼠动作从 MCP 入口并发交叉
- `web/`：复杂页面、人工/HID 对比采集、长期拟人度分析实验台

## 仓库结构

- `Sources/InjectorCore/`：执行器、投递模式、浏览器目标解析
- `Sources/HumanizationKit/`：纯算法拟人化库
- `Sources/Supervisor/`：kill switch 与 passive observer
- `Sources/ProfileStore/`：SQLite 存储与模板聚合
- `Sources/ControlServer/`：daemon 协议与请求路由
- `Sources/InjectorDaemon/`：主守护进程入口
- `mcp/`：Node.js MCP shim
- `web/`：对比采集与学习 demo
- `docs/plan/`：实施计划与完成记录

## 常用命令

```bash
CLANG_MODULE_CACHE_PATH=/tmp/virtualhid-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/tmp/virtualhid-swiftpm-cache \
  xcrun swift build --disable-sandbox --scratch-path /tmp/virtualhid-spm-build

CLANG_MODULE_CACHE_PATH=/tmp/virtualhid-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/tmp/virtualhid-swiftpm-cache \
  xcrun swift test --disable-sandbox --scratch-path /tmp/virtualhid-spm-build

/tmp/virtualhid-spm-build/x86_64-apple-macosx/debug/vhid-daemon
/tmp/virtualhid-spm-build/x86_64-apple-macosx/debug/vhid-tray
node mcp/server.mjs
PORT=8123 python3 scripts/report_server.py
python3 scripts/humanization_analysis.py --pretty
```

仅在 VirtualHID Web 实验台自测时，才使用实验台自动拉起带 HUD 控制能力的内部执行服务：

```bash
VIRTUALHID_HUD_CONTROL=1 VIRTUALHID_VISUALIZE_HID=1 PORT=8123 python3 scripts/report_server.py
```

跨项目 mock 招聘演示不得把这个 Web 实验台入口当成执行链路。`recruit-agent` 侧只能通过 VirtualHID MCP 调用 `hid_*` 工具；MCP shim 到 Swift runtime 之间的本机 IPC/socket 是 VirtualHID 内部实现细节，不是 Agent 业务接口。

面向 recruit-agent / Chrome 的常驻 daemon 不要使用 `--self-target`；该参数只用于 VirtualHID 自测，会把 `targetApp` 固定为 daemon 自身而不是 Chrome。smoke harness 如需自测必须同时传 `--allow-self-target-daemon` 显式确认。

如果只做 profile 学习链路冒烟，可运行：

```bash
./scripts/profile-learn-smoke.sh
```

如果只做 HUD / visualization 验收，可运行：

```bash
./scripts/hud-smoke.sh
```

如果要做真实 macOS 图形会话里的 HUD 视觉验收，可运行：

```bash
./scripts/hud-manual-ui.sh
```

## Web 实验台与服务入口

- 实验台：`http://127.0.0.1:8123/`
- HID 状态：`GET /hid/state`
- daemon 元信息：`GET /hid/daemon`
- 重启 daemon：`POST /hid/restart`
- 长期分析：`GET /analysis/report`

页面顶部已经预留导航：`实验台 / 指标 / 对比 / 学习 / 长期分析 / 接口与 Codex`。
`预览通道` 默认关闭，`results/cursor-command.json` 也按一次性消费处理，避免页面刷新后自动回放旧命令。

## 学习链路

当前学习闭环已经打通：

1. `PassiveObserver` 采集真实事件
2. Agent / web demo 补齐 `host + sig + taskId + stage`
3. `trace.commit` 写入 `ProfileStore`
4. `profiles.rebuild` 生成学习模板
5. `action` 时命中模板并应用到 move / click / drag / type / key

长期分析则由 `scripts/humanization_analysis.py` 和 `results/humanization-history.jsonl` 负责，按 `instructionKey` 聚合人工/HID 差异并输出调参建议。分析器现在会优先使用 `replayFingerprint / compactTrace` 中的路径骨架、节奏片段和质量分，如果历史里没有这些字段，则自动降级为摘要级长期分析。

如果当前目标是接入 Autonomous Agent 模拟环境任务执行，请优先阅读 `docs/reference/hid-phase1-validation-contract_cn.md`。该文档收口了 Phase-1 为什么已经足够、最小验证 contract，以及与 browser / recruit-agent 的职责边界。

## 重要边界

- VirtualHID 不访问 DOM、不发网络请求、不解析 HTML
- 面向 `recruit-agent` / Agent 的正式入口只有 MCP `hid_*` 工具；本机 IPC/socket 只连接 MCP shim、`vhid-tray` 和 Swift HID/HUD runtime，不能被跨项目 mock 招聘流程直接调用。
- VirtualHID 接收**目标锚点**和可选 `landingZone`；业务目标选择由上游 Agent 负责，实际 HID 落点和轨迹由 VirtualHID 负责生成
- MCP 对外不暴露独立 `move` 操作；网页点击由上游传 `click` 原语，VirtualHID 在内部生成拟人化鼠标移动轨迹、实际落点和点击事件
- 网页目标的 viewport/document → macOS screen 坐标换算由 VirtualHID 负责；browser/recruit-agent 只传页面坐标、target 身份和可选页面证据（如 scrollOffset/pageScale/viewportSize），不要从 browser `screenX/screenY` 合成或信任 `viewportInScreen`
- `ActionContext` 只读白名单字段：`host / element.sig / element.role / taskId / stage / hints.urgency`
- 网页目标的 `host` 必须来自 browser active tab、tab list、snapshot URL 或上游已规范化的 `browser_target.host`；`target.host` 与 `context.host` 同时存在时必须一致，不能由 Agent 或 VirtualHID 按站点名编造
- `hid_action` 必须携带非空 `primitives`；缺失或空数组返回 `E_PRIMITIVES_REQUIRED`。VirtualHID 只返回 HID 执行计划、事件、实际落点和轨迹证据；下载链接、下载记录、本地 artifact 路径和业务完成判断属于 browser / recruit-agent。
- Chrome 下载气泡、下载列表、菜单和 popover 等浏览器外壳 UI 不属于网页 DOM，也不能靠页面 JS 或 mock 页面处理。网页目标动作默认启用 `options.browserChromeOverlayPolicy = "auto"`：VirtualHID 会用 macOS AX 检测与目标浏览器窗口重叠的非标准外壳瞬态窗口，必要时先发送 Escape 清理遮挡，并在 `result.preflight.browserChromeOverlay` 返回证据；该预处理不进入业务 `events`、HUD 轨迹或 ReplayTraceStore 学习样本。需要显式处理时可设为 `"force"`，需要关闭时可设为 `"off"`。
- `target / geometry` 是 action 顶层执行字段，不进入 `ActionContext`，不参与业务语义判断
- HUD 是 VirtualHID 自有透明穿透覆盖层；轨迹、expected/final point、窗口框、状态、点击/拖拽/滚动/输入标记必须来自 VirtualHID action events / execution context / verification，不能由网页、browser 或 recruit-agent mock 补造。HUD 是 VirtualHID 正式本地观察能力，可由 `--visualize-hid` / `VIRTUALHID_VISUALIZE_HID=1` 在 daemon 启动时开启，开启后作用于该 daemon 处理的每一次 `hid_action`；常驻显示开启时，action 结束后 HUD 会保留最后一次目标窗口、状态和落点，清除延迟只清掉动态轨迹/特效；`--no-hud` / `VIRTUALHID_NO_HUD=1` 强制禁用且不得影响 action 结果。
- `vhid-tray` 是 VirtualHID 的正式 macOS 菜单栏控制入口；启动托盘即代表启动 VirtualHID 本地主程序，托盘会自动拉起带 `--hud-control --visualize-hid` 的 daemon。点击图标打开 HUD 配置面板，可切换 HUD、常驻显示、轨迹、目标/实际落点、点击/拖拽/滚动/输入特效、状态文本和清除延迟。托盘通过 daemon socket 调用 `hud.state / hud.configure`；这些开关只影响 VirtualHID 本地可视化，不进入 `hid_action` payload，也不改变执行/验证结果。
- `global` / `auto` 写入会先由 VirtualHID 激活目标应用，再校验 `targetApp.frontmost == true`
- `pid` 模式只允许 `mouseMoved / scrollWheel`，不可用于 click / drag / type / pasteText / key
- `hid_unlock` 不只是解除 kill switch，也必须释放/清空 VirtualHID 观测到的卡住修饰键和鼠标按钮状态，避免下一次动作继承脏输入状态
- daemon 内 action 执行是**全局串行**的，避免鼠标/键盘并发交叉

## 相关文档

- 已完成实施文档：`docs/plan/completed/2026-04-23-virtualhid-impl_cn.md`
- 下一阶段活动计划：`docs/plan/active/2026-04-24-targeting-and-replay-plan_cn.md`
- 后续收口计划：`docs/plan/active/2026-04-26-browser-targeting-learning-hud-completion-plan_cn.md`
- 第一阶段最小验证契约：`docs/reference/hid-phase1-validation-contract_cn.md`
- HUD / 可视化验收契约：`docs/reference/hid-hud-visualization-acceptance_cn.md`
- 拟人化 / 长期学习 / Replay 审计：`docs/reference/humanization-learning-audit_cn.md`
- 待办：`docs/TODO_cn.md`
- 贡献说明：`AGENTS.md` / `AGENTS_cn.md`
