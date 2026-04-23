# VirtualHID 侧实施文档 · M2-M7

> **本文档角色**：VirtualHID 仓库在跨系统 HID 方案中的**主战场**实施说明
> **对应主文档**：同目录下的 `2026-04-23-hid-and-learning-plan_cn.md`（软链到 `~/AgentProjects/mcp-browser-chrome/docs/plan/active/` 下的正本）
> **覆盖里程碑**：M2 → M7
> **不覆盖**：M1（browser-mcp 侧的 signature 字段）、M7 里 Agent skill 蒸馏的 Agent 端实现
> **开发前置**：macOS 13+ / Swift 5.9+ / Xcode CLT / 已有 Accessibility 授权
> **状态**：✅ 已完成（VirtualHID 仓库侧，2026-04-23）

完成说明：

- M2-M6 已按本仓库实施范围落地并通过自动化验证。
- M7 的 VirtualHID 侧 daemon / MCP / profile / observer 接口已落地；Agent skill 蒸馏属于本文档明确“不覆盖”的 Agent 端工作。
- 当前遗留 TODO 仅为后续增强项，例如中文输入 `pasteText` / `imePinyin` 方案，不影响本计划完成状态。

---

## 0. 现状盘点

当前仓库能力（截至本文档写作时）：

| 模块 | 位置 | 能力 |
|---|---|---|
| `InjectorCLI` | `Sources/InjectorCLI/` | 硬编码 5 个 scenario，Chrome / Edge / Safari 支持，`CGEvent.postToPid` 做注入 |
| `BrowserResolver` | `Sources/InjectorCLI/BrowserResolver.swift` | 按 bundle id 解析窗口 frame |
| `FocusController` | `Sources/InjectorCLI/FocusController.swift` | `NSRunningApplication.activate` + TextEdit 作为 blur 测试目标 |
| `ScenarioRunner` | `Sources/InjectorCLI/ScenarioRunner.swift` | 场景执行器 + JSON 结果落 `results/` |
| `FocusHolderApp` | `Sources/FocusHolderApp/` | 用于测试的焦点持有器 |
| 自标记 | `eventSourceUserData = 0x56484944` | 已埋好自识别通道——M3 kill switch 会用到 |

**demo 阶段的一个重要实测结论**（必须在 M2 里响应）：`CGEvent.postToPid(pid)` 在目标窗口**非前台**时只能投递 `kCGEventMouseMoved`，`leftMouseDown/Up`、`keyDown/Up`、滚轮事件会被 WindowServer 丢弃或落到前台窗口。因此：

- `CGEventPost`（全局事件流，`.cgSessionEventTap`）作为**主力投递模式**
- `CGEventPostToPid` 保留作为**探测 / 诊断模式**，仅投递 `mouseMoved` 类事件
- 两种模式由外层 `postMode: "global" | "pid" | "auto"` 参数选择（详见主文档 §3.7）

**能留的**：`BrowserResolver`、`FocusController`、`eventSourceUserData` 自标记 —— 这些不要改。

**要改造的**：`ScenarioRunner` 里直接 `event.postToPid(pid)` 的调用全部改走新的 `EventPoster` 抽象（下节），让投递模式可切换。

**要重构的**：`ScenarioRunner` 的硬编码场景表 —— 拆成"原语执行器"。

**要新增的**：Humanization / Supervisor / ControlServer / StateReporter / ProfileStore 五大模块。

---

## 1. 目标包结构

```
VirtualHID/
├─ Package.swift                      # 扩展 targets
├─ Sources/
│  ├─ InjectorCore/                   # 新 (从 InjectorCLI 拆出，纯逻辑库)
│  │  ├─ ActionCore.swift             # move/click/drag/scroll/type/key 原语
│  │  ├─ KeyMap.swift                 # 扩展版键映射
│  │  ├─ BrowserResolver.swift        # (迁自 InjectorCLI)
│  │  ├─ FocusController.swift        # (迁自 InjectorCLI)
│  │  └─ EventPoster.swift            # global / pid / auto 投递模式 + 自标记 + 前置检查
│  ├─ HumanizationKit/                # 新 (纯算法库，可单测)
│  │  ├─ WindMouse.swift              # 鼠标轨迹
│  │  ├─ KeystrokeRhythm.swift        # Beta / Log-Normal 分布采样
│  │  ├─ Distributions.swift          # 分布采样工具
│  │  └─ ProfileApplier.swift         # 把 Template 参数应用到原语
│  ├─ Supervisor/                     # 新
│  │  ├─ EventTap.swift               # CGEventTap 封装
│  │  ├─ KillSwitch.swift             # 5×ESC 检测 + 修饰键释放
│  │  ├─ PassiveObserver.swift        # 真实用户事件记录
│  │  └─ SupervisorService.swift      # 对外 facade
│  ├─ ProfileStore/                   # 新
│  │  ├─ TraceDB.swift                # SQLite 读写 (SQLite3 C API，Swift 自带)
│  │  ├─ Aggregator.swift             # Trace → Template
│  │  └─ TemplateLookup.swift         # 执行时命中逻辑
│  ├─ ControlServer/                  # 新 (InjectorDaemon 后端入口，M4a)
│  │  ├─ SocketServer.swift           # Unix domain socket
│  │  ├─ JsonRpc.swift                # newline-delimited JSON
│  │  ├─ RequestRouter.swift          # method dispatch
│  │  └─ StateReporter.swift          # state snapshot 聚合
│  ├─ InjectorCLI/                    # 瘦身后的 CLI (调试入口)
│  │  └─ main.swift                   # --smoke / --scenarios 等手动测试
│  ├─ InjectorDaemon/                 # 新 (M4a 落地)
│  │  └─ main.swift                   # 主守护进程入口，加载 Supervisor + ControlServer
│  └─ FocusHolderApp/                 # 保留
├─ mcp/                                # 新 (M4b 落地，Node.js 薄 shim)
│  ├─ server.mjs                       # MCP stdio server，暴露 hid_* 工具，转发到 InjectorDaemon
│  ├─ tools.mjs                        # hid_* 工具表 + JSON Schema
│  └─ errors.mjs                       # E_* ↔ MCP isError 映射
└─ Tests/
   ├─ HumanizationKitTests/
   ├─ ProfileStoreTests/
   └─ ControlServerTests/
```

