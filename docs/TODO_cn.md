# TODO

## 当前剩余能力

以下几项仍未完成，因此对应活动计划还保留在 `docs/plan/active/`：

- 回放级 `compact trace` 指纹与 retention：`ReplayTraceStore` 与分析器已支持基础指纹 / retention / replay-aware report；仍缺 daemon 内自动生成、持久化接入和真实长期样本验证
- `windowId / tabId / host` 级目标解析与激活：当前仍主要依赖 app / 可见窗口
- viewport → OS 坐标换算：当前已支持基础映射，真实滚动后二次换算和窗口变化后的重采样仍需补齐
- 执行结果证据化：当前能确认事件已投递，但还缺结构化“是否点中 / 是否被观察到 / 是否语义确认成功”
- Codex replay-aware 自动调参：当前能消费 `replayFingerprint / compactTrace` 并输出建议；仍缺从真实长期样本到 profile 应用的自动闭环验收

## 中文输入支持

当前 `ActionCore.type(text:)` 只支持已映射的 ASCII 物理按键。中文、emoji、未映射符号会被跳过；系统不会把中文自动还原为拼音按键序列，例如不会把“鼠标”还原成 `shubiao`。

后续需要单独设计中文输入路径：

- `pasteText`：将中文写入剪贴板后模拟 `Cmd+V`。优点是稳定；缺点是不像真实逐字输入。
- `imePinyin`：将中文转成拼音按键并模拟输入法确认。需要处理多音字、候选词排序、当前输入法状态和候选选择，复杂度较高。
- 学习方案：先采集真实用户中文输入的 IME 行为，包括拼音节奏、候选确认、退格修正，再决定是否回放拼音序列或生成 profile。

建议优先级：先实现 `pasteText` 作为可靠 fallback，再设计 `imePinyin` 的采集和回放。

## 目标解析 / 坐标换算 / 回放级学习

M2-M7 主计划已经完成，但下一阶段还有一组结构性能力待补：

- 回放级 `compact trace` 指纹：基础指纹与 replay-aware 分析已落地；下一步要接入 daemon 持久化和真实样本回归
- `windowId / tabId / host` 级目标解析与激活
- viewport → OS 绝对坐标换算下沉到 VirtualHID
- 执行结果证据化：区分“事件已发出”和“语义确认成功”

当前边界已固定：

- **实际落点和轨迹只能由 VirtualHID 生成**
- 调用方必须传目标锚点；可附带 `landingZone` 表达允许落点区域，但不能传外部生成的实际落点、轨迹或补点动画
- 网页目标必须传可追溯的 host 归因语义；host 只能来自 browser active tab、tab list、snapshot URL 或上游已规范化 `browser_target.host`，并应在 `target.host` / `context.host` / `trace.commit.host` 中保持一致
- `region / targetSpread` 这类未收敛为目标锚点或 `landingZone` 的含糊区域仍视为上游契约错误
- 鼠标 / 键盘 action 在 daemon 内已经全局串行，不再允许并发交叉执行

详细方案见：

- `docs/plan/active/2026-04-24-targeting-and-replay-plan_cn.md`
