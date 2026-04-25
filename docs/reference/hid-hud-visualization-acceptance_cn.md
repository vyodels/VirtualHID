# VirtualHID HUD / 可视化验收契约

## 1. 验收目标

HUD 是 VirtualHID 自有的透明、鼠标穿透覆盖层，只观察 VirtualHID 执行动作产生的事件流。它不得依赖网页 JS / DOM，不得让 browser、recruit-agent 或 mock page 补造 expected / actual / trajectory。

HUD 开启时应展示：

- 目标 app/window 的 VirtualHID 解析窗口框。
- `ActionExecutor` 记录的实际 HID 事件轨迹。
- 点击、拖拽、滚轮、输入等事件效果。
- `OutcomeVerifier` 基于同一批 `ActionResult.events` 计算出的 `expectedPointer` 与 `finalPointer`。

## 2. 数据来源与边界

- actual trajectory 只来自 `InjectedEvent.location`，即 `ActionExecutor.record(...)` 记录的 VirtualHID 事件。
- expected/final point 只来自 `hid_action` 响应里的 `verification.expectedPointer` / `verification.finalPointer`。
- window scope 只来自 VirtualHID 的 `BrowserTarget.frame` / execution context；browser 只能提供 target 身份、页面坐标和可选页面证据，不能提供 screen coordinate authority。
- `geometry.viewportInScreen` 若由调用方提供，也只能作为输入证据；VirtualHID 会以自身解析出的 viewport/window 为准。
- `--no-hud` 或 `VIRTUALHID_NO_HUD=1` 强制禁用 HUD；禁用时 action、events、verification 仍照常产生，只是不挂 HUD sink。

## 3. 自动化验收

运行：

```bash
./scripts/hud-smoke.sh
```

该 smoke 不创建真实 NSPanel，验证的是 HUD 低层合同：

- `--no-hud` 下 `hid_action` 仍返回 VirtualHID 事件和 verification，但 HUD callback 为 0。
- `--visualize-hid` 下 HUD sink 收到 start / record / finish，事件数与 `hid_action.result.events` 一致。
- callback 的 expected/final point 与 action response 完全一致。
- `--no-hud` / `VIRTUALHID_NO_HUD=1` 对 `VIRTUALHID_VISUALIZE_HID=1` 或 `--visualize-hid` 有禁用优先级。

建议配套运行：

```bash
env DEVELOPER_DIR=/tmp/OldXcode.app \
  CLANG_MODULE_CACHE_PATH=/tmp/virtualhid-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/tmp/virtualhid-swiftpm-cache \
  xcrun swift test --disable-sandbox --scratch-path /tmp/virtualhid-spm-build
```

## 4. 手动 UI 验收命令

真实 HUD 需要 macOS 图形会话，无法稳定在 headless smoke 中断言。可用以下命令人工确认透明覆盖层、鼠标穿透和绘制内容：

```bash
BUILD_PATH=/tmp/virtualhid-hud-spm-build
SOCKET=/tmp/virtualhid-hud-manual.sock
DB=/tmp/virtualhid-hud-manual.sqlite
rm -f "$SOCKET" "$DB"

env DEVELOPER_DIR=/tmp/OldXcode.app \
  CLANG_MODULE_CACHE_PATH=/tmp/virtualhid-hud-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/tmp/virtualhid-hud-swiftpm-cache \
  xcrun swift build --disable-sandbox --scratch-path "$BUILD_PATH"

"$BUILD_PATH/x86_64-apple-macosx/debug/vhid-daemon" \
  --visualize-hid \
  --no-event-tap \
  --self-target \
  --allow-self-target-daemon \
  --socket-path "$SOCKET" \
  --db-path "$DB" &
HUD_PID=$!
trap 'kill "$HUD_PID" 2>/dev/null || true; wait "$HUD_PID" 2>/dev/null || true; rm -f "$SOCKET" "$DB"' EXIT

for _ in $(seq 1 50); do
  [[ -S "$SOCKET" ]] && break
  sleep 0.1
done

python3 - "$SOCKET" <<'PY'
import json
import socket
import sys

payload = {
    "id": "hud-manual",
    "method": "action",
    "params": {
        "context": {
            "host": "hud.local",
            "element": {"sig": "hud-button", "role": "button"},
            "taskId": "hud-acceptance",
            "stage": "manual-ui",
        },
        "options": {"dryRun": True, "postMode": "global"},
        "primitives": [
            {"type": "click", "at": {"x": 160, "y": 120}, "button": "left", "profile": {"origin": {"x": 160, "y": 120}}},
            {"type": "scroll", "at": {"x": 160, "y": 160}, "dx": 0, "dy": -72, "style": "wheel"},
        ],
    },
}

with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
    client.connect(sys.argv[1])
    client.sendall((json.dumps(payload) + "\n").encode())
    print(client.recv(65536).decode(), end="")
PY

sleep 3
```

预期：屏幕上短暂出现透明穿透 HUD，包含目标窗口虚线框、点击/滚动效果、expected/final 标记和 `HID dry-run click+scroll ...` 状态文本；不应出现来自网页 mock 的额外轨迹或坐标。