**关键拆分原则**：

- `InjectorCore` 是纯逻辑，**不**依赖任何其他新模块
- `HumanizationKit` 只依赖 `Foundation`（可完全离线单测）
- `Supervisor` 依赖 `InjectorCore`（要调用释放修饰键的原语）
- `ProfileStore` 独立于其他，只靠 `Foundation` + SQLite
- `ControlServer` 组装所有模块，是 `InjectorDaemon` 的 runtime（Unix socket 后端）
- `mcp/` 是 Node.js 薄 shim，**零业务逻辑**，只做 MCP ↔ Unix socket 协议转换；对外是 Agent 的唯一正式入口
- `InjectorCLI` 保留作为**开发期手动验证**工具，**不**是产品入口

---

## 2. `Package.swift` 调整

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VirtualHID",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "injector", targets: ["InjectorCLI"]),
        .executable(name: "focus-holder", targets: ["FocusHolderApp"]),
        .executable(name: "vhid-daemon", targets: ["InjectorDaemon"]),
        .library(name: "InjectorCore", targets: ["InjectorCore"]),
        .library(name: "HumanizationKit", targets: ["HumanizationKit"]),
    ],
    targets: [
        .target(name: "InjectorCore", path: "Sources/InjectorCore"),
        .target(name: "HumanizationKit", path: "Sources/HumanizationKit"),
        .target(name: "Supervisor",
                dependencies: ["InjectorCore"],
                path: "Sources/Supervisor"),
        .target(name: "ProfileStore", path: "Sources/ProfileStore"),
        .target(name: "ControlServer",
                dependencies: ["InjectorCore", "HumanizationKit", "Supervisor", "ProfileStore"],
                path: "Sources/ControlServer"),
        .executableTarget(name: "InjectorCLI",
                          dependencies: ["InjectorCore", "HumanizationKit"],
                          path: "Sources/InjectorCLI"),
        .executableTarget(name: "InjectorDaemon",
                          dependencies: ["ControlServer"],
                          path: "Sources/InjectorDaemon"),
        .executableTarget(name: "FocusHolderApp", path: "Sources/FocusHolderApp"),
        .testTarget(name: "HumanizationKitTests",
                    dependencies: ["HumanizationKit"],
                    path: "Tests/HumanizationKitTests"),
        .testTarget(name: "ProfileStoreTests",
                    dependencies: ["ProfileStore"],
                    path: "Tests/ProfileStoreTests"),
    ]
)
```

---

## 3. M2 — Humanization Layer（默认策略，不含学习）

**目标**：拆出 `InjectorCore` + `HumanizationKit`，让现有 5 个硬编码 scenario 变成"可复用原语 + 默认拟人策略"的组合。学习暂不接入，execution 走默认参数。

### 3.1 `InjectorCore.ActionCore`

核心接口：

```swift
public enum ActionPrimitive {
    case move(to: CGPoint, via: TrajectoryStyle, durationMs: Int?)
    case click(at: CGPoint, button: MouseButton, holdMs: Int?, count: Int)
    case drag(from: CGPoint, to: CGPoint, button: MouseButton, via: TrajectoryStyle)
    case scroll(at: CGPoint, dx: Double, dy: Double, style: ScrollStyle)
    case type(text: String, layout: KeyboardLayout)
    case key(chord: KeyChord, holdMs: Int?)
}

public enum TrajectoryStyle {
    case linear, bezier, wind, profile(Template)
}

public struct ActionRequest {
    public let id: String
    public let primitives: [ActionPrimitive]
    /// 不透明业务标签，由 Agent 组装并传入。VirtualHID 只读取 host / element.sig / taskId / stage / hints.urgency 几个白名单字段（详见主文档 §6.4）。
    public let context: ActionContext
    public let options: ActionOptions
}

public struct ActionOptions: Codable {
    /// 缺省使用 StateReporter.defaultPostMode（= .global）
    public var postMode: PostMode?
    public var timeoutMs: Int?
    public var dryRun: Bool
}

public enum PostMode: String, Codable {
    case global   // CGEvent.post(tap: .cgSessionEventTap)，默认
    case pid      // CGEvent.postToPid(pid)，仅用于探测类 move/scroll
    case auto     // 先试 pid；遇到不支持的事件类型 fallback 为 global
}

public struct ActionResult: Codable {
    public let id: String
    public let ok: Bool
    public let error: String?
    public let events: [InjectedEvent]  // 沿用现有结构
    public let elapsedMs: Int
}

