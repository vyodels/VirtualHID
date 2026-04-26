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
        case persistent

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
            case .persistent: return "常驻显示 HUD"
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
    private var learningStatusLabel: NSTextField?
    private var learningEnabledCheckbox: NSButton?
    private var learningModePopup: NSPopUpButton?
    private var trainingLabelField: NSTextField?
    private var trainingHostField: NSTextField?
    private var trainingActionField: NSTextField?
    private var lastLearningState = LearningState.offline(message: "未连接到 VirtualHID 执行服务")
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

    @objc private func applyLearningAction(_ sender: Any?) {
        do {
            let response = try client.call(method: "learning.configure", params: [
                "enabled": learningEnabledCheckbox?.state == .on,
                "mode": selectedLearningMode()
            ])
            lastLearningState = LearningState(response: response)
        } catch {
            lastLearningState = .offline(message: localizedErrorMessage(error))
        }
        updateControls()
    }

    @objc private func startTrainingAction(_ sender: Any?) {
        do {
            let response = try client.call(method: "learning.session.start", params: [
                "label": trainingLabelField?.stringValue ?? "",
                "host": trainingHostField?.stringValue ?? "",
                "targetAction": trainingActionField?.stringValue ?? ""
            ])
            lastLearningState = LearningState(response: response)
        } catch {
            lastLearningState = .offline(message: localizedErrorMessage(error))
        }
        updateControls()
    }

    @objc private func commitTrainingAction(_ sender: Any?) {
        stopTraining(commit: true)
    }

    @objc private func discardTrainingAction(_ sender: Any?) {
        stopTraining(commit: false)
    }

    @objc private func startDaemonAction(_ sender: Any?) {
        do {
            try startManagedDaemon()
            lastState = .offline(message: "正在启动 VirtualHID 执行服务...")
            lastLearningState = .offline(message: "正在启动 VirtualHID 执行服务...")
            updateControls()
            scheduleRefreshAfterDaemonStart()
        } catch {
            lastState = .offline(message: localizedErrorMessage(error))
            lastLearningState = .offline(message: localizedErrorMessage(error))
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
            let learningResponse = try client.call(method: "learning.state", params: [:])
            lastLearningState = LearningState(response: learningResponse)
            autostartAttempted = false
        } catch {
            if autostartIfNeeded, !autostartAttempted {
                autostartAttempted = true
                do {
                    try startManagedDaemon()
                    lastState = .offline(message: "正在启动 VirtualHID 执行服务...")
                    lastLearningState = .offline(message: "正在启动 VirtualHID 执行服务...")
                    updateControls()
                    scheduleRefreshAfterDaemonStart()
                    return
                } catch {
                    lastState = .offline(message: localizedErrorMessage(error))
                    lastLearningState = .offline(message: localizedErrorMessage(error))
                    updateControls()
                    return
                }
            }
            lastState = .offline(message: localizedErrorMessage(error))
            lastLearningState = .offline(message: localizedErrorMessage(error))
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
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 760),
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
        subtitle.preferredMaxLayoutWidth = 398
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
        separator.widthAnchor.constraint(equalToConstant: 398).isActive = true

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

        let hudButtons = NSStackView()
        hudButtons.orientation = .horizontal
        hudButtons.spacing = 8
        hudButtons.addArrangedSubview(NSButton(title: "刷新", target: self, action: #selector(refreshAction(_:))))
        hudButtons.addArrangedSubview(NSButton(title: "应用 HUD", target: self, action: #selector(applyAction(_:))))
        hudButtons.addArrangedSubview(NSButton(title: "启动服务", target: self, action: #selector(startDaemonAction(_:))))
        hudButtons.addArrangedSubview(NSButton(title: "退出", target: self, action: #selector(quitAction(_:))))
        root.addArrangedSubview(hudButtons)

        let learningSeparator = NSBox()
        learningSeparator.boxType = .separator
        root.addArrangedSubview(learningSeparator)
        learningSeparator.widthAnchor.constraint(equalToConstant: 398).isActive = true

        let learningTitle = NSTextField(labelWithString: "鼠标习惯学习")
        learningTitle.font = NSFont.boldSystemFont(ofSize: 15)
        root.addArrangedSubview(learningTitle)

        let learningHint = NSTextField(labelWithString: "学习只采集压缩后的鼠标行为指纹：路径骨架、节奏、停顿、点击时间流和速度特征；不保存业务页面内容。")
        learningHint.font = NSFont.systemFont(ofSize: 11)
        learningHint.textColor = .secondaryLabelColor
        learningHint.lineBreakMode = .byWordWrapping
        learningHint.maximumNumberOfLines = 3
        learningHint.preferredMaxLayoutWidth = 398
        root.addArrangedSubview(learningHint)

        let learningStatus = NSTextField(labelWithString: "")
        learningStatus.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        learningStatus.lineBreakMode = .byWordWrapping
        learningStatus.maximumNumberOfLines = 3
        learningStatus.preferredMaxLayoutWidth = 398
        root.addArrangedSubview(learningStatus)
        learningStatusLabel = learningStatus

        let learningEnabled = NSButton(checkboxWithTitle: "开启鼠标习惯学习", target: self, action: #selector(applyLearningAction(_:)))
        root.addArrangedSubview(learningEnabled)
        learningEnabledCheckbox = learningEnabled

        let modeStack = NSStackView()
        modeStack.orientation = .horizontal
        modeStack.alignment = .centerY
        modeStack.spacing = 8
        modeStack.addArrangedSubview(NSTextField(labelWithString: "学习模式"))
        let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        modePopup.addItems(withTitles: ["被动学习", "专项训练", "关闭"])
        modePopup.target = self
        modePopup.action = #selector(applyLearningAction(_:))
        modePopup.widthAnchor.constraint(equalToConstant: 128).isActive = true
        modeStack.addArrangedSubview(modePopup)
        learningModePopup = modePopup
        root.addArrangedSubview(modeStack)

        let labelField = NSTextField(string: "手动轨迹训练")
        let hostField = NSTextField(string: "")
        hostField.placeholderString = "可选：训练目标 host"
        let actionField = NSTextField(string: "click")
        actionField.placeholderString = "click / drag / scroll"
        for field in [labelField, hostField, actionField] {
            field.widthAnchor.constraint(equalToConstant: 250).isActive = true
        }
        trainingLabelField = labelField
        trainingHostField = hostField
        trainingActionField = actionField

        let trainingGrid = NSGridView(views: [
            [NSTextField(labelWithString: "训练名称"), labelField],
            [NSTextField(labelWithString: "目标 Host"), hostField],
            [NSTextField(labelWithString: "动作类型"), actionField]
        ])
        trainingGrid.rowSpacing = 6
        trainingGrid.columnSpacing = 8
        root.addArrangedSubview(trainingGrid)

        let learningButtons = NSStackView()
        learningButtons.orientation = .horizontal
        learningButtons.spacing = 8
        learningButtons.addArrangedSubview(NSButton(title: "应用学习", target: self, action: #selector(applyLearningAction(_:))))
        learningButtons.addArrangedSubview(NSButton(title: "开始训练", target: self, action: #selector(startTrainingAction(_:))))
        learningButtons.addArrangedSubview(NSButton(title: "提交训练", target: self, action: #selector(commitTrainingAction(_:))))
        learningButtons.addArrangedSubview(NSButton(title: "丢弃训练", target: self, action: #selector(discardTrainingAction(_:))))
        root.addArrangedSubview(learningButtons)

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

        learningStatusLabel?.stringValue = lastLearningState.statusText
        learningStatusLabel?.textColor = lastLearningState.available ? .labelColor : .systemRed
        learningEnabledCheckbox?.isEnabled = lastLearningState.available
        learningEnabledCheckbox?.state = lastLearningState.enabled ? .on : .off
        setLearningMode(lastLearningState.mode)
        learningModePopup?.isEnabled = lastLearningState.available
        trainingLabelField?.isEnabled = lastLearningState.available
        trainingHostField?.isEnabled = lastLearningState.available
        trainingActionField?.isEnabled = lastLearningState.available
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

    private func stopTraining(commit: Bool) {
        do {
            let response = try client.call(method: "learning.session.stop", params: ["commit": commit])
            lastLearningState = LearningState(response: response)
        } catch {
            lastLearningState = .offline(message: localizedErrorMessage(error))
        }
        updateControls()
    }

    private func selectedLearningMode() -> String {
        switch learningModePopup?.indexOfSelectedItem ?? 0 {
        case 1:
            return "training"
        case 2:
            return "off"
        default:
            return "passive"
        }
    }

    private func setLearningMode(_ mode: String) {
        let index: Int
        switch mode {
        case "training":
            index = 1
        case "off":
            index = 2
        default:
            index = 0
        }
        learningModePopup?.selectItem(at: index)
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

private struct LearningState {
    let available: Bool
    let enabled: Bool
    let mode: String
    let activeSessionLabel: String?
    let producedSamples: Int
    let pendingTrainingSamples: Int
    let persistedSamples: Int
    let totalTemplates: Int
    let lastLearnedAt: String?
    let message: String?

    var statusText: String {
        if let message {
            return "学习离线：\(message)"
        }
        let modeText: String
        switch mode {
        case "training":
            modeText = "专项训练"
        case "off":
            modeText = "关闭"
        default:
            modeText = "被动学习"
        }
        let sessionText = activeSessionLabel.map { "，训练：\($0)" } ?? ""
        return "学习：\(enabled ? "开启" : "关闭") / \(modeText)，已产出 \(producedSamples) 个样本，待提交 \(pendingTrainingSamples) 个，已持久化 \(persistedSamples) 个，模板 \(totalTemplates) 个\(sessionText)"
    }

    init(response: [String: Any]) {
        let responseResult = response["result"] as? [String: Any] ?? response
        let result = responseResult["state"] as? [String: Any] ?? responseResult
        let settings = result["settings"] as? [String: Any] ?? [:]
        let activeSession = result["activeSession"] as? [String: Any]
        available = true
        enabled = settings["enabled"] as? Bool ?? false
        mode = settings["mode"] as? String ?? "off"
        activeSessionLabel = activeSession?["label"] as? String
        producedSamples = intValue(result["producedSamples"]) ?? 0
        pendingTrainingSamples = intValue(result["pendingTrainingSamples"]) ?? 0
        persistedSamples = intValue(responseResult["persistedSamples"]) ?? intValue(result["persistedSamples"]) ?? 0
        totalTemplates = intValue(responseResult["totalTemplates"])
            ?? intValue(responseResult["generatedTemplates"])
            ?? intValue(result["totalTemplates"])
            ?? 0
        lastLearnedAt = result["lastLearnedAt"] as? String
        message = nil
    }

    static func offline(message: String) -> LearningState {
        LearningState(
            available: false,
            enabled: false,
            mode: "off",
            activeSessionLabel: nil,
            producedSamples: 0,
            pendingTrainingSamples: 0,
            persistedSamples: 0,
            totalTemplates: 0,
            lastLearnedAt: nil,
            message: message
        )
    }

    private init(
        available: Bool,
        enabled: Bool,
        mode: String,
        activeSessionLabel: String?,
        producedSamples: Int,
        pendingTrainingSamples: Int,
        persistedSamples: Int,
        totalTemplates: Int,
        lastLearnedAt: String?,
        message: String?
    ) {
        self.available = available
        self.enabled = enabled
        self.mode = mode
        self.activeSessionLabel = activeSessionLabel
        self.producedSamples = producedSamples
        self.pendingTrainingSamples = pendingTrainingSamples
        self.persistedSamples = persistedSamples
        self.totalTemplates = totalTemplates
        self.lastLearnedAt = lastLearnedAt
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

private func intValue(_ value: Any?) -> Int? {
    if let int = value as? Int {
        return int
    }
    if let double = value as? Double {
        return Int(double)
    }
    if let string = value as? String {
        return Int(string)
    }
    return nil
}
