# VirtualHID 下一阶段实施计划 · 目标解析 / 坐标换算 / 回放级指纹

> **文档角色**：M2-M7 完成后的下一阶段活动计划
> **状态**：🟡 进行中（边界已冻结；固定点契约 / 串行执行 / 服务控制已完成，核心能力待继续实施）
> **承接文档**：`docs/plan/completed/2026-04-23-virtualhid-impl_cn.md`
> **目标**：把“摘要级学习”推进到“可回放、可验证、可长期优化”的执行与分析体系

---

## 0. 为什么要开新计划

M2-M7 已经把基础执行、学习闭环、长期摘要分析补齐，但还存在 4 个结构性缺口：

1. 长期分析目前主要基于摘要指标（速度、直线度、停顿等），**不够回放级**。
2. 请求里传给 VirtualHID 的仍主要是**绝对点位**，坐标换算还没有完整下沉。
3. 目标解析目前停留在 `bundleId + 可见窗口`，还没有稳定覆盖 `windowId / tabId / host` 级别的激活。
4. 执行成功目前主要是“事件已发出”，还不是“目标确实点中 / 结果确实发生”。

本计划专门解决这些缺口。

### 0.1 当前快照（2026-04-24）

本计划启动前，仓库已经先补齐了一批基础能力：

- 固定目标点契约已经收紧；`landingZone / region / targetSpread` 不再属于 VirtualHID 输入
- `click` / `drag` 已有完整前置慢速移动，禁止视觉跳点
- daemon `action` 已改为全局串行执行，避免键盘和鼠标并发交叉
- `trace.commit -> profiles.rebuild -> applyProfiles` 学习闭环已打通
- Web 实验台已提供 `长期分析 / 接口与 Codex` 导航，`report_server.py` 已支持 daemon 自动拉起、`/hid/daemon` 状态查看和 `/hid/restart` 重启

因此，这份活动计划现在只聚焦**还没做完**的那部分：目标激活、坐标换算、回放级指纹、执行证据和 replay-aware 分析。

---

## 1. 先解释：什么是“回放级 compact trace 指纹”

当前已经落地的是**摘要级历史分析**：保存一条指令在人工/HID 两侧的统计结果，例如：

- 平均速度
- 直线度
- 转向抖动
- 点数密度
- 停顿次数
- 行为模式混合

这能做调参，但**不能重建一段像人的节奏片段**。

“回放级 compact trace 指纹”指的是：**不保存完整原始事件流，也不保存 DOM/文本，但保存足以重建节奏与路径骨架的压缩指纹**。它通常包含：

- 指令键：`host + taskId + stage + instructionKey + actionType`
- 目标锚点：原点、固定目标点、末端收敛误差分布
- 路径骨架：8-24 个控制点或分段控制向量
- 时间骨架：每段耗时、hesitation、settle、click hold、inter-click、scroll burst
- 行为标签：`idle / normal / flow / lowEfficiency`、`smooth / gentle / hurried`
- 质量标签：样本数、方差、置信度、时间衰减权重

它的特点是：

- **比原始事件流小很多**：适合长期保存和聚合
- **比摘要统计保真很多**：可以重建“像人的节奏片段”
- **保留随机性**：回放时按分布采样，不是机械复读

它不是全量录像，也不是 DOM snapshot；它是“可重建行为节奏的压缩手势指纹”。

---

## 2. 当前边界与红线

这一阶段仍然严格继承旧文档 §9.4 红线：

- VirtualHID **不能**访问 DOM、发网络请求、解析 HTML。
- VirtualHID **不能**把 signature 生成搬进来。
- `ActionContext` 仍然只允许读白名单字段：`host / element.sig / element.role / taskId / stage / hints.urgency`。
- 不允许根据 `host/url/text` 做业务判断。

因此，下面这条边界要明确：

- **元素发现、DOM 可见性判断、站点业务语义** 仍然在 Agent / browser-mcp 一侧。
- **窗口激活、tab 激活、viewport→OS 坐标换算、慢速轨迹执行、执行结果证据聚合** 下沉到 VirtualHID。

也就是说，VirtualHID 负责“怎么执行”，但不负责“页面上哪个按钮叫提交”。

---

## 3. 新请求契约（拟定）

为避免污染 `ActionContext`，新增显式执行字段：

```json
{
  "id": "action-001",
  "target": {
    "bundleId": "com.google.Chrome",
    "windowId": 91234,
    "tabId": 187654321,
    "host": "example.com"
  },
  "geometry": {
    "coordSpace": "viewport",
    "viewportInScreen": { "x": 120, "y": 94, "width": 1280, "height": 800 },
    "pageScale": 1,
    "scrollOffset": { "x": 0, "y": 640 }
  },
  "primitives": [
    {
      "type": "click",
      "at": { "x": 820, "y": 438 },
      "behaviorMode": "normal",
      "flavor": "smooth"
    }
  ],
  "context": {
    "host": "example.com",
    "element": { "sig": "sig-123", "role": "button" },
    "taskId": "checkout",
    "stage": "submit",
    "hints": { "urgency": "normal" }
  }
}
```

关键点：

- `target`：目标应用 / 窗口 / tab 的解析信息，**不放进** `ActionContext`
- `geometry`：由外部提供 viewport 快照，VirtualHID 负责换算
- `at`：调用方必须传**固定目标点**；随机落点由上游在传入前完成
- `behaviorMode / flavor`：允许显式提示；缺省时由学习模板决定

---

## 4. 工作流改造

### 4.1 Target Resolver v2

目标：从“只找 bundle 的可见窗口”升级为：

