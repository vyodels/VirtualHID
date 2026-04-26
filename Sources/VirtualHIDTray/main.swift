import AppKit
import Darwin
import Foundation

private let defaultBundles = "com.google.Chrome,org.chromium.Chromium,com.microsoft.edgemac,com.apple.Safari"

final class VirtualHIDTrayApp: NSObject, NSApplicationDelegate {
    private enum Component: String, CaseIterable {
        case windowFrame
        case diagnostic
        case trail
        case trailPoints
        case expectedPoint
        case actualPoint
        case clickEffects
        case dragEffects
        case scrollEffects
        case keyboardEffects
        case status

        var title: String {
            switch self {
            case .windowFrame: return "显示目标窗口边框"
            case .diagnostic: return "显示 HUD 诊断标签"
            case .trail: return "显示鼠标移动轨迹线"
            case .trailPoints: return "显示轨迹采样点"
            case .expectedPoint: return "显示预期目标落点"
            case .actualPoint: return "显示实际最终落点"
            case .clickEffects: return "显示单击 / 双击特效"
            case .dragEffects: return "显示拖拽特效"
            case .scrollEffects: return "显示滚动特效"
            case .keyboardEffects: return "显示键盘 / 输入 / 粘贴特效"
            case .status: return "显示动作状态文字"
            }
        }
    }

