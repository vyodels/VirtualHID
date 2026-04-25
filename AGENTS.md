# Repository Guidelines

## Project Structure & Module Organization

This is a Swift Package for macOS VirtualHID automation. Main Swift sources live under `Sources/`:

- `InjectorCore/`: action primitives, browser resolution, focus checks, event posting.
- `HumanizationKit/`: WindMouse paths and keystroke timing.
- `Supervisor/`: kill switch, event tap, passive observer.
- `ControlServer/` and `InjectorDaemon/`: Unix socket backend and daemon entry point.
- `ProfileStore/`: SQLite-backed trace/template storage.
- `InjectorCLI/` and `FocusHolderApp/`: local executable tools.

Tests are in `Tests/<ModuleName>Tests/`. MCP stdio shim code is in `mcp/`. Smoke and validation scripts are in `scripts/`. Planning docs live in `docs/plan/active/` and should be treated as implementation contracts unless explicitly updated.

## Build, Test, and Development Commands

Use the local Xcode shim in this environment when needed:

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

Run the daemon locally:

```sh
/tmp/virtualhid-spm-build/x86_64-apple-macosx/debug/vhid-daemon --no-event-tap
```

Run milestone smoke checks:

```sh
./scripts/kill-switch-smoke.sh
./scripts/control-server-smoke.sh
./scripts/mcp-smoke.sh
./scripts/observer-smoke.sh
./scripts/profile-learn-smoke.sh
```

## Coding Style & Naming Conventions

Use Swift 5.7-compatible syntax and 4-space indentation. Prefer explicit public APIs for package boundaries and keep implementation helpers `private`. Use `PascalCase` for types, `camelCase` for methods/properties, and descriptive enum cases such as `notFrontmost`.

Do not add non-SPM Swift package managers. Swift-side persistence must use system `SQLite3`. MCP code must remain a thin stdio shim and may only depend on `@modelcontextprotocol/sdk`.

## Testing Guidelines

Tests use XCTest-style test targets, with a local shim target for this environment. Name tests `test<Behavior>()` and place them beside the relevant module, for example `Tests/ProfileStoreTests/ProfileStoreTests.swift`.

For behavior touching event delivery, include boundary tests for `global`, `pid`, and `auto` routes. Always run `swift test` plus the relevant smoke script before submitting daemon, supervisor, MCP, or profile changes.

## Security & Architecture Constraints

`global` event posting must require the target app to be frontmost and return `E_NOT_FRONTMOST` otherwise. `pid` posting is only valid for `mouseMoved` and `scrollWheel`; unsupported event types must return `E_POST_MODE_UNSUPPORTED`.

Never access DOM, parse HTML, generate element signatures, or make network requests from VirtualHID. Treat `ActionContext` as an opaque Agent-provided label and only read whitelisted fields needed for profile keys, trace storage, or sensitive filtering.

Kill switch modifier/button release must post directly to `.cgSessionEventTap`, not through `EventPoster`.

## Commit & Pull Request Guidelines

The current history uses concise imperative subjects, e.g. `Add CGEventPostToPid browser validation harness`. Keep commits focused and describe the user-visible or architectural change.

PRs should include a short summary, affected modules, linked plan/task references when applicable, and exact validation output such as `swift test` and smoke script results. Include screenshots only for web/demo UI changes.