- 按 `bundleId` 找应用
- 按 `windowId` / `windowTitle` 定位窗口
- 按 `tabId` 或 `host` 激活指定 tab
- 激活后确认 `frontmost == true`

实现原则：

- Safari / Chrome / Edge 走各自可控的 AppleScript / AX 路径
- `tabId` 是强定位，`host` 是弱定位兜底
- 找不到明确目标时返回硬错误，不静默猜测

### 4.2 Viewport Coordinate Mapper

目标：把“viewport 内固定目标点”转换为 OS 绝对坐标。

职责：

- 接收 `viewportInScreen + scrollOffset + pageScale + at`
- 计算固定目标点对应的屏幕绝对坐标
- 若目标不在当前 viewport，可按计划滚动后再重新换算

注意：VirtualHID 做的是**几何换算**，不是 DOM 查询。

### 4.3 Execution Planner

目标：把“点击某固定点”扩展成完整事件流：

1. 激活目标 app / window / tab
2. 如需滚动，先滚动到目标点进入当前 viewport
3. 生成慢速鼠标轨迹，完整发出 `mouseMoved`
4. 执行 `mouseDown / mouseUp` 或 `drag` 全流
5. 落点后保留 settle / hesitation / overshoot 修正，但最终点必须等于请求点

原则：

- **禁止**直接从 A 点跳到 B 点
- `click` / `drag` / `scroll-before-click` 都必须走完整前奏
- 随机性来自模板分布采样，不来自纯随机乱抖

### 4.4 Outcome Verifier

目标：把“事件发出了”升级为“执行证据完整”。

证据分层：

- **注入层**：事件已成功投递
- **指针层**：光标最终收敛到请求点（或定义好的误差容忍阈值内）
- **焦点层**：目标 app / window / tab 确实已激活
- **观察层**：PassiveObserver 收到预期回声（move/click/drag/scroll）
- **语义层**：由 Agent/browser 侧确认 DOM 状态变化

说明：

- “点击有没有点上”这件事，VirtualHID **单独**无法做 DOM 语义验证。
- 正确设计是：VirtualHID 提供执行证据；Agent/browser 再做语义确认。

### 4.5 Replay Compact Trace

目标：把长期分析从摘要级升级到“节奏片段可重建”。

计划存储内容：

- 路径控制点指纹
- 分段时长指纹
- click/drag/scroll 特征段
- 行为模式混合
- 目标点与末端节奏误差分布

约束：

- 单条记录限制大小
- 只保留最近 N 条或最近 N 天
- 聚合后淘汰低质量、过旧、重复指纹

---

## 5. Codex 长期分析与自动调参

新增能力目标：

- 同一条指令可长期采集“人工 vs HID”的并行样本
- Codex 可按 `instructionKey` 看趋势，而不是只看单次 compare
- 分析器输出的不只是摘要，还要输出：
- 推荐行为模式混合
- 速度区间
- 点数区间
- hesitation / settle / detour 概率
- compact trace 指纹的优先级

调参原则：

- 学习结果是**概率分布**，不是固定值
- 高置信度命中站点/元素时覆盖更多参数
- 低置信度时回退到基础先验策略
- 旧样本按时间衰减，避免“学死”

---

## 6. 任务拆分

- [ ] W1 `ReplayTraceStore`：新增 compact trace 指纹 schema、压缩与 retention
- [ ] W2 `TargetResolverV2`：应用 / 窗口 / tab 激活与确认
- [ ] W3 `ViewportMapper`：viewport↔screen 坐标换算
- [ ] W4 `ExecutionPlanner`：scroll-to-visible、完整 click/drag 事件流、行为模式切换
- [ ] W5 `OutcomeVerifier`：注入层 / 指针层 / 焦点层 / observer 层证据
- [ ] W6 `Codex Analysis Loop v2`：从摘要级分析升级到 replay-aware 分析

已具备的基础：

- [x] `trace.commit -> profiles.rebuild -> applyProfiles` 学习闭环
- [x] 长期摘要分析脚本与 HTTP 接口
- [x] 行为模式混合与非匀速时间分配
- [x] `click` 前置缓慢移动
- [x] 固定目标点契约与非法区域参数拒绝
- [x] daemon 全局串行动作执行
- [x] Web 导航、daemon 自动拉起、`/hid/daemon` 与 `/hid/restart`

---

## 7. 验收标准

### 7.1 目标解析

- 指定 `bundleId + windowId + tabId` 时，VirtualHID 能稳定激活到目标 tab
- 指定 `host` 兜底时，找不到匹配 tab 要明确报错

### 7.2 坐标换算

- 调用方只传 viewport 固定点；VirtualHID 自行换算到 OS 坐标
- 页面缩放、滚动、窗口移动后仍能点中固定点

### 7.3 执行流

- `click` / `drag` 不允许直接跳点
- 事件记录里必须能看到完整 move/down/up 或 drag 流

### 7.4 结果验证

- 响应里必须返回执行证据，而不只是 `ok: true`
- 当 observer/Agent 语义确认失败时，响应应能区分“事件已发出但语义未验证”

### 7.5 长期学习

- 同一条指令重复采集后，HID 的速度/直线度/停顿分布逐步逼近人工区间
- compact trace 指纹能在不保存原始全量轨迹的前提下重建节奏片段

---

## 8. 迁移完成条件

当以下条件全部满足时，本计划可从 `active/` 移到 `completed/`：

- 调用方不再需要传 OS 精确坐标
- VirtualHID 能处理窗口/tab 激活与 viewport 换算
- 执行响应包含结构化执行证据
- 长期分析使用 compact trace 指纹，而不只依赖摘要指标
