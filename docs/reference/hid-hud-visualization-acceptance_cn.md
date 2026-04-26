# VirtualHID HUD / 可视化验收契约

## 1. 验收目标

HUD 是 VirtualHID 自有的透明、鼠标穿透覆盖层，只观察 VirtualHID 执行动作产生的事件流。它不得依赖网页 JS / DOM，不得让 browser、recruit-agent 或 mock page 补造 expected / actual / trajectory。

HUD 开启时应展示：

- 目标 app/window 的 VirtualHID 解析窗口框。
- `ActionExecutor` 记录的实际 HID 事件轨迹。
- 点击、拖拽、滚轮、输入等事件效果。
- `OutcomeVerifier` 基于同一批 `ActionResult.events` 计算出的 `expectedPointer` 与 `finalPointer`。
- 常驻显示开启时，action 结束并超过清除延迟后仍保留最后一次 VirtualHID 目标窗口、状态、expected/final point；只清除动态轨迹和事件特效。

## 2. VirtualHID 正式 HUD / 控制面语义

HUD 是 daemon 启动时确定的 VirtualHID 自有观察层：通过 `--visualize-hid` 或 `VIRTUALHID_VISUALIZE_HID=1` 启动后，应持续作用于该 daemon 处理的每一次 `hid_action`，直到 daemon 退出或被禁用入口关闭。它不是某个 smoke、demo 或单次 action 的专用参数。

HUD 配置属于 VirtualHID 本地观察设置，不属于 `hid_action` 的业务数据。上游 Agent / browser / recruit-agent 不应在 action payload 中传 HUD 绘制开关、视觉样式或坐标修正字段；这些设置只影响 VirtualHID 如何展示自己已经执行和验证的事件，不改变 action 计划、事件生成、落点选择或 verification 结果。

`--no-hud` 或 `VIRTUALHID_NO_HUD=1` 具有最高优先级；关闭时 action、events、verification、trace 与分析链路仍照常产生，只是不挂 HUD sink。

`vhid-tray` 是 VirtualHID 的正式 macOS 菜单栏控制入口，不是 `vhid-daemon` 的附属启动模式。启动托盘即代表启动 VirtualHID 本地主程序；如果目标 socket 没有可用 daemon，托盘必须自动拉起带 `--hud-control --visualize-hid` 的 daemon，然后通过 daemon socket 调用 `hud.state / hud.configure`。托盘面板只允许修改 VirtualHID 本地 HUD 展示设置，例如 HUD 启停、轨迹、采样点、expected/final point、点击/拖拽/滚动/输入特效、状态文本和清除延迟；它不得写入 action payload、不得改变动作计划，也不得作为业务状态来源。

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
- daemon / action 状态文本。
- 事件轨迹线与轨迹采样点。
- expected / final 指针点。
- click / double-click 命中环。
- drag 起止与路径环。
- scroll 方向/幅度 glyph。
- keyboard / type / paste 输入徽标。
- HUD 清除延迟；常驻显示开启时该延迟只清动态轨迹/特效，关闭时到期后隐藏 HUD 内容。

这些内容只能来自 VirtualHID action events、execution context 和 verification；不得由网页 mock、browser snapshot 或 recruit-agent 自行补画。

配置入口：

- daemon 启动参数：`--hud-control`、`--hud-show <components>`、`--hud-hide <components>`、`--hud-clear-delay <seconds>`。
- 环境变量：`VIRTUALHID_HUD_SHOW`、`VIRTUALHID_HUD_HIDE`、`VIRTUALHID_HUD_CLEAR_DELAY_SECONDS`。
- 组件名：`all`、`persistent`、`window-frame`、`diagnostic`、`trail`、`trail-points`、`expected-point`、`actual-point`、`click-effects`、`drag-effects`、`scroll-effects`、`keyboard-effects`、`status`。
- 交互入口：`vhid-tray` 在菜单栏显示 VirtualHID 图标，点击后打开同一批配置项的最小面板。

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

## 6. 手动 UI 验收命令

真实 HUD 需要 macOS 图形会话，无法稳定在 headless smoke 中断言。可用以下脚本人工确认透明覆盖层、鼠标穿透和绘制内容：

```bash
VIRTUALHID_HUD_SCREENSHOT=/tmp/virtualhid-hud-ui-smoke.png \
VIRTUALHID_HUD_RESPONSE=/tmp/virtualhid-hud-ui-smoke.json \
./scripts/hud-manual-ui.sh
```

该脚本会构建 `vhid-daemon`，在 AppKit 主循环中运行 `--smoke-hud-ui`，触发真实 `ControlService -> ActionExecutor -> HIDOverlayController` 路径，并用 `screencapture` 保存证据图。

默认情况下，`--smoke-hud-ui` 会解析当前运行中的 Chrome / Chromium / Edge / Safari 目标窗口，并用 VirtualHID 自己解析出的 `AXWebArea` / browser content viewport 做 viewport 到 screen 的映射。只有显式传 `--self-target` 时才进入自测 fallback；fallback 区域必须是主屏 `visibleFrame`，不得跨桌面或画到不可见区域。

预期：屏幕上短暂出现透明穿透 HUD，包含目标窗口虚线框、`HUD ACTIVE` 诊断标签、VirtualHID 事件轨迹、点击/滚动效果、expected/final 标记和 `HID dry-run click+scroll ...` 状态文本。`click` primitive 内部会生成拟人化鼠标移动轨迹；demo 不应再显式下发独立 `move` primitive，也不应出现来自网页 mock 的额外轨迹或坐标。

多屏坐标注意事项：Chrome/AX/CG 返回的窗口和事件点可能使用主屏顶部为基准的全局坐标，例如上方外接屏会出现负 Y。HUD 必须在 VirtualHID 内部把该坐标系转换为 AppKit `NSScreen.frame` 坐标后绘制；browser、recruit-agent 或 mock page 不得提供或修正 screen coordinate authority。

如果输出 `could not create image from display`，脚本会同时打印 `screencapture` 退出码、前后 `IODisplayWrangler` 状态和诊断信息。若显示器不是 `Current State 0` 仍失败，通常是当前 macOS GUI session、锁屏状态、空间/外接屏状态或 Screen Recording 权限阻止截图；此时只能标记为视觉证据环境阻塞，不能伪造通过。
