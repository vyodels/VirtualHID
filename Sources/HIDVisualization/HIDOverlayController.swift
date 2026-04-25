import AppKit
import Foundation
import InjectorCore

public final class HIDOverlayController: HIDEventSink {
    private let queue = DispatchQueue(label: "com.vyodels.virtualhid.hud.state")
    private var eventsByAction = [String: [InjectedEvent]]()
    private var overlayWindow: NSPanel?
    private var overlayView: HIDOverlayView?
    private var clearToken = 0

    public init() {}

    public func hidActionDidStart(_ context: HIDActionVisualContext) {
        guard accepts(context) else {
            return
        }
        queue.sync {
            eventsByAction[context.actionId] = []
        }
        DispatchQueue.main.async { [weak self] in
            self?.ensureOverlay()
            self?.overlayView?.render(
                HIDOverlayFrame(context: context, events: [], expected: nil, actual: nil, errorCode: nil)
            )
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
            self?.ensureOverlay()
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
            self?.ensureOverlay()
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

    private func ensureOverlay() {
        if overlayWindow != nil {
            return
        }
        let frame = NSScreen.screens.map(\.frame).reduce(NSScreen.main?.frame ?? .zero) { $0.union($1) }
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let view = HIDOverlayView(frame: NSRect(origin: .zero, size: frame.size), screenFrame: frame)
        panel.contentView = view
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.orderFrontRegardless()
        overlayWindow = panel
        overlayView = view
    }

    private func scheduleClear() {
        clearToken += 1
        let token = clearToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            guard self?.clearToken == token else {
                return
            }
            self?.overlayView?.clear()
        }
    }

    private func accepts(_ context: HIDActionVisualContext) -> Bool {
        context.source == "hid"
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
    private let screenFrame: NSRect
    private var frameData: HIDOverlayFrame?

    init(frame: NSRect, screenFrame: NSRect) {
        self.screenFrame = screenFrame
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
        needsDisplay = true
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
    }

    func clear() {
        frameData = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let frameData else {
            return
        }
        NSGraphicsContext.current?.shouldAntialias = true
        drawWindowFrame(frameData.context.windowFrame)
        drawTrail(frameData.events)
        drawEffects(frameData.events, context: frameData.context)
        if let expected = frameData.expected {
            drawMarker(point: expected, color: .systemOrange, label: "expected", radius: 9)
        }
        if let actual = frameData.actual {
            drawMarker(point: actual, color: .systemCyan, label: "actual", radius: 6)
        }
        if let errorCode = frameData.errorCode {
            drawStatus(text: "HID \(frameData.context.actionId) failed: \(errorCode)", color: .systemRed)
        } else {
            drawStatus(text: statusText(frameData.context), color: .controlAccentColor)
        }
    }

    private func drawWindowFrame(_ rect: CodableRect) {
        let path = NSBezierPath(rect: convert(rect))
        NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.18, alpha: 0.32).setStroke()
        path.lineWidth = 2
        let dashPattern: [CGFloat] = [8, 5]
        dashPattern.withUnsafeBufferPointer { buffer in
            path.setLineDash(buffer.baseAddress, count: buffer.count, phase: 0)
        }
        path.stroke()
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
        NSColor(calibratedRed: 0.1, green: 0.72, blue: 0.95, alpha: 0.76).setStroke()
        path.lineWidth = 3
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private func drawEffects(_ events: [InjectedEvent], context: HIDActionVisualContext) {
        let locationEvents = events.filter { $0.location != nil }
        for event in locationEvents.suffix(12) {
            guard let location = event.location else {
                continue
            }
            let point = convert(location)
            if event.type.contains("MouseDown") {
                drawRing(at: point, color: .systemOrange, radius: 14, lineWidth: 3)
            } else if event.type.contains("MouseUp") {
                drawRing(at: point, color: .systemCyan, radius: 19, lineWidth: 2)
            } else if event.type.contains("Dragged") {
                drawRing(at: point, color: .systemPink, radius: 7, lineWidth: 2)
            } else if event.type == "scrollWheel" {
                drawScrollGlyph(at: point)
            }
        }
        drawClickCountBadges(events)
        if context.actionTypes.contains("type") || context.actionTypes.contains("key") {
            if let location = locationEvents.last?.location {
                drawTypePulse(at: convert(location), eventCount: keyEventCount(events))
            } else {
                drawTypeBadge(eventCount: keyEventCount(events))
            }
        }
    }

    private func drawMarker(point: CodablePoint, color: NSColor, label: String, radius: CGFloat) {
        let converted = convert(point)
        color.withAlphaComponent(0.9).setStroke()
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: converted.x - radius, y: converted.y))
        cross.line(to: NSPoint(x: converted.x + radius, y: converted.y))
        cross.move(to: NSPoint(x: converted.x, y: converted.y - radius))
        cross.line(to: NSPoint(x: converted.x, y: converted.y + radius))
        cross.lineWidth = 2
        cross.stroke()
        drawLabel(label, at: NSPoint(x: converted.x + radius + 4, y: converted.y + radius + 4), color: color)
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
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
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
        NSPoint(x: point.x - screenFrame.minX, y: screenFrame.maxY - point.y)
    }

    private func convert(_ rect: CodableRect) -> NSRect {
        NSRect(
            x: rect.x - screenFrame.minX,
            y: screenFrame.maxY - rect.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
}
