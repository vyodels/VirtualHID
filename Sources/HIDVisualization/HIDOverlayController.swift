import AppKit
import Foundation
import InjectorCore

public struct HIDOverlaySettings: Equatable {
    public var clearDelaySeconds: TimeInterval
    public var showWindowFrame: Bool
    public var showDiagnostic: Bool
    public var showTrail: Bool
    public var showTrailPoints: Bool
    public var showExpectedPoint: Bool
    public var showActualPoint: Bool
    public var showClickEffects: Bool
    public var showDragEffects: Bool
    public var showScrollEffects: Bool
    public var showKeyboardEffects: Bool
    public var showStatus: Bool
    public var persistent: Bool

    public init(
        clearDelaySeconds: TimeInterval = 2.4,
        showWindowFrame: Bool = true,
        showDiagnostic: Bool = true,
        showTrail: Bool = true,
        showTrailPoints: Bool = true,
        showExpectedPoint: Bool = true,
        showActualPoint: Bool = true,
        showClickEffects: Bool = true,
        showDragEffects: Bool = true,
        showScrollEffects: Bool = true,
        showKeyboardEffects: Bool = true,
        showStatus: Bool = true,
        persistent: Bool = true
    ) {
        self.clearDelaySeconds = max(0.1, clearDelaySeconds)
        self.showWindowFrame = showWindowFrame
        self.showDiagnostic = showDiagnostic
        self.showTrail = showTrail
        self.showTrailPoints = showTrailPoints
        self.showExpectedPoint = showExpectedPoint
        self.showActualPoint = showActualPoint
        self.showClickEffects = showClickEffects
        self.showDragEffects = showDragEffects
        self.showScrollEffects = showScrollEffects
        self.showKeyboardEffects = showKeyboardEffects
        self.showStatus = showStatus
        self.persistent = persistent
    }
}

public final class HIDOverlayController: HIDEventSink, HIDVisualizationControl {
    private let queue = DispatchQueue(label: "com.vyodels.virtualhid.hud.state")
    private var settings: HIDOverlaySettings
    private var enabled: Bool
    private let lockedOff: Bool
    private var eventsByAction = [String: [InjectedEvent]]()
    private var overlayWindow: NSPanel?
    private var overlayView: HIDOverlayView?
    private var overlayFrame: NSRect?
    private var trackedTarget: HIDTrackedTarget?
    private var trackingTimer: Timer?
    private var axObserver: AXObserver?
    private var observedAXWindow: AXUIElement?
    private var observedAXTargetKey: String?
    private var workspaceTerminationObserver: NSObjectProtocol?
    private var clearToken = 0
    private var playbackToken = 0
    private var lastReplayableSummary: HIDActionVisualSummary?
    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public init(settings: HIDOverlaySettings = HIDOverlaySettings(), enabled: Bool = true, lockedOff: Bool = false) {
        self.settings = settings
        self.enabled = enabled && !lockedOff
        self.lockedOff = lockedOff
    }

    public convenience init(clearDelaySeconds: TimeInterval) {
        self.init(settings: HIDOverlaySettings(clearDelaySeconds: clearDelaySeconds))
    }

