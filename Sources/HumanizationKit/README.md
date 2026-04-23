# HumanizationKit

纯算法拟人化策略库，不依赖 CoreGraphics / AppKit。`InjectorCore` 负责把这里的抽象路径、时序和键节律转换成 `CGEvent`。

当前包含：
- `WindMouse` / `BezierMouse` 路径生成
- `HumanTimingCurve`：加速-巡航-减速、hesitation、settle
- `MotionProfile`：速度区间、点数区间、落点 spread、click/drag/type 参数
- `BehaviorBlend`：`idle / normal / flow / lowEfficiency` 概率混合
- `KeystrokeRhythm`：ASCII 键映射与 dwell / inter-key 节律采样
- 默认 `HumanizationProfile` 参数

设计原则：

- 只输出“路径骨架 + 时间骨架 + 分布采样结果”
- 不关心浏览器、窗口、坐标系、CGEvent、权限
- 学习结果必须以**分布**形式参与执行，避免学成固定脚本
