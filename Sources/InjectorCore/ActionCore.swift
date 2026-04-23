import AppKit
import CoreGraphics
import Foundation
import HumanizationKit

public enum MouseButton: String {
    case left
    case right
    case middle

    var cgButton: CGMouseButton {
        switch self {
        case .left:
            return .left
        case .right:
            return .right
        case .middle:
            return .center
        }
    }

    var downEventType: CGEventType {
        switch self {
        case .left:
            return .leftMouseDown
        case .right:
            return .rightMouseDown
        case .middle:
            return .otherMouseDown
        }
    }

    var upEventType: CGEventType {
        switch self {
        case .left:
            return .leftMouseUp
        case .right:
            return .rightMouseUp
        case .middle:
            return .otherMouseUp
        }
    }
}

public enum ScrollStyle: String {
    case wheel
    case trackpad
}

public enum KeyboardLayout: String {
    case us
    case macABC = "mac-abc"
}

public struct TemplateReference: Hashable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

public enum TrajectoryStyle {
    case linear
    case bezier
    case wind
    case profile(TemplateReference)
}

public struct KeyChord {
    public let keyCode: CGKeyCode

    public init(keyCode: CGKeyCode) {
        self.keyCode = keyCode
    }
}

public enum ActionPrimitive {
    case move(to: CGPoint, via: TrajectoryStyle, durationMs: Int?)
    case click(at: CGPoint, button: MouseButton, holdMs: Int?, count: Int)
    case drag(from: CGPoint, to: CGPoint, button: MouseButton, via: TrajectoryStyle)
    case scroll(at: CGPoint, dx: Double, dy: Double, style: ScrollStyle)
    case type(text: String, layout: KeyboardLayout)
    case key(chord: KeyChord, holdMs: Int?)
}

public struct ActionContext: Codable {
    public struct Element: Codable {
        public let sig: String?
        public let role: String?

        public init(sig: String? = nil, role: String? = nil) {
            self.sig = sig
            self.role = role
        }
    }

    public struct Hints: Codable {
        public let urgency: String?

        public init(urgency: String? = nil) {
            self.urgency = urgency
        }
    }

    public let host: String
    public let url: String?
    public let element: Element?
    public let taskId: String?
    public let stage: String?
    public let hints: Hints?

    public init(host: String, url: String? = nil, element: Element? = nil, taskId: String? = nil, stage: String? = nil, hints: Hints? = nil) {
        self.host = host
        self.url = url
        self.element = element
        self.taskId = taskId
        self.stage = stage
        self.hints = hints
    }
}

public struct ActionOptions: Codable {
    public var postMode: PostMode?
    public var timeoutMs: Int?
    public var dryRun: Bool

    public init(postMode: PostMode? = nil, timeoutMs: Int? = nil, dryRun: Bool = false) {
        self.postMode = postMode
        self.timeoutMs = timeoutMs
        self.dryRun = dryRun
    }
}

public struct ActionRequest {
    public let id: String
    public let primitives: [ActionPrimitive]
    public let context: ActionContext
    public let options: ActionOptions

    public init(id: String, primitives: [ActionPrimitive], context: ActionContext, options: ActionOptions = ActionOptions()) {
        self.id = id
        self.primitives = primitives
        self.context = context
        self.options = options
    }
}

public struct ActionResult: Codable {
    public let id: String
    public let ok: Bool
    public let error: String?
    public let events: [InjectedEvent]
    public let elapsedMs: Int

    public init(id: String, ok: Bool, error: String?, events: [InjectedEvent], elapsedMs: Int) {
        self.id = id
        self.ok = ok
        self.error = error
        self.events = events
        self.elapsedMs = elapsedMs
    }
}

public enum ActionExecutionError: Error, LocalizedError {
    case busy
    case cancelled
    case eventCreationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .busy:
            return "执行器忙碌中"
        case .cancelled:
            return "执行已取消"
        case .eventCreationFailed(let detail):
            return "无法创建事件：\(detail)"
        }
    }
}

