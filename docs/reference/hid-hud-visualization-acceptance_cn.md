# VirtualHID HUD / 可视化验收契约

## 1. 验收目标

HUD 是 VirtualHID 自有的透明、鼠标穿透覆盖层，只观察 VirtualHID 执行动作产生的事件流。它不得依赖网页 JS / DOM，不得让 browser、recruit-agent 或 mock page 补造 expected / actual / trajectory。

HUD 开启时应展示：

- 目标 app/window 的 VirtualHID 解析窗口框。
- `ActionExecutor` 记录的实际 HID 事件轨迹。
- 点击、拖拽、滚轮、输入等事件效果。
- `OutcomeVerifier` 基于同一批 `ActionResult.events` 计算出的 `expectedPointer` 与 `finalPointer`。
- 常驻显示开启时，action 结束并超过清除延迟后仍保留最后一次 VirtualHID 目标窗口、状态、expected/final point；只清除动态轨迹和事件特效。
- HUD 生命周期必须绑定 VirtualHID 当前 target window：目标窗口打开并开始 action 时自动显示；目标窗口移动或 resize 时，HUD 外框、viewport/window 诊断和 expected/final 标记必须跟随同一窗口重算并移动；目标窗口关闭、失去可解析 target 或 action 被取消/停止后，HUD 必须关闭或隐藏，不能停留在旧屏幕坐标。

## 2. VirtualHID 正式 HUD / 控制面语义

HUD 是 VirtualHID runtime 启动时确定的自有观察层：`VirtualHID.app` 默认持有可管理 HUD；CLI / smoke 入口通过 `--visualize-hid` 或 `VIRTUALHID_VISUALIZE_HID=1` 启动后，应持续作用于该 runtime 处理的每一次 `hid_action`，直到 runtime 退出或被禁用入口关闭。它不是某个 smoke、demo 或单次 action 的专用参数。

HUD 配置属于 VirtualHID 本地观察设置，不属于 `hid_action` 的业务数据。上游 Agent / browser / recruit-agent 不应在 action payload 中传 HUD 绘制开关、视觉样式或坐标修正字段；这些设置只影响 VirtualHID 如何展示自己已经执行和验证的事件，不改变 action 计划、事件生成、落点选择或 verification 结果。

`--no-hud` 或 `VIRTUALHID_NO_HUD=1` 具有最高优先级；关闭时 action、events、verification、trace 与分析链路仍照常产生，只是不挂 HUD sink。

`VirtualHID.app` 是 VirtualHID 的正式 macOS 菜单栏控制入口，不是 `vhid-daemon` 的附属启动模式。启动 app 即代表启动 VirtualHID 本地主程序；app 进程直接持有 `VirtualHIDRuntime`、HUD、学习控制和供 MCP shim 连接的本机 socket。单击托盘显示快捷配置菜单，双击托盘打开管理中心。管理 UI 只允许修改和观察 VirtualHID 本地能力，例如 HUD 启停、轨迹、采样点、expected/final point、点击/拖拽/滚动/输入特效、状态文本、清除延迟、键鼠输入学习分析、聚焦采集、实时事件、动作片段、历史片段、能力模板和安全 dry-run 学习效果演示；它不得写入业务 action payload、不得改变动作计划，也不得作为业务状态来源。

## 3. 数据来源与边界

- actual trajectory 只来自 `InjectedEvent.location`，即 `ActionExecutor.record(...)` 记录的 VirtualHID 事件。
- expected/final point 只来自 `hid_action` 响应里的 `verification.expectedPointer` / `verification.finalPointer`。
- window scope 只来自 VirtualHID 的 `BrowserTarget.frame` / execution context；browser 只能提供 target 身份、页面坐标和可选页面证据，不能提供 screen coordinate authority。
- `geometry.viewportInScreen` 若由调用方提供，也只能作为输入证据；VirtualHID 会以自身解析出的 viewport/window 为准。
- HUD 永远不创建 HID 事件、verification 坐标或 screen coordinate authority；它只渲染 VirtualHID 已产生的事件流、解析出的窗口范围和验证结果。

