import AppKit
import Darwin
import Foundation
import VirtualHIDRuntime

final class VirtualHIDTrayApp: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private enum ManagementSection: Int, CaseIterable {
        case overview
        case hud
        case learning
        case templates
        case analysis
        case runtime
        case security

        var title: String {
            switch self {
            case .overview: return "总览"
            case .hud: return "HUD 可视化"
            case .learning: return "键鼠学习"
            case .templates: return "能力模板"
            case .analysis: return "效果分析"
            case .runtime: return "运行时"
            case .security: return "安全"
            }
        }

        var subtitle: String {
            switch self {
            case .overview:
                return "查看 VirtualHID.app 的运行状态、HUD、学习样本和 MCP 接入概览。"
            case .hud:
                return "配置透明穿透浮层、轨迹、落点、事件特效和常驻显示。"
            case .learning:
                return "开启整体键鼠输入学习分析，自动沉淀真实鼠标、滚动、拖拽和键盘节奏。"
            case .templates:
                return "查看 VirtualHID 已学习到的轨迹、节奏、点击、滚动和键盘输入能力模板。"
            case .analysis:
                return "验证拟人化算法、学习模板命中情况和安全 dry-run 轨迹效果。"
            case .runtime:
                return "管理本地 runtime 状态、刷新、重启和退出。"
            case .security:
                return "查看权限、kill switch 和执行边界；这些设置不改变 Agent 决策。"
            }
        }
    }

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

    private var runtime: VirtualHIDRuntimeHost?
    private var runtimeError: String?
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var singleClickTimer: Timer?
    private var panelRefreshTimer: Timer?
    private var lastStatusClickAt: Date?
    private var quickMenu: NSMenu?
    private var panel: NSPanel?
    private var selectedSection: ManagementSection = .overview
    private var sidebarButtons = [ManagementSection: NSButton]()
    private var contentStack: NSStackView?
    private var statusLabel: NSTextField?
    private var enabledCheckbox: NSButton?
    private var delayField: NSTextField?
    private var componentCheckboxes = [Component: NSButton]()
    private var lastState = HUDState.offline(message: "未连接到 VirtualHID 执行服务")
    private var learningStatusLabel: NSTextField?
    private var learningCountersLabel: NSTextField?
    private var learningCaptureLabel: NSTextField?
    private var learningEventsLabel: NSTextField?
    private var learningSamplesLabel: NSTextField?
    private var learningTracesLabel: NSTextField?
    private var learningTemplatesLabel: NSTextField?
    private var templateInventoryCountLabel: NSTextField?
    private var templateInventoryTextView: NSTextView?
    private var learningAnalysisLabel: NSTextField?
    private var learningDemoStatusLabel: NSTextField?
    private var learningEnabledCheckbox: NSButton?
    private var reuseDemoPointsCheckbox: NSButton?
    private var trainingHostField: NSTextField?
    private var lastLearningDemoStatus = "尚未演示。请选择一个动作单独演示；每次只播放当前动作，可重复点击查看轨迹、落点和事件时间线。"
    private var lastLearningDemoAction: (action: String, title: String)?
    private var lastLearningState = LearningState.offline(message: "未连接到 VirtualHID 执行服务")
    private let learningInspectLimit = 200

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard let button = statusItem.button else {
            return
        }
        button.image = NSImage(systemSymbolName: "cursorarrow.click.2", accessibilityDescription: "VirtualHID 控制面")
        button.image?.isTemplate = true
        button.title = " VHID"
        button.target = self
        button.action = #selector(statusItemAction(_:))
        startRuntime()
        refreshState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopPanelRefreshTimer()
        runtime?.stop()
    }

    @objc private func statusItemAction(_ sender: Any?) {
        let now = Date()
        let isManualDoubleClick = lastStatusClickAt.map { now.timeIntervalSince($0) < 0.35 } ?? false
        lastStatusClickAt = now
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 || isManualDoubleClick {
            singleClickTimer?.invalidate()
            singleClickTimer = nil
            showPanel()
            return
        }
        singleClickTimer?.invalidate()
        singleClickTimer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: false) { [weak self] _ in
            self?.showQuickMenu()
        }
    }

    @objc private func togglePanel(_ sender: Any?) {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            stopPanelRefreshTimer()
            return
        }
        showPanel()
    }

    private func showQuickMenu() {
        refreshState()
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: runtime == nil ? "Runtime：离线" : "Runtime：在线", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "HUD：\(lastState.enabled ? "开启" : "关闭")", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "学习：\(lastLearningState.enabled ? "开启" : "关闭") / \(lastLearningState.modeText)", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: lastState.enabled ? "暂停 HUD" : "开启 HUD", action: #selector(toggleHUDAction(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: lastLearningState.enabled ? "暂停键鼠学习" : "开启键鼠学习", action: #selector(toggleLearningAction(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "清除动态轨迹", action: #selector(clearTrailAction(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "打开管理中心", action: #selector(openManagementAction(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "退出 VirtualHID", action: #selector(quitAction(_:)), keyEquivalent: ""))
        for item in menu.items {
            item.target = self
        }
        statusItem.menu = menu
        quickMenu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === quickMenu else {
            return
        }
        statusItem.menu = nil
        quickMenu = nil
    }

    @objc private func refreshAction(_ sender: Any?) {
        refreshState()
    }

    @objc private func unlockAction(_ sender: Any?) {
        do {
            _ = try call(method: "unlock", params: [:])
            refreshState()
        } catch {
            lastState = .offline(message: localizedErrorMessage(error))
            updateControls()
        }
    }

    @objc private func openAccessibilitySettingsAction(_ sender: Any?) {
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    @objc private func openInputMonitoringSettingsAction(_ sender: Any?) {
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    @objc private func stopAction(_ sender: Any?) {
        do {
            _ = try call(method: "stop", params: [:])
            refreshState()
        } catch {
            lastState = .offline(message: localizedErrorMessage(error))
            updateControls()
        }
    }

    @objc private func selectSectionAction(_ sender: NSButton) {
        guard let section = ManagementSection(rawValue: sender.tag) else {
            return
        }
        selectedSection = section
        rebuildContent()
        updateControls()
    }

    @objc private func openManagementAction(_ sender: Any?) {
        showPanel()
    }

    @objc private func toggleHUDAction(_ sender: Any?) {
        do {
            let response = try call(method: "hud.configure", params: ["enabled": !lastState.enabled])
            lastState = HUDState(response: response)
        } catch {
            lastState = .offline(message: localizedErrorMessage(error))
        }
        updateControls()
    }

    @objc private func toggleLearningAction(_ sender: Any?) {
        do {
            _ = try call(method: "learning.configure", params: [
                "enabled": !lastLearningState.enabled,
                "mode": lastLearningState.enabled ? "off" : "passive"
            ])
            let response = try call(method: "learning.inspect", params: ["limit": learningInspectLimit])
            lastLearningState = LearningState(response: response)
        } catch {
            lastLearningState = .offline(message: localizedErrorMessage(error))
        }
        updateControls()
    }

    @objc private func clearTrailAction(_ sender: Any?) {
        do {
            let response = try call(method: "hud.configure", params: [
                "clear": true,
                "clearDelaySeconds": delayField?.doubleValue ?? 2.4
            ])
            lastState = HUDState(response: response)
        } catch {
            lastState = .offline(message: localizedErrorMessage(error))
        }
        updateControls()
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
            let response = try call(method: "hud.configure", params: payload)
            lastState = HUDState(response: response)
        } catch {
            lastState = .offline(message: localizedErrorMessage(error))
        }
        updateControls()
    }

    @objc private func applyLearningAction(_ sender: Any?) {
        do {
            let enabled = learningEnabledCheckbox?.state == .on
            _ = try call(method: "learning.configure", params: [
                "enabled": enabled,
                "mode": enabled ? "passive" : "off"
            ])
            let response = try call(method: "learning.inspect", params: ["limit": learningInspectLimit])
            lastLearningState = LearningState(response: response)
        } catch {
            lastLearningState = .offline(message: localizedErrorMessage(error))
        }
        updateControls()
    }

    @objc private func startTrainingAction(_ sender: Any?) {
        do {
            _ = try call(method: "learning.session.start", params: [
                "host": trainingHostField?.stringValue ?? ""
            ])
            let response = try call(method: "learning.inspect", params: ["limit": learningInspectLimit])
            lastLearningState = LearningState(response: response)
        } catch {
            lastLearningState = .offline(message: localizedErrorMessage(error))
        }
        updateControls()
    }

    @objc private func commitTrainingAction(_ sender: Any?) {
        stopTraining(commit: true)
    }

    @objc private func rebuildLearningProfilesAction(_ sender: Any?) {
        do {
            _ = try call(method: "profiles.rebuild", params: [:])
            let response = try call(method: "learning.inspect", params: ["limit": learningInspectLimit])
            lastLearningState = LearningState(response: response)
            lastLearningDemoStatus = "学习模板已重建。当前模板 \(lastLearningState.totalTemplates) 个。"
        } catch {
            lastLearningDemoStatus = "重建失败：\(localizedErrorMessage(error))"
        }
        updateControls()
    }

    @objc private func runLearningDemoAction(_ sender: Any?) {
        runLearningDemoStep(action: "click", title: "完整点击演示")
    }

    @objc private func runMoveDemoAction(_ sender: Any?) {
        runLearningDemoStep(action: "move", title: "移动轨迹演示")
    }

    @objc private func runClickDemoAction(_ sender: Any?) {
        runLearningDemoStep(action: "click", title: "完整点击演示")
    }

    @objc private func runDoubleClickDemoAction(_ sender: Any?) {
        runLearningDemoStep(action: "dblclick", title: "双击演示")
    }

    @objc private func runDragDemoAction(_ sender: Any?) {
        runLearningDemoStep(action: "drag", title: "拖拽演示")
    }

    @objc private func runScrollDemoAction(_ sender: Any?) {
        runLearningDemoStep(action: "scroll", title: "滚轮演示")
    }

    @objc private func runKeyboardDemoAction(_ sender: Any?) {
        runLearningDemoStep(action: "keyboard", title: "键盘事件演示")
    }

    @objc private func stopLearningDemoAction(_ sender: Any?) {
        do {
            _ = try call(method: "learning.demo.stop", params: [:])
            let hudResponse = try call(method: "hud.configure", params: ["clear": true])
            lastState = HUDState(response: hudResponse)
            if let lastLearningDemoAction {
                lastLearningDemoStatus = "已关闭 \(lastLearningDemoAction.title) 的 HUD 结果。需要复看时点「重放上次演示」，不会真实点击或输入。"
            } else {
                lastLearningDemoStatus = "已关闭当前学习效果演示 HUD。"
            }
        } catch {
            lastLearningDemoStatus = "关闭演示失败：\(localizedErrorMessage(error))"
        }
        updateControls()
    }

    @objc private func clearLearningDemoHistoryAction(_ sender: Any?) {
        do {
            let hudResponse = try call(method: "hud.configure", params: ["clear": true])
            lastState = HUDState(response: hudResponse)
            lastLearningDemoStatus = "已清空 HUD 历史轨迹和历史落点。后续演示会重新累计，除非关闭常驻显示。"
        } catch {
            lastLearningDemoStatus = "清空历史失败：\(localizedErrorMessage(error))"
        }
        updateControls()
    }

    @objc private func replayLearningDemoAction(_ sender: Any?) {
        guard let lastLearningDemoAction else {
            lastLearningDemoStatus = "暂无可重放的演示结果。请先点击一个动作生成 dry-run HUD 结果。"
            updateControls()
            return
        }
        do {
            if runtime == nil {
                startRuntime()
            }
            let hudResponse = try call(method: "hud.configure", params: [
                "enabled": true,
                "replayLast": true,
                "settings": [
                    "trail": true,
                    "trailPoints": true,
                    "expectedPoint": true,
                    "actualPoint": true,
                    "clickEffects": true,
                    "dragEffects": true,
                    "scrollEffects": true,
                    "keyboardEffects": true,
                    "windowFrame": true,
                    "status": true,
                    "persistent": true
                ]
            ])
            lastState = HUDState(response: hudResponse)
            lastLearningDemoStatus = "\(lastLearningDemoAction.title) 已在 HUD 重放同一条 dry-run 事件链；结果会保留到手动关闭。"
        } catch {
            lastLearningDemoStatus = "重放演示失败：\(localizedErrorMessage(error))"
        }
        updateControls()
    }

    private func runLearningDemoStep(action: String, title: String) {
        let runtime: VirtualHIDRuntimeHost
        do {
            if self.runtime == nil {
                startRuntime()
            }
            guard let activeRuntime = self.runtime else {
                throw TrayError(runtimeError ?? "VirtualHID runtime 未启动")
            }
            runtime = activeRuntime
            lastLearningDemoAction = (action: action, title: title)
            lastLearningDemoStatus = "\(title) 准备中：HUD 只显示 VirtualHID 规划事件，不会真实点击或输入；本动作完成后会保留轨迹供观察。"
            updateControls()
        } catch {
            lastLearningDemoStatus = "演示失败：\(localizedErrorMessage(error))"
            updateControls()
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let hudResponse = try runtime.call(method: "hud.configure", params: [
                    "enabled": true,
                    "clearDelaySeconds": 10.0,
                    "settings": [
                        "trail": true,
                        "trailPoints": true,
                        "expectedPoint": true,
                        "actualPoint": true,
                        "clickEffects": true,
                        "dragEffects": true,
                        "scrollEffects": true,
                        "keyboardEffects": true,
                        "windowFrame": true,
                        "status": true,
                        "persistent": true
                    ]
                ])
                let demoResponse = try runtime.call(method: "learning.demo.step", params: [
                    "action": action,
                    "demoId": "management-center-\(action)",
                    "reuseLastPoints": self?.reuseDemoPointsCheckbox?.state == .on
                ])
                let learningResponse = try runtime.call(method: "learning.inspect", params: ["limit": self?.learningInspectLimit ?? 200])
                DispatchQueue.main.async {
                    guard let self else {
                        return
                    }
                    self.lastState = HUDState(response: hudResponse)
                    self.lastLearningState = LearningState(response: learningResponse)
                    self.lastLearningDemoStatus = LearningDemoResult(response: demoResponse, fallbackTitle: title).statusText
                    self.updateControls()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.lastLearningDemoStatus = "演示失败：\(localizedErrorMessage(error))"
                    self?.updateControls()
                }
            }
        }
    }

    @objc private func startDaemonAction(_ sender: Any?) {
        startRuntime(restart: true)
        refreshState()
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
        startPanelRefreshTimer()
    }

    func windowWillClose(_ notification: Notification) {
        stopPanelRefreshTimer()
    }

    private func refreshState(autostartIfNeeded: Bool = false) {
        do {
            let response = try call(method: "hud.state", params: [:])
            lastState = HUDState(response: response)
            let learningResponse = try call(method: "learning.inspect", params: ["limit": learningInspectLimit])
            lastLearningState = LearningState(response: learningResponse)
        } catch {
            lastState = .offline(message: localizedErrorMessage(error))
            lastLearningState = .offline(message: localizedErrorMessage(error))
        }
        updateControls()
    }

    private func startPanelRefreshTimer() {
        panelRefreshTimer?.invalidate()
        panelRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, self.panel?.isVisible == true else {
                self?.stopPanelRefreshTimer()
                return
            }
            self.refreshState()
        }
    }

    private func stopPanelRefreshTimer() {
        panelRefreshTimer?.invalidate()
        panelRefreshTimer = nil
    }

    private func startRuntime(restart: Bool = false) {
        if restart {
            runtime?.stop()
            runtime = nil
        }
        guard runtime == nil else {
            runtimeError = nil
            return
        }
        do {
            let host = try VirtualHIDRuntimeHost(
                configuration: VirtualHIDRuntimeConfiguration.appDefault()
            )
            try host.start()
            runtime = host
            runtimeError = nil
        } catch {
            runtimeError = localizedErrorMessage(error)
            lastState = .offline(message: runtimeError ?? "VirtualHID runtime 启动失败")
            lastLearningState = .offline(message: runtimeError ?? "VirtualHID runtime 启动失败")
        }
    }

    private func buildPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 560),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "VirtualHID 管理中心"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.delegate = self

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.translatesAutoresizingMaskIntoConstraints = false

        let root = NSStackView()
        root.orientation = .horizontal
        root.alignment = .top
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false

        let sidebar = makeSidebar()
        sidebar.widthAnchor.constraint(equalToConstant: 148).isActive = true
        root.addArrangedSubview(sidebar)

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false
        content.widthAnchor.constraint(equalToConstant: 680).isActive = true
        contentStack = content
        root.addArrangedSubview(content)

        rebuildContent()

        panel.contentView = effect
        effect.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            root.topAnchor.constraint(equalTo: effect.topAnchor),
            root.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])
        return panel
    }

    private func makeSidebar() -> NSView {
        let sidebar = CardView()
        let stack = cardStack(spacing: 12)
        stack.addArrangedSubview(label("VHID", size: 22, weight: .heavy))
        stack.addArrangedSubview(label("可视化与学习", size: 11, color: .secondaryLabelColor))
        for section in ManagementSection.allCases {
            let row = navigationButton(section)
            sidebarButtons[section] = row
            stack.addArrangedSubview(row)
        }
        let spacer = NSView()
        spacer.heightAnchor.constraint(equalToConstant: 150).isActive = true
        stack.addArrangedSubview(spacer)
        stack.addArrangedSubview(label("单击托盘：快捷菜单\n双击托盘：管理中心", size: 11, color: .secondaryLabelColor))
        sidebar.addContent(stack)
        updateSidebarSelection()
        return sidebar
    }

    private func navigationButton(_ section: ManagementSection) -> NSButton {
        let button = NSButton(title: section.title, target: self, action: #selector(selectSectionAction(_:)))
        button.tag = section.rawValue
        button.isBordered = false
        button.alignment = .left
        button.controlSize = .large
        button.font = NSFont.systemFont(ofSize: 13, weight: section == selectedSection ? .semibold : .regular)
        button.wantsLayer = true
        button.layer?.cornerRadius = 9
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        button.widthAnchor.constraint(equalToConstant: 120).isActive = true
        return button
    }

    private func rebuildContent() {
        guard let contentStack else {
            return
        }
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        clearContentBindings()

        let title = label(selectedSection.title, size: 24, weight: .bold)
        let subtitle = label(selectedSection.subtitle, size: 12, color: .secondaryLabelColor)
        subtitle.maximumNumberOfLines = 2
        subtitle.preferredMaxLayoutWidth = 660
        contentStack.addArrangedSubview(title)
        contentStack.addArrangedSubview(subtitle)
        contentStack.addArrangedSubview(makeSectionContent(selectedSection))
        updateSidebarSelection()
    }

    private func clearContentBindings() {
        statusLabel = nil
        enabledCheckbox = nil
        delayField = nil
        componentCheckboxes.removeAll()
        learningStatusLabel = nil
        learningCountersLabel = nil
        learningCaptureLabel = nil
        learningEventsLabel = nil
        learningSamplesLabel = nil
        learningTracesLabel = nil
        learningTemplatesLabel = nil
        templateInventoryCountLabel = nil
        templateInventoryTextView = nil
        learningAnalysisLabel = nil
        learningDemoStatusLabel = nil
        learningEnabledCheckbox = nil
        trainingHostField = nil
    }

    private func makeSectionContent(_ section: ManagementSection) -> NSView {
        switch section {
        case .overview:
            return makeOverviewSection()
        case .hud:
            return makeSplitSection(primary: makeHUDCard(), secondary: makeHUDGuideCard())
        case .learning:
            return makeSplitSection(primary: makeLearningCard(), secondary: makeLearningGuideCard())
        case .templates:
            return makeTemplatesSection()
        case .analysis:
            return makeAnalysisSection()
        case .runtime:
            return makeRuntimeSection()
        case .security:
            return makeSecuritySection()
        }
    }

    private func makeOverviewSection() -> NSView {
        let stack = cardStack(spacing: 14)
        stack.widthAnchor.constraint(equalToConstant: 680).isActive = true

        let overview = NSStackView()
        overview.orientation = .horizontal
        overview.spacing = 10
        overview.addArrangedSubview(metricCard(title: "运行时", value: runtime == nil ? "离线" : "在线", caption: "VirtualHID.app"))
        overview.addArrangedSubview(metricCard(title: "HUD", value: lastState.enabled ? "开启" : "关闭", caption: "透明轨迹层"))
        overview.addArrangedSubview(metricCard(title: "键鼠学习", value: lastLearningState.enabled ? "开启" : "关闭", caption: lastLearningState.modeText))
        overview.addArrangedSubview(metricCard(title: "历史片段", value: "\(lastLearningState.traceCount)", caption: "已入库"))
        stack.addArrangedSubview(overview)

        let shortcuts = NSStackView()
        shortcuts.orientation = .horizontal
        shortcuts.alignment = .top
        shortcuts.spacing = 14
        shortcuts.addArrangedSubview(makeShortcutCard(title: "HUD 可视化", body: "控制轨迹、落点、点击/滚动/输入特效和常驻显示。", section: .hud))
        shortcuts.addArrangedSubview(makeShortcutCard(title: "键鼠学习", body: "开启整体键鼠学习分析，自动入库真实操作片段。", section: .learning))
        stack.addArrangedSubview(shortcuts)

        let management = NSStackView()
        management.orientation = .horizontal
        management.alignment = .top
        management.spacing = 14
        management.addArrangedSubview(makeShortcutCard(title: "能力模板", body: "单独查看已学习模板、样本数、置信度和算法参数。", section: .templates))
        management.addArrangedSubview(makeShortcutCard(title: "效果分析", body: "用安全 dry-run 对比模板命中前后的轨迹和事件链。", section: .analysis))
        stack.addArrangedSubview(management)

        stack.addArrangedSubview(makeRuntimeCard(title: "运行时状态"))
        return stack
    }

    private func makeSplitSection(primary: NSView, secondary: NSView) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 14
        stack.widthAnchor.constraint(equalToConstant: 680).isActive = true
        stack.addArrangedSubview(primary)
        stack.addArrangedSubview(secondary)
        return stack
    }

    private func makeRuntimeSection() -> NSView {
        let stack = cardStack(spacing: 14)
        stack.widthAnchor.constraint(equalToConstant: 680).isActive = true
        stack.addArrangedSubview(makeRuntimeCard(title: "运行时与 MCP"))
        stack.addArrangedSubview(makeInfoCard(
            title: "正式入口",
            body: [
                "VirtualHID.app 持有 runtime、HUD、学习控制和 MCP socket。",
                "MCP 只通过 hid_* 工具进入；管理 UI 不生成 HID 动作，也不参与业务决策。",
                "默认 socket：~/Library/Application Support/VirtualHID/virtualhid.sock"
            ],
            width: 680
        ))
        return stack
    }

    private func makeSecuritySection() -> NSView {
        let stack = cardStack(spacing: 14)
        stack.widthAnchor.constraint(equalToConstant: 680).isActive = true
        stack.addArrangedSubview(makeInfoCard(
            title: "安全边界",
            body: [
                "VirtualHID 不访问 DOM、不解析页面、不发网络请求。",
                "点击、拖拽、滚动和输入全局串行执行，避免鼠标/键盘事件并发交叉。",
                "Kill switch 与 unlock 只清理 VirtualHID 的输入状态，不改变上游 Agent 的业务目标。"
            ],
            width: 680
        ))

        let card = CardView()
        card.widthAnchor.constraint(equalToConstant: 680).isActive = true
        let cardContent = cardStack()
        cardContent.addArrangedSubview(label("安全操作", size: 15, weight: .semibold))
        cardContent.addArrangedSubview(label("用于异常时停止当前动作或释放卡住的修饰键/鼠标按钮。", size: 12, color: .secondaryLabelColor))
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.addArrangedSubview(actionButton("停止当前动作", action: #selector(stopAction(_:))))
        buttons.addArrangedSubview(actionButton("解除 Kill Switch / 清理输入状态", action: #selector(unlockAction(_:))))
        buttons.addArrangedSubview(actionButton("刷新状态", action: #selector(refreshAction(_:))))
        cardContent.addArrangedSubview(buttons)
        let permissionButtons = NSStackView()
        permissionButtons.orientation = .horizontal
        permissionButtons.spacing = 8
        permissionButtons.addArrangedSubview(actionButton("打开辅助功能授权", action: #selector(openAccessibilitySettingsAction(_:))))
        permissionButtons.addArrangedSubview(actionButton("打开输入监控授权", action: #selector(openInputMonitoringSettingsAction(_:))))
        cardContent.addArrangedSubview(permissionButtons)
        card.addContent(cardContent)
        stack.addArrangedSubview(card)
        return stack
    }

    private func makeRuntimeCard(title: String) -> NSView {
        let runtimeCard = CardView()
        runtimeCard.widthAnchor.constraint(equalToConstant: 680).isActive = true
        let runtimeStack = cardStack()
        runtimeStack.addArrangedSubview(label(title, size: 15, weight: .semibold))
        let runtimeStatus = label("", size: 12, weight: .medium)
        runtimeStatus.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        runtimeStatus.maximumNumberOfLines = 4
        runtimeStack.addArrangedSubview(runtimeStatus)
        statusLabel = runtimeStatus
        let runtimeButtons = NSStackView()
        runtimeButtons.orientation = .horizontal
        runtimeButtons.spacing = 8
        runtimeButtons.addArrangedSubview(actionButton("刷新状态", action: #selector(refreshAction(_:))))
        runtimeButtons.addArrangedSubview(actionButton("重启 Runtime", action: #selector(startDaemonAction(_:))))
        runtimeButtons.addArrangedSubview(actionButton("退出", action: #selector(quitAction(_:))))
        runtimeStack.addArrangedSubview(runtimeButtons)
        runtimeCard.addContent(runtimeStack)
        return runtimeCard
    }

    private func makeShortcutCard(title: String, body: String, section: ManagementSection) -> NSView {
        let card = CardView()
        card.widthAnchor.constraint(equalToConstant: 333).isActive = true
        let stack = cardStack(spacing: 8)
        stack.addArrangedSubview(label(title, size: 16, weight: .semibold))
        let text = label(body, size: 12, color: .secondaryLabelColor)
        text.maximumNumberOfLines = 3
        text.preferredMaxLayoutWidth = 292
        stack.addArrangedSubview(text)
        let button = actionButton("打开 \(title)", action: #selector(selectSectionAction(_:)))
        button.tag = section.rawValue
        stack.addArrangedSubview(button)
        card.addContent(stack)
        return card
    }

    private func makeHUDGuideCard() -> NSView {
        makeInfoCard(
            title: "显示规则",
            body: [
                "HUD 只展示 VirtualHID action events、execution context 和 verification。",
                "expected/final point 与轨迹不能由网页、browser 或 recruit-agent mock 补造。",
                "常驻显示只保留最近一次目标窗口、状态和落点；动态轨迹按清除延迟消失。"
            ]
        )
    }

    private func makeLearningGuideCard() -> NSView {
        makeInfoCard(
            title: "学习边界",
            body: [
                "学习只在显式开启后采集系统键鼠事件，不记录输入文本内容。",
                "聚焦采集只是临时标记一段训练窗口，样本会实时自动入库，不需要手动保存。",
                "能力模板只影响轨迹、节奏、hold/inter-click、dwell/inter-key 等执行参数，不选择业务目标。"
            ]
        )
    }

    private func makeInfoCard(title: String, body: [String], width: CGFloat = 330) -> NSView {
        let card = CardView()
        card.widthAnchor.constraint(equalToConstant: width).isActive = true
        let stack = cardStack(spacing: 10)
        stack.addArrangedSubview(label(title, size: 16, weight: .semibold))
        for line in body {
            let row = label("• \(line)", size: 12, color: .secondaryLabelColor)
            row.maximumNumberOfLines = 0
            row.preferredMaxLayoutWidth = width - 38
            stack.addArrangedSubview(row)
        }
        card.addContent(stack)
        return card
    }

    private func updateSidebarSelection() {
        for (section, button) in sidebarButtons {
            let selected = section == selectedSection
            button.font = NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
            button.contentTintColor = selected ? .controlAccentColor : .labelColor
            button.layer?.backgroundColor = selected
                ? NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
                : NSColor.clear.cgColor
        }
    }

    private func makeHUDCard() -> NSView {
        let card = CardView()
        card.widthAnchor.constraint(equalToConstant: 330).isActive = true
        let stack = cardStack()
        stack.addArrangedSubview(label("HUD 可视化", size: 16, weight: .semibold))
        let preview = HUDPreviewView()
        preview.heightAnchor.constraint(equalToConstant: 118).isActive = true
        preview.widthAnchor.constraint(equalToConstant: 292).isActive = true
        stack.addArrangedSubview(preview)

        let enabled = NSButton(checkboxWithTitle: "开启透明浮层", target: self, action: #selector(applyAction(_:)))
        enabled.controlSize = .large
        enabledCheckbox = enabled
        stack.addArrangedSubview(enabled)

        let pillRows: [[Component]] = [
            [.trail, .trailPoints, .expectedPoint],
            [.actualPoint, .clickEffects, .dragEffects],
            [.scrollEffects, .keyboardEffects, .persistent]
        ]
        for rowComponents in pillRows {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6
            for component in rowComponents {
                row.addArrangedSubview(pill(component))
            }
            stack.addArrangedSubview(row)
        }

        let delayStack = NSStackView()
        delayStack.orientation = .horizontal
        delayStack.alignment = .centerY
        delayStack.spacing = 8
        delayStack.addArrangedSubview(label("清除延迟", size: 12, color: .secondaryLabelColor))
        let delay = NSTextField(string: "2.4")
        delay.alignment = .right
        delay.target = self
        delay.action = #selector(applyAction(_:))
        delay.widthAnchor.constraint(equalToConstant: 58).isActive = true
        delayField = delay
        delayStack.addArrangedSubview(delay)
        delayStack.addArrangedSubview(label("秒", size: 12, color: .secondaryLabelColor))
        stack.addArrangedSubview(delayStack)
        stack.addArrangedSubview(actionButton("应用 HUD 配置", action: #selector(applyAction(_:))))
        card.addContent(stack)
        return card
    }

    private func makeLearningCard() -> NSView {
        let card = CardView()
        card.widthAnchor.constraint(equalToConstant: 330).isActive = true
        let stack = cardStack()
        stack.addArrangedSubview(label("键鼠输入学习分析", size: 16, weight: .semibold))
        let learningStatus = label("", size: 11, color: .secondaryLabelColor)
        learningStatus.lineBreakMode = .byWordWrapping
        learningStatus.maximumNumberOfLines = 3
        learningStatus.preferredMaxLayoutWidth = 292
        learningStatusLabel = learningStatus
        stack.addArrangedSubview(learningStatus)

        let counters = label("", size: 12, weight: .semibold, color: .labelColor)
        counters.maximumNumberOfLines = 2
        counters.preferredMaxLayoutWidth = 292
        learningCountersLabel = counters
        stack.addArrangedSubview(counters)

        let captureLabel = label("", size: 11, color: .secondaryLabelColor)
        captureLabel.maximumNumberOfLines = 3
        captureLabel.preferredMaxLayoutWidth = 292
        learningCaptureLabel = captureLabel
        stack.addArrangedSubview(captureLabel)

        let learningEnabled = NSButton(checkboxWithTitle: "开启键鼠输入学习分析", target: self, action: #selector(applyLearningAction(_:)))
        learningEnabled.controlSize = .large
        learningEnabledCheckbox = learningEnabled
        stack.addArrangedSubview(learningEnabled)

        let rhythm = LearningRhythmView()
        rhythm.heightAnchor.constraint(equalToConstant: 64).isActive = true
        rhythm.widthAnchor.constraint(equalToConstant: 292).isActive = true
        stack.addArrangedSubview(rhythm)

        stack.addArrangedSubview(label("聚焦采集用于临时标记一段练习窗口；这不是另一种学习模式，也不需要手动保存。开启后产生的键鼠片段会实时入库并参与模板重建。", size: 11, color: .secondaryLabelColor))

        let hostField = NSTextField(string: "")
        hostField.placeholderString = "可选：网页域名 / 应用名；留空=全局键鼠能力"
        for field in [hostField] {
            field.widthAnchor.constraint(equalToConstant: 198).isActive = true
        }
        trainingHostField = hostField
        let grid = NSGridView(views: [
            [label("采集范围", size: 12, color: .secondaryLabelColor), hostField]
        ])
        grid.rowSpacing = 6
        grid.columnSpacing = 8
        stack.addArrangedSubview(grid)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.addArrangedSubview(actionButton("开始聚焦采集", action: #selector(startTrainingAction(_:))))
        buttons.addArrangedSubview(actionButton("结束聚焦采集", action: #selector(commitTrainingAction(_:))))
        stack.addArrangedSubview(buttons)

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(label("实时采集", size: 14, weight: .semibold))
        let eventsLabel = label("", size: 11, color: .secondaryLabelColor)
        eventsLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        eventsLabel.maximumNumberOfLines = 5
        eventsLabel.preferredMaxLayoutWidth = 292
        learningEventsLabel = eventsLabel
        stack.addArrangedSubview(eventsLabel)

        let samplesLabel = label("", size: 11, color: .secondaryLabelColor)
        samplesLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        samplesLabel.maximumNumberOfLines = 6
        samplesLabel.preferredMaxLayoutWidth = 292
        learningSamplesLabel = samplesLabel
        stack.addArrangedSubview(samplesLabel)

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(label("自动入库片段", size: 14, weight: .semibold))
        let tracesLabel = label("", size: 11, color: .secondaryLabelColor)
        tracesLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        tracesLabel.maximumNumberOfLines = 5
        tracesLabel.preferredMaxLayoutWidth = 292
        learningTracesLabel = tracesLabel
        stack.addArrangedSubview(tracesLabel)

        let demoStatus = label("", size: 11, color: .secondaryLabelColor)
        demoStatus.maximumNumberOfLines = 4
        demoStatus.preferredMaxLayoutWidth = 292
        learningDemoStatusLabel = demoStatus
        stack.addArrangedSubview(demoStatus)

        let demoButtons = NSStackView()
        demoButtons.orientation = .horizontal
        demoButtons.spacing = 8
        let templatesButton = actionButton("打开能力模板", action: #selector(selectSectionAction(_:)))
        templatesButton.tag = ManagementSection.templates.rawValue
        demoButtons.addArrangedSubview(templatesButton)
        let analysisButton = actionButton("打开效果分析", action: #selector(selectSectionAction(_:)))
        analysisButton.tag = ManagementSection.analysis.rawValue
        demoButtons.addArrangedSubview(analysisButton)
        stack.addArrangedSubview(demoButtons)
        card.addContent(stack)
        return card
    }

    private func makeTemplatesSection() -> NSView {
        let stack = cardStack(spacing: 14)
        stack.widthAnchor.constraint(equalToConstant: 680).isActive = true

        let card = CardView()
        card.widthAnchor.constraint(equalToConstant: 680).isActive = true
        let cardContent = cardStack(spacing: 10)
        cardContent.addArrangedSubview(label("能力模板管理", size: 16, weight: .semibold))
        cardContent.addArrangedSubview(label("模板来自自动入库的键鼠片段。它们只影响 VirtualHID 执行层的轨迹、节奏、停顿、按压和键盘间隔，不包含业务站点逻辑。", size: 12, color: .secondaryLabelColor))

        let inventoryCount = label("", size: 11, weight: .medium, color: .secondaryLabelColor)
        templateInventoryCountLabel = inventoryCount
        cardContent.addArrangedSubview(inventoryCount)

        let inventoryScroll = NSScrollView()
        inventoryScroll.drawsBackground = false
        inventoryScroll.hasVerticalScroller = true
        inventoryScroll.hasHorizontalScroller = false
        inventoryScroll.autohidesScrollers = false
        inventoryScroll.borderType = .noBorder
        inventoryScroll.translatesAutoresizingMaskIntoConstraints = false

        let inventoryTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: 642, height: 360))
        inventoryTextView.drawsBackground = false
        inventoryTextView.isEditable = false
        inventoryTextView.isSelectable = true
        inventoryTextView.isRichText = false
        inventoryTextView.importsGraphics = false
        inventoryTextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        inventoryTextView.textColor = .secondaryLabelColor
        inventoryTextView.textContainerInset = NSSize(width: 0, height: 8)
        inventoryTextView.textContainer?.lineFragmentPadding = 0
        inventoryTextView.textContainer?.containerSize = NSSize(width: 642, height: CGFloat.greatestFiniteMagnitude)
        inventoryTextView.textContainer?.widthTracksTextView = true
        inventoryTextView.isHorizontallyResizable = false
        inventoryTextView.isVerticallyResizable = true
        inventoryTextView.minSize = NSSize(width: 0, height: 360)
        inventoryTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        inventoryTextView.autoresizingMask = [.width]
        templateInventoryTextView = inventoryTextView

        inventoryScroll.documentView = inventoryTextView
        inventoryScroll.widthAnchor.constraint(equalToConstant: 642).isActive = true
        inventoryScroll.heightAnchor.constraint(equalToConstant: 360).isActive = true
        cardContent.addArrangedSubview(inventoryScroll)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.addArrangedSubview(actionButton("重建能力模板", action: #selector(rebuildLearningProfilesAction(_:))))
        buttons.addArrangedSubview(actionButton("刷新", action: #selector(refreshAction(_:))))
        cardContent.addArrangedSubview(buttons)
        card.addContent(cardContent)
        stack.addArrangedSubview(card)
        return stack
    }

    private func makeAnalysisSection() -> NSView {
        let stack = cardStack(spacing: 14)
        stack.widthAnchor.constraint(equalToConstant: 680).isActive = true

        let card = CardView()
        card.widthAnchor.constraint(equalToConstant: 680).isActive = true
        let cardContent = cardStack(spacing: 10)
        cardContent.addArrangedSubview(label("拟人化与学习效果", size: 16, weight: .semibold))
        cardContent.addArrangedSubview(label("这里展示模板是否真实参与执行、内置拟人化算法是否产生轨迹/点击/键盘事件，以及学习参数是否来自样本聚合。演示使用安全 dry-run，不会投递真实点击。", size: 12, color: .secondaryLabelColor))

        let controls = CardView()
        let controlsContent = cardStack(spacing: 8)
        controlsContent.addArrangedSubview(label("演示控制", size: 13, weight: .semibold))

        let reusePoints = NSButton(checkboxWithTitle: "沿用上次起点 / 终点新增演示", target: nil, action: nil)
        reusePoints.toolTip = "关闭时每次演示随机选择新的起点和终点；开启时复用该动作上一次起点和终点，但轨迹仍由 VirtualHID 学习策略重新生成。"
        reuseDemoPointsCheckbox = reusePoints
        controlsContent.addArrangedSubview(reusePoints)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.addArrangedSubview(actionButton("移动轨迹", action: #selector(runMoveDemoAction(_:))))
        buttons.addArrangedSubview(actionButton("完整点击", action: #selector(runClickDemoAction(_:))))
        buttons.addArrangedSubview(actionButton("双击", action: #selector(runDoubleClickDemoAction(_:))))
        buttons.addArrangedSubview(actionButton("拖拽", action: #selector(runDragDemoAction(_:))))
        controlsContent.addArrangedSubview(buttons)

        let moreButtons = NSStackView()
        moreButtons.orientation = .horizontal
        moreButtons.spacing = 8
        moreButtons.addArrangedSubview(actionButton("滚轮", action: #selector(runScrollDemoAction(_:))))
        moreButtons.addArrangedSubview(actionButton("键盘事件", action: #selector(runKeyboardDemoAction(_:))))
        moreButtons.addArrangedSubview(actionButton("重放上次演示", action: #selector(replayLearningDemoAction(_:))))
        moreButtons.addArrangedSubview(actionButton("清空历史轨迹", action: #selector(clearLearningDemoHistoryAction(_:))))
        moreButtons.addArrangedSubview(actionButton("关闭 HUD 演示", action: #selector(stopLearningDemoAction(_:))))
        moreButtons.addArrangedSubview(actionButton("刷新", action: #selector(refreshAction(_:))))
        controlsContent.addArrangedSubview(moreButtons)
        controls.addContent(controlsContent)
        cardContent.addArrangedSubview(controls)

        let analysis = label("", size: 11, color: .secondaryLabelColor)
        analysis.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        analysis.maximumNumberOfLines = 18
        analysis.preferredMaxLayoutWidth = 642
        learningAnalysisLabel = analysis
        cardContent.addArrangedSubview(analysis)

        let demoStatus = label("", size: 11, color: .secondaryLabelColor)
        demoStatus.maximumNumberOfLines = 18
        demoStatus.preferredMaxLayoutWidth = 642
        learningDemoStatusLabel = demoStatus
        cardContent.addArrangedSubview(demoStatus)

        card.addContent(cardContent)
        stack.addArrangedSubview(card)
        return stack
    }

    private func metricCard(title: String, value: String, caption: String) -> NSView {
        let card = CardView()
        card.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let stack = cardStack(spacing: 4)
        stack.addArrangedSubview(label(title, size: 11, color: .secondaryLabelColor))
        stack.addArrangedSubview(label(value, size: 22, weight: .bold))
        stack.addArrangedSubview(label(caption, size: 11, color: .secondaryLabelColor))
        card.addContent(stack, inset: 12)
        return card
    }

    private func pill(_ component: Component) -> NSButton {
        let button = NSButton(checkboxWithTitle: pillTitle(component), target: self, action: #selector(applyAction(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        componentCheckboxes[component] = button
        return button
    }

    private func pillTitle(_ component: Component) -> String {
        switch component {
        case .trail: return "轨迹"
        case .trailPoints: return "采样点"
        case .expectedPoint: return "预期靶心"
        case .actualPoint: return "实际 X"
        case .clickEffects: return "点击"
        case .dragEffects: return "拖拽"
        case .scrollEffects: return "滚动"
        case .keyboardEffects: return "键盘"
        case .persistent: return "常驻"
        case .windowFrame: return "窗口框"
        case .diagnostic: return "诊断"
        case .status: return "状态"
        }
    }

    private func cardStack(spacing: CGFloat = 10) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byWordWrapping
        return field
    }

    private func separator() -> NSView {
        let view = NSBox()
        view.boxType = .separator
        view.widthAnchor.constraint(equalToConstant: 292).isActive = true
        return view
    }

    private func actionButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func updateTemplateInventoryTextView(_ textView: NSTextView, text: String, color: NSColor) {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let didChangeText = textView.string != text
        if didChangeText {
            textView.string = text
        }
        textView.font = font
        textView.textColor = color

        let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
        if fullRange.length > 0 {
            textView.textStorage?.setAttributes([
                .font: font,
                .foregroundColor: color
            ], range: fullRange)
        }
        if didChangeText {
            textView.scrollToBeginningOfDocument(nil)
        }
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
        learningCountersLabel?.stringValue = lastLearningState.counterText
        learningCountersLabel?.textColor = lastLearningState.available ? .controlAccentColor : .systemRed
        learningCaptureLabel?.stringValue = lastLearningState.captureText
        learningCaptureLabel?.textColor = lastLearningState.captureHasProblem ? .systemRed : .secondaryLabelColor
        learningEventsLabel?.stringValue = lastLearningState.recentEventsText
        learningEventsLabel?.textColor = lastLearningState.available ? .secondaryLabelColor : .systemRed
        learningSamplesLabel?.stringValue = lastLearningState.recentSamplesText
        learningSamplesLabel?.textColor = lastLearningState.available ? .secondaryLabelColor : .systemRed
        learningTracesLabel?.stringValue = lastLearningState.recentTracesText
        learningTracesLabel?.textColor = lastLearningState.available ? .secondaryLabelColor : .systemRed
        learningTemplatesLabel?.stringValue = lastLearningState.templateListText
        learningTemplatesLabel?.textColor = lastLearningState.available ? .secondaryLabelColor : .systemRed
        let templateInventoryColor: NSColor = lastLearningState.available ? .secondaryLabelColor : .systemRed
        templateInventoryCountLabel?.stringValue = lastLearningState.templateInventoryCountText
        templateInventoryCountLabel?.textColor = templateInventoryColor
        if let templateInventoryTextView {
            updateTemplateInventoryTextView(
                templateInventoryTextView,
                text: lastLearningState.templateInventoryText,
                color: templateInventoryColor
            )
        }
        learningAnalysisLabel?.stringValue = lastLearningState.analysisText
        learningAnalysisLabel?.textColor = lastLearningState.available ? .secondaryLabelColor : .systemRed
        learningDemoStatusLabel?.stringValue = lastLearningDemoStatus
        learningDemoStatusLabel?.textColor = lastLearningDemoStatus.hasPrefix("演示失败") ? .systemRed : .secondaryLabelColor
        learningEnabledCheckbox?.isEnabled = lastLearningState.available
        learningEnabledCheckbox?.state = lastLearningState.enabled ? .on : .off
        trainingHostField?.isEnabled = lastLearningState.available
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

    private func stopTraining(commit: Bool) {
        do {
            _ = try call(method: "learning.session.stop", params: ["commit": commit])
            let response = try call(method: "learning.inspect", params: ["limit": learningInspectLimit])
            lastLearningState = LearningState(response: response)
        } catch {
            lastLearningState = .offline(message: localizedErrorMessage(error))
        }
        updateControls()
    }

    private func call(method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        if runtime == nil {
            startRuntime()
        }
        guard let runtime else {
            throw TrayError(runtimeError ?? "VirtualHID runtime 未启动")
        }
        return try runtime.call(method: method, params: params)
    }

    private func openSystemSettings(_ urlString: String) {
        guard let url = URL(string: urlString) else {
            return
        }
        NSWorkspace.shared.open(url)
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
            return "HUD 控制不可用：请从 VirtualHID.app 启动本地运行时，或使用 CLI smoke 显式开启 HUD。"
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
    let hasActiveSession: Bool
    let activeSessionLabel: String?
    let activeSessionSampleCount: Int
    let producedSamples: Int
    let pendingTrainingSamples: Int
    let persistedSamples: Int
    let totalTemplates: Int
    let traceCount: Int
    let eventTapRunning: Bool
    let eventTapError: String?
    let accessibility: Bool
    let inputMonitoring: Bool
    let recentEvents: [LearningEventSummary]
    let recentSamples: [LearningSampleSummary]
    let recentTraces: [LearningTraceSummary]
    let templates: [LearningTemplateSummary]
    let lastLearnedAt: String?
    let message: String?

    var modeText: String {
        if mode == "off" {
            return "关闭"
        }
        if hasActiveSession || activeSessionSampleCount > 0 {
            return "聚焦采集中"
        }
        return "持续分析"
    }

    var statusText: String {
        if let message {
            return "学习离线：\(message)"
        }
        let sessionText = hasActiveSession ? "，聚焦采集（\(activeSessionSampleCount) 个片段，实时入库）" : ""
        return "键鼠输入学习分析：\(enabled ? "开启" : "关闭") / \(modeText)，已捕捉 \(producedSamples) 个片段，历史片段 \(traceCount) 个，能力模板 \(totalTemplates) 个\(sessionText)"
    }

    var counterText: String {
        "已捕捉 \(producedSamples)  |  自动入库 \(persistedSamples)  |  历史片段 \(traceCount)  |  能力模板 \(totalTemplates)"
    }

    var captureText: String {
        guard available else {
            return message ?? "学习服务不可用"
        }
        if !enabled {
            return "学习关闭时不会采集真实键鼠事件。开启后，只有系统事件监听运行中才会增长计数。"
        }
        let permissionText = "辅助功能 \(accessibility ? "已授权" : "未授权")，输入监控 \(inputMonitoring ? "已授权" : "未授权")"
        if eventTapRunning {
            return "系统事件监听运行中。\(permissionText)。移动、单击、拖拽、滚动或键盘输入后，下方会出现实时事件和动作片段。"
        }
        let reason = eventTapError.map { "原因：\($0)。" } ?? ""
        return "系统事件监听未运行，所以计数不会增长。\(reason)\(permissionText)。"
    }

    var captureHasProblem: Bool {
        available && enabled && (!eventTapRunning || !accessibility)
    }

    var recentEventsText: String {
        guard available else {
            return message ?? "学习服务不可用"
        }
        guard !recentEvents.isEmpty else {
            return "最近原始事件：暂无。开启学习后移动鼠标、单击、滚动或按键，这里应立即出现事件。"
        }
        return "最近原始事件\n" + recentEvents.prefix(5).map(\.displayText).joined(separator: "\n")
    }

    var recentSamplesText: String {
        guard available else {
            return message ?? "学习服务不可用"
        }
        guard !recentSamples.isEmpty else {
            return "动作片段：暂无。完整片段会由移动/按下/抬起、滚动或键盘按下/抬起自动生成并入库。"
        }
        return "动作片段\n" + recentSamples.prefix(5).map(\.displayText).joined(separator: "\n")
    }

    var recentTracesText: String {
        guard available else {
            return message ?? "学习服务不可用"
        }
        guard !recentTraces.isEmpty else {
            return "历史片段：暂无。开启学习后真实键鼠动作会自动入库。"
        }
        return "历史片段\n" + recentTraces.prefix(5).map(\.displayText).joined(separator: "\n")
    }

    var templateListText: String {
        guard available else {
            return message ?? "学习服务不可用"
        }
        guard !templates.isEmpty else {
            return "暂无能力模板。开启键鼠输入学习分析积累真实片段后，点击「重建能力模板」再演示学习效果。"
        }
        return "能力模板\n" + templates.map(\.displayText).joined(separator: "\n")
    }

    var templateInventoryText: String {
        guard available else {
            return message ?? "学习服务不可用"
        }
        guard !templates.isEmpty else {
            if totalTemplates > 0 {
                return "当前服务报告共有 \(totalTemplates) 个能力模板，但本次 inspect 未返回模板详情，暂无法展开列表。请点击「刷新」或检查 learning.inspect 的 templates 字段。"
            }
            return "暂无能力模板。模板至少需要足够数量的历史片段才能聚合生成。"
        }
        return templates.enumerated().map { index, template in
            "\(index + 1). \(template.detailText)"
        }.joined(separator: "\n\n")
    }

    var templateInventoryCountText: String {
        guard available else {
            return "模板清单不可用"
        }
        let visibleCount = templates.count
        let totalCount = max(totalTemplates, visibleCount)
        if totalCount == visibleCount {
            return "显示 \(visibleCount) / 共 \(totalCount) 个模板"
        }
        return "显示 \(visibleCount) / 共 \(totalCount) 个模板（本次接口返回 \(visibleCount) 个）"
    }

    var analysisText: String {
        guard available else {
            return message ?? "学习服务不可用"
        }
        let templateDetails = templates.map { template in
            "• \(template.analysisText)"
        }.joined(separator: "\n")
        let eventTypes = recentEvents.prefix(8).map(\.type).joined(separator: ", ")
        let traceLine = recentTraces.first?.displayText ?? "暂无历史片段"
        return [
            "事件监听：\(eventTapRunning ? "运行中" : "未运行")；辅助功能 \(accessibility ? "已授权" : "未授权")，输入监控 \(inputMonitoring ? "已授权" : "未授权")。",
            "最近事件链：\(eventTypes.isEmpty ? "暂无" : eventTypes)。",
            "最新学习片段：\(traceLine)。",
            templateDetails.isEmpty ? "模板分析：暂无可分析模板。" : "模板分析：\n\(templateDetails)"
        ].joined(separator: "\n")
    }

    init(response: [String: Any]) {
        let responseResult = response["result"] as? [String: Any] ?? response
        let result = responseResult["state"] as? [String: Any] ?? responseResult
        let settings = result["settings"] as? [String: Any] ?? [:]
        let activeSession = result["activeSession"] as? [String: Any]
        available = true
        enabled = settings["enabled"] as? Bool ?? false
        mode = settings["mode"] as? String ?? "off"
        hasActiveSession = activeSession != nil
        activeSessionLabel = activeSession?["label"] as? String
        activeSessionSampleCount = intValue(activeSession?["sampleCount"]) ?? 0
        producedSamples = intValue(result["producedSamples"]) ?? 0
        pendingTrainingSamples = intValue(result["pendingTrainingSamples"]) ?? 0
        persistedSamples = intValue(responseResult["persistedSamples"]) ?? intValue(result["persistedSamples"]) ?? 0
        totalTemplates = intValue(responseResult["totalTemplates"])
            ?? intValue(responseResult["generatedTemplates"])
            ?? intValue(result["totalTemplates"])
            ?? 0
        traceCount = intValue(responseResult["traceCount"]) ?? intValue(result["traceCount"]) ?? 0
        let eventCapture = responseResult["eventCapture"] as? [String: Any] ?? [:]
        eventTapRunning = eventCapture["eventTapRunning"] as? Bool ?? false
        eventTapError = eventCapture["eventTapError"] as? String
        accessibility = eventCapture["accessibility"] as? Bool ?? false
        inputMonitoring = eventCapture["inputMonitoring"] as? Bool ?? false
        recentEvents = (responseResult["recentEvents"] as? [[String: Any]] ?? []).map(LearningEventSummary.init)
        recentSamples = (result["recentSamples"] as? [[String: Any]] ?? responseResult["recentSamples"] as? [[String: Any]] ?? [])
            .map(LearningSampleSummary.init)
        recentTraces = (responseResult["recentTraces"] as? [[String: Any]] ?? []).map(LearningTraceSummary.init)
        templates = (result["templates"] as? [[String: Any]] ?? responseResult["templates"] as? [[String: Any]] ?? [])
            .map(LearningTemplateSummary.init)
        lastLearnedAt = result["lastLearnedAt"] as? String
        message = nil
    }

    static func offline(message: String) -> LearningState {
        LearningState(
            available: false,
            enabled: false,
            mode: "off",
            hasActiveSession: false,
            activeSessionLabel: nil,
            activeSessionSampleCount: 0,
            producedSamples: 0,
            pendingTrainingSamples: 0,
            persistedSamples: 0,
            totalTemplates: 0,
            traceCount: 0,
            eventTapRunning: false,
            eventTapError: message,
            accessibility: false,
            inputMonitoring: false,
            recentEvents: [],
            recentSamples: [],
            recentTraces: [],
            templates: [],
            lastLearnedAt: nil,
            message: message
        )
    }

    private init(
        available: Bool,
        enabled: Bool,
        mode: String,
        hasActiveSession: Bool,
        activeSessionLabel: String?,
        activeSessionSampleCount: Int,
        producedSamples: Int,
        pendingTrainingSamples: Int,
        persistedSamples: Int,
        totalTemplates: Int,
        traceCount: Int,
        eventTapRunning: Bool,
        eventTapError: String?,
        accessibility: Bool,
        inputMonitoring: Bool,
        recentEvents: [LearningEventSummary],
        recentSamples: [LearningSampleSummary],
        recentTraces: [LearningTraceSummary],
        templates: [LearningTemplateSummary],
        lastLearnedAt: String?,
        message: String?
    ) {
        self.available = available
        self.enabled = enabled
        self.mode = mode
        self.hasActiveSession = hasActiveSession
        self.activeSessionLabel = activeSessionLabel
        self.activeSessionSampleCount = activeSessionSampleCount
        self.producedSamples = producedSamples
        self.pendingTrainingSamples = pendingTrainingSamples
        self.persistedSamples = persistedSamples
        self.totalTemplates = totalTemplates
        self.traceCount = traceCount
        self.eventTapRunning = eventTapRunning
        self.eventTapError = eventTapError
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
        self.recentEvents = recentEvents
        self.recentSamples = recentSamples
        self.recentTraces = recentTraces
        self.templates = templates
        self.lastLearnedAt = lastLearnedAt
        self.message = message
    }
}

private struct LearningEventSummary {
    let type: String
    let x: Double?
    let y: Double?
    let keyCode: Int?

    init(_ object: [String: Any]) {
        type = object["type"] as? String ?? "event"
        let point = object["point"] as? [String: Any]
        x = doubleValue(point?["x"])
        y = doubleValue(point?["y"])
        keyCode = intValue(object["keyCode"])
    }

    var displayText: String {
        if let x, let y {
            return "\(displayEventType(type)) @ \(Int(x)),\(Int(y))"
        }
        if let keyCode {
            return "\(displayEventType(type)) keyCode=\(keyCode)"
        }
        return displayEventType(type)
    }
}

private struct LearningSampleSummary {
    let host: String
    let actionType: String
    let pointCount: Int
    let durationMs: Double?
    let clickHoldMs: [Double]
    let dwellMs: [Double]
    let interKeyMs: [Double]
    let speedPxS: Double?
    let quality: Double?

    init(_ object: [String: Any]) {
        host = object["host"] as? String ?? "__global__"
        actionType = object["actionType"] as? String ?? "action"
        pointCount = intValue(object["pointCount"]) ?? 0
        durationMs = doubleValue(object["durationMs"])
        clickHoldMs = (object["clickHoldMs"] as? [Any] ?? []).compactMap(doubleValue)
        dwellMs = (object["dwellMs"] as? [Any] ?? []).compactMap(doubleValue)
        interKeyMs = (object["interKeyMs"] as? [Any] ?? []).compactMap(doubleValue)
        speedPxS = doubleValue(object["speedPxS"])
        quality = doubleValue(object["quality"])
    }

    var displayText: String {
        var parts = ["\(displayActionType(actionType))片段", displayScope(host)]
        if pointCount > 0 {
            parts.append("\(pointCount)点")
        }
        if let durationMs {
            parts.append(formatMs(durationMs))
        }
        if let hold = clickHoldMs.first {
            parts.append("按压\(formatMs(hold))")
        }
        if let dwell = dwellMs.first {
            parts.append("键停留\(formatMs(dwell))")
        }
        if let interKey = interKeyMs.first {
            parts.append("键间隔\(formatMs(interKey))")
        }
        if let speedPxS {
            parts.append("\(Int(speedPxS))px/s")
        }
        return parts.joined(separator: " · ")
    }
}

private struct LearningTraceSummary {
    let host: String
    let actionType: String
    let pointCount: Int
    let durationMs: Double?
    let clickHoldMs: [Double]
    let dwellMs: [Double]
    let interKeyMs: [Double]
    let speedPxS: Double?

    init(_ object: [String: Any]) {
        host = object["host"] as? String ?? "__global__"
        actionType = object["actionType"] as? String ?? "action"
        pointCount = intValue(object["pointCount"]) ?? 0
        durationMs = doubleValue(object["durationMs"])
        clickHoldMs = (object["clickHoldMs"] as? [Any] ?? []).compactMap(doubleValue)
        dwellMs = (object["dwellMs"] as? [Any] ?? []).compactMap(doubleValue)
        interKeyMs = (object["interKeyMs"] as? [Any] ?? []).compactMap(doubleValue)
        speedPxS = doubleValue(object["speedPxS"])
    }

    var displayText: String {
        var parts = [displayActionType(actionType), displayScope(host)]
        if pointCount > 0 {
            parts.append("\(pointCount)点")
        }
        if let durationMs {
            parts.append(formatMs(durationMs))
        }
        if let hold = clickHoldMs.first {
            parts.append("按压\(formatMs(hold))")
        }
        if let dwell = dwellMs.first {
            parts.append("键停留\(formatMs(dwell))")
        }
        if let interKey = interKeyMs.first {
            parts.append("键间隔\(formatMs(interKey))")
        }
        return parts.joined(separator: " · ")
    }
}

private struct LearningTemplateSummary {
    let host: String
    let elementSig: String
    let actionType: String
    let sampleSize: Int
    let confidence: Double
    let motion: [String: Any]

    init(_ object: [String: Any]) {
        host = object["host"] as? String ?? "unknown"
        elementSig = object["elementSig"] as? String ?? object["element_sig"] as? String ?? ""
        actionType = object["actionType"] as? String ?? object["action_type"] as? String ?? "action"
        sampleSize = intValue(object["sampleSize"] ?? object["sample_size"]) ?? 0
        if let double = object["confidence"] as? Double {
            confidence = double
        } else if let int = object["confidence"] as? Int {
            confidence = Double(int)
        } else if let string = object["confidence"] as? String, let parsed = Double(string) {
            confidence = parsed
        } else {
            confidence = 0
        }
        motion = object["motion"] as? [String: Any] ?? [:]
    }

    var displayText: String {
        "\(displayActionType(actionType))能力 · \(displayScope(host)) · \(sampleSize)个片段 · 置信度 \(String(format: "%.2f", confidence))"
    }

    var detailText: String {
        [
            displayText,
            "目标签名：\(elementSig.isEmpty ? "通用" : elementSig)",
            "算法参数：\(motionText)"
        ].joined(separator: "\n")
    }

    var analysisText: String {
        "\(displayActionType(actionType)) / \(displayScope(host))：\(sampleSize) 个样本，置信度 \(String(format: "%.2f", confidence))，\(motionText)"
    }

    private var motionText: String {
        var parts = [String]()
        if let flavor = motion["flavor"] as? String {
            parts.append("轨迹=\(displayMotionFlavor(flavor))")
        }
        if let pointCount = motion["pointCount"] as? [String: Any],
           let min = intValue(pointCount["min"]),
           let max = intValue(pointCount["max"]) {
            parts.append("点数 \(min)-\(max)")
        }
        if let clickHold = motion["clickHoldMs"] as? [String: Any],
           let min = intValue(clickHold["min"]),
           let max = intValue(clickHold["max"]) {
            parts.append("按压 \(min)-\(max)ms")
        }
        if let doubleClick = motion["doubleClickInterClickMs"] as? [String: Any],
           let min = intValue(doubleClick["min"]),
           let max = intValue(doubleClick["max"]) {
            parts.append("双击间隔 \(min)-\(max)ms")
        }
        if let scrollDelta = motion["scrollDeltaY"] as? [String: Any],
           let min = doubleValue(scrollDelta["min"]),
           let max = doubleValue(scrollDelta["max"]) {
            parts.append("滚轮 \(Int(min))-\(Int(max))px")
        }
        if let scrollSteps = motion["scrollStepCount"] as? [String: Any],
           let min = intValue(scrollSteps["min"]),
           let max = intValue(scrollSteps["max"]) {
            parts.append("滚轮段数 \(min)-\(max)")
        }
        if let scrollDelay = motion["scrollStepDelayMs"] as? [String: Any],
           let min = intValue(scrollDelay["min"]),
           let max = intValue(scrollDelay["max"]) {
            parts.append("滚轮间隔 \(min)-\(max)ms")
        }
        if let moveSpeed = motion["moveSpeedPxS"] as? [String: Any],
           let min = doubleValue(moveSpeed["min"]),
           let max = doubleValue(moveSpeed["max"]) {
            parts.append("移动 \(Int(min))-\(Int(max))px/s")
        }
        if let dragSpeed = motion["dragSpeedPxS"] as? [String: Any],
           let min = doubleValue(dragSpeed["min"]),
           let max = doubleValue(dragSpeed["max"]) {
            parts.append("拖拽 \(Int(min))-\(Int(max))px/s")
        }
        if let dwell = doubleValue(motion["dwellMsMean"]) {
            parts.append("键停留均值 \(formatMs(dwell))")
        }
        if let dwellRange = motion["dwellMs"] as? [String: Any],
           let min = intValue(dwellRange["min"]),
           let max = intValue(dwellRange["max"]) {
            parts.append("键停留 \(min)-\(max)ms")
        }
        if let interKey = doubleValue(motion["interKeyMsMean"]) {
            parts.append("键间隔均值 \(formatMs(interKey))")
        }
        if let interKeyRange = motion["interKeyMs"] as? [String: Any],
           let min = intValue(interKeyRange["min"]),
           let max = intValue(interKeyRange["max"]) {
            parts.append("键间隔 \(min)-\(max)ms")
        }
        if let skeleton = motion["pathSkeleton"] as? [[String: Any]], !skeleton.isEmpty {
            parts.append("骨架 \(skeleton.count)点")
        }
        if let segments = motion["segmentMs"] as? [[String: Any]], !segments.isEmpty {
            parts.append("节奏 \(segments.count)段")
        }
        if let straightness = doubleValue(motion["straightnessMean"]) {
            parts.append("直线度 \(String(format: "%.2f", straightness))")
        }
        if let turnJitter = doubleValue(motion["turnJitterMean"]) {
            parts.append("转向抖动 \(String(format: "%.2f", turnJitter))")
        }
        return parts.isEmpty ? "暂无可视化参数" : parts.joined(separator: "，")
    }
}

private struct LearningDemoResult {
    let statusText: String

    init(response: [String: Any], fallbackTitle: String = "学习效果演示") {
        let result = response["result"] as? [String: Any] ?? response
        let assertions = result["assertions"] as? [String: Any] ?? [:]
        guard result["ok"] as? Bool == true else {
            if let error = response["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "暂无可演示的真实学习结果"
                statusText = "演示失败：\(message)。请先开启键鼠输入学习分析，完成若干真实操作后重建能力模板。"
                return
            }
            let profile = assertions["learnedProfilesApplied"] as? Bool == true ? "模板已命中" : "模板未命中"
            let click = assertions["learnedActionsHaveClickEvents"] as? Bool == true ? "点击事件已生成" : "点击事件缺失"
            statusText = "安全预览未通过：\(profile)，\(click)。不会实际点击页面。"
            return
        }
        let template = result["template"] as? [String: Any] ?? [:]
        let actions = result["actions"] as? [[String: Any]] ?? []
        let baseline = result["baseline"] as? [String: Any]
        let effect = result["learningEffect"] as? [String: Any] ?? [:]
        let demoAction = result["demoAction"] as? String
        let templateId = "\(displayActionType(template["actionType"] as? String ?? demoAction ?? "click"))习惯 · \(displayScope(template["host"] as? String ?? "__global__"))"
        let activeFields = (effect["activeFields"] as? [String] ?? []).prefix(8).joined(separator: ", ")
        let title = result["title"] as? String ?? fallbackTitle
        var lines = [
            "\(title) 完成：已使用真实学习结果 \(templateId) 生成 \(actions.count) 次 dry-run 动作；不会真实点击页面。",
            "学习生效字段：\(activeFields.isEmpty ? "暂无" : activeFields)。"
        ]
        if let manual = result["manualControl"] as? [String: Any] {
            let repeatable = manual["repeatable"] as? Bool == true ? "可重复播放" : "不可重复"
            let autoAdvance = manual["autoAdvance"] as? Bool == true ? "自动推进" : "不自动推进"
            lines.append("演示控制：\(repeatable)，\(autoAdvance)，同一时间最多一个演示。")
        }
        lines.append("HUD 控制：结果保留到手动关闭；可点「重放上次演示」复播同一条 dry-run 事件链。")
        if let baseline {
            lines.append("对照：\(Self.actionSummaryLine(baseline))")
        }
        if let firstAction = actions.first {
            lines.append("学习动作 #1：\(Self.actionSummaryLine(firstAction))")
            lines.append(contentsOf: Self.stepLines(firstAction).prefix(8))
        }
        lines.append("证据来源：VirtualHID action events / HUD，不由页面或脚本构造轨迹。")
        statusText = lines.joined(separator: "\n")
    }

    private static func actionSummaryLine(_ action: [String: Any]) -> String {
        let profile = action["profileApplied"] as? Bool == true ? "模板已应用" : "模板未应用"
        let trajectory = action["trajectory"] as? [String: Any] ?? [:]
        let metrics = action["metrics"] as? [String: Any] ?? [:]
        let points = intValue(trajectory["pointCount"]) ?? intValue(action["mouseMoveCount"]) ?? 0
        let duration = doubleValue(metrics["durationMs"]).map(formatMs) ?? "未知时长"
        let path = doubleValue(metrics["pathLengthPx"]).map { "\(Int($0.rounded()))px" } ?? "未知距离"
        return "\(profile)，轨迹点 \(points)，距离 \(path)，时长 \(duration)"
    }

    private static func stepLines(_ action: [String: Any]) -> [String] {
        let steps = action["steps"] as? [[String: Any]] ?? []
        return steps.map { step in
            let index = intValue(step["index"]).map { $0 + 1 } ?? 0
            let title = step["title"] as? String ?? step["phase"] as? String ?? "步骤"
            let detail = step["detail"] as? String ?? ""
            if detail.isEmpty {
                return "\(index). \(title)"
            }
            return "\(index). \(title)：\(detail)"
        }
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

private func doubleValue(_ value: Any?) -> Double? {
    if let double = value as? Double {
        return double
    }
    if let int = value as? Int {
        return Double(int)
    }
    if let string = value as? String {
        return Double(string)
    }
    return nil
}

private func displayActionType(_ value: String) -> String {
    switch value {
    case "dblclick":
        return "双击"
    case "keyboard":
        return "键盘"
    case "click":
        return "单击"
    case "drag":
        return "拖拽"
    case "scroll":
        return "滚动"
    case "move":
        return "移动"
    case "type", "pasteText", "key":
        return "输入"
    default:
        return value
    }
}

private func displayEventType(_ value: String) -> String {
    switch value {
    case "mouseMoved":
        return "移动"
    case "leftMouseDown", "rightMouseDown", "otherMouseDown":
        return "按下"
    case "leftMouseUp", "rightMouseUp", "otherMouseUp":
        return "抬起"
    case "leftMouseDragged", "rightMouseDragged", "otherMouseDragged":
        return "拖动"
    case "scrollWheel":
        return "滚动"
    case "keyDown":
        return "键盘按下"
    case "keyUp":
        return "键盘抬起"
    case "flagsChanged":
        return "修饰键变化"
    default:
        return value
    }
}

private func displayMotionFlavor(_ value: String) -> String {
    switch value {
    case "smooth":
        return "平滑"
    case "gentle":
        return "温和"
    case "hurried":
        return "快速"
    case "idle":
        return "停顿"
    default:
        return value
    }
}

private func displayScope(_ value: String) -> String {
    switch value {
    case "", "__global__":
        return "全局"
    case "virtualhid-management-demo-baseline.local":
        return "未使用模板"
    default:
        return value
    }
}

private func formatMs(_ value: Double) -> String {
    "\(Int(value.rounded()))ms"
}

private final class CardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.72).cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.32).cgColor
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func addContent(_ view: NSView, inset: CGFloat = 14) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            view.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)
        ])
    }
}

private final class HUDPreviewView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bounds = self.bounds.insetBy(dx: 16, dy: 14)
        NSColor(calibratedRed: 0.10, green: 0.77, blue: 0.78, alpha: 1).setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bounds.minX + 10, y: bounds.minY + 18))
        path.curve(
            to: NSPoint(x: bounds.maxX - 62, y: bounds.maxY - 26),
            controlPoint1: NSPoint(x: bounds.minX + 58, y: bounds.minY + 92),
            controlPoint2: NSPoint(x: bounds.maxX - 130, y: bounds.midY - 20)
        )
        path.lineWidth = 3
        path.stroke()

        NSColor.white.withAlphaComponent(0.88).setFill()
        for point in [NSPoint(x: bounds.minX + 44, y: bounds.minY + 52), NSPoint(x: bounds.midX - 4, y: bounds.midY), NSPoint(x: bounds.maxX - 94, y: bounds.maxY - 44)] {
            NSBezierPath(ovalIn: NSRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)).fill()
        }

        NSColor.systemOrange.setStroke()
        let target = NSPoint(x: bounds.maxX - 44, y: bounds.maxY - 34)
        let ring = NSBezierPath(ovalIn: NSRect(x: target.x - 12, y: target.y - 12, width: 24, height: 24))
        ring.lineWidth = 1.5
        ring.stroke()
        NSBezierPath(rect: NSRect(x: target.x - 1, y: target.y - 15, width: 2, height: 30)).stroke()
        NSBezierPath(rect: NSRect(x: target.x - 15, y: target.y - 1, width: 30, height: 2)).stroke()

        NSColor.systemRed.setStroke()
        let actual = NSPoint(x: bounds.maxX - 34, y: bounds.maxY - 28)
        let xPath = NSBezierPath()
        xPath.move(to: NSPoint(x: actual.x - 9, y: actual.y - 9))
        xPath.line(to: NSPoint(x: actual.x + 9, y: actual.y + 9))
        xPath.move(to: NSPoint(x: actual.x + 9, y: actual.y - 9))
        xPath.line(to: NSPoint(x: actual.x - 9, y: actual.y + 9))
        xPath.lineWidth = 2
        xPath.stroke()
    }
}

private final class LearningRhythmView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bars: [CGFloat] = [0.28, 0.62, 0.48, 0.82, 0.36, 0.70, 0.55, 0.88, 0.42]
        let width = bounds.width / CGFloat(bars.count * 2)
        for (index, value) in bars.enumerated() {
            let x = CGFloat(index) * width * 2 + width
            let height = max(8, bounds.height * value)
            let rect = NSRect(x: x, y: 8, width: width, height: height - 10)
            NSColor.controlAccentColor.withAlphaComponent(0.72).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        }
        let text = "速度变化 / 曲率 / 点击节奏"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        text.draw(at: NSPoint(x: 12, y: bounds.maxY - 20), withAttributes: attrs)
    }
}