public final class ActionExecutor {
    private let target: BrowserTarget
    private let defaultPostMode: PostMode
    private let humanizationProfile: HumanizationProfile
    private let isoFormatter: ISO8601DateFormatter
    private let lock = NSLock()
    private var busy = false
    private var cancelled = false

    public init(
        target: BrowserTarget,
        defaultPostMode: PostMode = .global,
        humanizationProfile: HumanizationProfile = HumanizationProfile()
    ) {
        self.target = target
        self.defaultPostMode = defaultPostMode
        self.humanizationProfile = humanizationProfile
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoFormatter = formatter
    }

    public var isBusy: Bool {
        lock.withLock { busy }
    }

    public func cancel() {
        lock.withLock {
            cancelled = true
        }
    }

    public func execute(_ request: ActionRequest) throws -> ActionResult {
        try beginExecution()
        defer { endExecution() }

        let startedAt = Date()
        let requestedMode = request.options.postMode ?? defaultPostMode
        let dryRun = request.options.dryRun
        let poster = EventPoster(mode: requestedMode, targetPid: target.pid)
        var rng = SystemRandomNumberGenerator()
        var events = [InjectedEvent]()

        if requestedMode == .global, !dryRun {
            try poster.preflight(frontmost: FocusController.isFrontmost(app: target.app))
        } else if requestedMode == .pid {
            try ensurePidSafePrimitives(request.primitives)
        }

        for primitive in request.primitives {
            try checkCancelled()
            let emitted = try emit(primitive, poster: poster, dryRun: dryRun, rng: &rng)
            events.append(contentsOf: emitted)
        }

        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        return ActionResult(id: request.id, ok: true, error: nil, events: events, elapsedMs: elapsedMs)
    }

    private func beginExecution() throws {
        try lock.withLock {
            if busy {
                throw ActionExecutionError.busy
            }
            busy = true
            cancelled = false
        }
    }

    private func endExecution() {
        lock.withLock {
            busy = false
            cancelled = false
        }
    }

    private func checkCancelled() throws {
        if lock.withLock({ cancelled }) {
            throw ActionExecutionError.cancelled
        }
    }

    private func ensurePidSafePrimitives(_ primitives: [ActionPrimitive]) throws {
        for primitive in primitives {
            guard let unsupportedType = primitive.firstUnsupportedPidEventType else {
                continue
            }
            throw PosterError.postModeUnsupported(unsupportedType)
        }
    }

