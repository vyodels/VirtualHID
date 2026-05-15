import AppKit
import Carbon
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
    case scroll(at: CGPoint, dx: Double, dy: Double, style: ScrollStyle, profile: PrimitiveProfile?)
    case type(text: String, layout: KeyboardLayout, profile: PrimitiveProfile?)
    case pasteText(text: String, restoreClipboard: Bool, profile: PrimitiveProfile?)
    case key(chord: KeyChord, holdMs: Int?, profile: PrimitiveProfile?)
}

public extension ActionPrimitive {
    var actionTypeName: String {
        switch self {
        case .move:
            return "move"
        case .click:
            return "click"
        case .drag:
            return "drag"
        case .scroll:
            return "scroll"
        case .type:
            return "type"
        case .pasteText:
            return "pasteText"
        case .key:
            return "key"
        }
    }
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
    public var browserChromeOverlayPolicy: BrowserChromeOverlayPolicy
    public var disableProfiles: Bool
    public var preDelayMs: Int?
    public var postDelayMs: Int?
    public var behaviorMode: HumanBehaviorMode?
    public var rhythmProfile: MotionProfile?

    public init(
        postMode: PostMode? = nil,
        timeoutMs: Int? = nil,
        dryRun: Bool = false,
        browserChromeOverlayPolicy: BrowserChromeOverlayPolicy = .auto,
        disableProfiles: Bool = false,
        preDelayMs: Int? = nil,
        postDelayMs: Int? = nil,
        behaviorMode: HumanBehaviorMode? = nil,
        rhythmProfile: MotionProfile? = nil
    ) {
        self.postMode = postMode
        self.timeoutMs = timeoutMs
        self.dryRun = dryRun
        self.browserChromeOverlayPolicy = browserChromeOverlayPolicy
        self.disableProfiles = disableProfiles
        self.preDelayMs = preDelayMs
        self.postDelayMs = postDelayMs
        self.behaviorMode = behaviorMode
        self.rhythmProfile = rhythmProfile
    }
}

public enum BrowserChromeOverlayPolicy: String, Codable {
    case auto
    case force
    case off
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
    public let inputDiagnostics: [InputFallbackDiagnostic]

    public init(id: String, ok: Bool, error: String?, events: [InjectedEvent], elapsedMs: Int, inputDiagnostics: [InputFallbackDiagnostic] = []) {
        self.id = id
        self.ok = ok
        self.error = error
        self.events = events
        self.elapsedMs = elapsedMs
        self.inputDiagnostics = inputDiagnostics
    }
}

public struct InputFallbackDiagnostic: Codable, Equatable {
    public let primitiveIndex: Int
    public let status: String
    public let path: String
    public let textLength: Int
    public let chunks: Int
    public let fallback: String?
    public let fallbackReason: String?
    public let evidence: [String]

    public init(
        primitiveIndex: Int,
        status: String,
        path: String,
        textLength: Int,
        chunks: Int,
        fallback: String? = nil,
        fallbackReason: String? = nil,
        evidence: [String] = []
    ) {
        self.primitiveIndex = primitiveIndex
        self.status = status
        self.path = path
        self.textLength = textLength
        self.chunks = chunks
        self.fallback = fallback
        self.fallbackReason = fallbackReason
        self.evidence = evidence
    }
}

public enum ActionExecutionError: Error, LocalizedError {
    case busy
    case cancelled
    case timedOut(Int)
    case eventCreationFailed(String)
    case cursorInterference

    public var errorDescription: String? {
        switch self {
        case .busy:
            return "执行器忙碌中"
        case .cancelled:
            return "执行已取消"
        case .timedOut(let timeoutMs):
            return "执行超过超时时间：\(timeoutMs)ms"
        case .eventCreationFailed(let detail):
            return "无法创建事件：\(detail)"
        case .cursorInterference:
            return "检测到持续鼠标抢占，无法安全完成目标落点"
        }
    }
}

private struct PrimitiveEmitResult {
    let events: [InjectedEvent]
    let inputDiagnostics: [InputFallbackDiagnostic]
    let terminalError: String?

    init(events: [InjectedEvent], inputDiagnostics: [InputFallbackDiagnostic] = [], terminalError: String? = nil) {
        self.events = events
        self.inputDiagnostics = inputDiagnostics
        self.terminalError = terminalError
    }
}

private struct ActionDeadline {
    private let timeoutMs: Int?
    private let expiresAt: Date?

    init(timeoutMs: Int?, responseReserveMs: Int = 350) {
        guard let timeoutMs, timeoutMs > 0 else {
            self.timeoutMs = nil
            self.expiresAt = nil
            return
        }
        self.timeoutMs = timeoutMs
        let executableMs = max(50, timeoutMs - responseReserveMs)
        self.expiresAt = Date().addingTimeInterval(TimeInterval(executableMs) / 1000.0)
    }

    func assertNotExpired() throws {
        guard let timeoutMs, let expiresAt else {
            return
        }
        if Date() >= expiresAt {
            throw ActionExecutionError.timedOut(timeoutMs)
        }
    }

    func assertCanSpend(milliseconds: Int) throws {
        guard let timeoutMs, let expiresAt else {
            return
        }
        let remainingMs = Int(expiresAt.timeIntervalSince(Date()) * 1000)
        if remainingMs <= max(milliseconds, 0) {
            throw ActionExecutionError.timedOut(timeoutMs)
        }
    }
}

public final class ActionExecutor {
    private let target: BrowserTarget
    private let defaultPostMode: PostMode
    private let humanizationProfile: HumanizationProfile
    private let eventSink: HIDEventSink?
    private let cursorLocationProvider: (() -> CGPoint?)?
    private let isoFormatter: ISO8601DateFormatter
    private let lock = NSLock()
    private let cursorInterferenceTolerancePx: CGFloat = 24
    private let terminalPointerTolerancePx: CGFloat = 3
    private var busy = false
    private var cancelled = false
    private var activeVisualContext: HIDActionVisualContext?
    private var activeDryRunTimestamp: Date?