    deinit {
        trackingTimer?.invalidate()
        uninstallAXObserver()
        if let workspaceTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceTerminationObserver)
        }
    }

    public var currentSettings: HIDOverlaySettings {
        queue.sync { settings }
    }

    public var isEnabled: Bool {
        queue.sync { enabled }
    }

    public func setEnabled(_ enabled: Bool) {
        queue.sync {
            self.enabled = enabled && !lockedOff
        }
        DispatchQueue.main.async { [weak self] in
            if !enabled {
                self?.closeOverlay()
            }
        }
    }

    public func updateSettings(_ settings: HIDOverlaySettings) {
        queue.sync {
            self.settings = settings
        }
        DispatchQueue.main.async { [weak self] in
            self?.overlayView?.updateSettings(settings)
        }
    }

    public func hidVisualizationState() -> [String: Any] {
        let snapshot = queue.sync { (enabled, settings) }
        return [
            "available": true,
            "enabled": snapshot.0,
            "lockedOff": lockedOff,
            "settings": settingsObject(snapshot.1)
        ]
    }

    public func hidVisualizationConfigure(_ params: [String: Any]) -> [String: Any] {
        if let requestedEnabled = boolValue(params["enabled"]) {
            setEnabled(requestedEnabled)
        }
        let shouldClear = boolValue(params["clear"]) ?? boolValue(params["close"]) ?? false
        let shouldReplay = boolValue(params["replayLast"])
            ?? boolValue(params["replay"])
            ?? boolValue(params["replay_last"])
            ?? false

        var next = currentSettings
        if let clearDelay = doubleValue(params["clearDelaySeconds"]), clearDelay.isFinite, clearDelay > 0 {
            next.clearDelaySeconds = clearDelay
        }
        if let show = componentList(params["show"]) {
            applyComponents(show, visible: true, settings: &next)
        }
        if let hide = componentList(params["hide"]) {
            applyComponents(hide, visible: false, settings: &next)
        }
        if let settingsObject = params["settings"] as? [String: Any] {
            applySettingsObject(settingsObject, settings: &next)
        }
        updateSettings(next)
        if shouldClear {
            DispatchQueue.main.async { [weak self] in
                self?.closeOverlay()
            }
        } else if shouldReplay {
            DispatchQueue.main.async { [weak self] in
                self?.replayLastSummary()
            }
        }
        return hidVisualizationState()
    }

    public func hidActionDidStart(_ context: HIDActionVisualContext) {
        guard accepts(context) else {
            return
        }
        queue.sync {
            eventsByAction[context.actionId] = []
        }
        DispatchQueue.main.async { [weak self] in
            self?.ensureOverlay(for: context)
            self?.overlayView?.render(
                HIDOverlayFrame(
                    context: context,
                    events: [],
                    expected: nil,
                    actual: nil,
                    errorCode: nil,
                    stepTitle: "准备执行",
                    stepDetail: "等待 VirtualHID 事件流"
                )
            )
            self?.clearToken += 1
        }
    }

    public func hidActionDidRecord(_ event: InjectedEvent, context: HIDActionVisualContext) {
        guard accepts(context) else {
            return
        }
        let events = queue.sync { () -> [InjectedEvent] in
            var current = eventsByAction[context.actionId] ?? []
            current.append(event)
            eventsByAction[context.actionId] = current
            return current
        }
        if context.dryRun {
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            let step = self.playbackStep(for: events)
            self.ensureOverlay(for: context)
            self.overlayView?.render(
                HIDOverlayFrame(
                    context: context,
                    events: events,
                    expected: nil,
                    actual: nil,
                    errorCode: nil,
                    stepTitle: step.title,
                    stepDetail: step.detail
                )
            )
        }
    }

    public func hidActionDidFinish(_ summary: HIDActionVisualSummary) {
        guard accepts(summary.context) else {
            return
        }
        queue.sync {
            eventsByAction[summary.context.actionId] = nil
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.ensureOverlay(for: summary.context)
            if summary.context.dryRun {
                self.lastReplayableSummary = summary
            }
            if summary.context.dryRun, summary.events.count > 1 {
                self.playback(summary)
            } else {
                self.overlayView?.render(
                    HIDOverlayFrame(
                        context: summary.context,
                        events: summary.events,
                        expected: summary.verification.expectedPointer,
                        actual: summary.verification.finalPointer,
                        errorCode: nil,
                        stepTitle: self.playbackStep(for: summary.events, context: summary.context).title,
                        stepDetail: self.playbackStep(for: summary.events, context: summary.context).detail
                    )
                )
                if !self.shouldRetainCompletedAction(for: summary.context) {
                    self.scheduleClear()
                }
            }
        }
    }

    public func hidActionDidFail(actionId: String, errorCode: String) {
        queue.sync {
            eventsByAction[actionId] = nil
        }
        DispatchQueue.main.async { [weak self] in
            self?.overlayView?.markFailure(errorCode: errorCode)
            self?.scheduleClear()
        }
    }

    private func playback(_ summary: HIDActionVisualSummary) {
        playbackToken += 1
        let token = playbackToken
        let delays = playbackDelays(for: summary.events)
        let demoTitle = controllerDemoActionTitle(for: summary.context)
        let retainAtEnd = shouldRetainPlayback(for: summary.context)
        overlayView?.render(
            HIDOverlayFrame(
                context: summary.context,
                events: [],
                expected: summary.verification.expectedPointer,
                actual: nil,
                errorCode: nil,
                stepTitle: "\(demoTitle) 准备播放",
                stepDetail: "显示预期目标落点，等待轨迹事件"
            )
        )
        for index in summary.events.indices {
            let delay = delays[index]
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.playbackToken == token else {
                    return
                }
                let visibleEvents = Array(summary.events.prefix(index + 1))
                let step = self.playbackStep(for: visibleEvents, context: summary.context)
                let finalFrame = index == summary.events.count - 1
                let displayStep: HIDPlaybackStep
                if finalFrame && retainAtEnd {
                    displayStep = self.retainedPlaybackStep(title: demoTitle, finalStep: step, events: visibleEvents)
                } else {
                    displayStep = step
                }
                self.overlayView?.render(
                    HIDOverlayFrame(
                        context: summary.context,
                        events: visibleEvents,
                        expected: summary.verification.expectedPointer,
                        actual: finalFrame ? summary.verification.finalPointer : nil,
                        errorCode: nil,
                        stepTitle: displayStep.title,
                        stepDetail: displayStep.detail
                    )
                )
                if finalFrame && !retainAtEnd {
                    self.scheduleClear()
                }
            }
        }
    }

    private func replayLastSummary() {
        guard isEnabled, let summary = lastReplayableSummary else {
            return
        }
        ensureOverlay(for: summary.context)
        playback(summary)
    }

    private func shouldRetainPlayback(for context: HIDActionVisualContext) -> Bool {
        shouldRetainCompletedAction(for: context)
    }

    private func shouldRetainCompletedAction(for context: HIDActionVisualContext) -> Bool {
        accepts(context) && currentSettings.persistent
    }

    private func controllerDemoActionTitle(for context: HIDActionVisualContext) -> String {
        let actionId = context.actionId.lowercased()
        let types = Set(context.actionTypes.map { $0.lowercased() })
        if actionId.contains("dblclick") {
            return "双击演示"
        }
        if types.contains("drag") {
            return "拖拽演示"
        }
        if types.contains("scroll") {
            return "滚轮演示"
        }
        if types.contains("type") || types.contains("key") || types.contains("pastetext") {
            return "键盘事件演示"
        }
        if types.contains("move"), !types.contains("click") {
            return "移动轨迹演示"
        }
        if types.contains("click") {
            return "完整点击演示"
        }
        return context.actionTypes.joined(separator: "+")
    }

    private func retainedPlaybackStep(title: String, finalStep: HIDPlaybackStep, events: [InjectedEvent]) -> HIDPlaybackStep {
        let detail = "\(finalStep.title)：\(finalStep.detail)。完整事件链 \(events.count) 个已保留；可在管理中心重放或关闭。"
        return HIDPlaybackStep(title: "\(title) 结果已保留", detail: detail)
    }

    private func playbackStep(for events: [InjectedEvent], context: HIDActionVisualContext? = nil) -> HIDPlaybackStep {
        guard let last = events.last else {
            return HIDPlaybackStep(title: "准备移动", detail: "等待 VirtualHID 生成轨迹")
        }
        let focus = playbackFocus(for: context)
        let points = events.compactMap(\.location)
        if last.type == "mouseMoved" || last.type.contains("Dragged") {
            let start = points.first.map(shortPoint) ?? "?"
            let end = points.last.map(shortPoint) ?? "?"
            if last.type == "mouseMoved", context != nil, !focus.primaryTypes.contains("move") {
                return HIDPlaybackStep(
                    title: "\(focus.title)前置定位移动",
                    detail: "这一段只是把指针移动到目标附近，不是本次演示重点；起点 \(start) -> 当前 \(end)，轨迹点 \(points.count)。"
                )
            }
            return HIDPlaybackStep(
                title: last.type.contains("Dragged") ? "拖拽移动（本次重点）" : "滑动轨迹（本次重点）",
                detail: "起点 \(start) -> 当前 \(end)，轨迹点 \(points.count)。"
            )
        }
        if last.type.contains("MouseDown") {
            let clickOrdinal = events.filter { $0.type.contains("MouseDown") }.count
            return HIDPlaybackStep(
                title: focus.primaryTypes.contains("click") ? "\(focus.title)第 \(clickOrdinal) 次下压" : "开始下压",
                detail: "\(last.type) @ \(last.location.map(shortPoint) ?? "?")。"
            )
        }
        if last.type.contains("MouseUp") {
            let hold = holdDurationMs(in: events, upEvent: last).map { "\(Int($0.rounded()))ms" } ?? "未知"
            let clickOrdinal = events.filter { $0.type.contains("MouseUp") }.count
            return HIDPlaybackStep(
                title: focus.primaryTypes.contains("click") ? "\(focus.title)第 \(clickOrdinal) 次松开" : "松开",
                detail: "\(last.type) @ \(last.location.map(shortPoint) ?? "?")，按压 \(hold)。"
            )
        }
        if last.type == "scrollWheel" {
            let count = events.filter { $0.type == "scrollWheel" }.count
            return HIDPlaybackStep(title: "滚轮事件（本次重点）", detail: "第 \(count) 个 scrollWheel @ \(last.location.map(shortPoint) ?? "?")。")
        }
        if last.type == "keyDown" {
            return HIDPlaybackStep(title: "键盘下压（本次重点）", detail: "keyDown \(last.key ?? "")。")
        }
        if last.type == "keyUp" {
            let dwell = keyDwellDurationMs(in: events, upEvent: last).map { "\(Int($0.rounded()))ms" } ?? "未知"
            return HIDPlaybackStep(title: "键盘松开（本次重点）", detail: "keyUp \(last.key ?? "")，按键驻留 \(dwell)。")
        }
        if last.type == "pasteText" {
            return HIDPlaybackStep(title: "粘贴文本（本次重点）", detail: "安全预览粘贴事件。")
        }
        return HIDPlaybackStep(title: "执行事件", detail: last.type)
    }

    private func playbackFocus(for context: HIDActionVisualContext?) -> (title: String, primaryTypes: Set<String>) {
        let actionId = context?.actionId.lowercased() ?? ""
        let types = Set(context?.actionTypes.map { $0.lowercased() } ?? [])
        if actionId.contains("dblclick") {
            return ("双击", ["click"])
        }
        if types.contains("drag") {
            return ("拖拽", ["drag", "click"])
        }
        if types.contains("scroll") {
            return ("滚轮", ["scroll"])
        }
        if types.contains("type") || types.contains("key") || types.contains("pastetext") {
            return ("键盘", ["type", "key", "pastetext"])
        }
        if types.contains("move"), !types.contains("click") {
            return ("移动", ["move"])
        }
        if types.contains("click") {
            return ("点击", ["move", "click"])
        }
        return ("动作", types)
    }

    private func holdDurationMs(in events: [InjectedEvent], upEvent: InjectedEvent) -> Double? {
        guard let upDate = isoFormatter.date(from: upEvent.timestamp),
              let down = events.reversed().first(where: { $0.type.contains("MouseDown") }),
              let downDate = isoFormatter.date(from: down.timestamp) else {
            return nil
        }
        return max(0, upDate.timeIntervalSince(downDate) * 1000)
    }

    private func keyDwellDurationMs(in events: [InjectedEvent], upEvent: InjectedEvent) -> Double? {
        guard let upDate = isoFormatter.date(from: upEvent.timestamp),
              let down = events.reversed().first(where: { $0.type == "keyDown" && $0.virtualKey == upEvent.virtualKey }),
              let downDate = isoFormatter.date(from: down.timestamp) else {
            return nil
        }
        return max(0, upDate.timeIntervalSince(downDate) * 1000)
    }

    private func shortPoint(_ point: CodablePoint) -> String {
        "(\(Int(point.x.rounded())),\(Int(point.y.rounded())))"
    }

    private func playbackDelays(for events: [InjectedEvent]) -> [TimeInterval] {
        guard !events.isEmpty else {
            return []
        }
        var delays: [TimeInterval] = [0]
        let dates = events.map { isoFormatter.date(from: $0.timestamp) }
        for index in 1..<events.count {
            let rawDelta: TimeInterval
            if let previous = dates[index - 1], let current = dates[index] {
                rawDelta = current.timeIntervalSince(previous)
            } else {
                rawDelta = 0.07
            }
            let actualDelta = rawDelta.isFinite ? max(rawDelta, 0) : 0
            delays.append(delays[index - 1] + actualDelta)
        }
        return delays
    }

    private func ensureOverlay(for context: HIDActionVisualContext) {
        updateTrackedTarget(context)
        let frame = overlayPanelFrame(for: context)
        if let overlayWindow {
            if overlayFrame != frame {
                overlayWindow.setFrame(frame, display: true)
                overlayView?.resize(frame: NSRect(origin: .zero, size: frame.size), screenFrame: frame)
                overlayFrame = frame
            }
            overlayWindow.orderFrontRegardless()
            return
        }
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let view = HIDOverlayView(frame: NSRect(origin: .zero, size: frame.size), screenFrame: frame, settings: currentSettings)
        panel.contentView = view
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.orderFrontRegardless()
        overlayWindow = panel
        overlayView = view
        overlayFrame = frame
    }

    private func updateTrackedTarget(_ context: HIDActionVisualContext) {
        let target = HIDTrackedTarget(
            pid: pid_t(context.pid),
            title: context.windowTitle,
            frame: cgRect(from: context.windowFrame),
            context: context
        )
        trackedTarget = target
        installWorkspaceTerminationObserverIfNeeded()
        installAXObserverIfAvailable(for: target)
        startTrackingTimerIfNeeded()
    }

    private func installWorkspaceTerminationObserverIfNeeded() {
        guard workspaceTerminationObserver == nil else {
            return
        }
        workspaceTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let self,
                let trackedTarget,
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app.processIdentifier == trackedTarget.pid
            else {
                return
            }
            if self.retainOverlayAfterTrackingLoss(for: trackedTarget.context) {
                return
            }
            self.closeOverlay()
        }
    }

    private func startTrackingTimerIfNeeded() {
        guard trackingTimer == nil else {
            return
        }
        let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.refreshTrackedTarget()
        }
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
    }

    private func refreshTrackedTarget() {
        guard let trackedTarget else {
            stopTrackingTimer()
            return
        }
        guard let app = NSRunningApplication(processIdentifier: trackedTarget.pid), !app.isTerminated else {
            if retainOverlayAfterTrackingLoss(for: trackedTarget.context) {
                return
            }
            closeOverlay()
            return
        }
        let windows = currentWindowSnapshots(for: trackedTarget.pid)
        guard let window = bestTrackedWindowMatch(target: trackedTarget, windows: windows) else {
            if retainOverlayAfterTrackingLoss(for: trackedTarget.context) {
                return
            }
            closeOverlay()
            return
        }
        applyTrackedWindowSnapshot(window, previousTarget: trackedTarget)
    }

    fileprivate func handleAXWindowNotification(_ notification: String, element: AXUIElement) {
        guard let trackedTarget else {
            uninstallAXObserver()
            return
        }
        if notification == kAXUIElementDestroyedNotification as String {
            if retainOverlayAfterTrackingLoss(for: trackedTarget.context) {
                return
            }
            closeOverlay()
            return
        }
        guard let frame = copyAXFrame(of: element), frame.width > 80, frame.height > 80 else {
            if retainOverlayAfterTrackingLoss(for: trackedTarget.context) {
                return
            }
            closeOverlay()
            return
        }
        let title = copyAXStringAttribute(of: element, name: kAXTitleAttribute)
        applyTrackedWindowSnapshot(
            HIDWindowSnapshot(pid: trackedTarget.pid, title: title, frame: frame),
            previousTarget: trackedTarget
        )
    }

    private func applyTrackedWindowSnapshot(_ window: HIDWindowSnapshot, previousTarget: HIDTrackedTarget) {
        guard !approximatelyEqual(window.frame, previousTarget.frame) else {
            return
        }
        let nextContext = replacingWindowFrame(in: previousTarget.context, with: codableRect(from: window.frame))
        trackedTarget = HIDTrackedTarget(
            pid: previousTarget.pid,
            title: window.title ?? previousTarget.title,
            frame: window.frame,
            context: nextContext
        )
        let nextPanelFrame = overlayPanelFrame(for: nextContext)
        if let overlayWindow, overlayFrame != nextPanelFrame {
            overlayWindow.setFrame(nextPanelFrame, display: true)
            overlayView?.resize(frame: NSRect(origin: .zero, size: nextPanelFrame.size), screenFrame: nextPanelFrame)
            overlayFrame = nextPanelFrame
        }
        overlayView?.updateWindowFrame(nextContext.windowFrame)
    }

    private func closeOverlay() {
        playbackToken += 1
        clearToken += 1
        trackedTarget = nil
        stopTrackingTimer()
        uninstallAXObserver()
        overlayView?.clearAll()
        overlayWindow?.orderOut(nil)
    }

    private func retainOverlayAfterTrackingLoss(for context: HIDActionVisualContext) -> Bool {
        guard context.dryRun, shouldRetainCompletedAction(for: context) else {
            return false
        }
        trackedTarget = nil
        stopTrackingTimer()
        uninstallAXObserver()
        return true
    }

    private func stopTrackingTimer() {
        trackingTimer?.invalidate()
        trackingTimer = nil
    }

    private func installAXObserverIfAvailable(for target: HIDTrackedTarget) {
        let targetKey = observerKey(for: target)
        if axObserver != nil, observedAXTargetKey == targetKey {
            return
        }
        uninstallAXObserver()
        guard let window = bestTrackedAXWindowMatch(target: target, windows: currentAXWindowSnapshots(for: target.pid)) else {
            return
        }

        var createdObserver: AXObserver?
        guard AXObserverCreate(target.pid, hidOverlayAXObserverCallback, &createdObserver) == .success, let createdObserver else {
            return
        }
        let observerContext = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        var installedAnyNotification = false
        for notification in trackedAXWindowNotifications {
            let status = AXObserverAddNotification(createdObserver, window.element, notification as CFString, observerContext)
            installedAnyNotification = installedAnyNotification || status == .success
        }
        guard installedAnyNotification else {
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(createdObserver), .commonModes)
        axObserver = createdObserver
        observedAXWindow = window.element
        observedAXTargetKey = targetKey
    }

    private func uninstallAXObserver() {
        if let axObserver, let observedAXWindow {
            for notification in trackedAXWindowNotifications {
                AXObserverRemoveNotification(axObserver, observedAXWindow, notification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .commonModes)
        }
        axObserver = nil
        observedAXWindow = nil
        observedAXTargetKey = nil
    }

    private func scheduleClear() {
        clearToken += 1
        let token = clearToken
        let clearDelaySeconds = currentSettings.clearDelaySeconds
        DispatchQueue.main.asyncAfter(deadline: .now() + clearDelaySeconds) { [weak self] in
            guard self?.clearToken == token else {
                return
            }
            self?.overlayView?.clearTransientState()
        }
    }

    private func accepts(_ context: HIDActionVisualContext) -> Bool {
        context.source == "hid" && isEnabled
    }

    private func overlayPanelFrame(for context: HIDActionVisualContext) -> NSRect {
        let fallback = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let windowRect = appKitRect(from: context.windowFrame)
        guard windowRect.width > 1, windowRect.height > 1 else {
            return fallback
        }
        if let screen = NSScreen.screens
            .map({ screen in (screen, screen.frame.intersection(windowRect)) })
            .filter({ !$0.1.isNull && !$0.1.isEmpty })
            .max(by: { $0.1.width * $0.1.height < $1.1.width * $1.1.height })?
            .0 {
            return screen.frame
        }
        let center = CGPoint(x: windowRect.midX, y: windowRect.midY)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            return screen.frame
        }
        return fallback
    }

    private func appKitRect(from rect: CodableRect) -> NSRect {
        let yReference = primaryScreenTopY()
        return NSRect(
            x: rect.x,
            y: yReference - rect.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    private func cgRect(from rect: CodableRect) -> CGRect {
        CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }
}

struct HIDTrackedTarget {
    let pid: pid_t
    let title: String?
    let frame: CGRect
    let context: HIDActionVisualContext
}

struct HIDWindowSnapshot: Equatable {
    let pid: pid_t
    let title: String?
    let frame: CGRect
}

func currentWindowSnapshots(for pid: pid_t) -> [HIDWindowSnapshot] {
    guard
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else {
        return []
    }

    return windowList.compactMap { window in
        guard
            let ownerPid = window[kCGWindowOwnerPID as String] as? pid_t,
            ownerPid == pid,
            let layer = window[kCGWindowLayer as String] as? Int,
            layer == 0,
            let boundsValue = window[kCGWindowBounds as String] as? [String: Any],
            let frame = CGRect(dictionaryRepresentation: boundsValue as CFDictionary),
            frame.width > 80,
            frame.height > 80
        else {
            return nil
        }
        return HIDWindowSnapshot(
            pid: ownerPid,
            title: window[kCGWindowName as String] as? String,
            frame: frame
        )
    }
}

func bestTrackedWindowMatch(target: HIDTrackedTarget, windows: [HIDWindowSnapshot]) -> HIDWindowSnapshot? {
    let candidates = windows.filter { $0.pid == target.pid }
    guard !candidates.isEmpty else {
        return nil
    }

    let normalizedTitle = target.title?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let normalizedTitle, !normalizedTitle.isEmpty {
        let titleMatches = candidates.filter { candidate in
            guard let candidateTitle = candidate.title?.trimmingCharacters(in: .whitespacesAndNewlines), !candidateTitle.isEmpty else {
                return false
            }
            return candidateTitle == normalizedTitle
                || candidateTitle.contains(normalizedTitle)
                || normalizedTitle.contains(candidateTitle)
        }
        if let best = nearestWindow(to: target.frame, in: titleMatches) {
            return best
        }
    }

    guard let nearest = nearestWindow(to: target.frame, in: candidates) else {
        return nil
    }
    if normalizedTitle?.isEmpty == false {
        return windowLooksLikeMovedTarget(previous: target.frame, current: nearest.frame) ? nearest : nil
    }
    return nearest
}

private func nearestWindow(to frame: CGRect, in windows: [HIDWindowSnapshot]) -> HIDWindowSnapshot? {
    windows.min { left, right in
        windowDistance(from: frame, to: left.frame) < windowDistance(from: frame, to: right.frame)
    }
}

private func windowDistance(from left: CGRect, to right: CGRect) -> CGFloat {
    let centerDistance = hypot(left.midX - right.midX, left.midY - right.midY)
    let sizeDistance = abs(left.width - right.width) + abs(left.height - right.height)
    return centerDistance + sizeDistance * 0.5
}

private func windowLooksLikeMovedTarget(previous: CGRect, current: CGRect) -> Bool {
    if previous.intersects(current) {
        let overlap = previous.intersection(current)
        let smallerArea = min(previous.width * previous.height, current.width * current.height)
        if smallerArea > 0, (overlap.width * overlap.height) / smallerArea >= 0.45 {
            return true
        }
    }
    let centerDistance = hypot(previous.midX - current.midX, previous.midY - current.midY)
    if centerDistance <= 180 {
        return true
    }
    let sizeDelta = abs(previous.width - current.width) + abs(previous.height - current.height)
    return centerDistance <= 260 && sizeDelta <= 120
}

private func approximatelyEqual(_ left: CGRect, _ right: CGRect) -> Bool {
    abs(left.origin.x - right.origin.x) < 1
        && abs(left.origin.y - right.origin.y) < 1
        && abs(left.width - right.width) < 1
        && abs(left.height - right.height) < 1
}

private func replacingWindowFrame(in context: HIDActionVisualContext, with frame: CodableRect) -> HIDActionVisualContext {
    HIDActionVisualContext(
        actionId: context.actionId,
        source: context.source,
        bundleIdentifier: context.bundleIdentifier,
        pid: context.pid,
        windowTitle: context.windowTitle,
        windowFrame: frame,
        dryRun: context.dryRun,
        postMode: context.postMode,
        actionTypes: context.actionTypes
    )
}

private func codableRect(from frame: CGRect) -> CodableRect {
    CodableRect(
        x: frame.origin.x,
        y: frame.origin.y,
        width: frame.width,
        height: frame.height
    )
}

private let trackedAXWindowNotifications = [
    kAXMovedNotification as String,
    kAXResizedNotification as String,
    kAXUIElementDestroyedNotification as String,
    kAXWindowMiniaturizedNotification as String
]

private let hidOverlayAXObserverCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else {
        return
    }
    let controller = Unmanaged<HIDOverlayController>.fromOpaque(refcon).takeUnretainedValue()
    DispatchQueue.main.async {
        controller.handleAXWindowNotification(notification as String, element: element)
    }
}

