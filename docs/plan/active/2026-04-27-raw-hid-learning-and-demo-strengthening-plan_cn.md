# VirtualHID 原始 HID 学习与可控演示强化计划

> **状态**：active  
> **创建日期**：2026-04-27  
> **承接文档**：`docs/plan/active/2026-04-26-browser-targeting-learning-hud-completion-plan_cn.md`  
> **目标**：把键鼠学习从“基础可用”推进到“原始 HID 事件完整、分布化、自适应、可观测、可重复演示”的核心能力。

---

## 1. 核心原则

- VirtualHID 只学习 macOS 原始键鼠事件语义，不学习 Chrome / DOM 派生事件语义。
- `mouseMoved`、`leftMouseDown`、`leftMouseUp`、`leftMouseDragged`、`scrollWheel`、`keyDown`、`keyUp`、`flagsChanged` 等是学习输入；`mouseenter`、`mouseleave`、`mouseover`、`mouseout` 不是原始 HID 事件，不进入学习模型。
- 如果后续需要“进入/离开目标区域”的可视化或分析，只能基于原始坐标流和可信几何区域派生，不能读取 DOM 或依赖浏览器事件。
- 学习结果不能是确定值。速度、轨迹、阶段节奏、按压时长、双击间隔、滚动幅度、键盘 dwell/inter-key、modifier 节奏等都必须表达为范围、分布或可采样时间序列。
- 每次生成的轨迹和键鼠事件不能完全相同，但必须与学习样本保持相似性和人类合理性。
- Replay 指纹是行为特征来源，不是逐点复读。`pathSkeleton / segmentMs` 应参与轨迹生成，但必须保留随机扰动、相似性约束和质量回退。
- HUD / 管理中心是观察和控制层，不是行为数据源；关闭 HUD 不得改变 HID 执行结果。

---

## 2. 强化任务

### W1. dblclick 一等学习模板

目标：把双击从 `count=2 + interClickMs` 的执行参数升级成可学习、可演示、可测试的独立行为模板。

任务：

- 从真实 `down -> up -> down -> up` 事件流中识别双击窗口。
- 学习第一次和第二次点击的按压时长、间隔、落点偏移、微移动和释放后停顿。
- `MotionProfile` 或后续 profile schema 必须表达双击分布，而不是只保存一个间隔均值。
- demo 中提供“完整双击演示”，逐步显示第一次下压、第一次松开、间隔、第二次下压、第二次松开。

验收：

- 同一模板多次生成的双击节奏相似但不完全一致。
- dry-run 事件流能明确区分两组 down/up，并返回双击学习字段。
- 测试覆盖 learned-vs-disabled 的双击间隔和落点偏移差异。

### W2. drag 完整时间流学习

目标：把拖拽作为完整鼠标行为学习，而不是只记录 dragged 事件。

任务：

- 学习 `移动到起点 -> down -> 持续拖动 -> up -> release/settle` 的完整时间流。
- 学习拖拽路径骨架、分段节奏、阶段速度、按住时长、释放后恢复。
- 支持拖拽轨迹的相似性生成，不允许每次复读同一条线。
- demo 中提供“完整拖拽演示”，显示起点、终点、按住、拖动、释放和速度/时长摘要。

验收：

- drag 样本能重建路径骨架和 `segmentMs`。
- drag 执行会受学习 profile 影响，并在 tests 中与 disabled profile 产生可解释差异。
- HUD 能展示 drag 过程中连续轨迹、起点、终点、实际落点和阶段信息。

### W3. scrollWheel 分布学习

目标：滚轮学习必须覆盖方向、delta、节奏、惯性和分段。

任务：

- 在 observer / learning payload 中保留 scroll delta、方向、事件间隔和连续滚动 burst。
- 学习单次滚动幅度、连续滚动段数、段内节奏、段间停顿和惯性衰减。
- 执行 scroll 时从学习分布采样，而不是固定使用调用方传入的一次性 dx/dy。
- demo 中提供“滚轮演示”，显示每段 delta、方向、时间间隔和惯性曲线。

验收：

- scroll sample 中能看到 delta 序列和 rhythm。
- learned profile 能改变 dry-run scroll 事件数量、delta 分布和时间序列。
- 不保存页面文本、DOM 或截图。

### W4. keyboard 分布学习

目标：键盘学习从 dwell/inter-key 均值升级为完整键盘事件分布。

任务：

- 学习 `keyDown -> keyUp` 的 dwell 分布，`keyUp -> next keyDown` 的 inter-key 分布。
- 学习 `flagsChanged` / modifier 的按住、组合键、释放顺序。
- 学习重复键、修正键、组合键和文本输入节奏，不保存敏感文本正文。
- `dwellMsMean / interKeyMsMean` 需要升级为范围或分布字段，并保持兼容旧模板。
- demo 中提供“键盘事件演示”，显示每个 keyDown/keyUp、modifier、dwell、inter-key，不真实输入敏感文本。

验收：

- keyboard profile 保存分布字段，而不是只有均值。
- type dry-run 能证明 learned profile 改变 dwell/inter-key 序列。
- modifier / combo / repeat 至少有基础样本和测试覆盖。

### W5. pathSkeleton / segmentMs 参与生成

目标：Replay 指纹里的路径骨架和分段节奏必须从“仅存证据”变成“影响执行”的学习输入。

任务：

- 从高质量样本中选择或聚合路径骨架模板。
- 在 move/click/drag 生成中融合 path skeleton：约束大体路径形态，同时加入随机扰动和落点采样。
- 在 timing curve 中融合 `segmentMs`：保留加速、减速、停顿、阶段差异，而不是重新生成均匀时间。
- 低质量、样本不足或目标距离差异过大时回退到基础 Wind/Bezier 生成。

验收：

- tests 能证明有 path skeleton / segmentMs 的 profile 会影响 dry-run 轨迹点和时间戳。
- 生成轨迹相似但不完全一致。
- 不允许逐点固定复读单条人工轨迹。

### W6. 管理中心可控演示

目标：学习效果演示必须人工分步可控、可重复、可观测。

任务：

- 演示最多只能开启一个；新演示开始前必须停止旧演示。
- 演示应在当前桌面/当前可见屏幕显示，不跳到其他 Space。
- 每类动作由用户手动触发：移动演示、完整点击演示、双击演示、拖拽演示、滚轮演示、键盘演示。
- 每个动作都可重复点击播放，不自动跳到下一个动作。
- 每个动作完成后保留 HUD 结果数秒，并允许重复回放。
- HUD 必须显示起始点、目标点、实际点、轨迹、阶段标签、速度、按压时长、间隔、delta、dwell/inter-key 等关键事件信息。
- 轨迹必须到达本次演示目标区域后才结束；不能出现“轨迹还没到就没了”。

验收：

- 管理中心能选择并重复播放单个动作。
- HUD 显示起始点、目标点、实际点和完整轨迹。
- 点击/双击/拖拽/滚轮/键盘演示均不真实触发外部应用操作，但事件链和时间线完整可见。

---

## 3. 执行顺序

1. 先完成 profile schema 的兼容扩展，保证旧数据可读。
2. 再补 observer / passive learning 的原始事件字段采集。
3. 然后接入 ActionCore 的 profile 应用逻辑。
4. 最后完成管理中心演示和 HUD 可视化。

---

## 4. 不做事项

- 不把 Chrome / DOM 的 `mouseenter/mouseover` 等事件写入 HID 学习层。
- 不解析 DOM、不注入页面 JS、不读取页面文本来判断行为。
- 不用脚本替代管理中心能力验收。
- 不保存完整原始轨迹、截图、页面文本或敏感键入内容。