    private func emit(_ primitive: ActionPrimitive, poster: EventPoster, dryRun: Bool, rng: inout SystemRandomNumberGenerator) throws -> [InjectedEvent] {
        switch primitive {
        case .move(let to, let style, let durationMs):
            let path = trajectoryPath(
                from: currentMouseLocation(fallback: target.frame.center),
                to: to,
                style: style,
                pointCount: movePointCount(style: style, durationMs: durationMs),
                rng: &rng
            )
            let delayMs = perPointDelay(totalDurationMs: durationMs, pointCount: path.count)
            var emitted = [InjectedEvent]()
            for point in path {
                emitted.append(try postMouse(type: .mouseMoved, location: point, button: .left, poster: poster, dryRun: dryRun))
                if delayMs > 0 {
                    FocusController.sleep(milliseconds: delayMs)
                }
            }
            return emitted

        case .click(let at, let button, let holdMs, let count):
            var emitted = [InjectedEvent]()
            for _ in 0..<max(count, 1) {
                emitted.append(try postMouse(type: button.downEventType, location: at, button: button.cgButton, poster: poster, dryRun: dryRun))
                FocusController.sleep(milliseconds: holdMs ?? 45)
                emitted.append(try postMouse(type: button.upEventType, location: at, button: button.cgButton, poster: poster, dryRun: dryRun))
            }
            FocusController.sleep(milliseconds: 120)
            return emitted

        case .drag(let from, let to, let button, let style):
            let dragPath = trajectoryPath(
                from: from,
                to: to,
                style: style,
                pointCount: humanizationProfile.dragPointCount,
                rng: &rng
            )
            var emitted = [InjectedEvent]()
            emitted.append(try postMouse(type: .mouseMoved, location: from, button: button.cgButton, poster: poster, dryRun: dryRun))
            FocusController.sleep(milliseconds: 36)
            emitted.append(try postMouse(type: button.downEventType, location: from, button: button.cgButton, poster: poster, dryRun: dryRun))
            FocusController.sleep(milliseconds: 48)
            for point in dragPath {
                emitted.append(try postMouse(type: dragEventType(for: button), location: point, button: button.cgButton, poster: poster, dryRun: dryRun))
                FocusController.sleep(milliseconds: 28)
            }
            let releasePoint = dragPath.last ?? to
            emitted.append(try postMouse(type: button.upEventType, location: releasePoint, button: button.cgButton, poster: poster, dryRun: dryRun))
            FocusController.sleep(milliseconds: 120)
            return emitted

        case .scroll(let at, let dx, let dy, _):
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else {
                throw ActionExecutionError.eventCreationFailed("scroll")
            }
            event.location = at
            if !dryRun {
                _ = try poster.post(event, type: .scrollWheel, frontmost: FocusController.isFrontmost(app: target.app))
            }
            return [record(type: "scrollWheel", location: at)]

        case .type(let text, _):
            var emitted = [InjectedEvent]()
            let schedule = KeystrokeRhythm.schedule(for: text, params: humanizationProfile.keyRhythmParams, rng: &rng)
            for keyEvent in schedule {
                if keyEvent.delayBeforeMs > 0 {
                    FocusController.sleep(milliseconds: keyEvent.delayBeforeMs)
                }

                if keyEvent.modifiers.contains(.shift) {
                    emitted.append(try postKey(keyCode: 56, keyDown: true, recordedKey: nil, poster: poster, dryRun: dryRun))
                }

                let keyCode = CGKeyCode(keyEvent.keyCode)
                let recordedKey = String(keyEvent.char)
                emitted.append(try postKey(keyCode: keyCode, keyDown: true, recordedKey: recordedKey, poster: poster, dryRun: dryRun))
                FocusController.sleep(milliseconds: keyEvent.dwellMs)
                emitted.append(try postKey(keyCode: keyCode, keyDown: false, recordedKey: recordedKey, poster: poster, dryRun: dryRun))

                if keyEvent.modifiers.contains(.shift) {
                    emitted.append(try postKey(keyCode: 56, keyDown: false, recordedKey: nil, poster: poster, dryRun: dryRun))
                }
            }
            return emitted

        case .key(let chord, let holdMs):
            var emitted = [InjectedEvent]()
            emitted.append(try postKey(keyCode: chord.keyCode, keyDown: true, recordedKey: nil, poster: poster, dryRun: dryRun))
            FocusController.sleep(milliseconds: holdMs ?? 45)
            emitted.append(try postKey(keyCode: chord.keyCode, keyDown: false, recordedKey: nil, poster: poster, dryRun: dryRun))
            return emitted
        }
    }

