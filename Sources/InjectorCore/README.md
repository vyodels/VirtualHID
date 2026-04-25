# InjectorCore

`InjectorCore` 负责把上层动作请求执行成真实输入事件流。它不做 DOM 发现，也不做业务判断，但负责目标解析、焦点控制、事件投递与原语执行。

当前范围：
- `BrowserResolver` / `FocusController`
- `EventPoster` 的 `global` / `pid` / `auto` 路由
- `ActionExecutor`：`move / click / drag / scroll / type / key`
- `PrimitiveProfile`：支持起点提示与 motion profile 注入
- `click` / `drag` 的完整事件流，避免视觉跳点

默认投递模式已切到 `global`，`pid` 仅允许 `mouseMoved` / `scrollWheel`。

边界说明：

- 只执行上游传入的固定目标点或允许落点区域；`landingZone` 内的最终落点采样由 VirtualHID 执行证据返回，但目标区域本身必须来自上游观察证据
- `ActionContext` 只读 `host / element.sig / element.role / taskId / stage / hints.urgency`
- 不得根据 `host/url/text` 做业务分支
- 目标解析当前仍以 app / window 为主；`windowId / tabId / viewport` 级执行见活动计划：
  `../../docs/plan/active/2026-04-24-targeting-and-replay-plan_cn.md`