public actor ActionExecutor {
    public func execute(_ request: ActionRequest) async throws -> ActionResult
    public var isBusy: Bool { get }
    public func cancel()
}
```

**执行策略路由**：

```swift
private func resolveStyle(_ raw: TrajectoryStyle, ctx: ActionContext) -> TrajectoryResolver {
    switch raw {
    case .profile(let tpl): return ProfileResolver(template: tpl)
    case .wind:             return WindMouseResolver(defaultParams)
    case .bezier:           return BezierResolver(defaultParams)
    case .linear:           return LinearResolver()
    }
}
```

M2 阶段只实现 `linear`、`bezier`、`wind`；`profile` 在 M6 接入。

### 3.1bis `InjectorCore.EventPoster` — 投递模式抽象（M2 必做）

```swift
public final class EventPoster {
    public let mode: PostMode
    public let targetPid: pid_t
    private let markValue: Int64 = 0x56484944

    public init(mode: PostMode, targetPid: pid_t) { ... }

    /// 执行前的"能投递吗"预检。global 模式要求目标 App 是前台。
    public func preflight(frontmost: Bool) throws {
        switch mode {
        case .global:
            guard frontmost else { throw PosterError.notFrontmost }
        case .pid, .auto:
            break  // postToPid 允许非前台
        }
    }

    /// 单个事件投递。CGEventType 决定允许走哪条路径。
    public func post(_ event: CGEvent, type: CGEventType) throws {
        event.setIntegerValueField(.eventSourceUserData, value: markValue)

        switch mode {
        case .global:
            event.post(tap: .cgSessionEventTap)

        case .pid:
            guard isPidSafe(type) else { throw PosterError.postModeUnsupported(type) }
            event.postToPid(targetPid)

        case .auto:
            if isPidSafe(type) {
                event.postToPid(targetPid)
            } else {
                event.post(tap: .cgSessionEventTap)
            }
        }
    }

    /// 哪些事件能通过 postToPid 可靠投递
    private func isPidSafe(_ type: CGEventType) -> Bool {
        switch type {
        case .mouseMoved, .scrollWheel:
            return true
        default:
            return false
        }
    }
}

public enum PosterError: Error {
    case notFrontmost              // 映射到 ControlServer 的 E_NOT_FRONTMOST
    case postModeUnsupported(CGEventType)  // 映射到 E_POST_MODE_UNSUPPORTED
}
```

**`ActionExecutor.execute` 的开场调用链**（伪代码）：

```swift
let mode = request.options.postMode ?? stateReporter.defaultPostMode   // .global
let poster = EventPoster(mode: mode, targetPid: resolvedPid)

// 1. 前置聚焦（仅 global 需要；pid/auto 跳过）
if mode == .global {
    try focusController.ensureFrontmost(targetBundleId: ctx.host.asBundleIdHint ?? "com.google.Chrome",
                                        deadline: .milliseconds(260))
}
// 2. 状态预检
try poster.preflight(frontmost: stateReporter.currentFrontmost)
// 3. pid 模式下，任何 primitive 里出现 click/type/key/drag 直接拒
if mode == .pid {
    try ensurePidSafePrimitives(request.primitives)
}
// 4. 按 primitives 生成 CGEvent 并 try poster.post(event, type:)
```

**修饰键释放（kill switch 专用）例外**：`Supervisor.KillSwitch.releaseAllModifiers` 不走 `EventPoster`，直接 `event.post(tap: .cgSessionEventTap)` —— 因为修饰键 release 必须到达系统事件流，且 kill switch 发生时不能信任 `EventPoster` 的当前配置。

### 3.2 `HumanizationKit.WindMouse`

实现 Benjamin J. Land 的 WindMouse 算法。参考伪代码（MIT 兼容，可直接移植到 Swift）：

```swift
public struct WindMouseParams {
    public var gravity: Double = 9.0
    public var wind: Double = 3.0
    public var maxStep: Double = 15.0
    public var distanceDecay: Double = 12.0
    public var targetArea: Double = 4.0
    public init() {}
}

public enum WindMouse {
    public static func path(from start: CGPoint, to target: CGPoint,
                            params: WindMouseParams = WindMouseParams(),
                            rng: inout RandomNumberGenerator) -> [CGPoint] {
        // 完整实现见附录 A（这里只列接口）
    }
}
```

关键特征（必须通过测试验证）：

- 路径**非单调**（中间有抖动）
- 距离目标越近，步长越小（呼应 Fitts' law）
- 50% 概率产生 **overshoot + correction**
- 两次相同起终点调用产生**不同路径**（RNG 驱动）

### 3.3 `HumanizationKit.KeystrokeRhythm`

```swift
public struct KeyRhythmParams {
    public var dwellMsRange: ClosedRange<Int> = 40...180
    public var dwellShape: (alpha: Double, beta: Double) = (2.0, 5.0)   // Beta distribution
    public var intraWordMu: Double = log(110)
    public var intraWordSigma: Double = 0.35
    public var interWordMu: Double = log(180)
    public var interWordSigma: Double = 0.40
}

public enum KeystrokeRhythm {
    public static func schedule(for text: String,
                                params: KeyRhythmParams = KeyRhythmParams(),
                                rng: inout RandomNumberGenerator) -> [KeystrokeEvent]
}