private struct HIDAXWindowSnapshot {
    let element: AXUIElement
    let snapshot: HIDWindowSnapshot
}

private func observerKey(for target: HIDTrackedTarget) -> String {
    [
        String(target.pid),
        target.title ?? "",
        String(Int(target.frame.width.rounded())),
        String(Int(target.frame.height.rounded()))
    ].joined(separator: "|")
}

private func currentAXWindowSnapshots(for pid: pid_t) -> [HIDAXWindowSnapshot] {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.2)
    guard let windows = copyAXAttribute(of: app, name: kAXWindowsAttribute) as? [AXUIElement] else {
        return []
    }
    return windows.compactMap { window in
        AXUIElementSetMessagingTimeout(window, 0.2)
        guard
            let frame = copyAXFrame(of: window),
            frame.width > 80,
            frame.height > 80,
            copyAXBoolAttribute(of: window, name: kAXMinimizedAttribute) != true
        else {
            return nil
        }
        return HIDAXWindowSnapshot(
            element: window,
            snapshot: HIDWindowSnapshot(
                pid: pid,
                title: copyAXStringAttribute(of: window, name: kAXTitleAttribute),
                frame: frame
            )
        )
    }
}

private func bestTrackedAXWindowMatch(target: HIDTrackedTarget, windows: [HIDAXWindowSnapshot]) -> HIDAXWindowSnapshot? {
    guard let best = bestTrackedWindowMatch(target: target, windows: windows.map(\.snapshot)) else {
        return nil
    }
    return windows.first { window in
        window.snapshot.pid == best.pid
            && window.snapshot.title == best.title
            && approximatelyEqual(window.snapshot.frame, best.frame)
    }
}

