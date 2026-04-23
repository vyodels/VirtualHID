# InjectorCore

PR-1 将现有 `InjectorCLI` 中的浏览器解析、聚焦控制、按键映射、事件投递与原语执行逻辑拆到这里。

当前范围：
- `BrowserResolver` / `FocusController`
- `EventPoster` 的 `global` / `pid` / `auto` 路由
- 兼容旧 CLI scenario 的 `ActionExecutor`

默认投递模式已切到 `global`，`pid` 仅允许 `mouseMoved` / `scrollWheel`。