## 4. 可视化内容范围

HUD 设置应覆盖这些 VirtualHID 本地观察项：

- 窗口框与 viewport/window 诊断。
- 常驻显示 HUD。
- runtime / action 状态文本。
- 事件轨迹线与轨迹采样点。
- expected / final 指针点。
- click / double-click 命中环。
- drag 起止与路径环。
- scroll 方向/幅度 glyph。
- keyboard / type / paste 输入徽标。
- HUD 清除延迟；常驻显示开启时该延迟只清动态轨迹/特效，关闭时到期后隐藏 HUD 内容。

这些内容只能来自 VirtualHID action events、execution context 和 verification；不得由网页 mock、browser snapshot 或 recruit-agent 自行补画。

配置入口：

- CLI / smoke 启动参数：`--hud-control`、`--hud-show <components>`、`--hud-hide <components>`、`--hud-clear-delay <seconds>`。
- 环境变量：`VIRTUALHID_HUD_SHOW`、`VIRTUALHID_HUD_HIDE`、`VIRTUALHID_HUD_CLEAR_DELAY_SECONDS`。
- 组件名：`all`、`persistent`、`window-frame`、`diagnostic`、`trail`、`trail-points`、`expected-point`、`actual-point`、`click-effects`、`drag-effects`、`scroll-effects`、`keyboard-effects`、`status`。
- 交互入口：`VirtualHID.app` 在菜单栏显示 VirtualHID 图标；单击显示快捷配置菜单，双击打开管理中心。HUD / 学习效果演示的正式入口是管理中心，不是单独的 shell demo。

## 5. 自动化验收

运行：

```bash
./scripts/hud-smoke.sh
```

该 smoke 不创建真实 NSPanel，验证的是 HUD 低层合同：

- `--no-hud` 下 `hid_action` 仍返回 VirtualHID 事件和 verification，但 HUD callback 为 0。
- `--visualize-hid` 下 HUD sink 收到 start / record / finish，事件数与 `hid_action.result.events` 一致。
- callback 的 expected/final point 与 action response 完全一致。
- `--no-hud` / `VIRTUALHID_NO_HUD=1` 对 `VIRTUALHID_VISUALIZE_HID=1` 或 `--visualize-hid` 有禁用优先级。
- HUD sink 的开启/关闭状态来自 VirtualHID 本地控制设置，而不是单次 `hid_action` payload。
- `--hud-show` / `--hud-hide` / `VIRTUALHID_HUD_*` 能改变 `hudSettings`，包括 `persistent` 常驻显示开关，但不会改变 action events 或 verification。

建议配套运行：

```bash
CLANG_MODULE_CACHE_PATH=/tmp/virtualhid-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/tmp/virtualhid-swiftpm-cache \
  xcrun swift test --disable-sandbox --scratch-path /tmp/virtualhid-spm-build
```

学习效果回放验收的正式入口是 `VirtualHID.app` 管理中心：

1. 启动 `VirtualHID.app`。
2. 双击托盘图标打开管理中心。
3. 打开“学习预训练”。
4. 查看“实时采集”和“历史片段与习惯模板”中的事件监听状态、动作片段、历史片段和模板摘要。
5. 点击“演示学习效果”。

预期：管理中心显示安全预览结果；HUD 分步显示 VirtualHID 自己产生的轨迹、采样点、expected/final point、按下/抬起点击事件。`learning.demo.run` 返回 `source = virtualhid-action-events`、`mode = safe-dry-run-preview`、`safety.dryRun == true`、`safety.realClickPosted == false`；未使用模板的 baseline 不命中 profile，使用模板的 action 命中 profile。

低层自动化 smoke 可运行：

```bash
./scripts/learning-playback-demo.sh
```