public struct KeystrokeEvent {
    public let char: Character
    public let keyCode: CGKeyCode
    public let modifiers: CGEventFlags
    public let dwellMs: Int
    public let delayBeforeMs: Int    // 距离上一次 keyUp
}
```

**边界**：

- ASCII 按 `KeyMap` 直接映射
- 多字节字符（中文等）走"剪贴板 + cmd+v"路径，由 `ActionCore.type` 自动分流（不污染 `KeystrokeRhythm`）

### 3.4 M2 验收

- `swift test --filter HumanizationKit` 通过
- `InjectorCLI` 的 5 个现有 scenario 用新原语重写后，从外部观察**功能等价**（验证 `results/*.json` 的 events 数量和类型相同）
- 连续跑同一 scenario 5 次，`events[].location` 序列两两不同（证明引入了随机性）
- 跑一次完整 `--scenarios mouse_move_click_active`，鼠标轨迹**非单调**（可从 `results` JSON 验证）
- **投递模式验收**（`EventPoster` 单测 + CLI smoke）：
  - `mode=.global` + Chrome 前台 → `move` / `click` 全部投递成功（鼠标真的落在目标坐标且 Chrome 收到点击）
  - `mode=.global` + Chrome 非前台 → `poster.preflight` 抛 `notFrontmost`，**没有任何事件被投递**（用 CGEventTap 旁路验证）
  - `mode=.pid` + Chrome 非前台 + `move` → 成功（回归 demo 阶段能力）
  - `mode=.pid` + Chrome 非前台 + `click` → 抛 `postModeUnsupported(.leftMouseDown)`
  - `mode=.auto` + 混合 primitives + Chrome 非前台 → `move` 走 pid，`click` 走 global（但 global 前必须先激活，所以实际应 fallback 到 "auto 模式下遇到非 pid-safe 事件时等前台再投"）
- **CLI smoke**：`injector --smoke --post-mode global` 与 `--post-mode pid` 两条命令都要能跑通（pid 模式 scenario 精简为"仅 move"）

---

## 4. M3 — Supervisor 紧急停止（不含 observer）

**目标**：独立线程跑 `CGEventTap`，监听真实 ESC，5×ESC/1500ms 触发 kill switch。

### 4.1 `Supervisor.EventTap`

```swift
public final class EventTap {
    public init(eventsOfInterest: CGEventMask)
    public func start(callback: @escaping (CGEventType, CGEvent) -> Unmanaged<CGEvent>?) throws
    public func stop()
}
```

实现要点：

- 使用 `kCGSessionEventTap` 层
- `options: .listenOnly`（M3 阶段只听，不拦截；M5 的 observer 也是同层）
- **独立 `DispatchQueue`**，不占用主线程
- 启动时调用 `AXIsProcessTrustedWithOptions`；未授权时抛明确错误

### 4.2 `Supervisor.KillSwitch`

```swift
public final class KillSwitch {
    public var isActive: Bool { get }
    public var triggeredAt: Date? { get }
    public func feed(_ event: CGEvent, type: CGEventType)
    public func unlock()
    public var onTrigger: (() -> Void)?   // Daemon 订阅
}
```

核心逻辑：

```swift
func feed(_ event: CGEvent, type: CGEventType) {
    guard type == .keyDown else { return }
    let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
    guard keyCode == 0x35 else { return }  // ESC = 0x35

    let source = event.getIntegerValueField(.eventSourceUserData)
    guard source != 0x56484944 else { return }  // 过滤自己发的

    let now = Date()
    escBuffer.append(now)
    escBuffer = escBuffer.filter { now.timeIntervalSince($0) <= 1.5 }
    if escBuffer.count >= 5 {
        trigger()
    }
}

func trigger() {
    guard !isActive else { return }
    isActive = true
    triggeredAt = Date()
    escBuffer.removeAll()

    // 1. 取消所有正在跑的 ActionExecutor
    ActionExecutor.shared.cancel()

    // 2. 释放所有修饰键
    releaseAllModifiers()

    // 3. 释放所有鼠标按键
    releaseAllMouseButtons()

    // 4. 蜂鸣
    NSSound.beep()

    // 5. 订阅者通知
    onTrigger?()
}
```

**`releaseAllModifiers` 实现**：

```swift
private func releaseAllModifiers() {
    let modifierCodes: [CGKeyCode] = [0x37, 0x38, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E]
    // cmd_l, shift_l, opt_l, ctrl_l, shift_r, opt_r, cmd_r
    for code in modifierCodes {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        event?.setIntegerValueField(.eventSourceUserData, value: 0x56484944)
        event?.post(tap: .cgSessionEventTap)
    }
}
```

**注意**：这里 release 事件**不**用 `postToPid` 而用全局 `post(tap:)` —— 因为修饰键是系统级"卡住"，必须给系统事件流发真释放。

### 4.3 M3 验收

1. `vhid-daemon --smoke-kill-switch` 启动后，故意按下 `cmd` 不释放，再连按 5 次 ESC → 1500ms 内 `cmd` 被释放（观察方式：打开任意文本编辑器，按住 cmd 应该触发菜单快捷键；释放后恢复正常）
2. 脚本触发的 ESC（`source data = 0x56484944`）即使连按 100 次也不应触发 kill switch
3. 触发后 `SupervisorService.state.killSwitch.active` 为 `true`，`ControlServer` 的 `action` 请求全部返回 `E_KILL_SWITCH`
4. 调 `unlock` 后恢复正常

---

## 5. M4a — InjectorDaemon + Unix socket backend + StateReporter

**目标**：让 Swift 侧守护进程通过 Unix socket 对外暴露 action / state / stop / unlock / observe / profiles / trace 等方法。**这是内部协议**，MCP shim（M4b）和 `nc -U` 调试都靠它。

### 5.1 Socket 规范（Daemon 内部协议）

- 路径：`$TMPDIR/virtualhid.sock`
- 帧格式：newline-delimited JSON，一行一条 request / response
- 并发：单连接单 request，next 必须等 previous response（简化实现，M4a 够用；MCP shim 也做连接级互斥）
- 访问控制：仅本用户可读写（`umask 077` + socket 文件权限 0600）

### 5.2 请求 / 响应 schema（内部协议）

请求：

```json
{ "id": "uuid", "method": "action", "params": { /* per-method */ } }
```

响应：

```json
{ "id": "uuid", "ok": true,  "result": { /* per-method */ } }
{ "id": "uuid", "ok": false, "error": { "code": "E_BUSY", "message": "..." } }
```

错误码（主文档 §3.5）：`E_BUSY` / `E_KILL_SWITCH` / `E_NO_TARGET` / `E_PERMISSION` / `E_CONTEXT_REQUIRED` / `E_PROFILE_MISS` / `E_NOT_FRONTMOST` / `E_POST_MODE_UNSUPPORTED` / `E_UNKNOWN`

**action params schema**（摘要）：

```jsonc
{
  "id": "act-1234",
  "primitives": [ /* ... */ ],
  "context": { /* ActionContext，参见主文档 §6 */ },
  "options": {
    "postMode": "global" | "pid" | "auto",   // 可选；省略 = state.post.default
    "timeoutMs": 5000,
    "dryRun": false
  }
}
```

### 5.3 State 聚合（对齐主文档 §3.4）

`StateReporter.snapshot()` 返回的结构必须**逐字段**与主文档 §3.4 的 JSON 示例对齐。关键字段：

- `modifiers.stuck`：维护一个 `[CGKeyCode: Date]` map，记录最后一次 keyDown 时间，定期（每 1s）扫一遍 > 10s 的键
- `permissions.accessibility`：调 `AXIsProcessTrustedWithOptions` 查
- `permissions.inputMonitoring`：macOS 10.15+ 用 `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)`
- `targetApp.frontmost`：`NSWorkspace.shared.frontmostApplication?.bundleIdentifier == target.bundleId`
- `post.default`：启动时的默认投递模式，默认 `"global"`，可通过启动参数 `--default-post-mode pid` 改
- `post.lastUsed`：上次 `action` 请求实际使用的模式（含 auto 的 fallback 实际值），首次启动前为 `null`
- `post.available`：固定 `["global", "pid", "auto"]`
- `profiles.totalTemplates`：M6 落地前返回 `0`（提前占位）

### 5.4 M4a 验收

1. `vhid-daemon` 启动后，`nc -U $TMPDIR/virtualhid.sock` 交互，依次发：
   - `{"id":"1","method":"state","params":{}}` → 返回完整 state，其中 `post.default == "global"`、`post.available == ["global","pid","auto"]`
   - `{"id":"2","method":"action","params":{"id":"a1","primitives":[{"type":"move","to":{"x":100,"y":100},"via":"linear"}],"context":{"host":"test","url":"test","element":{"ref":"@e1","sig":"deadbeef"}}}}` → Chrome 被激活到前台后鼠标真的动到 (100,100)，响应里带 `post.used: "global"`
2. 不传 `context` → 返回 `E_CONTEXT_REQUIRED`
3. 触发 kill switch 后 `action` → `E_KILL_SWITCH`
4. 投递模式边界：
   - `options.postMode = "global"` + Chrome 非前台 + 禁用 `FocusController.ensureFrontmost`（通过 `--smoke-no-autofocus` 开关）→ `E_NOT_FRONTMOST`
   - `options.postMode = "pid"` + primitives 含 `click` → `E_POST_MODE_UNSUPPORTED`
   - `options.postMode = "pid"` + 仅 `move` + Chrome 非前台 → 成功，响应 `post.used: "pid"`
5. 连续发 5 条 action，`state.post.lastUsed` 每次更新到实际使用的模式

---

## 5bis. M4b — MCP stdio shim (`mcp/server.mjs`)

**目标**：在 Swift daemon 之上放一个**零业务逻辑**的 Node.js MCP 薄 shim，让 VirtualHID 以 MCP stdio server 的形式接入 Codex / Cursor / Claude。与 browser-mcp 的 `mcp/server.mjs` **结构完全对称**，Agent 侧注册方式一致。

### 5bis.1 目录 / 依赖

```
mcp/
├─ server.mjs        # MCP stdio 入口，注册 10 个 hid_* 工具
├─ tools.mjs         # 工具定义（name / description / inputSchema）
└─ errors.mjs        # E_* → MCP isError 文本映射
```

- 依赖 `@modelcontextprotocol/sdk`（唯一允许的新 npm 依赖）
- **禁止**引入任何其他 npm 包（不加 `axios` / `zod` / `ajv` 等；JSON Schema 用字面量对象即可）

### 5bis.2 工具表（10 个）

严格对齐**主文档 §3.5** 的 `hid_*` 工具表：

| MCP tool | 下游 Unix socket method |
|---|---|
| `hid_action` | `action` |
| `hid_state` | `state` |
| `hid_stop` | `stop` |
| `hid_unlock` | `unlock` |
| `hid_observe` | `observe` |
| `hid_profiles_list` | `profiles.list` |
| `hid_profiles_get` | `profiles.get` |
| `hid_profiles_forget` | `profiles.forget` |
| `hid_trace_tail` | `trace.tail` |
| `hid_trace_commit` | `trace.commit` |

每个工具都有完整 `inputSchema`（JSON Schema）；`description` 里明确"本工具由 Agent 调度使用，执行前请先通过 browser-mcp 完成前置条件（窗口激活等）"。

### 5bis.3 协议转换规则

- `tools/call` → 把 `arguments` 直接当作下游 `params`，`id` 用 shim 侧生成的 uuid
- 下游 `{ ok: true, result }` → MCP `content: [{ type: "text", text: JSON.stringify(result, null, 2) }]`
- 下游 `{ ok: false, error: { code, message } }` → MCP `isError: true, content: [{ type: "text", text: \`${code}: ${message}\` }]`
- 连接生命周期：MCP client 连上时，shim 立即尝试连接 Unix socket；连不上返回 `E_DAEMON_UNREACHABLE`（供 Agent 提示用户启动 daemon）

### 5bis.4 启动与注册

- 启动：`node mcp/server.mjs`（和 browser-mcp 同构）
- Codex 注册（脚本 `scripts/install-codex-mcp.mjs`）：
  ```toml
  [mcp.servers.virtualhid]
  command = "node"
  args = ["/absolute/path/to/VirtualHID/mcp/server.mjs"]
  ```
- 不需要 Native Messaging manifest（VirtualHID 不是 Chrome 扩展链路）

### 5bis.5 M4b 验收

1. `node mcp/server.mjs` 启动后 stdio 正常工作：发 `tools/list` 返回 10 个 `hid_*` 工具
2. `tools/call` 调 `hid_state` → 返回的 `content[0].text` 解析 JSON 后字段与 `nc -U` 调 `state` 完全一致
3. 触发 kill switch 后调 `hid_action` → MCP 响应 `isError: true`，`content[0].text` 以 `E_KILL_SWITCH:` 开头
4. daemon 未启动时调任意工具 → `isError: true`，`E_DAEMON_UNREACHABLE: ...`
5. Codex CLI 注册后，`codex mcp list` 能看到 `virtualhid` server；实际 prompt 里 AI 调 `hid_action` 能走通端到端
6. `rg -n "ActionContext\|element\.sig\|profileStore" mcp/` 结果是 0——shim 严格中立，不解读业务字段（`context` 直接原样透传）

---

## 6. M5 — Passive Observer

**目标**：Supervisor 里开启被动观察，记录真实用户事件，与 Agent 侧的 snapshot 时间戳对齐。

### 6.1 启停控制

`ControlServer`（Unix socket 层）暴露 `observe` method；MCP shim 对应 `hid_observe` 工具：

```
# Unix socket 内部协议
observe { enable: true, host?: string, taskId?: string }
observe { enable: false }

# Agent 视角（MCP）
hid_observe { enable: true, host?: "example.com", taskId?: "login-flow" }
```

- **默认关闭**（隐私优先）
- 开启时必须指定 `host`——限定录制范围（不录其他 App 的事件，靠 `targetApp.frontmost + host` 双重判断）
- 录到 `password` 输入框附近的事件直接 drop —— element sig 的 role 由 Agent 后续回填，VirtualHID 自己不认识 role，所以这条判定由 Agent 在 `trace.tag` 时做（见下）

### 6.2 事件流

```
EventTap (读) → PassiveObserver.buffer (滚动 30s)
                      ↓
            ControlServer.trace.tagUnresolved  ← Agent 轮询取
```

Agent 收到事件后：

1. 从自己的 snapshot 窗口里找时间戳最近的 snapshot
2. 在 clickables 里找 viewport 距离 event 坐标最近的元素（≤8px）
3. 提取 element.sig / role / text
4. 调 `trace.commit` 把补齐的 trace 交还给 VirtualHID

```
# Unix socket 内部协议
trace.tail    { sinceEventId?: string } → { events: [{ id, ts, type, point, keyCode }, ...] }
trace.commit  { event_id, element_sig, role, text, host, task_id?, stage? }
                    → 服务端写入 traces 表

# Agent 视角（MCP）
hid_trace_tail   { sinceEventId?: "..." }
hid_trace_commit { event_id, element_sig, role, text, host, task_id?, stage? }
```

**敏感过滤**：Agent 提交时如果 `role == "textbox" && el.type == "password"` → 整条 trace 丢弃（不写库）。这是最后一道防线。

### 6.3 M5 验收

1. 调 `hid_observe { enable: true, host: "example.com" }`，手动在浏览器页面点两下、打几个字
2. `hid_trace_tail` 应该有对应条目
3. 让 Agent 侧轮询并 `hid_trace_commit`
4. `profiles.rebuild` 后看到 `traces` 表有记录，`element_sig` 非空
5. 开 observe 后在 `password` 输入框里打字 —— trace 表**不**应出现这些事件

---

## 7. M6 — Profile Store 聚合 + 执行命中

**目标**：trace 聚合成 template；`ActionExecutor` 执行时查 profile 并应用。

### 7.1 SQLite 初始化

直接用 SQLite3 C API（Swift 自带 `import SQLite3`），**不**引入 GRDB / SwiftData 等外部依赖（保持 VirtualHID 依赖干净，和 browser-mcp 0 依赖原则对齐）。

表结构严格对齐主文档 §3.6：`traces` + `templates` 两张表。

### 7.2 Aggregator

```swift
public actor Aggregator {
    public func rebuild(for host: String? = nil) async throws -> AggregateReport

    public struct AggregateReport: Codable {
        let scannedTraces: Int
        let generatedTemplates: Int
        let updatedTemplates: Int
    }
}
```

算法：

```
for each (host, element_sig, task_id, action_type) group:
    if sample_size < 5: skip
    if action_type == "click" or "drag":
        // Douglas-Peucker 简化到 8-16 控制点
        // 每个控制点算均值 + 协方差 (2x2)
        template.params = { controlPoints: [...], covariances: [...] }
    if action_type == "type":
        // 对 dwell 序列和 inter-key 序列各做 Beta / Log-Normal MLE 拟合
        template.params = { dwellBeta: {alpha, beta}, interKeyLogNormal: {mu, sigma} }
    confidence = min(1.0, sample_size / 50) * (1 - sample_variance / threshold)
```

### 7.3 执行命中

`ActionExecutor` 在拿到 `ActionRequest` 时：

```swift
let candidates: [TemplateKey] = [
    TemplateKey(host: ctx.host, sig: ctx.element.sig, taskId: ctx.taskId, action: action),
    TemplateKey(host: ctx.host, sig: ctx.element.sig, taskId: nil,       action: action),
    TemplateKey(host: ctx.host, sig: nil,             taskId: nil,       action: action),
]

if let tpl = candidates.lazy.compactMap({ store.lookup($0) }).first(where: { $0.confidence >= 0.5 }) {
    primitives = primitives.map { applyTemplate(tpl, to: $0) }
}
```

### 7.4 M6 验收

1. 伪造 10 条 trace 注入 DB，`profiles.rebuild` 后 `templates` 表出现对应行
2. `profiles.get { host, sig }` 能返回 template 参数
3. `action` 请求带对应 context，观察生成的轨迹与 template 参数一致（方差在合理区间）
4. `profiles.forget { host }` 后该站 templates 清空

---

## 8. M7 — 与 Agent 对接

Agent 侧改动**不**在本文档负责（属 Agent 仓库 / skill 体系）。但需要 VirtualHID 侧提供：

- ✅ M4a 的 InjectorDaemon Unix socket backend
- ✅ M4b 的 MCP stdio shim（Agent 的正式入口）
- ✅ M6 的 template 查询接口（通过 `hid_profiles_*`）
- 一个**极小 Swift client SDK**（可选，`Sources/VirtualHIDClient/`），封装 Unix socket + JSON-RPC，仅用于 Swift 端开发调试；**不**作为 Agent 的入口（Agent 走 MCP）

**VirtualHID 对 `ActionContext` 的态度**（强调一次）：context 是 Agent 传下来的不透明业务标签。**禁止**在 VirtualHID 代码里：

- 根据 `host` 做特殊站点白/黑名单逻辑
- 根据 `url` 做正则匹配派生行为
- 根据 `element.text` 识别"这是不是登录按钮"
- 对 context 的字段做任何业务语义解读

只允许的用法见主文档 §6.4 白名单：`host` / `element.sig` / `element.role`（仅敏感过滤）/ `taskId` / `stage` / `hints.urgency`。

---

## 9. 跨里程碑通用约束

### 9.1 日志

- 统一走 `Logger(subsystem: "com.vyodels.virtualhid", category: ...)`（OSLog）
- 关键事件（kill switch 触发、template 命中、trace drop）必须有独立 category

### 9.2 测试

- `HumanizationKit` 100% 单元覆盖（纯函数）
- `ProfileStore` 80%+ 覆盖（用内存 SQLite `:memory:`）
- `Supervisor.KillSwitch` 单测用注入 fake event 实现
- `ControlServer` 用 `UnixSocketPair` 端到端测试

### 9.3 CI（建议）

- `swift build -c release`
- `swift test`
- `swiftlint`（可选）
- 跨版本矩阵：macOS 13 / 14 / 15

### 9.4 绝对不要做的事

1. **不要**让 VirtualHID 去访问 DOM / 发网络请求 / 解析 HTML —— 违反三方解耦
2. **不要**把 signature 生成逻辑搬到 VirtualHID —— sig 由 browser-mcp 产出、Agent 传下来；VirtualHID 只会收到字符串
3. **不要**对 `ActionContext` 做业务解读 —— 见 §8 末尾
4. **不要**在 Profile Store 的 `payload` 里存任何文本内容（典型错误：`"typed_text": "hello"` —— 绝对禁止，只存键码时序）
5. **不要**在 kill switch 不 release 修饰键 —— 会把用户键盘卡住，这是最严重的用户体验事故
6. **不要**在 `global` 投递模式下绕过 `frontmost` 预检 —— 事件可能落到用户当前正在用的其他 App 上，造成严重误操作
7. **不要**让 `mode=.pid` 静默降级：不支持的事件类型必须明确报错，交给 Agent 决策（而不是 VirtualHID 擅自切模式）；`auto` 模式才可以 fallback
8. **不要**让 ControlServer 接受 TCP / 局域网连接 —— 一律 Unix socket，权限靠文件系统兜底；MCP shim 也只监听 stdio，不起 HTTP
9. **不要**引入 Pod / SPM 以外的包管理器（Swift 侧）；MCP shim **只允许** `@modelcontextprotocol/sdk` 一个 npm 依赖
10. **不要**在 MCP shim 里做任何业务逻辑 —— 不要解读 `ActionContext`、不要做 sig 映射、不要缓存 profile；shim 只是协议转换器，业务决策全部在 Agent 或 Swift daemon 里
11. **不要**让 MCP 工具命名偏离 `hid_*` 前缀 —— 保持和 `browser_*` 对称，便于 Agent 在 prompt 里做角色区分

---

## 10. 里程碑验收矩阵

| 里程碑 | 最小交付物 | 验收命令 |
|---|---|---|
| M2 | `InjectorCore` + `HumanizationKit` 两个 target 可 build、可测；`InjectorCLI` 旧 scenario 改写后行为等价 | `swift build && swift test --filter HumanizationKit && ./scripts/validate.py` |
| M3 | `vhid-daemon --smoke-kill-switch` 5×ESC 生效；修饰键释放 | `./scripts/kill-switch-smoke.sh` |
| M4a | `nc -U $TMPDIR/virtualhid.sock` 能调 state / action（内部协议） | `./scripts/control-server-smoke.sh` |
| M4b | `node mcp/server.mjs` 可注册到 Codex；`tools/list` 返回 10 个 `hid_*`；端到端 `hid_state` / `hid_action` 打通 | `./scripts/mcp-smoke.sh` |
| M5 | observe 模式录到的真实事件能被 Agent tag；password 被 drop | 手测 + `./scripts/observer-smoke.sh` |
| M6 | 10 条 trace → template → 执行命中 | `./scripts/profile-learn-smoke.sh` |
| M7 | Agent-VHID 端到端：一次观察+学习→下次自动按用户节奏执行 | 人工 + 记录截图 |

---

## 11. 开发顺序建议

**关键路径**：M2 → M3 → M4a → M4b → M5 → M6 → M7

并行机会：

- `HumanizationKit`（M2 里的纯算法库）可以**完全离线**单独开发 / 测试，不需要整个 Package 跑起来
- MCP shim（M4b）可以和 M5/M6 **部分并行**：只要 M4a 的 Unix socket method 定义稳定，shim 可以提前按 stub 实现
- SQLite schema（M6 前置）可以在 M4a 期间提前冻结并写入迁移脚本，不阻塞主路径

建议分 5 个 PR 合入：

1. **PR-1**：`Package.swift` 拆分 + `InjectorCore` 重构（M2 前半）—— **不**引入任何新行为
2. **PR-2**：`HumanizationKit` + 默认策略接入（M2 后半）
3. **PR-3**：`Supervisor` + ControlServer + Daemon（M3 + M4a 一把梭，因为它们耦合紧）
4. **PR-4**：MCP stdio shim + Codex 注册脚本（M4b）
5. **PR-5**：`ProfileStore` + Observer（M5 + M6）

每个 PR 内必须：

- 自带单元测试
- 更新对应模块的 README
- 不破坏既有 CLI 入口（`injector` 命令仍然可用）

---

## 12. 附录 A · WindMouse 参考伪代码

MIT 兼容，已有大量开源实现，可直接参考：

- JS 原始：[`GhostTypingJsHackerRank`](https://github.com/BenLand100/windmouse)（Benjamin J. Land 本人）
- Python：`pyhm / windmouse` 多个 fork
- 核心算法不超过 60 行，直接用 Swift 移植即可，不要引入运行时依赖

---

## 13. 修订记录

| 日期 | 修改人 | 内容 |
|---|---|---|
| 2026-04-23 | Cursor Agent | 初稿 |
| 2026-04-23 | Cursor Agent | rev-1：①新增 `EventPoster` 抽象，支持 `global` / `pid` / `auto` 三种投递模式，以 `CGEventPost`（global）为主力；②`ActionOptions.postMode` + `StateReporter.post` 字段；③错误码新增 `E_NOT_FRONTMOST` / `E_POST_MODE_UNSUPPORTED`；④M2/M4 验收补充模式切换用例；⑤§9.4 补红线：不得业务解读 `ActionContext`、`global` 必须 frontmost、`pid` 不得静默降级；⑥明确 `ActionContext` 是 Agent ↔ VirtualHID 契约，browser-mcp 不感知 |
| 2026-04-23 | Cursor Agent | rev-2：对外协议升级为 **MCP stdio server**（两层拓扑：Node.js 薄 shim `mcp/server.mjs` + Swift `InjectorDaemon` Unix socket 后端）；①§1 包结构新增 `mcp/` 目录；②M4 拆成 M4a（Swift daemon，原 ControlServer）+ M4b（MCP shim，10 个 `hid_*` 工具）；③§6 observer 文档同时列出内部 method 名与 `hid_*` 工具名；④§9.4 红线新增：shim 零业务逻辑、禁 TCP、仅允许 `@modelcontextprotocol/sdk` 依赖、工具命名必须 `hid_*` 前缀；⑤验收矩阵、PR 拆分同步更新 |
