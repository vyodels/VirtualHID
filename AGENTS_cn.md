# 仓库指南

## 项目结构与模块组织

本仓库是面向 macOS 的 Swift Package，用于 VirtualHID 自动化。主要源码位于 `Sources/`：

- `InjectorCore/`：动作原语、浏览器解析、前台检查、事件投递。
- `HumanizationKit/`：WindMouse 鼠标轨迹与键盘节奏。
- `Supervisor/`：kill switch、事件监听、被动观察。
- `ControlServer/` 与 `InjectorDaemon/`：Unix socket 后端与 daemon 入口。
- `ProfileStore/`：基于 SQLite 的 trace/template 存储。
- `InjectorCLI/` 与 `FocusHolderApp/`：本地调试和验证工具。

测试位于 `Tests/<ModuleName>Tests/`。MCP stdio shim 位于 `mcp/`。Smoke 与验证脚本位于 `scripts/`。计划文档在 `docs/plan/active/`，除非明确要求更新，否则应视为实现契约。

## 构建、测试与开发命令

当前环境如遇系统 CLT 问题，使用本地 Xcode shim：

```sh
env DEVELOPER_DIR=/tmp/OldXcode.app \
  CLANG_MODULE_CACHE_PATH=/tmp/virtualhid-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/tmp/virtualhid-swiftpm-cache \
  xcrun swift build --disable-sandbox --scratch-path /tmp/virtualhid-spm-build
env DEVELOPER_DIR=/tmp/OldXcode.app \
  CLANG_MODULE_CACHE_PATH=/tmp/virtualhid-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/tmp/virtualhid-swiftpm-cache \
  xcrun swift test --disable-sandbox --scratch-path /tmp/virtualhid-spm-build --filter HumanizationKit
```

本地运行 daemon：

```sh
/tmp/virtualhid-spm-build/x86_64-apple-macosx/debug/vhid-daemon --no-event-tap
```

运行里程碑 smoke：

```sh
./scripts/kill-switch-smoke.sh
./scripts/control-server-smoke.sh
./scripts/mcp-smoke.sh
./scripts/observer-smoke.sh
./scripts/profile-learn-smoke.sh
```

## 代码风格与命名约定

使用 Swift 5.7 兼容语法，缩进为 4 个空格。跨模块 API 显式标注 `public`，内部辅助实现优先使用 `private`。类型使用 `PascalCase`，方法和属性使用 `camelCase`，错误和枚举 case 使用具备语义的名称，例如 `notFrontmost`。

Swift 侧不要引入 SPM 之外的包管理器。持久化只能使用系统 `SQLite3`。MCP 代码必须保持薄 shim，只做 stdio 与 Unix socket 协议转换；唯一允许的 npm 依赖是 `@modelcontextprotocol/sdk`。

## 测试规范

测试使用 XCTest 风格目标，本环境包含本地 XCTest shim。测试命名采用 `test<Behavior>()`，并放在对应模块测试目录，例如 `Tests/ProfileStoreTests/ProfileStoreTests.swift`。

涉及事件投递的改动必须覆盖 `global`、`pid`、`auto` 边界。修改 daemon、supervisor、MCP 或 profile 逻辑后，至少运行 `swift test` 和相关 smoke 脚本。

## 安全与架构约束

`global` 投递前必须确认目标 App 已在前台，否则返回 `E_NOT_FRONTMOST`，不得投递事件。`pid` 投递只允许 `mouseMoved` 和 `scrollWheel`；不支持的事件类型必须返回 `E_POST_MODE_UNSUPPORTED`，不得静默降级。

VirtualHID 不得访问 DOM、解析 HTML、生成元素 signature 或发起网络请求。`ActionContext` 必须被视为 Agent 提供的不透明标签，只读取白名单字段用于 profile key、trace 存储或敏感过滤。

Kill switch 触发时，修饰键和鼠标键释放必须直接使用 `.cgSessionEventTap` 全局投递，不能走 `EventPoster` 抽象。

## Commit 与 PR 规范

当前历史使用简短祈使句提交标题，例如 `Add CGEventPostToPid browser validation harness`。提交应保持聚焦，标题说明用户可见或架构层面的变化。

PR 应包含简短摘要、影响模块、相关 plan/task 链接，以及明确验证输出，例如 `swift test` 和 smoke 脚本结果。只有涉及 Web/demo UI 时才需要截图。
