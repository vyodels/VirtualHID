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
    private var clearToken = 0

    public init(settings: HIDOverlaySettings = HIDOverlaySettings(), enabled: Bool = true, lockedOff: Bool = false) {
        self.settings = settings
        self.enabled = enabled && !lockedOff
        self.lockedOff = lockedOff
    }

    public convenience init(clearDelaySeconds: TimeInterval) {
        self.init(settings: HIDOverlaySettings(clearDelaySeconds: clearDelaySeconds))
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
                self?.overlayView?.clearAll()
                self?.overlayWindow?.orderOut(nil)
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
                HIDOverlayFrame(context: context, events: [], expected: nil, actual: nil, errorCode: nil)
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
        DispatchQueue.main.async { [weak self] in
            self?.ensureOverlay(for: context)
            self?.overlayView?.render(
                HIDOverlayFrame(context: context, events: events, expected: nil, actual: nil, errorCode: nil)
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
            self?.ensureOverlay(for: summary.context)
            self?.overlayView?.render(
                HIDOverlayFrame(
                    context: summary.context,
                    events: summary.events,
                    expected: summary.verification.expectedPointer,
                    actual: summary.verification.finalPointer,
                    errorCode: nil
                )
            )
            self?.scheduleClear()
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

    private func ensureOverlay(for context: HIDActionVisualContext) {
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

private struct HIDOverlayFrame {
    let context: HIDActionVisualContext
    let events: [InjectedEvent]
    let expected: CodablePoint?
    let actual: CodablePoint?
    let errorCode: String?
}

private final class HIDOverlayView: NSView {
    private var screenFrame: NSRect
    private var settings: HIDOverlaySettings
    private var frameData: HIDOverlayFrame?
    private var lastPersistentFrame: HIDOverlayFrame?

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
        lastPersistentFrame = data
        needsDisplay = true
        displayIfNeeded()
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

    func markFailure(errorCode: String) {
        guard let frameData else {
            return
        }
        self.frameData = HIDOverlayFrame(
            context: frameData.context,
            events: frameData.events,
            expected: frameData.expected,
            actual: frameData.actual,
            errorCode: errorCode
        )
        needsDisplay = true
        displayIfNeeded()
    }

    func clearTransientState() {
        if settings.persistent, let lastPersistentFrame {
            frameData = HIDOverlayFrame(
                context: lastPersistentFrame.context,
                events: [],
                expected: lastPersistentFrame.expected,
                actual: lastPersistentFrame.actual,
                errorCode: lastPersistentFrame.errorCode
            )
        } else {
            frameData = nil
        }
        needsDisplay = true
        displayIfNeeded()
    }

    func clearAll() {
        frameData = nil
        lastPersistentFrame = nil
        needsDisplay = true
        displayIfNeeded()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let frameData else {
            return
        }
        NSGraphicsContext.current?.shouldAntialias = true
        if settings.showDiagnostic {
            drawDiagnostic(frameData)
        }
        if settings.showWindowFrame {
            drawWindowFrame(frameData.context.windowFrame)
        }
        if settings.showTrail {
            drawTrail(frameData.events)
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

    private func drawTrail(_ events: [InjectedEvent]) {
        let points = events.compactMap(\.location).map(convert(_:))
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
        NSColor(calibratedRed: 0.0, green: 0.88, blue: 1.0, alpha: 0.54).setStroke()
        path.lineWidth = 1.25
        path.stroke()
        if settings.showTrailPoints {
            for point in points {
                NSColor.white.withAlphaComponent(0.46).setFill()
                NSBezierPath(ovalIn: NSRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)).fill()
            }
        }
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
            } else if settings.showClickEffects, event.type.contains("MouseUp") {
                drawRing(at: point, color: .systemCyan, radius: 19, lineWidth: 2)
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
        let radius: CGFloat = 7
        let tickGap: CGFloat = 3
        let tickLength: CGFloat = 5

        let ring = NSBezierPath(ovalIn: NSRect(
            x: converted.x - radius,
            y: converted.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        ring.lineWidth = 1.25
        NSColor.systemOrange.withAlphaComponent(0.82).setStroke()
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
    }

    private func drawActualCrosshair(point: CodablePoint) {
        let converted = convert(point)
        let radius: CGFloat = 8
        let innerGap: CGFloat = 2
        let outerRadius: CGFloat = 11

        let scope = NSBezierPath(ovalIn: NSRect(
            x: converted.x - outerRadius,
            y: converted.y - outerRadius,
            width: outerRadius * 2,
            height: outerRadius * 2
        ))
        scope.lineWidth = 0.75
        NSColor.systemRed.withAlphaComponent(0.36).setStroke()
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
        cross.lineWidth = 1.25
        NSColor.systemRed.withAlphaComponent(0.82).setStroke()
        cross.stroke()
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

    private func statusText(_ context: HIDActionVisualContext) -> String {
        let mode = context.dryRun ? "dry-run" : context.postMode
        return "HID \(mode) \(context.actionTypes.joined(separator: "+")) \(context.bundleIdentifier)"
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