该脚本只用于 CI / smoke 验证，不是用户演示入口。它验证学习能力对后续 HID action 的真实影响：VirtualHID 先在本地生成一批可聚合的训练轨迹样本，写入 `ProfileStore`，重建 learned template，然后提交 baseline + 多个随机起止点的普通 `action` 请求。baseline 不应命中 profile；后续 learned action 必须通过 `ControlService.applyProfiles` 命中模板，并由 `ActionExecutor` 产生 `mouseMoved`、`leftMouseDown`、`leftMouseUp` 等完整事件。HUD 只显示这些 action events 与 verification，不允许脚本、mock page、browser 或 recruit-agent 自行生成轨迹、expected point 或 actual point。

脚本输出会保存到 `/tmp/virtualhid-learning-playback-response.jsonl`，最后一行 `learning-playback-summary` 必须满足：

- `training.generatedTemplates >= 1`。
- `assertions.baselineProfileNotApplied == true`。
- `assertions.learnedProfilesApplied == true`。
- `assertions.learnedActionsHaveClickEvents == true`。
- learned action 的 `templateIds` 非空，并且 `eventTypes` 中包含 `leftMouseDown / leftMouseUp`。`learnedActionsHaveMouseMovement` 用于诊断轨迹事件，不再作为安全预览失败的唯一依据。

## 6. 手动 UI 验收命令

真实 HUD 需要 macOS 图形会话，无法稳定在 headless smoke 中断言。正式人工确认应从 `VirtualHID.app` 管理中心打开 HUD 并触发“演示学习效果”。以下脚本只保留为低层 smoke / 截图证据：

```bash
VIRTUALHID_HUD_SCREENSHOT=/tmp/virtualhid-hud-ui-smoke.png \
VIRTUALHID_HUD_RESPONSE=/tmp/virtualhid-hud-ui-smoke.json \
./scripts/hud-manual-ui.sh
```

该脚本会构建 `vhid-daemon`，在 AppKit 主循环中运行 `--smoke-hud-ui`，触发真实 `ControlService -> ActionExecutor -> HIDOverlayController` 路径，并用 `screencapture` 保存证据图。

默认情况下，`--smoke-hud-ui` 会解析当前运行中的 Chrome / Chromium / Edge / Safari 目标窗口，并用 VirtualHID 自己解析出的 `AXWebArea` / browser content viewport 做 viewport 到 screen 的映射。只有显式传 `--self-target` 时才进入自测 fallback；fallback 区域必须是主屏 `visibleFrame`，不得跨桌面或画到不可见区域。

预期：屏幕上短暂出现透明穿透 HUD，包含目标窗口虚线框、`HUD ACTIVE` 诊断标签、VirtualHID 事件轨迹、点击/滚动效果、expected/final 标记和 `HID dry-run click+scroll ...` 状态文本。`click` primitive 内部会生成拟人化鼠标移动轨迹；demo 不应再显式下发独立 `move` primitive，也不应出现来自网页 mock 的额外轨迹或坐标。

目标窗口生命周期验收：在真实 Chrome / Edge / Safari 目标窗口上触发 HUD 后，人工或脚本移动/缩放该目标窗口时，HUD 外框与窗口诊断必须在下一次 target 解析或 action 更新时跟随新 frame；关闭目标窗口后，HUD 必须隐藏或进入明确的无 target 状态，不得继续显示旧窗口框、旧落点或旧轨迹。该验收只能使用 VirtualHID 的 targetApp / execution context / verification 证据，不得由 browser snapshot 或页面脚本补算 screen 坐标。

多屏坐标注意事项：Chrome/AX/CG 返回的窗口和事件点可能使用主屏顶部为基准的全局坐标，例如上方外接屏会出现负 Y。HUD 必须在 VirtualHID 内部把该坐标系转换为 AppKit `NSScreen.frame` 坐标后绘制；browser、recruit-agent 或 mock page 不得提供或修正 screen coordinate authority。

如果输出 `could not create image from display`，脚本会同时打印 `screencapture` 退出码、前后 `IODisplayWrangler` 状态和诊断信息。若显示器不是 `Current State 0` 仍失败，通常是当前 macOS GUI session、锁屏状态、空间/外接屏状态或 Screen Recording 权限阻止截图；此时只能标记为视觉证据环境阻塞，不能伪造通过。