    private let client = VirtualHIDSocketClient()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var panel: NSPanel?
    private var statusLabel: NSTextField?
    private var enabledCheckbox: NSButton?
    private var delayField: NSTextField?
    private var componentCheckboxes = [Component: NSButton]()
    private var lastState = HUDState.offline(message: "未连接到 VirtualHID 执行服务")
    private var autostartAttempted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard let button = statusItem.button else {
            return
        }
        button.image = NSImage(systemSymbolName: "cursorarrow.click.2", accessibilityDescription: "VirtualHID 控制面")
        button.image?.isTemplate = true
        button.title = " VHID"
        button.target = self
        button.action = #selector(togglePanel(_:))
        refreshState(autostartIfNeeded: true)
    }

    @objc private func togglePanel(_ sender: Any?) {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            return
        }
        showPanel()
    }

    @objc private func refreshAction(_ sender: Any?) {
        refreshState()
    }

    @objc private func applyAction(_ sender: Any?) {
        var settings = [String: Any]()
        for component in Component.allCases {
            if let checkbox = componentCheckboxes[component] {
                settings[component.rawValue] = checkbox.state == .on
            }
        }
        let payload: [String: Any] = [
            "enabled": enabledCheckbox?.state == .on,
            "clearDelaySeconds": delayField?.doubleValue ?? 2.4,
            "settings": settings
        ]
        do {
            let response = try client.call(method: "hud.configure", params: payload)
            lastState = HUDState(response: response)
        } catch {
            lastState = .offline(message: localizedErrorMessage(error))
        }
        updateControls()
    }

    @objc private func startDaemonAction(_ sender: Any?) {
        do {
            try startManagedDaemon()
            lastState = .offline(message: "正在启动 VirtualHID 执行服务...")
            updateControls()
            scheduleRefreshAfterDaemonStart()
        } catch {
            lastState = .offline(message: localizedErrorMessage(error))
            updateControls()
        }
    }

    @objc private func quitAction(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func showPanel() {
        if panel == nil {
            panel = buildPanel()
        }
        guard let panel else {
            return
        }
        refreshState(autostartIfNeeded: true)
        position(panel: panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func refreshState(autostartIfNeeded: Bool = false) {
        do {
            let response = try client.call(method: "hud.state", params: [:])
            lastState = HUDState(response: response)
            autostartAttempted = false
        } catch {
            if autostartIfNeeded, !autostartAttempted {
                autostartAttempted = true
                do {
                    try startManagedDaemon()
                    lastState = .offline(message: "正在启动 VirtualHID 执行服务...")
                    updateControls()
                    scheduleRefreshAfterDaemonStart()
                    return
                } catch {
                    lastState = .offline(message: localizedErrorMessage(error))
                    updateControls()
                    return
                }
            }
            lastState = .offline(message: localizedErrorMessage(error))
        }
        updateControls()
    }

    private func scheduleRefreshAfterDaemonStart() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.refreshState()
        }
    }

    private func buildPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 548),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "VirtualHID 控制面"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "VirtualHID HUD 可视化配置")
        title.font = NSFont.boldSystemFont(ofSize: 17)
        root.addArrangedSubview(title)

        let subtitle = NSTextField(labelWithString: "这是 VirtualHID 的本地控制面。托盘只通过 daemon socket 配置 HUD 显示项，不创建 HID 事件，也不参与业务决策。")
        subtitle.font = NSFont.systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 3
        subtitle.preferredMaxLayoutWidth = 338
        root.addArrangedSubview(subtitle)

        let status = NSTextField(labelWithString: "")
        status.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        root.addArrangedSubview(status)
        statusLabel = status

        let enabled = NSButton(checkboxWithTitle: "开启 HUD 透明可视化浮层", target: self, action: #selector(applyAction(_:)))
        root.addArrangedSubview(enabled)
        enabledCheckbox = enabled

        let separator = NSBox()
        separator.boxType = .separator
        root.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalToConstant: 338).isActive = true

        for component in Component.allCases {
            let checkbox = NSButton(checkboxWithTitle: component.title, target: self, action: #selector(applyAction(_:)))
            componentCheckboxes[component] = checkbox
            root.addArrangedSubview(checkbox)
        }

        let delayStack = NSStackView()
        delayStack.orientation = .horizontal
        delayStack.alignment = .centerY
        delayStack.spacing = 8
        delayStack.addArrangedSubview(NSTextField(labelWithString: "自动清除延迟"))
        let delay = NSTextField(string: "2.4")
        delay.alignment = .right
        delay.target = self
        delay.action = #selector(applyAction(_:))
        delay.widthAnchor.constraint(equalToConstant: 64).isActive = true
        delayStack.addArrangedSubview(delay)
        delayStack.addArrangedSubview(NSTextField(labelWithString: "秒"))
        delayField = delay
        root.addArrangedSubview(delayStack)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.addArrangedSubview(NSButton(title: "刷新", target: self, action: #selector(refreshAction(_:))))
        buttons.addArrangedSubview(NSButton(title: "应用", target: self, action: #selector(applyAction(_:))))
        buttons.addArrangedSubview(NSButton(title: "启动服务", target: self, action: #selector(startDaemonAction(_:))))
        buttons.addArrangedSubview(NSButton(title: "退出", target: self, action: #selector(quitAction(_:))))
        root.addArrangedSubview(buttons)

        panel.contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor)
        ])
        return panel
    }

    private func updateControls() {
        statusItem.button?.toolTip = lastState.statusText
        statusItem.button?.alphaValue = lastState.available ? 1.0 : 0.6
        statusLabel?.stringValue = lastState.statusText
        statusLabel?.textColor = lastState.available ? .labelColor : .systemRed

        enabledCheckbox?.isEnabled = lastState.available && !lastState.lockedOff
        enabledCheckbox?.state = lastState.enabled ? .on : .off
        delayField?.isEnabled = lastState.available
        delayField?.stringValue = String(format: "%.1f", lastState.clearDelaySeconds)

        for component in Component.allCases {
            let checkbox = componentCheckboxes[component]
            checkbox?.isEnabled = lastState.available
            checkbox?.state = lastState.settings[component.rawValue, default: true] ? .on : .off
        }
    }

    private func position(panel: NSPanel) {
        guard let screenFrame = NSScreen.main?.visibleFrame else {
            panel.center()
            return
        }
        var origin = NSPoint(x: screenFrame.maxX - panel.frame.width - 16, y: screenFrame.maxY - panel.frame.height - 8)
        if let button = statusItem.button, let window = button.window {
            let buttonFrame = window.convertToScreen(button.frame)
            origin.x = buttonFrame.midX - panel.frame.width / 2
            origin.y = buttonFrame.minY - panel.frame.height - 8
        }
        origin.x = min(max(origin.x, screenFrame.minX + 8), screenFrame.maxX - panel.frame.width - 8)
        origin.y = min(max(origin.y, screenFrame.minY + 8), screenFrame.maxY - panel.frame.height - 8)
        panel.setFrameOrigin(origin)
    }

    private func startManagedDaemon() throws {
        guard let executableURL = Bundle.main.executableURL else {
            throw TrayError("无法定位 vhid-tray 可执行文件")
        }
        let daemonURL = executableURL.deletingLastPathComponent().appendingPathComponent("vhid-daemon")
        guard FileManager.default.isExecutableFile(atPath: daemonURL.path) else {
            throw TrayError("未在 vhid-tray 同目录找到 vhid-daemon")
        }
        let process = Process()
        process.executableURL = daemonURL
        process.arguments = [
            "--socket-path",
            client.socketPath,
            "--bundle",
            ProcessInfo.processInfo.environment["VIRTUALHID_BUNDLES"] ?? defaultBundles,
            "--hud-control",
            "--visualize-hid"
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["VIRTUALHID_SOCKET"] = client.socketPath
        process.environment = environment
        try process.run()
    }
}

let app = NSApplication.shared
let delegate = VirtualHIDTrayApp()
app.delegate = delegate
app.run()

private struct HUDState {
    let available: Bool
    let enabled: Bool
    let lockedOff: Bool
    let settings: [String: Bool]
    let clearDelaySeconds: Double
    let message: String?

    var statusText: String {
        if let message {
            return "离线：\(message)"
        }
        if !available {
            return "HUD 控制不可用：请以 --hud-control 或 --visualize-hid 启动 vhid-daemon。"
        }
        if lockedOff {
            return "HUD 已被启动配置强制关闭。"
        }
        return enabled ? "HUD 已开启" : "HUD 已关闭"
    }

    init(response: [String: Any]) {
        let result = response["result"] as? [String: Any] ?? response
        available = result["available"] as? Bool ?? false
        enabled = result["enabled"] as? Bool ?? false
        lockedOff = result["lockedOff"] as? Bool ?? false
        let rawSettings = result["settings"] as? [String: Any] ?? [:]
        var parsedSettings = [String: Bool]()
        for (key, value) in rawSettings {
            if let bool = value as? Bool {
                parsedSettings[key] = bool
            }
        }
        settings = parsedSettings
        clearDelaySeconds = rawSettings["clearDelaySeconds"] as? Double ?? 2.4
        message = nil
    }

    static func offline(message: String) -> HUDState {
        HUDState(available: false, enabled: false, lockedOff: false, settings: [:], clearDelaySeconds: 2.4, message: message)
    }

    private init(
        available: Bool,
        enabled: Bool,
        lockedOff: Bool,
        settings: [String: Bool],
        clearDelaySeconds: Double,
        message: String?
    ) {
        self.available = available
        self.enabled = enabled
        self.lockedOff = lockedOff
        self.settings = settings
        self.clearDelaySeconds = clearDelaySeconds
        self.message = message
    }
}

private final class VirtualHIDSocketClient {
    let socketPath: String

    init(socketPath: String = VirtualHIDSocketClient.defaultSocketPath()) {
        self.socketPath = socketPath
    }

    func call(method: String, params: [String: Any]) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer {
            close(fd)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        try socketPath.withCString { pathPointer in
            try withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
                try tuplePointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { destination in
                    guard strlen(pathPointer) < maxPathLength else {
                        throw POSIXError(.ENAMETOOLONG)
                    }
                    strncpy(destination, pathPointer, maxPathLength - 1)
                }
            }
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + socketPath.utf8.count + 1)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, length)
            }
        }
        guard connectResult == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .ECONNREFUSED)
        }

        let request: [String: Any] = [
            "id": "tray-\(UUID().uuidString)",
            "method": method,
            "params": params
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        var line = data
        line.append(0x0A)
        try writeAll(line, fd: fd)
        return try readResponse(fd: fd)
    }

    private func writeAll(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(fd, baseAddress.advanced(by: offset), data.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR {
                    continue
                }
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        }
    }

    private func readResponse(fd: Int32) throws -> [String: Any] {
        var data = Data()
        var byte: UInt8 = 0
        while true {
            let readCount = Darwin.read(fd, &byte, 1)
            if readCount < 0, errno == EINTR {
                continue
            }
            if readCount <= 0 {
                break
            }
            if byte == 0x0A {
                break
            }
            data.append(byte)
        }
        guard !data.isEmpty else {
            throw TrayError("empty daemon response")
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private static func defaultSocketPath() -> String {
        ProcessInfo.processInfo.environment["VIRTUALHID_SOCKET"]
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("virtualhid.sock")
    }
}

private struct TrayError: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

private func localizedErrorMessage(_ error: Error) -> String {
    if let posix = error as? POSIXError {
        switch posix.code {
        case .ECONNREFUSED:
            return "连接被拒绝：VirtualHID 执行服务没有运行，或 socket 已失效。"
        case .ENOENT:
            return "未找到 socket：请先启动 VirtualHID 执行服务。"
        case .ENAMETOOLONG:
            return "socket 路径过长。"
        default:
            return "系统错误：\(posix.code.rawValue)"
        }
    }
    return error.localizedDescription
}