private func copyAXAttribute(of element: AXUIElement, name: String) -> Any? {
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    guard status == .success else {
        return nil
    }
    return value
}

private func copyAXStringAttribute(of element: AXUIElement, name: String) -> String? {
    copyAXAttribute(of: element, name: name) as? String
}

private func copyAXBoolAttribute(of element: AXUIElement, name: String) -> Bool? {
    if let value = copyAXAttribute(of: element, name: name) as? Bool {
        return value
    }
    if let value = copyAXAttribute(of: element, name: name) as? NSNumber {
        return value.boolValue
    }
    return nil
}

private func copyAXValueAttribute(of element: AXUIElement, name: String) -> AXValue? {
    guard let value = copyAXAttribute(of: element, name: name) as CFTypeRef? else {
        return nil
    }
    guard CFGetTypeID(value) == AXValueGetTypeID() else {
        return nil
    }
    return (value as! AXValue)
}

private func copyAXFrame(of element: AXUIElement) -> CGRect? {
    guard
        let positionValue = copyAXValueAttribute(of: element, name: kAXPositionAttribute),
        let sizeValue = copyAXValueAttribute(of: element, name: kAXSizeAttribute)
    else {
        return nil
    }
    var position = CGPoint.zero
    var size = CGSize.zero
    guard
        AXValueGetValue(positionValue, .cgPoint, &position),
        AXValueGetValue(sizeValue, .cgSize, &size)
    else {
        return nil
    }
    return CGRect(origin: position, size: size)
}

