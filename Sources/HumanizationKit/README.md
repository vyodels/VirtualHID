# HumanizationKit

纯算法拟人化策略库，不依赖 CoreGraphics / AppKit。InjectorCore 负责把这里的抽象点位与键码转换成 CGEvent。

当前包含：
- WindMouse 轨迹生成与固定点数重采样
- Bezier 轨迹生成
- ASCII 键码映射
- Keystroke rhythm dwell / delay 采样
- 默认 HumanizationProfile 参数
