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
    public let motionProfile: MotionProfile?

    public init(id: String, motionProfile: MotionProfile? = nil) {
        self.id = id
        self.motionProfile = motionProfile
    }
}

public struct LandingZone {
    public let center: CGPoint?
    public let width: Double?
    public let height: Double?
    public let radius: Double?

    public init(center: CGPoint? = nil, width: Double? = nil, height: Double? = nil, radius: Double? = nil) {
        self.center = center
        self.width = width
        self.height = height
        self.radius = radius
    }
}

public struct PrimitiveProfile {
    public let origin: CGPoint?
    public let landingZone: LandingZone?
    public let motionProfile: MotionProfile?

    public init(origin: CGPoint? = nil, landingZone: LandingZone? = nil, motionProfile: MotionProfile? = nil) {
        self.origin = origin
        self.landingZone = landingZone
        self.motionProfile = motionProfile
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
    case move(to: CGPoint, via: TrajectoryStyle, durationMs: Int?, profile: PrimitiveProfile?)
    case click(at: CGPoint, button: MouseButton, holdMs: Int?, count: Int, profile: PrimitiveProfile?)
    case drag(from: CGPoint, to: CGPoint, button: MouseButton, via: TrajectoryStyle, profile: PrimitiveProfile?)
    case scroll(at: CGPoint, dx: Double, dy: Double, style: ScrollStyle)
    case type(text: String, layout: KeyboardLayout, profile: PrimitiveProfile?)
    case key(chord: KeyChord, holdMs: Int?, profile: PrimitiveProfile?)
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
        case .move(let to, let style, let durationMs, let profile):
            let motionProfile = resolvedMotionProfile(style: style, explicitProfile: profile)
            let start = profile?.origin ?? currentMouseLocation(fallback: target.frame.center)
            let resolvedTarget = to
            return try emitMovePath(
                from: start,
                to: resolvedTarget,
                style: style,
                durationMs: durationMs,
                motionProfile: motionProfile,
                button: .left,
                poster: poster,
                dryRun: dryRun,
                rng: &rng
            )

        case .click(let at, let button, let holdMs, let count, let profile):
            let motionProfile = profile?.motionProfile
            let clickPoint = at
            let resolvedHoldMs = motionProfile?.resolvedClickHoldMs(defaultValue: holdMs ?? 45, rng: &rng) ?? (holdMs ?? 45)
            let interClickMs = motionProfile?.resolvedInterClickMs(defaultValue: 120, rng: &rng) ?? 120
            var emitted = [InjectedEvent]()
            let start = profile?.origin ?? currentMouseLocation(fallback: clickPoint)
            if needsCursorTravel(from: start, to: clickPoint) {
                emitted.append(contentsOf: try emitMovePath(
                    from: start,
                    to: clickPoint,
                    style: pointerActionStyle(for: motionProfile),
                    durationMs: nil,
                    motionProfile: motionProfile,
                    button: button.cgButton,
                    poster: poster,
                    dryRun: dryRun,
                    rng: &rng
                ))
            }
            let clickCount = max(count, 1)
            for index in 0..<clickCount {
                emitted.append(try postMouse(type: button.downEventType, location: clickPoint, button: button.cgButton, poster: poster, dryRun: dryRun))
                FocusController.sleep(milliseconds: resolvedHoldMs)
                emitted.append(try postMouse(type: button.upEventType, location: clickPoint, button: button.cgButton, poster: poster, dryRun: dryRun))
                if index < clickCount - 1 {
                    FocusController.sleep(milliseconds: interClickMs)
                }
            }
            let settleMs = motionProfile?.settleMs?.sample(rng: &rng) ?? 72
            FocusController.sleep(milliseconds: settleMs)
            return emitted

        case .drag(let from, let to, let button, let style, let profile):
            let motionProfile = resolvedMotionProfile(style: style, explicitProfile: profile)
            let start = profile?.origin ?? from
            let resolvedTarget = to
            let dragPath = trajectoryPath(
                from: start,
                to: resolvedTarget,
                style: style,
                pointCount: motionProfile?.resolvedPointCount(fallback: humanizationProfile.dragPointCount, rng: &rng) ?? humanizationProfile.dragPointCount,
                motionProfile: motionProfile,
                rng: &rng
            )
            let timing = HumanTimingCurve.plan(
                path: dragPath.map(\.humanPoint),
                requestedDurationMs: nil,
                profile: motionProfile,
                isDrag: true,
                rng: &rng
            )
            let preHoldMs = motionProfile?.settleMs?.sample(rng: &rng) ?? 40
            let dragHoldMs = motionProfile?.resolvedClickHoldMs(defaultValue: 56, rng: &rng) ?? 56
            var emitted = [InjectedEvent]()
            emitted.append(try postMouse(type: .mouseMoved, location: start, button: button.cgButton, poster: poster, dryRun: dryRun))
            FocusController.sleep(milliseconds: preHoldMs)
            emitted.append(try postMouse(type: button.downEventType, location: start, button: button.cgButton, poster: poster, dryRun: dryRun))
            FocusController.sleep(milliseconds: dragHoldMs)
            for (index, point) in dragPath.enumerated() {
                emitted.append(try postMouse(type: dragEventType(for: button), location: point, button: button.cgButton, poster: poster, dryRun: dryRun))
                if index < dragPath.count - 1, timing.delaysMs.indices.contains(index), timing.delaysMs[index] > 0 {
                    FocusController.sleep(milliseconds: timing.delaysMs[index])
                }
            }
            let releasePoint = dragPath.last ?? resolvedTarget
            emitted.append(try postMouse(type: button.upEventType, location: releasePoint, button: button.cgButton, poster: poster, dryRun: dryRun))
            FocusController.sleep(milliseconds: motionProfile?.settleMs?.sample(rng: &rng) ?? 92)
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

        case .type(let text, _, let profile):
            var emitted = [InjectedEvent]()
            let schedule = KeystrokeRhythm.schedule(
                for: text,
                params: resolvedKeyRhythmParams(profile?.motionProfile),
                rng: &rng
            )
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

        case .key(let chord, let holdMs, let profile):
            var emitted = [InjectedEvent]()
            emitted.append(try postKey(keyCode: chord.keyCode, keyDown: true, recordedKey: nil, poster: poster, dryRun: dryRun))
            let keyHold = profile?.motionProfile?.resolvedClickHoldMs(defaultValue: holdMs ?? 45, rng: &rng) ?? (holdMs ?? 45)
            FocusController.sleep(milliseconds: keyHold)
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

    private func emitMovePath(
        from start: CGPoint,
        to end: CGPoint,
        style: TrajectoryStyle,
        durationMs: Int?,
        motionProfile: MotionProfile?,
        button: CGMouseButton,
        poster: EventPoster,
        dryRun: Bool,
        rng: inout SystemRandomNumberGenerator
    ) throws -> [InjectedEvent] {
        let path = trajectoryPath(
            from: start,
            to: end,
            style: style,
            pointCount: movePointCount(style: style, durationMs: durationMs, motionProfile: motionProfile, rng: &rng),
            motionProfile: motionProfile,
            rng: &rng
        )
        let timing = HumanTimingCurve.plan(
            path: path.map(\.humanPoint),
            requestedDurationMs: durationMs,
            profile: motionProfile,
            rng: &rng
        )
        var emitted = [InjectedEvent]()
        for (index, point) in path.enumerated() {
            emitted.append(try postMouse(type: .mouseMoved, location: point, button: button, poster: poster, dryRun: dryRun))
            if index < path.count - 1, timing.delaysMs.indices.contains(index), timing.delaysMs[index] > 0 {
                FocusController.sleep(milliseconds: timing.delaysMs[index])
            }
        }
        return emitted
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
        motionProfile: MotionProfile?,
        rng: inout SystemRandomNumberGenerator
    ) -> [CGPoint] {
        let count = max(pointCount, 1)
        if let waypoint = detourWaypoint(from: start, to: end, motionProfile: motionProfile, rng: &rng), count >= 6 {
            let firstCount = max(3, count / 2)
            let secondCount = max(3, count - firstCount + 1)
            let firstLeg = baseTrajectoryPath(
                from: start,
                to: waypoint,
                style: style,
                pointCount: firstCount,
                motionProfile: motionProfile,
                rng: &rng
            )
            let secondLeg = baseTrajectoryPath(
                from: waypoint,
                to: end,
                style: style,
                pointCount: secondCount,
                motionProfile: motionProfile,
                rng: &rng
            )
            return Array(firstLeg.dropLast()) + secondLeg
        }
        return baseTrajectoryPath(from: start, to: end, style: style, pointCount: count, motionProfile: motionProfile, rng: &rng)
    }

    private func baseTrajectoryPath(
        from start: CGPoint,
        to end: CGPoint,
        style: TrajectoryStyle,
        pointCount: Int,
        motionProfile: MotionProfile?,
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
                params: motionProfile?.resolvedBezierParams(base: humanizationProfile.bezierParams) ?? humanizationProfile.bezierParams,
                rng: &rng
            ).map(\.cgPoint)
        case .wind:
            return WindMouse.resampledPath(
                from: start.humanPoint,
                to: end.humanPoint,
                count: count,
                params: motionProfile?.resolvedWindParams(base: humanizationProfile.windMouseParams) ?? humanizationProfile.windMouseParams,
                rng: &rng
            ).map(\.cgPoint)
        case .profile:
            if prefersBezierProfile(motionProfile) {
                return BezierMouse.path(
                    from: start.humanPoint,
                    to: end.humanPoint,
                    count: count,
                    params: motionProfile?.resolvedBezierParams(base: humanizationProfile.bezierParams) ?? humanizationProfile.bezierParams,
                    rng: &rng
                ).map(\.cgPoint)
            }
            return WindMouse.resampledPath(
                from: start.humanPoint,
                to: end.humanPoint,
                count: count,
                params: motionProfile?.resolvedWindParams(base: humanizationProfile.windMouseParams) ?? humanizationProfile.windMouseParams,
                rng: &rng
            ).map(\.cgPoint)
        }
    }

    private func movePointCount(style: TrajectoryStyle, durationMs: Int?, motionProfile: MotionProfile?, rng: inout SystemRandomNumberGenerator) -> Int {
        switch style {
        case .linear:
            guard let durationMs else {
                return 1
            }
            return pointCount(durationMs: durationMs, fallback: 1)
        case .bezier, .wind, .profile:
            let fallback = pointCount(durationMs: durationMs, fallback: humanizationProfile.movePointCount)
            return motionProfile?.resolvedPointCount(fallback: fallback, rng: &rng) ?? fallback
        }
    }

    private func pointCount(durationMs: Int?, fallback: Int) -> Int {
        guard let durationMs else {
            return fallback
        }
        return max(1, Int((Double(durationMs) / 28.0).rounded()))
    }

    private func currentMouseLocation(fallback: CGPoint) -> CGPoint {
        CGEvent(source: nil)?.location ?? fallback
    }

    private func needsCursorTravel(from start: CGPoint, to end: CGPoint) -> Bool {
        hypot(end.x - start.x, end.y - start.y) > 2
    }

    private func pointerActionStyle(for motionProfile: MotionProfile?) -> TrajectoryStyle {
        guard let motionProfile else {
            return .wind
        }
        return .profile(TemplateReference(id: "inline-pointer-action", motionProfile: motionProfile))
    }

    private func resolvedMotionProfile(style: TrajectoryStyle, explicitProfile: PrimitiveProfile?) -> MotionProfile? {
        switch style {
        case .profile(let reference):
            if let explicit = explicitProfile?.motionProfile {
                return reference.motionProfile?.merging(explicit) ?? explicit
            }
            return reference.motionProfile
        case .linear, .bezier, .wind:
            return explicitProfile?.motionProfile
        }
    }

    private func detourWaypoint(
        from start: CGPoint,
        to end: CGPoint,
        motionProfile: MotionProfile?,
        rng: inout SystemRandomNumberGenerator
    ) -> CGPoint? {
        guard let motionProfile else {
            return nil
        }
        let distance = hypot(end.x - start.x, end.y - start.y)
        guard distance > 80 else {
            return nil
        }
        let probability = motionProfile.detourProbability ?? defaultDetourProbability(for: motionProfile)
        guard rng.nextDouble(in: 0..<1) < probability else {
            return nil
        }

        let progress = rng.nextDouble(in: 0.28..<0.72)
        let dx = end.x - start.x
        let dy = end.y - start.y
        let normal = CGPoint(x: -dy / distance, y: dx / distance)
        let sway = distance * rng.nextDouble(in: 0.05..<0.18)
        let direction = rng.nextDouble(in: 0..<1) < 0.5 ? -1.0 : 1.0
        return CGPoint(
            x: start.x + CGFloat(Double(dx) * progress + Double(normal.x) * sway * direction),
            y: start.y + CGFloat(Double(dy) * progress + Double(normal.y) * sway * direction)
        )
    }

    private func defaultDetourProbability(for motionProfile: MotionProfile) -> Double {
        switch motionProfile.flavor {
        case .idle:
            return 0.30
        case .gentle:
            return 0.16
        case .hurried:
            return 0.04
        case .smooth:
            return 0.10
        case nil:
            return 0.12
        }
    }

    private func prefersBezierProfile(_ motionProfile: MotionProfile?) -> Bool {
        guard let motionProfile else {
            return false
        }
        if motionProfile.flavor == .smooth || motionProfile.flavor == .gentle {
            return true
        }
        return (motionProfile.straightnessMean ?? 0) > 0.78 && (motionProfile.turnJitterMean ?? 0) < 0.55
    }

    private func resolvedKeyRhythmParams(_ motionProfile: MotionProfile?) -> KeyRhythmParams {
        guard let motionProfile else {
            return humanizationProfile.keyRhythmParams
        }

        var params = humanizationProfile.keyRhythmParams
        if let dwellMsMean = motionProfile.dwellMsMean {
            let lower = max(24, Int((dwellMsMean * 0.68).rounded()))
            let upper = max(lower + 8, Int((dwellMsMean * 1.36).rounded()))
            params.dwellMsRange = lower...upper
        }
        if let interKeyMsMean = motionProfile.interKeyMsMean {
            let intra = max(26, interKeyMsMean)
            params.intraWordMu = log(intra)
            params.interWordMu = log(max(intra * 1.45, intra + 32))
            params.intraWordSigma = 0.28
            params.interWordSigma = 0.34
        }
        return params
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

private extension RandomNumberGenerator {
    mutating func nextDouble(in range: Range<Double>) -> Double {
        let unit = Double(next() >> 11) / Double(1 << 53)
        return range.lowerBound + (range.upperBound - range.lowerBound) * unit
    }
}
