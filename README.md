# VirtualHID

VirtualHID 是一个面向 macOS 的拟人化输入执行与学习仓库。它负责把上层 Agent 给出的目标、固定落点和动作序列，转换成真实的鼠标/键盘事件流，并通过观察、聚合和长期分析不断调整自己的执行参数。

## 当前能力

- `InjectorCore`：目标窗口解析、焦点控制、事件投递、动作原语执行
- `HumanizationKit`：轨迹生成、时间曲线、键盘节律、行为模式混合
- `Supervisor`：kill switch、被动观察、事件 tap
- `ProfileStore`：SQLite trace/template 存储、聚合、遗忘与 retention
- `ControlServer` + `InjectorDaemon`：Unix socket JSON-RPC 后端
- `mcp/`：MCP stdio shim，向 Agent 暴露 `hid_*` 工具
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
swift build
swift test
.build/debug/vhid-daemon
node mcp/server.mjs
PORT=8123 python3 scripts/report_server.py
python3 scripts/humanization_analysis.py --pretty
```

如果只做 profile 学习链路冒烟，可运行：

```bash
./scripts/profile-learn-smoke.sh
```

## 学习链路

当前学习闭环已经打通：

1. `PassiveObserver` 采集真实事件
2. Agent / web demo 补齐 `host + sig + taskId + stage`
3. `trace.commit` 写入 `ProfileStore`
4. `profiles.rebuild` 生成学习模板
5. `action` 时命中模板并应用到 move / click / drag / type / key

长期分析则由 `scripts/humanization_analysis.py` 和 `results/humanization-history.jsonl` 负责，按 `instructionKey` 聚合人工/HID 差异并输出调参建议。

## 重要边界

- VirtualHID 不访问 DOM、不发网络请求、不解析 HTML
- VirtualHID 只接收**固定目标点**；落点随机性、区域采样由上游项目负责
- `ActionContext` 只读白名单字段：`host / element.sig / element.role / taskId / stage / hints.urgency`
- `global` 投递模式下必须先满足 `targetApp.frontmost == true`
- `pid` 模式只允许 `mouseMoved / scrollWheel`
- daemon 内 action 执行是**全局串行**的，避免鼠标/键盘并发交叉

## 相关文档

- 已完成实施文档：`docs/plan/completed/2026-04-23-virtualhid-impl_cn.md`
- 下一阶段活动计划：`docs/plan/active/2026-04-24-targeting-and-replay-plan_cn.md`
- 待办：`docs/TODO_cn.md`