    public init(
        target: BrowserTarget,
        defaultPostMode: PostMode = .global,
        humanizationProfile: HumanizationProfile = HumanizationProfile(),
        eventSink: HIDEventSink? = nil,
        cursorLocationProvider: (() -> CGPoint?)? = nil
    ) {
        self.target = target
        self.defaultPostMode = defaultPostMode
        self.humanizationProfile = humanizationProfile
        self.eventSink = eventSink
        self.cursorLocationProvider = cursorLocationProvider
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
        let deadline = ActionDeadline(timeoutMs: request.options.timeoutMs)
        let poster = EventPoster(mode: requestedMode, targetPid: target.pid)
        let visualContext = HIDActionVisualContext(
            actionId: request.id,
            bundleIdentifier: target.bundleIdentifier,
            pid: target.pid,
            windowTitle: target.windowTitle,
            windowFrame: CodableRect(x: target.frame.origin.x, y: target.frame.origin.y, width: target.frame.width, height: target.frame.height),
            dryRun: dryRun,
            postMode: requestedMode.rawValue,
            actionTypes: request.primitives.map(\.actionTypeName)
        )
        var rng = SystemRandomNumberGenerator()
        var events = [InjectedEvent]()
        var inputDiagnostics = [InputFallbackDiagnostic]()
        activeVisualContext = visualContext
        activeDryRunTimestamp = dryRun ? startedAt : nil
        eventSink?.hidActionDidStart(visualContext)
        defer {
            activeVisualContext = nil
            activeDryRunTimestamp = nil
        }

        if requestedMode == .global, !dryRun {
            try ensureFrontmostForPost(type: .leftMouseDown, poster: poster, dryRun: dryRun)
            try poster.preflight(frontmost: FocusController.isFrontmost(app: target.app))
        } else if requestedMode == .pid {
            try ensurePidSafePrimitives(request.primitives)
        }

        try sleep(milliseconds: request.options.preDelayMs ?? 0, dryRun: dryRun, deadline: deadline)

        for (index, primitive) in request.primitives.enumerated() {
            try checkCancelled()
            try deadline.assertNotExpired()
            let emitted = try emit(primitive, primitiveIndex: index, poster: poster, options: request.options, deadline: deadline, rng: &rng)
            events.append(contentsOf: emitted.events)
            inputDiagnostics.append(contentsOf: emitted.inputDiagnostics)
            if let terminalError = emitted.terminalError {
                let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                return ActionResult(id: request.id, ok: false, error: terminalError, events: events, elapsedMs: elapsedMs, inputDiagnostics: inputDiagnostics)
            }
        }

        try sleep(milliseconds: request.options.postDelayMs ?? 0, dryRun: dryRun, deadline: deadline)

        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        return ActionResult(id: request.id, ok: true, error: nil, events: events, elapsedMs: elapsedMs, inputDiagnostics: inputDiagnostics)
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

    private func emit(_ primitive: ActionPrimitive, primitiveIndex: Int, poster: EventPoster, options: ActionOptions, deadline: ActionDeadline, rng: inout SystemRandomNumberGenerator) throws -> PrimitiveEmitResult {
        let dryRun = options.dryRun
        try deadline.assertNotExpired()
        switch primitive {
        case .move(let to, let style, let durationMs, let profile):
            let motionProfile = actionMotionProfile(resolvedMotionProfile(style: style, explicitProfile: profile), options: options)
            let start = profile?.origin ?? currentMouseLocation(fallback: target.frame.center)
            let resolvedTarget = resolvedLandingPoint(base: to, profile: profile, rng: &rng)
            return PrimitiveEmitResult(events: try emitMovePath(
                from: start,
                to: resolvedTarget,
                style: style,
                durationMs: durationMs,
                motionProfile: motionProfile,
                button: .left,
                poster: poster,
                dryRun: dryRun,
                deadline: deadline,
                rng: &rng
            ))

        case .click(let at, let button, let holdMs, let count, let profile):
            let motionProfile = actionMotionProfile(profile?.motionProfile, options: options)
            let clickPoint = resolvedLandingPoint(base: at, profile: profile, rng: &rng)
            let resolvedHoldMs = motionProfile?.resolvedClickHoldMs(defaultValue: holdMs ?? 45, rng: &rng) ?? (holdMs ?? 45)
            let interClickMs = motionProfile?.resolvedInterClickMs(defaultValue: 120, rng: &rng) ?? 120
            var emitted = [InjectedEvent]()
            let start = profile?.origin ?? currentMouseLocation(fallback: clickPoint)
            if needsCursorTravel(from: start, to: clickPoint) {
                let travelDurationMs = motionProfile == nil
                    ? implicitPointerTravelDurationMs(options: options, holdMs: resolvedHoldMs, settleMs: 72)
                    : nil
                emitted.append(contentsOf: try emitMovePath(
                    from: start,
                    to: clickPoint,
                    style: pointerActionStyle(for: motionProfile),
                    durationMs: travelDurationMs,
                    motionProfile: motionProfile,
                    button: button.cgButton,
                    poster: poster,
                    dryRun: dryRun,
                    deadline: deadline,
                    rng: &rng
                ))
            }
            let clickCount = max(count, 1)
            let secondClickOffset = clickCount > 1 ? motionProfile?.resolvedDoubleClickSecondOffset(rng: &rng).cgPoint ?? .zero : .zero
            for index in 0..<clickCount {
                try deadline.assertNotExpired()
                let perClickHoldMs = clickCount > 1
                    ? motionProfile?.resolvedDoubleClickHoldMs(defaultValue: resolvedHoldMs, rng: &rng) ?? resolvedHoldMs
                    : motionProfile?.resolvedClickHoldMs(defaultValue: resolvedHoldMs, rng: &rng) ?? resolvedHoldMs
                let perClickPoint = index == 1 ? CGPoint(x: clickPoint.x + secondClickOffset.x, y: clickPoint.y + secondClickOffset.y) : clickPoint
                emitted.append(contentsOf: try ensurePointerAtTarget(
                    perClickPoint,
                    style: pointerActionStyle(for: motionProfile),
                    motionProfile: motionProfile,
                    button: button.cgButton,
                    poster: poster,
                    dryRun: dryRun,
                    deadline: deadline,
                    rng: &rng
                ))
                emitted.append(try postMouse(type: button.downEventType, location: perClickPoint, button: button.cgButton, poster: poster, dryRun: dryRun))
                try sleep(milliseconds: perClickHoldMs, dryRun: dryRun, deadline: deadline)
                emitted.append(try postMouse(type: button.upEventType, location: perClickPoint, button: button.cgButton, poster: poster, dryRun: dryRun))
                if index < clickCount - 1 {
                    let interval = clickCount == 2
                        ? motionProfile?.resolvedDoubleClickInterClickMs(defaultValue: interClickMs, rng: &rng) ?? interClickMs
                        : interClickMs
                    try sleep(milliseconds: interval, dryRun: dryRun, deadline: deadline)
                }
            }
            let settleMs = motionProfile?.settleMs?.sample(rng: &rng) ?? 72
            try sleep(milliseconds: settleMs, dryRun: dryRun, deadline: deadline)
            return PrimitiveEmitResult(events: emitted)

        case .drag(let from, let to, let button, let style, let profile):
            let motionProfile = actionMotionProfile(resolvedMotionProfile(style: style, explicitProfile: profile), options: options)
            let start = profile?.origin ?? from
            let resolvedTarget = resolvedLandingPoint(base: to, profile: profile, rng: &rng)
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
            emitted.append(contentsOf: try ensurePointerAtTarget(
                start,
                style: pointerActionStyle(for: motionProfile),
                motionProfile: motionProfile,
                button: button.cgButton,
                poster: poster,
                dryRun: dryRun,
                deadline: deadline,
                rng: &rng
            ))
            if emitted.last?.location.map({ distance(CGPoint(x: $0.x, y: $0.y), start) <= terminalPointerTolerancePx }) != true {
                emitted.append(try postMouse(type: .mouseMoved, location: start, button: button.cgButton, poster: poster, dryRun: dryRun))
            }
            try sleep(milliseconds: preHoldMs, dryRun: dryRun, deadline: deadline)
            emitted.append(try postMouse(type: button.downEventType, location: start, button: button.cgButton, poster: poster, dryRun: dryRun))
            try sleep(milliseconds: dragHoldMs, dryRun: dryRun, deadline: deadline)
            for (index, point) in dragPath.enumerated() {
                try deadline.assertNotExpired()
                emitted.append(try postMouse(type: dragEventType(for: button), location: point, button: button.cgButton, poster: poster, dryRun: dryRun))
                if index < dragPath.count - 1, timing.delaysMs.indices.contains(index), timing.delaysMs[index] > 0 {
                    try sleep(milliseconds: timing.delaysMs[index], dryRun: dryRun, deadline: deadline)
                }
            }
            let releasePoint = dragPath.last ?? resolvedTarget
            emitted.append(try postMouse(type: button.upEventType, location: releasePoint, button: button.cgButton, poster: poster, dryRun: dryRun))
            try sleep(milliseconds: motionProfile?.settleMs?.sample(rng: &rng) ?? 92, dryRun: dryRun, deadline: deadline)
            return PrimitiveEmitResult(events: emitted)

        case .scroll(let at, let dx, let dy, _, let profile):
            return try emitScroll(at: at, dx: dx, dy: dy, motionProfile: profile?.motionProfile, poster: poster, dryRun: dryRun, deadline: deadline, rng: &rng)

        case .type(let text, _, let profile):
            return try emitTypeText(
                text,
                primitiveIndex: primitiveIndex,
                profile: profile?.motionProfile,
                options: options,
                poster: poster,
                dryRun: dryRun,
                deadline: deadline,
                rng: &rng
            )

        case .pasteText(let text, let restoreClipboard, _):
            let events = try emitPasteText(text, restoreClipboard: restoreClipboard, poster: poster, dryRun: dryRun, deadline: deadline)
            return PrimitiveEmitResult(
                events: events,
                inputDiagnostics: [
                    InputFallbackDiagnostic(
                        primitiveIndex: primitiveIndex,
                        status: "explicitFallback",
                        path: "pasteText",
                        textLength: text.count,
                        chunks: 1,
                        fallback: nil,
                        fallbackReason: "explicit pasteText primitive",
                        evidence: ["restoreClipboard=\(restoreClipboard)"]
                    )
                ]
            )

        case .key(let chord, let holdMs, let profile):
            var emitted = [InjectedEvent]()
            let motionProfile = actionMotionProfile(profile?.motionProfile, options: options)
            emitted.append(try postKey(keyCode: chord.keyCode, keyDown: true, recordedKey: nil, poster: poster, dryRun: dryRun))
            let keyHold = motionProfile?.resolvedClickHoldMs(defaultValue: holdMs ?? 45, rng: &rng) ?? (holdMs ?? 45)
            try sleep(milliseconds: keyHold, dryRun: dryRun, deadline: deadline)
            emitted.append(try postKey(keyCode: chord.keyCode, keyDown: false, recordedKey: nil, poster: poster, dryRun: dryRun))
            return PrimitiveEmitResult(events: emitted)
        }
    }

    private func emitPasteText(
        _ text: String,
        restoreClipboard: Bool,
        poster: EventPoster,
        dryRun: Bool,
        deadline: ActionDeadline
    ) throws -> [InjectedEvent] {
        var emitted = [record(type: "pasteText", key: "clipboard")]
        let oldClipboard: String?
        if dryRun {
            oldClipboard = nil
        } else {
            let pasteboard = NSPasteboard.general
            oldClipboard = pasteboard.string(forType: .string)
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }

        emitted.append(try postKey(keyCode: 55, keyDown: true, recordedKey: nil, poster: poster, dryRun: dryRun, flags: [.maskCommand]))
        emitted.append(try postKey(keyCode: 9, keyDown: true, recordedKey: "v", poster: poster, dryRun: dryRun, flags: [.maskCommand]))
        try sleep(milliseconds: 36, dryRun: dryRun, deadline: deadline)
        emitted.append(try postKey(keyCode: 9, keyDown: false, recordedKey: "v", poster: poster, dryRun: dryRun, flags: [.maskCommand]))
        emitted.append(try postKey(keyCode: 55, keyDown: false, recordedKey: nil, poster: poster, dryRun: dryRun))

        if !dryRun, restoreClipboard {
            try sleep(milliseconds: 120, dryRun: false, deadline: deadline)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if let oldClipboard {
                pasteboard.setString(oldClipboard, forType: .string)
            }
        }
        return emitted
    }

    private func emitScroll(
        at point: CGPoint,
        dx: Double,
        dy: Double,
        motionProfile: MotionProfile?,
        poster: EventPoster,
        dryRun: Bool,
        deadline: ActionDeadline,
        rng: inout SystemRandomNumberGenerator
    ) throws -> PrimitiveEmitResult {
        let stepCount = motionProfile?.resolvedScrollStepCount(fallback: 1, rng: &rng) ?? 1
        let baseDelta = motionProfile?.resolvedScrollDelta(requestedDx: dx, requestedDy: dy, rng: &rng)
            ?? HumanPoint(x: dx, y: dy)
        let decay = motionProfile?.resolvedScrollInertiaDecay(rng: &rng) ?? 1
        let delay = motionProfile?.resolvedScrollDelayMs(fallback: 0, rng: &rng) ?? 0
        var emitted = [InjectedEvent]()
        for index in 0..<stepCount {
            try deadline.assertNotExpired()
            let factor = pow(decay, Double(index))
            let stepDx = baseDelta.x * factor
            let stepDy = baseDelta.y * factor
            if dryRun {
                emitted.append(record(type: "scrollWheel", location: point))
            } else {
                guard let event = CGEvent(
                    scrollWheelEvent2Source: nil,
                    units: .pixel,
                    wheelCount: 2,
                    wheel1: Int32(stepDy.rounded()),
                    wheel2: Int32(stepDx.rounded()),
                    wheel3: 0
                ) else {
                    throw ActionExecutionError.eventCreationFailed("scroll")
                }
                event.location = point
                try ensureFrontmostForPost(type: .scrollWheel, poster: poster, dryRun: dryRun)
                _ = try poster.post(event, type: .scrollWheel, frontmost: FocusController.isFrontmost(app: target.app))
                emitted.append(record(type: "scrollWheel", location: point))
            }
            if index < stepCount - 1, delay > 0 {
                try sleep(milliseconds: delay, dryRun: dryRun, deadline: deadline)
            }
        }
        return PrimitiveEmitResult(events: emitted)
    }

    private func emitTypeText(
        _ text: String,
        primitiveIndex: Int,
        profile: MotionProfile?,
        options: ActionOptions,
        poster: EventPoster,
        dryRun: Bool,
        deadline: ActionDeadline,
        rng: inout SystemRandomNumberGenerator
    ) throws -> PrimitiveEmitResult {
        let effectiveProfile = options.rhythmProfile?.merging(profile) ?? profile
        let textLength = text.count
        if text.isEmpty {
            return PrimitiveEmitResult(
                events: [],
                inputDiagnostics: [
                    InputFallbackDiagnostic(primitiveIndex: primitiveIndex, status: "typed", path: "keyboardCharByChar", textLength: 0, chunks: 0)
                ]
            )
        }

        let keyboardChunks = chunkText(text, maxScalars: 40)
        let fullSchedule = KeystrokeRhythm.schedule(
            for: text,
            params: resolvedKeyRhythmParams(effectiveProfile),
            rng: &rng
        )
        if fullSchedule.count == text.unicodeScalars.count {
            var emitted = [InjectedEvent]()
            for (chunkIndex, chunk) in keyboardChunks.enumerated() {
                let schedule = KeystrokeRhythm.schedule(
                    for: chunk,
                    params: resolvedKeyRhythmParams(effectiveProfile),
                    rng: &rng
                )
                for keyEvent in schedule {
                    try emitScheduledKeyEvent(keyEvent, emitted: &emitted, poster: poster, dryRun: dryRun, deadline: deadline)
                }
                if chunkIndex < keyboardChunks.count - 1 {
                    try sleep(milliseconds: 90, dryRun: dryRun, deadline: deadline)
                }
            }
            return PrimitiveEmitResult(
                events: emitted,
                inputDiagnostics: [
                    InputFallbackDiagnostic(
                        primitiveIndex: primitiveIndex,
                        status: "typed",
                        path: keyboardChunks.count > 1 ? "chunkedKeyboardCharByChar" : "keyboardCharByChar",
                        textLength: textLength,
                        chunks: keyboardChunks.count,
                        evidence: keyboardChunks.count > 1 ? ["chunkSizeScalars=40"] : []
                    )
                ]
            )
        }

        if containsChinese(text) {
            guard let inputSource = dryRun ? nil : currentChineseInputSource() else {
                return PrimitiveEmitResult(
                    events: [],
                    inputDiagnostics: [
                        InputFallbackDiagnostic(
                            primitiveIndex: primitiveIndex,
                            status: "fallbackRequired",
                            path: "chineseImeCharByChar",
                            textLength: textLength,
                            chunks: text.count,
                            fallback: "pasteText",
                            fallbackReason: "Chinese IME input source is unavailable; submit an explicit pasteText primitive if paste fallback is acceptable",
                            evidence: ["automatic pasteText disabled"]
                        )
                    ],
                    terminalError: "E_INPUT_FALLBACK_REQUIRED"
                )
            }
            let emitted = try emitChineseIMEText(text, inputSource: inputSource, poster: poster, dryRun: dryRun, deadline: deadline, rng: &rng)
            return PrimitiveEmitResult(
                events: emitted,
                inputDiagnostics: [
                    InputFallbackDiagnostic(
                        primitiveIndex: primitiveIndex,
                        status: "typed",
                        path: "chineseImeCharByChar",
                        textLength: textLength,
                        chunks: text.count,
                        evidence: ["inputSourceId=\(inputSource.id)", "inputSourceName=\(inputSource.name)"]
                    )
                ]
            )
        }

        return PrimitiveEmitResult(
            events: [],
            inputDiagnostics: [
                InputFallbackDiagnostic(
                    primitiveIndex: primitiveIndex,
                    status: "fallbackRequired",
                    path: "keyboardCharByChar",
                    textLength: textLength,
                    chunks: keyboardChunks.count,
                    fallback: "pasteText",
                    fallbackReason: "text contains characters that are not mappable to the configured keyboard layout; submit an explicit pasteText primitive if paste fallback is acceptable",
                    evidence: ["automatic pasteText disabled"]
                )
            ],
            terminalError: "E_INPUT_FALLBACK_REQUIRED"
        )
    }

    private func emitScheduledKeyEvent(
        _ keyEvent: KeystrokeEvent,
        emitted: inout [InjectedEvent],
        poster: EventPoster,
        dryRun: Bool,
        deadline: ActionDeadline
    ) throws {
        if keyEvent.delayBeforeMs > 0 {
            try sleep(milliseconds: keyEvent.delayBeforeMs, dryRun: dryRun, deadline: deadline)
        }

        if keyEvent.modifiers.contains(.shift) {
            emitted.append(try postKey(keyCode: 56, keyDown: true, recordedKey: nil, poster: poster, dryRun: dryRun))
        }

        let keyCode = CGKeyCode(keyEvent.keyCode)
        let recordedKey = String(keyEvent.char)
        emitted.append(try postKey(keyCode: keyCode, keyDown: true, recordedKey: recordedKey, poster: poster, dryRun: dryRun))
        try sleep(milliseconds: keyEvent.dwellMs, dryRun: dryRun, deadline: deadline)
        emitted.append(try postKey(keyCode: keyCode, keyDown: false, recordedKey: recordedKey, poster: poster, dryRun: dryRun))

        if keyEvent.modifiers.contains(.shift) {
            emitted.append(try postKey(keyCode: 56, keyDown: false, recordedKey: nil, poster: poster, dryRun: dryRun))
        }
    }

    private func emitChineseIMEText(
        _ text: String,
        inputSource: ChineseInputSource,
        poster: EventPoster,
        dryRun: Bool,
        deadline: ActionDeadline,
        rng: inout SystemRandomNumberGenerator
    ) throws -> [InjectedEvent] {
        var emitted = [InjectedEvent]()
        for scalar in text.unicodeScalars {
            if emitted.count > 0 {
                try sleep(milliseconds: Int.random(in: 80...160, using: &rng), dryRun: dryRun, deadline: deadline)
            }
            emitted.append(try postUnicodeScalar(scalar, keyDown: true, poster: poster, dryRun: dryRun))
            try sleep(milliseconds: Int.random(in: 45...110, using: &rng), dryRun: dryRun, deadline: deadline)
            emitted.append(try postUnicodeScalar(scalar, keyDown: false, poster: poster, dryRun: dryRun))
        }
        return emitted
    }

    private func postUnicodeScalar(_ scalar: UnicodeScalar, keyDown: Bool, poster: EventPoster, dryRun: Bool) throws -> InjectedEvent {
        if dryRun {
            return record(type: keyDown ? "keyDown" : "keyUp", key: nil, virtualKey: 0)
        }
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown) else {
            throw ActionExecutionError.eventCreationFailed("unicode scalar")
        }
        let utf16 = Array(String(scalar).utf16)
        utf16.withUnsafeBufferPointer { buffer in
            event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        try ensureFrontmostForPost(type: keyDown ? .keyDown : .keyUp, poster: poster, dryRun: dryRun)
        _ = try poster.post(event, type: keyDown ? .keyDown : .keyUp, frontmost: FocusController.isFrontmost(app: target.app))
        return record(type: keyDown ? "keyDown" : "keyUp", key: nil, virtualKey: 0)
    }

    private func postMouse(type: CGEventType, location: CGPoint, button: CGMouseButton, poster: EventPoster, dryRun: Bool) throws -> InjectedEvent {
        if dryRun {
            return record(type: eventName(for: type), location: location)
        }
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: button) else {
            throw ActionExecutionError.eventCreationFailed(eventTypeDescription(type))
        }
        try ensureFrontmostForPost(type: type, poster: poster, dryRun: dryRun)
        _ = try poster.post(event, type: type, frontmost: FocusController.isFrontmost(app: target.app))
        return record(type: eventName(for: type), location: location)
    }