    private func postMouse(type: CGEventType, location: CGPoint, button: CGMouseButton, poster: EventPoster, dryRun: Bool) throws -> InjectedEvent {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: button) else {
            throw ActionExecutionError.eventCreationFailed(eventTypeDescription(type))
        }
        if !dryRun {
            _ = try poster.post(event, type: type, frontmost: FocusController.isFrontmost(app: target.app))
        }
        return record(type: eventName(for: type), location: location)
    }

    private func postKey(keyCode: CGKeyCode, keyDown: Bool, recordedKey: String?, poster: EventPoster, dryRun: Bool) throws -> InjectedEvent {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown) else {
            throw ActionExecutionError.eventCreationFailed("keyCode=\(keyCode)")
        }
        if !dryRun {
            _ = try poster.post(event, type: keyDown ? .keyDown : .keyUp, frontmost: FocusController.isFrontmost(app: target.app))
        }
        return record(type: keyDown ? "keyDown" : "keyUp", key: recordedKey, virtualKey: keyCode)
    }

    private func record(type: String, location: CGPoint? = nil, key: String? = nil, virtualKey: CGKeyCode? = nil) -> InjectedEvent {
        InjectedEvent(
            type: type,
            location: location.map { CodablePoint(x: $0.x, y: $0.y) },
            key: key,
            virtualKey: virtualKey,
            timestamp: isoFormatter.string(from: Date())
        )
    }

    private func dragEventType(for button: MouseButton) -> CGEventType {
        switch button {
        case .left:
            return .leftMouseDragged
        case .right:
            return .rightMouseDragged
        case .middle:
            return .otherMouseDragged
        }
    }

    private func trajectoryPath(
        from start: CGPoint,
        to end: CGPoint,
        style: TrajectoryStyle,
        pointCount: Int,
        rng: inout SystemRandomNumberGenerator
    ) -> [CGPoint] {
        let count = max(pointCount, 1)
        switch style {
        case .linear:
            return interpolatedPath(from: start, to: end, steps: count)
        case .bezier:
            return BezierMouse.path(
                from: start.humanPoint,
                to: end.humanPoint,
                count: count,
                params: humanizationProfile.bezierParams,
                rng: &rng
            ).map(\.cgPoint)
        case .wind, .profile(_):
            return WindMouse.resampledPath(
                from: start.humanPoint,
                to: end.humanPoint,
                count: count,
                params: humanizationProfile.windMouseParams,
                rng: &rng
            ).map(\.cgPoint)
        }
    }

    private func movePointCount(style: TrajectoryStyle, durationMs: Int?) -> Int {
        switch style {
        case .linear:
            guard let durationMs else {
                return 1
            }
            return pointCount(durationMs: durationMs, fallback: 1)
        case .bezier, .wind, .profile:
            return pointCount(durationMs: durationMs, fallback: humanizationProfile.movePointCount)
        }
    }

    private func pointCount(durationMs: Int?, fallback: Int) -> Int {
        guard let durationMs else {
            return fallback
        }
        return max(1, Int((Double(durationMs) / 28.0).rounded()))
    }

    private func perPointDelay(totalDurationMs: Int?, pointCount: Int) -> Int {
        guard let totalDurationMs, pointCount > 0 else {
            return 0
        }
        return max(0, totalDurationMs / pointCount)
    }

    private func currentMouseLocation(fallback: CGPoint) -> CGPoint {
        CGEvent(source: nil)?.location ?? fallback
    }

    private func interpolatedPath(from start: CGPoint, to end: CGPoint, steps: Int) -> [CGPoint] {
        guard steps > 1 else { return [end] }
        return (0..<steps).map { index in
            let progress = CGFloat(index) / CGFloat(steps - 1)
            let eased = progress * progress * (3 - 2 * progress)
            return CGPoint(
                x: start.x + (end.x - start.x) * eased,
                y: start.y + (end.y - start.y) * eased
            )
        }
    }

    private func eventName(for type: CGEventType) -> String {
        switch type {
        case .mouseMoved:
            return "mouseMoved"
        case .leftMouseDown:
            return "leftMouseDown"
        case .leftMouseUp:
            return "leftMouseUp"
        case .rightMouseDown:
            return "rightMouseDown"
        case .rightMouseUp:
            return "rightMouseUp"
        case .otherMouseDown:
            return "otherMouseDown"
        case .otherMouseUp:
            return "otherMouseUp"
        case .leftMouseDragged:
            return "leftMouseDragged"
        case .rightMouseDragged:
            return "rightMouseDragged"
        case .otherMouseDragged:
            return "otherMouseDragged"
        case .scrollWheel:
            return "scrollWheel"
        default:
            return eventTypeDescription(type)
        }
    }

    private func eventTypeDescription(_ type: CGEventType) -> String {
        String(type.rawValue)
    }
}

private extension ActionPrimitive {
    var firstUnsupportedPidEventType: CGEventType? {
        switch self {
        case .move:
            return nil
        case .scroll:
            return nil
        case .click:
            return .leftMouseDown
        case .drag:
            return .leftMouseDown
        case .type:
            return .keyDown
        case .key:
            return .keyDown
        }
    }

    var requiresFrontmostInAutoMode: Bool {
        firstUnsupportedPidEventType != nil
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

private extension CGPoint {
    var humanPoint: HumanPoint {
        HumanPoint(x: Double(x), y: Double(y))
    }
}

private extension HumanPoint {
    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}
