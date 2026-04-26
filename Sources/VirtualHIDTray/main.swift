import AppKit
import Darwin
import Foundation
import VirtualHIDRuntime

final class VirtualHIDTrayApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum ManagementSection: Int, CaseIterable {
        case overview
        case hud
        case learning
        case runtime
        case security

        var title: String {
            switch self {
            case .overview: return "总览"
            case .hud: return "HUD 可视化"
            case .learning: return "学习预训练"
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
                return "开启被动学习或专项训练，沉淀鼠标轨迹、节奏和点击行为模板。"
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
    private var learningEnabledCheckbox: NSButton?
    private var learningModePopup: NSPopUpButton?
    private var trainingLabelField: NSTextField?
    private var trainingHostField: NSTextField?
    private var trainingActionField: NSTextField?
    private var lastLearningState = LearningState.offline(message: "未连接到 VirtualHID 执行服务")

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
        menu.addItem(NSMenuItem(title: lastLearningState.enabled ? "暂停学习" : "开启被动学习", action: #selector(toggleLearningAction(_:)), keyEquivalent: ""))
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
            let response = try call(method: "learning.configure", params: [
                "enabled": !lastLearningState.enabled,
                "mode": lastLearningState.enabled ? "off" : "passive"
            ])
            lastLearningState = LearningState(response: response)
        } catch {
            lastLearningState = .offline(message: localizedErrorMessage(error))
        }
        updateControls()
    }

    @objc private func clearTrailAction(_ sender: Any?) {
        do {
            _ = try call(method: "hud.configure", params: ["clearDelaySeconds": 0.1])
            let response = try call(method: "hud.configure", params: ["clearDelaySeconds": delayField?.doubleValue ?? 2.4])
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
            let response = try call(method: "learning.configure", params: [
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
            let response = try call(method: "learning.session.start", params: [
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
    }

    private func refreshState(autostartIfNeeded: Bool = false) {
        do {
            let response = try call(method: "hud.state", params: [:])
            lastState = HUDState(response: response)
            let learningResponse = try call(method: "learning.state", params: [:])
            lastLearningState = LearningState(response: learningResponse)
        } catch {
            lastState = .offline(message: localizedErrorMessage(error))
            lastLearningState = .offline(message: localizedErrorMessage(error))
        }
        updateControls()
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
        learningEnabledCheckbox = nil
        learningModePopup = nil
        trainingLabelField = nil
        trainingHostField = nil
        trainingActionField = nil
    }

    private func makeSectionContent(_ section: ManagementSection) -> NSView {
        switch section {
        case .overview:
            return makeOverviewSection()
        case .hud:
            return makeSplitSection(primary: makeHUDCard(), secondary: makeHUDGuideCard())
        case .learning:
            return makeSplitSection(primary: makeLearningCard(), secondary: makeLearningGuideCard())
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
        overview.addArrangedSubview(metricCard(title: "学习", value: lastLearningState.enabled ? "开启" : "关闭", caption: lastLearningState.modeText))
        overview.addArrangedSubview(metricCard(title: "样本", value: "\(lastLearningState.persistedSamples)", caption: "已持久化"))
        stack.addArrangedSubview(overview)

        let shortcuts = NSStackView()
        shortcuts.orientation = .horizontal
        shortcuts.alignment = .top
        shortcuts.spacing = 14
        shortcuts.addArrangedSubview(makeShortcutCard(title: "HUD 可视化", body: "控制轨迹、落点、点击/滚动/输入特效和常驻显示。", section: .hud))
        shortcuts.addArrangedSubview(makeShortcutCard(title: "学习预训练", body: "开启被动学习或进入专项训练，沉淀可复用的人类行为模板。", section: .learning))
        stack.addArrangedSubview(shortcuts)

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
                "被动学习只在显式开启后采集真实鼠标事件流。",
                "专项训练用于沉淀通用行为特征，不把 mock 页面数据当真实站点 skill。",
                "学习模板只影响轨迹、节奏、hold/inter-click 等执行参数。"
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
        stack.addArrangedSubview(label("学习与训练", size: 16, weight: .semibold))
        let learningStatus = label("", size: 11, color: .secondaryLabelColor)
        learningStatus.lineBreakMode = .byWordWrapping
        learningStatus.maximumNumberOfLines = 3
        learningStatus.preferredMaxLayoutWidth = 292
        learningStatusLabel = learningStatus
        stack.addArrangedSubview(learningStatus)

        let learningEnabled = NSButton(checkboxWithTitle: "开启鼠标习惯学习", target: self, action: #selector(applyLearningAction(_:)))
        learningEnabled.controlSize = .large
        learningEnabledCheckbox = learningEnabled
        stack.addArrangedSubview(learningEnabled)

        let modeStack = NSStackView()
        modeStack.orientation = .horizontal
        modeStack.alignment = .centerY
        modeStack.spacing = 8
        modeStack.addArrangedSubview(label("模式", size: 12, color: .secondaryLabelColor))
        let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        modePopup.addItems(withTitles: ["被动学习", "专项训练", "关闭"])
        modePopup.target = self
        modePopup.action = #selector(applyLearningAction(_:))
        modePopup.widthAnchor.constraint(equalToConstant: 128).isActive = true
        learningModePopup = modePopup
        modeStack.addArrangedSubview(modePopup)
        stack.addArrangedSubview(modeStack)

        let rhythm = LearningRhythmView()
        rhythm.heightAnchor.constraint(equalToConstant: 64).isActive = true
        rhythm.widthAnchor.constraint(equalToConstant: 292).isActive = true
        stack.addArrangedSubview(rhythm)

        let labelField = NSTextField(string: "手动轨迹训练")
        let hostField = NSTextField(string: "")
        hostField.placeholderString = "可选 host"
        let actionField = NSTextField(string: "click")
        actionField.placeholderString = "click / drag / scroll"
        for field in [labelField, hostField, actionField] {
            field.widthAnchor.constraint(equalToConstant: 198).isActive = true
        }
        trainingLabelField = labelField
        trainingHostField = hostField
        trainingActionField = actionField
        let grid = NSGridView(views: [
            [label("名称", size: 12, color: .secondaryLabelColor), labelField],
            [label("Host", size: 12, color: .secondaryLabelColor), hostField],
            [label("动作", size: 12, color: .secondaryLabelColor), actionField]
        ])
        grid.rowSpacing = 6
        grid.columnSpacing = 8
        stack.addArrangedSubview(grid)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.addArrangedSubview(actionButton("开始", action: #selector(startTrainingAction(_:))))
        buttons.addArrangedSubview(actionButton("提交", action: #selector(commitTrainingAction(_:))))
        buttons.addArrangedSubview(actionButton("丢弃", action: #selector(discardTrainingAction(_:))))
        stack.addArrangedSubview(buttons)
        card.addContent(stack)
        return card
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

    private func actionButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
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

    private func stopTraining(commit: Bool) {
        do {
            let response = try call(method: "learning.session.stop", params: ["commit": commit])
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
    let activeSessionLabel: String?
    let producedSamples: Int
    let pendingTrainingSamples: Int
    let persistedSamples: Int
    let totalTemplates: Int
    let lastLearnedAt: String?
    let message: String?

    var modeText: String {
        switch mode {
        case "training":
            return "专项训练"
        case "off":
            return "关闭"
        default:
            return "被动学习"
        }
    }

    var statusText: String {
        if let message {
            return "学习离线：\(message)"
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