    private func postKey(
        keyCode: CGKeyCode,
        keyDown: Bool,
        recordedKey: String?,
        poster: EventPoster,
        dryRun: Bool,
        flags: CGEventFlags = []
    ) throws -> InjectedEvent {
        if dryRun {
            return record(type: keyDown ? "keyDown" : "keyUp", key: recordedKey, virtualKey: keyCode)
        }
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown) else {
            throw ActionExecutionError.eventCreationFailed("keyCode=\(keyCode)")
        }
        event.flags = flags
        try ensureFrontmostForPost(type: keyDown ? .keyDown : .keyUp, poster: poster, dryRun: dryRun)
        _ = try poster.post(event, type: keyDown ? .keyDown : .keyUp, frontmost: FocusController.isFrontmost(app: target.app))
        return record(type: keyDown ? "keyDown" : "keyUp", key: recordedKey, virtualKey: keyCode)
    }

    private func ensureFrontmostForPost(type: CGEventType, poster: EventPoster, dryRun: Bool) throws {
        guard !dryRun else {
            return
        }

        switch poster.mode {
        case .global:
            guard FocusController.ensureFrontmost(app: target.app, timeout: 1.2) else {
                throw PosterError.notFrontmost
            }
        case .auto:
            guard !EventPoster.isPidSafe(type) else {
                return
            }
            guard FocusController.ensureFrontmost(app: target.app, timeout: 1.2) else {
                throw PosterError.notFrontmost
            }
        case .pid:
            return
        }
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
        deadline: ActionDeadline,
        rng: inout SystemRandomNumberGenerator,
        correctionBudget: Int = 2
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
        var lastPlannedPoint = start
        for (index, point) in path.enumerated() {
            try deadline.assertNotExpired()
            if correctionBudget > 0,
               index > 0,
               shouldMonitorPhysicalCursor(dryRun: dryRun) {
                let actual = currentMouseLocation(fallback: lastPlannedPoint)
                if distance(actual, lastPlannedPoint) > cursorInterferenceTolerancePx {
                    emitted.append(contentsOf: try emitMovePath(
                        from: actual,
                        to: end,
                        style: style,
                        durationMs: nil,
                        motionProfile: motionProfile,
                        button: button,
                        poster: poster,
                        dryRun: dryRun,
                        deadline: deadline,
                        rng: &rng,
                        correctionBudget: correctionBudget - 1
                    ))
                    return emitted
                }
            } else if correctionBudget == 0,
                      index > 0,
                      shouldMonitorPhysicalCursor(dryRun: dryRun),
                      distance(currentMouseLocation(fallback: lastPlannedPoint), lastPlannedPoint) > cursorInterferenceTolerancePx {
                throw ActionExecutionError.cursorInterference
            }
            emitted.append(try postMouse(type: .mouseMoved, location: point, button: button, poster: poster, dryRun: dryRun))
            lastPlannedPoint = point
            if index < path.count - 1, timing.delaysMs.indices.contains(index), timing.delaysMs[index] > 0 {
                try sleep(milliseconds: timing.delaysMs[index], dryRun: dryRun, deadline: deadline)
            }
        }
        if shouldMonitorPhysicalCursor(dryRun: dryRun) {
            let actual = currentMouseLocation(fallback: end)
            if correctionBudget > 0, distance(actual, end) > terminalPointerTolerancePx {
                emitted.append(contentsOf: try emitMovePath(
                    from: actual,
                    to: end,
                    style: style,
                    durationMs: nil,
                    motionProfile: motionProfile,
                    button: button,
                    poster: poster,
                    dryRun: dryRun,
                    deadline: deadline,
                    rng: &rng,
                    correctionBudget: correctionBudget - 1
                ))
            } else if correctionBudget == 0, distance(actual, end) > terminalPointerTolerancePx {
                throw ActionExecutionError.cursorInterference
            }
        }
        return emitted
    }

    private func ensurePointerAtTarget(
        _ targetPoint: CGPoint,
        style: TrajectoryStyle,
        motionProfile: MotionProfile?,
        button: CGMouseButton,
        poster: EventPoster,
        dryRun: Bool,
        deadline: ActionDeadline,
        rng: inout SystemRandomNumberGenerator
    ) throws -> [InjectedEvent] {
        guard shouldMonitorPhysicalCursor(dryRun: dryRun) else {
            return []
        }
        let actual = currentMouseLocation(fallback: targetPoint)
        guard distance(actual, targetPoint) > terminalPointerTolerancePx else {
            return []
        }
        return try emitMovePath(
            from: actual,
            to: targetPoint,
            style: style,
            durationMs: nil,
            motionProfile: motionProfile,
            button: button,
            poster: poster,
            dryRun: dryRun,
            deadline: deadline,
            rng: &rng,
            correctionBudget: 1
        )
    }

    private func implicitPointerTravelDurationMs(options: ActionOptions, holdMs: Int, settleMs: Int) -> Int {
        let fallback = 650
        guard let timeoutMs = options.timeoutMs, timeoutMs > 0 else {
            return fallback
        }
        let reservedMs = max(800, holdMs + settleMs + 700)
        return min(fallback, max(120, timeoutMs - reservedMs))
    }

    private func sleep(milliseconds: Int, dryRun: Bool, deadline: ActionDeadline) throws {
        guard milliseconds > 0 else {
            try deadline.assertNotExpired()
            return
        }
        if dryRun {
            activeDryRunTimestamp = (activeDryRunTimestamp ?? Date()).addingTimeInterval(TimeInterval(milliseconds) / 1000.0)
            try deadline.assertNotExpired()
            return
        }
        try deadline.assertCanSpend(milliseconds: milliseconds)
        var remaining = milliseconds
        while remaining > 0 {
            try checkCancelled()
            try deadline.assertNotExpired()
            let chunk = min(remaining, 50)
            FocusController.sleep(milliseconds: chunk)
            remaining -= chunk
        }
    }

    private func record(type: String, location: CGPoint? = nil, key: String? = nil, virtualKey: CGKeyCode? = nil) -> InjectedEvent {
        let event = InjectedEvent(
            type: type,
            location: location.map { CodablePoint(x: $0.x, y: $0.y) },
            key: key,
            virtualKey: virtualKey,
            timestamp: isoFormatter.string(from: activeDryRunTimestamp ?? Date())
        )
        if let context = activeVisualContext {
            eventSink?.hidActionDidRecord(event, context: context)
        }
        return event
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
        let count = effectivePointCount(from: start, to: end, requested: pointCount, motionProfile: motionProfile)
        if let learned = learnedSkeletonPath(from: start, to: end, count: count, motionProfile: motionProfile, rng: &rng) {
            return learned
        }
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

    private func effectivePointCount(from start: CGPoint, to end: CGPoint, requested: Int, motionProfile: MotionProfile?) -> Int {
        let requested = max(requested, 1)
        guard let skeleton = motionProfile?.pathSkeleton, skeleton.count >= 2 else {
            return requested
        }
        let distance = hypot(end.x - start.x, end.y - start.y)
        let densityCount = Int((distance / 10.0).rounded(.up))
        let skeletonCount = skeleton.count * 6
        return min(max(requested, densityCount, skeletonCount, 18), 96)
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

    private func learnedSkeletonPath(
        from start: CGPoint,
        to end: CGPoint,
        count: Int,
        motionProfile: MotionProfile?,
        rng: inout SystemRandomNumberGenerator
    ) -> [CGPoint]? {
        guard let skeleton = motionProfile?.pathSkeleton, skeleton.count >= 2, count >= 2 else {
            return nil
        }
        let sourceStart = skeleton[0].cgPoint
        let sourceEnd = skeleton[skeleton.count - 1].cgPoint
        let sourceDx = sourceEnd.x - sourceStart.x
        let sourceDy = sourceEnd.y - sourceStart.y
        let sourceDistance = max(hypot(sourceDx, sourceDy), 1)
        let targetDx = end.x - start.x
        let targetDy = end.y - start.y
        let targetDistance = hypot(targetDx, targetDy)
        guard targetDistance > 4 else {
            return nil
        }

        let sourceUnit = CGPoint(x: sourceDx / sourceDistance, y: sourceDy / sourceDistance)
        let sourceNormal = CGPoint(x: -sourceUnit.y, y: sourceUnit.x)
        let targetUnit = CGPoint(x: targetDx / targetDistance, y: targetDy / targetDistance)
        let targetNormal = CGPoint(x: -targetUnit.y, y: targetUnit.x)
        let sideScale = min(max(targetDistance / sourceDistance, 0.35), 2.8)
        let jitterLimit = min(max(targetDistance * 0.018, 0.8), 7.0)

        let mapped = skeleton.enumerated().map { index, point -> CGPoint in
            if index == 0 {
                return start
            }
            if index == skeleton.count - 1 {
                return end
            }
            let original = point.cgPoint
            let rel = CGPoint(x: original.x - sourceStart.x, y: original.y - sourceStart.y)
            let progress = min(max((rel.x * sourceUnit.x + rel.y * sourceUnit.y) / sourceDistance, 0), 1)
            let side = (rel.x * sourceNormal.x + rel.y * sourceNormal.y) * sideScale
            let jitter = rng.nextDouble(in: -jitterLimit..<jitterLimit)
            let longitudinalJitter = rng.nextDouble(in: -jitterLimit * 0.35..<jitterLimit * 0.35)
            return CGPoint(
                x: start.x + targetDx * progress + targetUnit.x * longitudinalJitter + targetNormal.x * (side + jitter),
                y: start.y + targetDy * progress + targetUnit.y * longitudinalJitter + targetNormal.y * (side + jitter)
            )
        }
        var smoothed = catmullRomPath(points: mapped, count: count)
        smoothed = lightSmooth(points: smoothed, passes: 2)
        smoothed[0] = start
        smoothed[smoothed.count - 1] = end
        return smoothed
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

    private func resolvedLandingPoint(
        base: CGPoint,
        profile: PrimitiveProfile?,
        rng: inout SystemRandomNumberGenerator
    ) -> CGPoint {
        guard let zone = profile?.landingZone else {
            return base
        }

        let center = zone.center ?? base
        if let radius = zone.radius, radius > 0 {
            let angle = rng.nextDouble(in: 0..<(Double.pi * 2))
            let distance = sqrt(rng.nextDouble(in: 0..<1)) * radius
            return CGPoint(
                x: center.x + CGFloat(cos(angle) * distance),
                y: center.y + CGFloat(sin(angle) * distance)
            )
        }

        if let width = zone.width, let height = zone.height, width > 0, height > 0 {
            return CGPoint(
                x: center.x + CGFloat(rng.nextDouble(in: (-(width / 2))..<(width / 2))),
                y: center.y + CGFloat(rng.nextDouble(in: (-(height / 2))..<(height / 2)))
            )
        }

        return center
    }

    private func pointCount(durationMs: Int?, fallback: Int) -> Int {
        guard let durationMs else {
            return fallback
        }
        return max(1, Int((Double(durationMs) / 28.0).rounded()))
    }

    private func resample(points: [CGPoint], count: Int) -> [CGPoint] {
        guard count > 0 else {
            return []
        }
        guard count > 1, points.count > 1 else {
            return [points.last ?? .zero]
        }
        var distances = [Double](repeating: 0, count: points.count)
        for index in 1..<points.count {
            distances[index] = distances[index - 1] + hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y)
        }
        guard let totalDistance = distances.last, totalDistance > 0 else {
            return Array(repeating: points.last ?? .zero, count: count)
        }
        return (0..<count).map { outputIndex in
            let targetDistance = totalDistance * Double(outputIndex) / Double(count - 1)
            var segmentIndex = 1
            while segmentIndex < distances.count && distances[segmentIndex] < targetDistance {
                segmentIndex += 1
            }
            if segmentIndex >= points.count {
                return points[points.count - 1]
            }
            let previousDistance = distances[segmentIndex - 1]
            let nextDistance = distances[segmentIndex]
            let span = max(nextDistance - previousDistance, Double.ulpOfOne)
            let progress = (targetDistance - previousDistance) / span
            let start = points[segmentIndex - 1]
            let end = points[segmentIndex]
            return CGPoint(
                x: start.x + (end.x - start.x) * progress,
                y: start.y + (end.y - start.y) * progress
            )
        }
    }

    private func catmullRomPath(points: [CGPoint], count: Int) -> [CGPoint] {
        guard count > 1, points.count > 1 else {
            return points
        }
        let samplesPerSegment = max(3, Int(ceil(Double(count - 1) / Double(points.count - 1))))
        var output = [CGPoint]()
        output.reserveCapacity((points.count - 1) * samplesPerSegment + 1)
        for segment in 0..<(points.count - 1) {
            let p0 = points[max(0, segment - 1)]
            let p1 = points[segment]
            let p2 = points[segment + 1]
            let p3 = points[min(points.count - 1, segment + 2)]
            for step in 0..<samplesPerSegment {
                if segment > 0 || step > 0 {
                    let t = CGFloat(step) / CGFloat(samplesPerSegment)
                    output.append(catmullRom(p0: p0, p1: p1, p2: p2, p3: p3, t: t))
                } else {
                    output.append(p1)
                }
            }
        }
        output.append(points[points.count - 1])
        return resample(points: output, count: count)
    }

    private func catmullRom(p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint, t: CGFloat) -> CGPoint {
        let t2 = t * t
        let t3 = t2 * t
        let x0 = 2 * p1.x
        let x1 = (-p0.x + p2.x) * t
        let x2 = (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2
        let x3 = (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3
        let y0 = 2 * p1.y
        let y1 = (-p0.y + p2.y) * t
        let y2 = (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2
        let y3 = (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3
        return CGPoint(x: 0.5 * (x0 + x1 + x2 + x3), y: 0.5 * (y0 + y1 + y2 + y3))
    }

    private func lightSmooth(points: [CGPoint], passes: Int) -> [CGPoint] {
        guard points.count > 4, passes > 0 else {
            return points
        }
        var current = points
        for _ in 0..<passes {
            var next = current
            for index in 1..<(current.count - 1) {
                next[index] = CGPoint(
                    x: current[index].x * 0.50 + (current[index - 1].x + current[index + 1].x) * 0.25,
                    y: current[index].y * 0.50 + (current[index - 1].y + current[index + 1].y) * 0.25
                )
            }
            current = next
        }
        return current
    }

    private func currentMouseLocation(fallback: CGPoint) -> CGPoint {
        if let cursorLocationProvider {
            return cursorLocationProvider() ?? fallback
        }
        return CGEvent(source: nil)?.location ?? fallback
    }

    private func shouldMonitorPhysicalCursor(dryRun: Bool) -> Bool {
        !dryRun || cursorLocationProvider != nil
    }

    private func needsCursorTravel(from start: CGPoint, to end: CGPoint) -> Bool {
        distance(start, end) > 2
    }

    private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
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

    private func actionMotionProfile(_ primitiveProfile: MotionProfile?, options: ActionOptions) -> MotionProfile? {
        options.rhythmProfile?.merging(primitiveProfile) ?? primitiveProfile
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
        if let dwellMs = motionProfile.dwellMs {
            params.dwellMsRange = max(12, dwellMs.min)...max(12, dwellMs.max)
        } else if let dwellMsMean = motionProfile.dwellMsMean {
            let lower = max(24, Int((dwellMsMean * 0.68).rounded()))
            let upper = max(lower + 8, Int((dwellMsMean * 1.36).rounded()))
            params.dwellMsRange = lower...upper
        }
        if let interKeyMs = motionProfile.interKeyMs {
            let intra = max(16, Double((interKeyMs.min + interKeyMs.max) / 2))
            params.intraWordMu = log(intra)
            params.interWordMu = log(max(intra * 1.45, intra + 24))
            params.intraWordSigma = 0.16
            params.interWordSigma = 0.20
        } else if let interKeyMsMean = motionProfile.interKeyMsMean {
            let intra = max(26, interKeyMsMean)
            params.intraWordMu = log(intra)
            params.interWordMu = log(max(intra * 1.45, intra + 32))
            params.intraWordSigma = 0.28
            params.interWordSigma = 0.34
        }
        return params
    }

    private struct ChineseInputSource {
        let id: String
        let name: String
    }

    private func currentChineseInputSource() -> ChineseInputSource? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        let id = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
            .map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
        let name = TISGetInputSourceProperty(source, kTISPropertyLocalizedName)
            .map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
        let languages = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages)
            .map { Unmanaged<CFArray>.fromOpaque($0).takeUnretainedValue() as? [String] }
            ?? nil
        let isChinese = languages?.contains(where: { $0.lowercased().hasPrefix("zh") }) == true
            || id?.lowercased().contains("chinese") == true
            || id?.lowercased().contains("pinyin") == true
            || id?.lowercased().contains("scim") == true
        guard isChinese else {
            return nil
        }
        return ChineseInputSource(id: id ?? "unknown", name: name ?? "unknown")
    }

    private func containsChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
                || (0x20000...0x2A6DF).contains(scalar.value)
        }
    }

    private func chunkText(_ text: String, maxScalars: Int) -> [String] {
        guard maxScalars > 0 else {
            return [text]
        }
        var chunks = [String]()
        var current = ""
        var count = 0
        for scalar in text.unicodeScalars {
            if count >= maxScalars {
                chunks.append(current)
                current = ""
                count = 0
            }
            current.unicodeScalars.append(scalar)
            count += 1
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
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
        case .pasteText:
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

private extension LearnedPathPoint {
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