private func settingsObject(_ settings: HIDOverlaySettings) -> [String: Any] {
    [
        "clearDelaySeconds": settings.clearDelaySeconds,
        "windowFrame": settings.showWindowFrame,
        "diagnostic": settings.showDiagnostic,
        "trail": settings.showTrail,
        "trailPoints": settings.showTrailPoints,
        "expectedPoint": settings.showExpectedPoint,
        "actualPoint": settings.showActualPoint,
        "clickEffects": settings.showClickEffects,
        "dragEffects": settings.showDragEffects,
        "scrollEffects": settings.showScrollEffects,
        "keyboardEffects": settings.showKeyboardEffects,
        "status": settings.showStatus,
        "persistent": settings.persistent
    ]
}

private func applySettingsObject(_ object: [String: Any], settings: inout HIDOverlaySettings) {
    for (key, rawValue) in object {
        guard let value = boolValue(rawValue) else {
            continue
        }
        applyComponents([key], visible: value, settings: &settings)
    }
}

private func componentList(_ value: Any?) -> [String]? {
    if let string = value as? String {
        return string.split(separator: ",").map(String.init)
    }
    if let strings = value as? [String] {
        return strings
    }
    return nil
}

private func boolValue(_ value: Any?) -> Bool? {
    if let bool = value as? Bool {
        return bool
    }
    if let int = value as? Int {
        return int != 0
    }
    if let string = value as? String {
        switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
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

private func applyComponents(_ components: [String], visible: Bool, settings: inout HIDOverlaySettings) {
    for rawComponent in components {
        let component = rawComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        guard !component.isEmpty else {
            continue
        }
        switch component {
        case "all":
            settings.showWindowFrame = visible
            settings.showDiagnostic = visible
            settings.showTrail = visible
            settings.showTrailPoints = visible
            settings.showExpectedPoint = visible
            settings.showActualPoint = visible
            settings.showClickEffects = visible
            settings.showDragEffects = visible
            settings.showScrollEffects = visible
            settings.showKeyboardEffects = visible
            settings.showStatus = visible
            settings.persistent = visible
        case "window", "window-frame", "frame", "target-window", "windowframe":
            settings.showWindowFrame = visible
        case "diagnostic", "hud-active":
            settings.showDiagnostic = visible
        case "trail", "trajectory", "path":
            settings.showTrail = visible
        case "trail-points", "trajectory-points", "points", "path-points", "trailpoints":
            settings.showTrailPoints = visible
        case "expected", "expected-point", "target", "target-point", "expectedpoint":
            settings.showExpectedPoint = visible
        case "actual", "actual-point", "final", "final-point", "landing", "landing-point", "actualpoint":
            settings.showActualPoint = visible
        case "click", "clicks", "click-effects", "mouse-click", "clickeffects":
            settings.showClickEffects = visible
        case "drag", "drags", "drag-effects", "drageffects":
            settings.showDragEffects = visible
        case "scroll", "scrolls", "scroll-effects", "wheel", "scrolleffects":
            settings.showScrollEffects = visible
        case "keyboard", "key", "keys", "type", "typing", "paste", "paste-text", "keyboard-effects", "keyboardeffects":
            settings.showKeyboardEffects = visible
        case "status", "status-text":
            settings.showStatus = visible
        case "persistent", "persistent-hud", "hud-persistent", "always-on", "resident":
            settings.persistent = visible
        case "mouse-effects", "events", "event-effects":
            settings.showClickEffects = visible
            settings.showDragEffects = visible
            settings.showScrollEffects = visible
            settings.showKeyboardEffects = visible
        default:
            continue
        }
    }
}

struct HIDOverlayFrame {
    let context: HIDActionVisualContext
    let events: [InjectedEvent]
    let expected: CodablePoint?
    let actual: CodablePoint?
    let errorCode: String?
    let stepTitle: String?
    let stepDetail: String?
}

struct HIDOverlayViewSnapshot: Equatable {
    let currentEventCount: Int?
    let currentTrailPoints: [CodablePoint]
    let historyEventCounts: [Int]
    let historyTrailPoints: [[CodablePoint]]
}

func hidOverlayTrailPoints(events: [InjectedEvent], actual: CodablePoint?) -> [CodablePoint] {
    var points = events.compactMap(\.location)
    guard let actual else {
        return points
    }
    if let last = points.last, hidOverlayApproximatelyEqual(last, actual) {
        return points
    }
    points.append(actual)
    return points
}

private func hidOverlayIsCompletedHistoryFrame(_ frame: HIDOverlayFrame) -> Bool {
    frame.actual != nil
        && frame.events.count > 1
        && hidOverlayTrailPoints(events: frame.events, actual: frame.actual).count >= 2
}

private func hidOverlayApproximatelyEqual(_ lhs: CodablePoint, _ rhs: CodablePoint, tolerance: Double = 0.5) -> Bool {
    abs(lhs.x - rhs.x) <= tolerance && abs(lhs.y - rhs.y) <= tolerance
}

private struct HIDPlaybackStep {
    let title: String
    let detail: String
}

final class HIDOverlayView: NSView {
    private let maxHistoricalFrames = 20
    private var screenFrame: NSRect
    private var settings: HIDOverlaySettings
    private var frameData: HIDOverlayFrame?
    private var lastPersistentFrame: HIDOverlayFrame?
    private var historicalFrames = [HIDOverlayFrame]()

    init(frame: NSRect, screenFrame: NSRect, settings: HIDOverlaySettings) {
        self.screenFrame = screenFrame
        self.settings = settings
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(_ data: HIDOverlayFrame) {
        frameData = data
        if settings.persistent, hidOverlayIsCompletedHistoryFrame(data) {
            lastPersistentFrame = data
            recordHistoricalFrame(data)
        } else if !settings.persistent || !data.context.dryRun || lastPersistentFrame == nil {
            lastPersistentFrame = data
        }
        needsDisplay = true
        displayIfNeeded()
    }

    func snapshotForTesting() -> HIDOverlayViewSnapshot {
        HIDOverlayViewSnapshot(
            currentEventCount: frameData?.events.count,
            currentTrailPoints: frameData.map { hidOverlayTrailPoints(events: $0.events, actual: $0.actual) } ?? [],
            historyEventCounts: historicalFrames.map(\.events.count),
            historyTrailPoints: historicalFrames.map { hidOverlayTrailPoints(events: $0.events, actual: $0.actual) }
        )
    }

    func resize(frame: NSRect, screenFrame: NSRect) {
        self.frame = frame
        self.screenFrame = screenFrame
        needsDisplay = true
        displayIfNeeded()
    }

    func updateSettings(_ settings: HIDOverlaySettings) {
        self.settings = settings
        if !settings.persistent, let frameData, frameData.events.isEmpty {
            self.frameData = nil
        }
        needsDisplay = true
        displayIfNeeded()
    }

    func updateWindowFrame(_ windowFrame: CodableRect) {
        if let frameData {
            self.frameData = HIDOverlayFrame(
                context: replacingWindowFrame(in: frameData.context, with: windowFrame),
                events: frameData.events,
                expected: frameData.expected,
                actual: frameData.actual,
                errorCode: frameData.errorCode,
                stepTitle: frameData.stepTitle,
                stepDetail: frameData.stepDetail
            )
        }
        if let lastPersistentFrame {
            self.lastPersistentFrame = HIDOverlayFrame(
                context: replacingWindowFrame(in: lastPersistentFrame.context, with: windowFrame),
                events: lastPersistentFrame.events,
                expected: lastPersistentFrame.expected,
                actual: lastPersistentFrame.actual,
                errorCode: lastPersistentFrame.errorCode,
                stepTitle: lastPersistentFrame.stepTitle,
                stepDetail: lastPersistentFrame.stepDetail
            )
        }
        historicalFrames = historicalFrames.map { frame in
            HIDOverlayFrame(
                context: replacingWindowFrame(in: frame.context, with: windowFrame),
                events: frame.events,
                expected: frame.expected,
                actual: frame.actual,
                errorCode: frame.errorCode,
                stepTitle: frame.stepTitle,
                stepDetail: frame.stepDetail
            )
        }
        needsDisplay = true
        displayIfNeeded()
    }

    func markFailure(errorCode: String) {
        guard let frameData else {
            return
        }
        self.frameData = HIDOverlayFrame(
            context: frameData.context,
            events: frameData.events,
            expected: frameData.expected,
            actual: frameData.actual,
            errorCode: errorCode,
            stepTitle: frameData.stepTitle,
            stepDetail: frameData.stepDetail
        )
        needsDisplay = true
        displayIfNeeded()
    }

    func clearTransientState() {
        if settings.persistent, let lastPersistentFrame {
            frameData = lastPersistentFrame
        } else {
            frameData = nil
        }
        needsDisplay = true
        displayIfNeeded()
    }

    func clearAll() {
        frameData = nil
        lastPersistentFrame = nil
        historicalFrames.removeAll()
        needsDisplay = true
        displayIfNeeded()
    }

    private func recordHistoricalFrame(_ frame: HIDOverlayFrame) {
        historicalFrames.removeAll { $0.context.actionId == frame.context.actionId }
        historicalFrames.append(frame)
        if historicalFrames.count > maxHistoricalFrames {
            historicalFrames.removeFirst(historicalFrames.count - maxHistoricalFrames)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard frameData != nil || !historicalFrames.isEmpty else {
            return
        }
        NSGraphicsContext.current?.shouldAntialias = true
        if let frameData, settings.showDiagnostic {
            drawDiagnostic(frameData)
        }
        if let frameData, settings.showWindowFrame {
            drawWindowFrame(frameData.context.windowFrame)
        }
        drawHistoricalFrames(excluding: frameData?.context.actionId)
        guard let frameData else {
            return
        }
        if settings.showTrail {
            drawTrail(frameData.events, actual: frameData.actual, final: frameData.actual != nil)
        }
        drawEffects(frameData.events, context: frameData.context)
        if settings.showExpectedPoint, let expected = frameData.expected {
            drawExpectedReticle(point: expected)
        }
        if settings.showActualPoint, let actual = frameData.actual {
            drawActualCrosshair(point: actual)
        }
        if settings.showStatus {
            if let errorCode = frameData.errorCode {
                drawStatus(text: "HID \(frameData.context.actionId) failed: \(errorCode)", color: .systemRed)
            } else {
                drawStatus(text: statusText(frameData.context), color: .controlAccentColor)
            }
            if let stepTitle = frameData.stepTitle {
                drawStepPanel(title: stepTitle, detail: frameData.stepDetail)
            }
        }
    }

    private func drawWindowFrame(_ rect: CodableRect) {
        let path = NSBezierPath(rect: convert(rect))
        NSColor.black.withAlphaComponent(0.58).setStroke()
        path.lineWidth = 8
        path.stroke()
        NSColor(calibratedRed: 1.0, green: 0.68, blue: 0.0, alpha: 0.94).setStroke()
        path.lineWidth = 4
        let dashPattern: [CGFloat] = [8, 5]
        dashPattern.withUnsafeBufferPointer { buffer in
            path.setLineDash(buffer.baseAddress, count: buffer.count, phase: 0)
        }
        path.stroke()
    }

    private func drawDiagnostic(_ frameData: HIDOverlayFrame) {
        let eventCount = frameData.events.count
        let title = frameData.context.windowTitle ?? frameData.context.bundleIdentifier
        drawLabel(
            "HUD ACTIVE events=\(eventCount) target=\(title)",
            at: NSPoint(x: bounds.minX + 24, y: bounds.maxY - 34),
            color: .systemYellow
        )
    }

    private func drawTrail(_ events: [InjectedEvent], actual: CodablePoint?, final: Bool) {
        let points = hidOverlayTrailPoints(events: events, actual: final ? actual : nil).map(convert(_:))
        guard points.count >= 2 else {
            return
        }
        let path = NSBezierPath()
        path.move(to: points[0])
        for point in points.dropFirst() {
            path.line(to: point)
        }
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor(calibratedRed: 0.0, green: 0.82, blue: 1.0, alpha: 0.58).setStroke()
        path.lineWidth = 1.1
        path.stroke()
        if settings.showTrailPoints {
            for point in points {
                NSColor.white.withAlphaComponent(0.46).setFill()
                NSBezierPath(ovalIn: NSRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)).fill()
            }
        }
        drawTrailEndpointMarker(at: points[0], title: "起点", color: .systemTeal)
        if let end = points.last {
            drawTrailEndpointMarker(at: end, title: final ? "终点" : "当前", color: .white)
        }
    }

    private func drawHistoricalFrames(excluding currentActionId: String?) {
        guard settings.persistent, settings.showTrail, !historicalFrames.isEmpty else {
            return
        }
        for (index, frame) in historicalFrames.enumerated() where currentActionId == nil || frame.context.actionId != currentActionId {
            drawHistoricalTrail(frame.events, actual: frame.actual, ordinal: index + 1)
            if settings.showExpectedPoint, let expected = frame.expected {
                drawHistoricalPoint(expected, title: "目标\(index + 1)", color: .systemOrange)
            }
            if settings.showActualPoint, let actual = frame.actual {
                drawHistoricalPoint(actual, title: "实际\(index + 1)", color: .systemRed)
            }
        }
    }

    private func drawHistoricalTrail(_ events: [InjectedEvent], actual: CodablePoint?, ordinal: Int) {
        let points = hidOverlayTrailPoints(events: events, actual: actual).map(convert(_:))
        guard points.count >= 2 else {
            return
        }
        let path = NSBezierPath()
        path.move(to: points[0])
        for point in points.dropFirst() {
            path.line(to: point)
        }
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor(calibratedRed: 0.15, green: 0.56, blue: 1.0, alpha: 0.24).setStroke()
        path.lineWidth = 0.8
        path.stroke()
        drawTrailEndpointMarker(at: points[0], title: "起\(ordinal)", color: .systemTeal.withAlphaComponent(0.72))
        if let end = points.last {
            drawTrailEndpointMarker(at: end, title: "终\(ordinal)", color: .white.withAlphaComponent(0.72))
        }
    }

    private func drawHistoricalPoint(_ point: CodablePoint, title: String, color: NSColor) {
        let converted = convert(point)
        color.withAlphaComponent(0.58).setStroke()
        let marker = NSBezierPath(ovalIn: NSRect(x: converted.x - 6, y: converted.y - 6, width: 12, height: 12))
        marker.lineWidth = 0.8
        marker.stroke()
        drawSmallLabel(title, at: NSPoint(x: converted.x + 8, y: converted.y + 3), color: color.withAlphaComponent(0.82))
    }

    private func drawEffects(_ events: [InjectedEvent], context: HIDActionVisualContext) {
        let locationEvents = events.filter { $0.location != nil }
        for event in locationEvents.suffix(12) {
            guard let location = event.location else {
                continue
            }
            let point = convert(location)
            if settings.showClickEffects, event.type.contains("MouseDown") {
                drawRing(at: point, color: .systemOrange, radius: 14, lineWidth: 3)
                drawSmallLabel("下压", at: NSPoint(x: point.x + 12, y: point.y + 8), color: .systemOrange)
            } else if settings.showClickEffects, event.type.contains("MouseUp") {
                drawRing(at: point, color: .systemCyan, radius: 19, lineWidth: 2)
                drawSmallLabel("松开", at: NSPoint(x: point.x + 12, y: point.y - 18), color: .systemCyan)
            } else if settings.showDragEffects, event.type.contains("Dragged") {
                drawRing(at: point, color: .systemPink, radius: 7, lineWidth: 2)
            } else if settings.showScrollEffects, event.type == "scrollWheel" {
                drawScrollGlyph(at: point)
            }
        }
        if settings.showClickEffects {
            drawClickCountBadges(events)
        }
        if settings.showKeyboardEffects,
           context.actionTypes.contains("type") || context.actionTypes.contains("pasteText") || context.actionTypes.contains("key") {
            if let location = locationEvents.last?.location {
                drawTypePulse(at: convert(location), eventCount: keyEventCount(events))
            } else {
                drawTypeBadge(eventCount: keyEventCount(events))
            }
        }
    }

    private func drawExpectedReticle(point: CodablePoint) {
        let converted = convert(point)
        let radius: CGFloat = 9
        let tickGap: CGFloat = 4
        let tickLength: CGFloat = 6

        let ring = NSBezierPath(ovalIn: NSRect(
            x: converted.x - radius,
            y: converted.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        ring.lineWidth = 1.15
        NSColor(calibratedRed: 1.0, green: 0.64, blue: 0.05, alpha: 0.88).setStroke()
        ring.stroke()

        let ticks = NSBezierPath()
        ticks.move(to: NSPoint(x: converted.x - radius - tickGap - tickLength, y: converted.y))
        ticks.line(to: NSPoint(x: converted.x - radius - tickGap, y: converted.y))
        ticks.move(to: NSPoint(x: converted.x + radius + tickGap, y: converted.y))
        ticks.line(to: NSPoint(x: converted.x + radius + tickGap + tickLength, y: converted.y))
        ticks.move(to: NSPoint(x: converted.x, y: converted.y - radius - tickGap - tickLength))
        ticks.line(to: NSPoint(x: converted.x, y: converted.y - radius - tickGap))
        ticks.move(to: NSPoint(x: converted.x, y: converted.y + radius + tickGap))
        ticks.line(to: NSPoint(x: converted.x, y: converted.y + radius + tickGap + tickLength))
        ticks.lineWidth = 1.0
        ticks.stroke()
        drawSmallLabel("目标", at: NSPoint(x: converted.x + 12, y: converted.y + 10), color: .systemOrange)
    }

    private func drawActualCrosshair(point: CodablePoint) {
        let converted = convert(point)
        let radius: CGFloat = 9
        let innerGap: CGFloat = 2.5
        let outerRadius: CGFloat = 12

        let scope = NSBezierPath(ovalIn: NSRect(
            x: converted.x - outerRadius,
            y: converted.y - outerRadius,
            width: outerRadius * 2,
            height: outerRadius * 2
        ))
        scope.lineWidth = 0.75
        NSColor(calibratedRed: 1.0, green: 0.22, blue: 0.18, alpha: 0.32).setStroke()
        scope.stroke()

        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: converted.x - radius, y: converted.y - radius))
        cross.line(to: NSPoint(x: converted.x - innerGap, y: converted.y - innerGap))
        cross.move(to: NSPoint(x: converted.x + innerGap, y: converted.y + innerGap))
        cross.line(to: NSPoint(x: converted.x + radius, y: converted.y + radius))
        cross.move(to: NSPoint(x: converted.x - radius, y: converted.y + radius))
        cross.line(to: NSPoint(x: converted.x - innerGap, y: converted.y + innerGap))
        cross.move(to: NSPoint(x: converted.x + innerGap, y: converted.y - innerGap))
        cross.line(to: NSPoint(x: converted.x + radius, y: converted.y - radius))
        cross.lineWidth = 1.35
        NSColor(calibratedRed: 1.0, green: 0.22, blue: 0.18, alpha: 0.9).setStroke()
        cross.stroke()
        drawSmallLabel("实际", at: NSPoint(x: converted.x + 13, y: converted.y - 2), color: .systemRed)
    }

    private func drawTrailEndpointMarker(at point: NSPoint, title: String, color: NSColor) {
        color.withAlphaComponent(0.9).setStroke()
        let marker = NSBezierPath(ovalIn: NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
        marker.lineWidth = 1.2
        marker.stroke()
        drawSmallLabel(title, at: NSPoint(x: point.x + 8, y: point.y + 5), color: color)
    }

    private func drawRing(at point: NSPoint, color: NSColor, radius: CGFloat, lineWidth: CGFloat) {
        let rect = NSRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        color.withAlphaComponent(0.82).setStroke()
        let path = NSBezierPath(ovalIn: rect)
        path.lineWidth = lineWidth
        path.stroke()
    }

    private func drawScrollGlyph(at point: NSPoint) {
        NSColor.systemPurple.withAlphaComponent(0.85).setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: point.x, y: point.y - 18))
        path.line(to: NSPoint(x: point.x, y: point.y + 18))
        path.move(to: NSPoint(x: point.x - 7, y: point.y + 9))
        path.line(to: NSPoint(x: point.x, y: point.y + 18))
        path.line(to: NSPoint(x: point.x + 7, y: point.y + 9))
        path.lineWidth = 3
        path.stroke()
    }

    private func drawTypePulse(at point: NSPoint, eventCount: Int) {
        let rect = NSRect(x: point.x - 18, y: point.y - 13, width: 36, height: 26)
        NSColor.systemYellow.withAlphaComponent(0.75).setStroke()
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        path.lineWidth = 2
        path.stroke()
        drawLabel(typeLabel(eventCount: eventCount), at: NSPoint(x: point.x + 22, y: point.y + 6), color: .systemYellow)
    }

    private func drawTypeBadge(eventCount: Int) {
        drawLabel(typeLabel(eventCount: eventCount), at: statusOrigin(offsetY: 18), color: .systemYellow)
    }

    private func drawStatus(text: String, color: NSColor) {
        drawLabel(text, at: statusOrigin(), color: color)
    }

    private func drawStepPanel(title: String, detail: String?) {
        let origin = statusOrigin(offsetY: 28)
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.systemYellow
        ]
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9)
        ]
        let titleSize = (title as NSString).size(withAttributes: titleAttributes)
        let detailText = detail ?? ""
        let detailSize = (detailText as NSString).size(withAttributes: detailAttributes)
        let width = max(titleSize.width, detailSize.width) + 16
        let height = titleSize.height + (detailText.isEmpty ? 0 : detailSize.height + 4) + 12
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: NSRect(x: origin.x - 6, y: origin.y - 6, width: width, height: height), xRadius: 7, yRadius: 7).fill()
        (title as NSString).draw(at: origin, withAttributes: titleAttributes)
        if !detailText.isEmpty {
            (detailText as NSString).draw(
                at: NSPoint(x: origin.x, y: origin.y + titleSize.height + 2),
                withAttributes: detailAttributes
            )
        }
    }

    private func drawLabel(_ text: String, at point: NSPoint, color: NSColor) {
        let size = (text as NSString).size(withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .heavy)
        ])
        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: NSRect(x: point.x - 6, y: point.y - 5, width: size.width + 12, height: size.height + 8), xRadius: 5, yRadius: 5).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .heavy),
            .foregroundColor: color
        ]
        (text as NSString).draw(at: point, withAttributes: attributes)
    }

    private func drawSmallLabel(_ text: String, at point: NSPoint, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: color
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: NSRect(x: point.x - 4, y: point.y - 3, width: size.width + 8, height: size.height + 6), xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(at: point, withAttributes: attributes)
    }

    private func statusText(_ context: HIDActionVisualContext) -> String {
        let mode = context.dryRun ? "dry-run" : context.postMode
        if context.dryRun && settings.persistent {
            return "HID \(mode) \(demoActionTitle(for: context)) retained"
        }
        return "HID \(mode) \(context.actionTypes.joined(separator: "+")) \(context.bundleIdentifier)"
    }

    private func demoActionTitle(for context: HIDActionVisualContext) -> String {
        let actionId = context.actionId.lowercased()
        let types = Set(context.actionTypes.map { $0.lowercased() })
        if actionId.contains("dblclick") {
            return "双击演示"
        }
        if types.contains("drag") {
            return "拖拽演示"
        }
        if types.contains("scroll") {
            return "滚轮演示"
        }
        if types.contains("type") || types.contains("key") || types.contains("pastetext") {
            return "键盘事件演示"
        }
        if types.contains("move"), !types.contains("click") {
            return "移动轨迹演示"
        }
        if types.contains("click") {
            return "完整点击演示"
        }
        return context.actionTypes.joined(separator: "+")
    }

    private func drawClickCountBadges(_ events: [InjectedEvent]) {
        let clicks = clickClusters(events)
        for click in clicks where click.count > 1 {
            let point = convert(click.location)
            drawLabel("x\(click.count)", at: NSPoint(x: point.x + 18, y: point.y + 18), color: .systemOrange)
        }
    }

    private func clickClusters(_ events: [InjectedEvent]) -> [(location: CodablePoint, count: Int)] {
        var clusters = [(location: CodablePoint, count: Int)]()
        for event in events where event.type.contains("MouseDown") {
            guard let location = event.location else {
                continue
            }
            if let last = clusters.last,
               hypot(last.location.x - location.x, last.location.y - location.y) <= 2 {
                clusters[clusters.count - 1] = (last.location, last.count + 1)
            } else {
                clusters.append((location, 1))
            }
        }
        return clusters
    }

    private func keyEventCount(_ events: [InjectedEvent]) -> Int {
        events.filter { $0.type == "keyDown" || $0.type == "keyUp" }.count
    }

    private func typeLabel(eventCount: Int) -> String {
        eventCount > 0 ? "type \(eventCount)e" : "type"
    }

    private func statusOrigin(offsetY: CGFloat = 0) -> NSPoint {
        NSPoint(x: max(18, bounds.minX + 18), y: max(18, bounds.minY + 18 + offsetY))
    }

    private func convert(_ point: CodablePoint) -> NSPoint {
        NSPoint(
            x: point.x - screenFrame.minX,
            y: primaryScreenTopY() - point.y - screenFrame.minY
        )
    }

    private func convert(_ rect: CodableRect) -> NSRect {
        NSRect(
            x: rect.x - screenFrame.minX,
            y: primaryScreenTopY() - rect.y - rect.height - screenFrame.minY,
            width: rect.width,
            height: rect.height
        )
    }
}

private func primaryScreenTopY() -> CGFloat {
    if let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) {
        return primary.frame.maxY
    }
    return NSScreen.screens.first?.frame.maxY ?? 0
}
