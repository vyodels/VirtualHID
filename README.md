# VirtualHID

VirtualHID 是一个面向 macOS 的拟人化输入执行与学习仓库。它负责把上层 Agent 给出的目标、固定落点和动作序列，转换成真实的鼠标/键盘事件流，并通过观察、聚合和长期分析不断调整自己的执行参数。

## 当前状态（2026-04-24）

已完成：

- M2-M7 主实施范围已经归档到 `docs/plan/completed/2026-04-23-virtualhid-impl_cn.md`
- 固定目标点契约、完整点击前奏、非匀速时间曲线、全局串行动作执行
- `trace.commit -> profiles.rebuild -> applyProfiles` 学习闭环
- 长期拟人度分析脚本 / HTTP 接口 / Web 实验台导航
- `report_server.py` 对 `vhid-daemon` 的自动拉起、状态查看和重启控制

仍在进行：

- `windowId / tabId / host` 级目标激活
- viewport → OS 坐标换算下沉到 VirtualHID
- 回放级 compact trace 指纹
- 执行结果证据化与语义确认协作

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
.build/x86_64-apple-macosx/debug/vhid-daemon
node mcp/server.mjs
PORT=8123 python3 scripts/report_server.py
python3 scripts/humanization_analysis.py --pretty
```

如果只做 profile 学习链路冒烟，可运行：

```bash
./scripts/profile-learn-smoke.sh
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

长期分析则由 `scripts/humanization_analysis.py` 和 `results/humanization-history.jsonl` 负责，按 `instructionKey` 聚合人工/HID 差异并输出调参建议。当前仍是**摘要级长期分析**；更高一层的 replay-aware 分析见活动计划。

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
- 贡献说明：`AGENTS.md` / `AGENTS_cn.md`
