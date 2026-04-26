# TODO

## 当前剩余能力

以下几项仍需后续跨项目或真实长期样本验证，因此对应活动计划还保留在 `docs/plan/active/`：

- Edge/Safari live 矩阵：Chrome `windowId / tabId / host` 目标归因已通过 live smoke，Edge/Safari 仍需真实浏览器环境复验。
- 滚动后跨项目重采样链路：VirtualHID 已返回 `E_VIEWPORT_RESAMPLE_REQUIRED` 阻止旧坐标盲点；真正“滚动 -> browser/Agent 重采样 -> 再执行”需要上游提交更新后的 `scrollOffset/pageScale/viewport`。
- 真实长期样本质量：daemon replay 指纹持久化、被动鼠标习惯学习、专项训练和 synthetic proposal/apply smoke 已完成；仍需人工/HID 真实样本对照验证 profile 是否持续收敛。
- `imePinyin`：中文 `pasteText` fallback 已可用；逐字拟人化 IME 采集/回放仍未实现。

## 中文输入支持

当前 `ActionCore.type(text:)` 会优先使用已映射的物理按键；遇到中文、emoji、未映射符号时会自动降级到 `pasteText`，避免静默跳过。系统仍不会把中文自动还原为拼音按键序列，例如不会把“鼠标”还原成 `shubiao`。

后续需要单独设计中文输入路径：

- `pasteText`：已实现，将中文写入剪贴板后模拟 `Cmd+V`，默认尝试恢复原文本剪贴板。优点是稳定；缺点是不像真实逐字输入。
- `imePinyin`：将中文转成拼音按键并模拟输入法确认。需要处理多音字、候选词排序、当前输入法状态和候选选择，复杂度较高。
- 学习方案：先采集真实用户中文输入的 IME 行为，包括拼音节奏、候选确认、退格修正，再决定是否回放拼音序列或生成 profile。

建议优先级：继续设计 `imePinyin` 的采集和回放；不得用业务文案硬编码拼音序列。

## 目标解析 / 坐标换算 / 回放级学习

M2-M7 主计划已经完成，但下一阶段还有一组结构性能力待补：

- 回放级 `compact trace` 指纹：daemon 持久化、被动学习和专项训练已落地；下一步是真实样本回归
- `windowId / tabId / host` 级目标解析与激活：Chrome 已有 live smoke；Edge/Safari 待矩阵
- viewport → OS 绝对坐标换算下沉到 VirtualHID；primitive 坐标、origin 与 landingZone 已统一映射
- 执行结果证据化：已区分注入、指针、焦点、observer 和语义确认；页面语义成功仍由 browser / Agent 回写

当前边界已固定：

- **实际落点和轨迹只能由 VirtualHID 生成**
- 调用方必须传目标锚点；可附带 `landingZone` 表达允许落点区域，但不能传外部生成的实际落点、轨迹或补点动画
- 网页目标必须传可追溯的 host 归因语义；host 只能来自 browser active tab、tab list、snapshot URL 或上游已规范化 `browser_target.host`，并应在 `target.host` / `context.host` / `trace.commit.host` 中保持一致
- `region / targetSpread` 这类未收敛为目标锚点或 `landingZone` 的含糊区域仍视为上游契约错误
- 鼠标 / 键盘 action 在 daemon 内已经全局串行，不再允许并发交叉执行

详细方案见：

- `docs/plan/active/2026-04-24-targeting-and-replay-plan_cn.md`
- `docs/plan/active/2026-04-26-browser-targeting-learning-hud-completion-plan_cn.md`
