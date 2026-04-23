import AppKit
import CoreGraphics
import Foundation
import HumanizationKit
import InjectorCore
import ProfileStore
import Supervisor

#if canImport(IOKit)
import IOKit.hid
#endif

public struct ControlServerConfiguration {
    public let bundleIdentifiers: [String]
    public let defaultPostMode: PostMode
    public let allowSelfTarget: Bool

    public init(
        bundleIdentifiers: [String] = ["com.google.Chrome", "org.chromium.Chromium", "com.microsoft.edgemac"],
        defaultPostMode: PostMode = .global,
        allowSelfTarget: Bool = false
    ) {
        self.bundleIdentifiers = bundleIdentifiers
        self.defaultPostMode = defaultPostMode
        self.allowSelfTarget = allowSelfTarget
    }
}

public enum ControlServerError: Error, LocalizedError {
    case coded(String, String)

    public var errorDescription: String? {
        switch self {
        case .coded(_, let message):
            return message
        }
    }

    public var code: String {
        switch self {
        case .coded(let code, _):
            return code
        }
    }
}

public final class ControlService {
    private let configuration: ControlServerConfiguration
    private let supervisor: SupervisorService
    private let profileStore: ProfileStore
    private let actionQueue = DispatchQueue(label: "com.vyodels.virtualhid.control.actions")
    private let lock = NSLock()
    private let isoFormatter: ISO8601DateFormatter
    private var currentExecutor: ActionExecutor?
    private var lastAction: [String: Any]?
    private var lastPostUsed: String?

    public init(
        configuration: ControlServerConfiguration,
        supervisor: SupervisorService,
        profileStore: ProfileStore
    ) {
        self.configuration = configuration
        self.supervisor = supervisor
        self.profileStore = profileStore
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoFormatter = formatter
        self.supervisor.killSwitch.onTrigger = { [weak self] in
            self?.cancelCurrentAction()
        }
    }

    public func handleLine(_ line: String) -> String {
        do {
            let request = try parseRequest(line)
            let result = try handle(method: request.method, params: request.params)
            return encodeResponse(id: request.id, ok: true, result: result, error: nil)
        } catch let error as WireRequestError {
            return encodeResponse(id: error.id, ok: false, result: nil, error: (error.code, error.message))
        } catch let error as ControlServerError {
            return encodeResponse(id: nil, ok: false, result: nil, error: (error.code, error.localizedDescription))
        } catch {
            return encodeResponse(id: nil, ok: false, result: nil, error: ("E_UNKNOWN", error.localizedDescription))
        }
    }

    public func snapshot() -> [String: Any] {
        let target = snapshotTarget()
        let cursor = CGEvent(source: nil)?.location ?? .zero
        let modifiers = supervisor.modifierSnapshot()
        let killSwitch = supervisor.killSwitch
        let supervisorSnapshot = supervisor.snapshot()
        let totalTemplates = (try? profileStore.totalTemplates()) ?? 0
        let lastLearnedAt = (try? profileStore.lastLearnedAtMs()).flatMap { $0.map(isoString(ms:)) } ?? nil

        return [
            "version": "0.2.0",
            "busy": lock.withLock { currentExecutor?.isBusy ?? false },
            "lastAction": lock.withLock { lastAction as Any? ?? NSNull() },
            "cursor": [
                "x": Double(cursor.x),
                "y": Double(cursor.y),
                "screenIndex": 0
            ],
            "modifiers": [
                "shift": modifiers.shift,
                "cmd": modifiers.cmd,
                "opt": modifiers.opt,
                "ctrl": modifiers.ctrl,
                "fn": modifiers.fn,
                "stuck": modifiers.stuck
            ],
            "killSwitch": [
                "active": killSwitch.isActive,
                "triggeredAt": killSwitch.triggeredAt.map { isoFormatter.string(from: $0) } as Any? ?? NSNull(),
                "unlockable": true
            ],
            "supervisor": [
                "online": supervisorSnapshot.online,
                "observing": supervisorSnapshot.observing,
                "observingHost": supervisorSnapshot.observingHost as Any? ?? NSNull()
            ],
            "permissions": [
                "accessibility": EventTap.isAccessibilityTrusted(prompt: false),
                "inputMonitoring": inputMonitoringGranted()
            ],
            "targetApp": target,
            "post": [
                "default": configuration.defaultPostMode.rawValue,
                "lastUsed": lock.withLock { lastPostUsed as Any? ?? NSNull() },
                "available": ["global", "pid", "auto"]
            ],
            "profiles": [
                "totalTemplates": totalTemplates,
                "lastLearnedAt": lastLearnedAt as Any? ?? NSNull()
            ]
        ]
    }

    private func handle(method: String, params: [String: Any]) throws -> [String: Any] {
        switch method {
        case "state":
            return snapshot()
        case "action":
            return try handleAction(params)
        case "stop":
            cancelCurrentAction()
            return ["stopped": true]
        case "unlock":
            supervisor.killSwitch.unlock()
            return ["killSwitch": ["active": false]]
        case "observe":
            return try handleObserve(params)
        case "profiles.list":
            return try handleProfilesList(params)
        case "profiles.get":
            return try handleProfilesGet(params)
        case "profiles.forget":
            return try handleProfilesForget(params)
        case "profiles.rebuild":
            return try handleProfilesRebuild(params)
        case "trace.tail":
            return handleTraceTail(params)
        case "trace.commit":
            return try handleTraceCommit(params)
        default:
            throw ControlServerError.coded("E_UNKNOWN", "unknown method \(method)")
        }
    }

    private func handleAction(_ params: [String: Any]) throws -> [String: Any] {
        try actionQueue.sync {
            try performAction(params)
        }
    }

    private func performAction(_ params: [String: Any]) throws -> [String: Any] {
        guard !supervisor.killSwitch.isActive else {
            let triggeredAt = supervisor.killSwitch.triggeredAt.map { isoFormatter.string(from: $0) } ?? "unknown"
            throw ControlServerError.coded("E_KILL_SWITCH", "user triggered kill switch at \(triggeredAt)")
        }

        guard let contextObject = params["context"] as? [String: Any] else {
            throw ControlServerError.coded("E_CONTEXT_REQUIRED", "missing required field context.host")
        }
        let context = try parseActionContext(contextObject)
        let actionId = params["id"] as? String ?? UUID().uuidString
        let primitives = try parsePrimitives(params["primitives"] as? [[String: Any]])
        let options = parseOptions(params["options"] as? [String: Any])
        let target = try resolveTarget()
        let requestedMode = options.postMode ?? configuration.defaultPostMode
        let usedMode = inferredPostRoute(for: primitives, requestedMode: requestedMode).rawValue
        let profileResult = applyProfiles(to: primitives, context: context)
        let executor = ActionExecutor(target: target, defaultPostMode: configuration.defaultPostMode)

        lock.withLock {
            currentExecutor = executor
        }
        defer {
            lock.withLock {
                currentExecutor = nil
            }
        }

        do {
            let request = ActionRequest(
                id: actionId,
                primitives: profileResult.primitives,
                context: context,
                options: options
            )
            let result = try executor.execute(request)
            let response = try resultObject(result)
            lock.withLock {
                lastPostUsed = usedMode
                lastAction = [
                    "id": result.id,
                    "finishedAt": isoFormatter.string(from: Date()),
                    "ok": result.ok,
                    "error": result.error ?? NSNull(),
                    "elapsedMs": result.elapsedMs
                ]
            }
            var enriched = response
            enriched["post"] = ["used": usedMode]
            enriched["profiles"] = [
                "applied": profileResult.applied,
                "templateIds": profileResult.templateIds
            ]
            return enriched
        } catch {
            let mapped = mapError(error)
            lock.withLock {
                lastAction = [
                    "id": actionId,
                    "finishedAt": isoFormatter.string(from: Date()),
                    "ok": false,
                    "error": mapped.0,
                    "elapsedMs": 0
                ]
            }
            throw ControlServerError.coded(mapped.0, mapped.1)
        }
    }

    private func handleObserve(_ params: [String: Any]) throws -> [String: Any] {
        let enable = params["enable"] as? Bool ?? false
        if enable {
            guard let host = params["host"] as? String, !host.isEmpty else {
                throw ControlServerError.coded("E_CONTEXT_REQUIRED", "observe enable requires host")
            }
            try supervisor.observer.enable(host: host, taskId: params["taskId"] as? String)
        } else {
            supervisor.observer.disable()
        }
        let state = supervisor.snapshot()
        return [
            "observing": state.observing,
            "observingHost": state.observingHost ?? NSNull()
        ]
    }

    private func handleProfilesList(_ params: [String: Any]) throws -> [String: Any] {
        let templates = try profileStore.listTemplates(host: params["host"] as? String)
        return ["templates": try templates.map(templateObject)]
    }

    private func handleProfilesGet(_ params: [String: Any]) throws -> [String: Any] {
        guard let host = params["host"] as? String, let sig = params["sig"] as? String else {
            throw ControlServerError.coded("E_CONTEXT_REQUIRED", "profiles.get requires host and sig")
        }
        do {
            return ["template": try templateObject(profileStore.getTemplate(host: host, sig: sig))]
        } catch ProfileStoreError.notFound {
            throw ControlServerError.coded("E_PROFILE_MISS", "no template for host=\(host) sig=\(sig)")
        }
    }

    private func handleProfilesForget(_ params: [String: Any]) throws -> [String: Any] {
        let deleted = try profileStore.forget(host: params["host"] as? String, sig: params["sig"] as? String)
        return ["deleted": deleted]
    }

    private func handleProfilesRebuild(_ params: [String: Any]) throws -> [String: Any] {
        let report = try profileStore.rebuild(host: params["host"] as? String)
        return [
            "scannedTraces": report.scannedTraces,
            "generatedTemplates": report.generatedTemplates,
            "updatedTemplates": report.updatedTemplates
        ]
    }

    private func handleTraceTail(_ params: [String: Any]) -> [String: Any] {
        let limit = (params["n"] as? Int) ?? 50
        let events = supervisor.observer.tail(sinceEventId: params["sinceEventId"] as? String, limit: limit)
        return ["events": events.map(observedEventObject)]
    }

    private func handleTraceCommit(_ params: [String: Any]) throws -> [String: Any] {
        let eventId = (params["eventId"] as? String) ?? (params["event_id"] as? String)
        let elementSig = (params["elementSig"] as? String) ?? (params["element_sig"] as? String)
        guard let eventId, let elementSig, let host = params["host"] as? String else {
            throw ControlServerError.coded("E_CONTEXT_REQUIRED", "trace.commit requires eventId, elementSig, and host")
        }

        let observed = supervisor.observer.event(id: eventId)
        let payloadOverride = parseTracePayload(
            eventId: eventId,
            eventType: observed?.type ?? (params["actionType"] as? String) ?? "click",
            params: params,
            observed: observed
        )
        let point = payloadOverride?.point
            ?? observed?.point.map { TracePoint(x: $0.x, y: $0.y) }
            ?? parseOptionalPoint(params["point"] as? [String: Any])
        let keyCode = observed?.keyCode ?? UInt16(number(params["keyCode"]) ?? 0)
        let eventType = observed?.type ?? (params["actionType"] as? String) ?? "click"
        let ts = observed?.ts ?? Int64(Date().timeIntervalSince1970 * 1000)
        let result = try profileStore.commitObservedEvent(
            eventId: eventId,
            eventType: eventType,
            ts: ts,
            point: point,
            keyCode: keyCode == 0 ? nil : keyCode,
            elementSig: elementSig,
            role: params["role"] as? String,
            host: host,
            taskId: (params["taskId"] as? String) ?? (params["task_id"] as? String),
            stage: params["stage"] as? String,
            actionTypeOverride: params["traceType"] as? String,
            payloadOverride: payloadOverride
        )
        return [
            "committed": result.committed,
            "dropped": result.dropped,
            "traceId": result.traceId ?? NSNull(),
            "reason": result.reason ?? NSNull()
        ]
    }

    private func cancelCurrentAction() {
        lock.withLock {
            currentExecutor?.cancel()
        }
    }

    private func resolveTarget() throws -> BrowserTarget {
        if configuration.allowSelfTarget {
            return selfTarget()
        }
        do {
            return try BrowserResolver.resolve(bundleIdentifiers: configuration.bundleIdentifiers)
        } catch BrowserResolverError.permissionDenied {
            throw ControlServerError.coded("E_PERMISSION", "accessibility permission missing")
        } catch {
            throw ControlServerError.coded("E_NO_TARGET", error.localizedDescription)
        }
    }

    private func snapshotTarget() -> [String: Any] {
        if configuration.allowSelfTarget {
            let target = selfTarget()
            return [
                "bundleId": target.bundleIdentifier,
                "pid": Int(target.pid),
                "frontmost": FocusController.isFrontmost(app: target.app),
                "windowTitle": target.windowTitle ?? NSNull()
            ]
        }

        for bundleId in configuration.bundleIdentifiers {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
                .filter { !$0.isTerminated }
            if let app = apps.first {
                return [
                    "bundleId": bundleId,
                    "pid": Int(app.processIdentifier),
                    "frontmost": FocusController.isFrontmost(app: app),
                    "windowTitle": NSNull()
                ]
            }
        }

        return [
            "bundleId": configuration.bundleIdentifiers.first ?? NSNull(),
            "pid": NSNull(),
            "frontmost": false,
            "windowTitle": NSNull()
        ]
    }

    private func selfTarget() -> BrowserTarget {
        let app = NSRunningApplication.current
        return BrowserTarget(
            app: app,
            pid: app.processIdentifier,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.vyodels.virtualhid.daemon",
            windowTitle: nil,
            frame: NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        )
    }

    private func parseActionContext(_ object: [String: Any]) throws -> ActionContext {
        guard let host = object["host"] as? String, !host.isEmpty else {
            throw ControlServerError.coded("E_CONTEXT_REQUIRED", "missing required field context.host")
        }
        let elementObject = object["element"] as? [String: Any]
        let hintsObject = object["hints"] as? [String: Any]
        return ActionContext(
            host: host,
            element: ActionContext.Element(
                sig: elementObject?["sig"] as? String,
                role: elementObject?["role"] as? String
            ),
            taskId: object["taskId"] as? String,
            stage: object["stage"] as? String,
            hints: ActionContext.Hints(urgency: hintsObject?["urgency"] as? String)
        )
    }

    private func parseOptions(_ object: [String: Any]?) -> ActionOptions {
        guard let object else {
            return ActionOptions(postMode: configuration.defaultPostMode)
        }
        let postMode = (object["postMode"] as? String).flatMap(PostMode.init(rawValue:))
        return ActionOptions(
            postMode: postMode,
            timeoutMs: intValue(object["timeoutMs"]),
            dryRun: object["dryRun"] as? Bool ?? false
        )
    }

    private func parsePrimitives(_ array: [[String: Any]]?) throws -> [ActionPrimitive] {
        guard let array, !array.isEmpty else {
            throw ControlServerError.coded("E_CONTEXT_REQUIRED", "action requires primitives")
        }

        return try array.map { primitive in
            guard let type = primitive["type"] as? String else {
                throw ControlServerError.coded("E_UNKNOWN", "primitive.type is required")
            }
            try assertFixedPointOnlyPayload(primitive)
            let profile = try primitiveProfile(from: primitive)
            switch type {
            case "move":
                return .move(
                    to: try point(primitive["to"] as? [String: Any], name: "to"),
                    via: try trajectoryStyle(primitive["via"], fallbackMotionProfile: profile?.motionProfile),
                    durationMs: intValue(primitive["durationMs"]),
                    profile: profile
                )
            case "click":
                return .click(
                    at: try point(primitive["at"] as? [String: Any], name: "at"),
                    button: mouseButton(primitive["button"] as? String),
                    holdMs: intValue(primitive["holdMs"]),
                    count: intValue(primitive["count"]) ?? 1,
                    profile: profile
                )
            case "drag":
                return .drag(
                    from: try point(primitive["from"] as? [String: Any], name: "from"),
                    to: try point(primitive["to"] as? [String: Any], name: "to"),
                    button: mouseButton(primitive["button"] as? String),
                    via: try trajectoryStyle(primitive["via"], fallbackMotionProfile: profile?.motionProfile),
                    profile: profile
                )
            case "scroll":
                return .scroll(
                    at: try point(primitive["at"] as? [String: Any], name: "at"),
                    dx: number(primitive["dx"]) ?? 0,
                    dy: number(primitive["dy"]) ?? 0,
                    style: scrollStyle(primitive["style"] as? String)
                )
            case "type":
                return .type(
                    text: primitive["text"] as? String ?? "",
                    layout: KeyboardLayout(rawValue: primitive["layout"] as? String ?? "us") ?? .us,
                    profile: profile
                )
            case "key":
                let keyCode = UInt16(number(primitive["keyCode"]) ?? number(primitive["virtualKey"]) ?? 0)
                return .key(
                    chord: KeyChord(keyCode: keyCode),
                    holdMs: intValue(primitive["holdMs"]),
                    profile: profile
                )
            default:
                throw ControlServerError.coded("E_UNKNOWN", "unsupported primitive type \(type)")
            }
        }
    }

    private func applyProfiles(to primitives: [ActionPrimitive], context: ActionContext) -> (primitives: [ActionPrimitive], applied: Bool, templateIds: [String]) {
        guard let sig = context.element?.sig else {
            return (primitives, false, [])
        }

        var applied = false
        var templateIds = [String]()
        let mapped = primitives.map { primitive -> ActionPrimitive in
            let actionType = profileActionType(for: primitive)
            guard let template = try? profileStore.lookupTemplate(
                host: context.host,
                sig: sig,
                taskId: context.taskId,
                actionType: actionType
            ), template.confidence >= 0.5 else {
                return primitive
            }

            let motionProfile = decodedMotionProfile(from: template)
            let reference = TemplateReference(
                id: "\(template.host):\(template.elementSig):\(template.actionType)",
                motionProfile: motionProfile
            )
            applied = true
            templateIds.append(reference.id)
            switch primitive {
            case .move(let to, _, let durationMs, let profile):
                return .move(
                    to: to,
                    via: .profile(reference),
                    durationMs: durationMs,
                    profile: profile
                )
            case .click(let at, let button, let holdMs, let count, let profile):
                return .click(
                    at: at,
                    button: button,
                    holdMs: holdMs,
                    count: count,
                    profile: mergedPrimitiveProfile(profile, motionProfile: motionProfile)
                )
            case .drag(let from, let to, let button, _, let profile):
                return .drag(
                    from: from,
                    to: to,
                    button: button,
                    via: .profile(reference),
                    profile: profile
                )
            case .type(let text, let layout, let profile):
                return .type(
                    text: text,
                    layout: layout,
                    profile: mergedPrimitiveProfile(profile, motionProfile: motionProfile)
                )
            case .key(let chord, let holdMs, let profile):
                return .key(
                    chord: chord,
                    holdMs: holdMs,
                    profile: mergedPrimitiveProfile(profile, motionProfile: motionProfile)
                )
            case .scroll:
                return primitive
            }
        }
        return (mapped, applied, templateIds)
    }

    private func profileActionType(for primitive: ActionPrimitive) -> String {
        switch primitive {
        case .click:
            return "click"
        case .drag:
            return "drag"
        case .scroll:
            return "scroll"
        case .type, .key:
            return "type"
        case .move:
            return "move"
        }
    }

    private func inferredPostRoute(for primitives: [ActionPrimitive], requestedMode: PostMode) -> PostRoute {
        switch requestedMode {
        case .global:
            return .global
        case .pid:
            return .pid
        case .auto:
            return primitives.contains { !$0.isPidSafeForControlServer } ? .global : .pid
        }
    }

    private func mapError(_ error: Error) -> (String, String) {
        if let error = error as? PosterError {
            switch error {
            case .notFrontmost:
                return ("E_NOT_FRONTMOST", "target app is not frontmost, global post mode requires it")
            case .postModeUnsupported(let type):
                return ("E_POST_MODE_UNSUPPORTED", "postMode=pid cannot deliver \(type.rawValue)")
            }
        }
        if let error = error as? ActionExecutionError {
            switch error {
            case .busy:
                return ("E_BUSY", "injector is running another action")
            case .cancelled:
                return ("E_BUSY", "injector action was cancelled")
            case .eventCreationFailed(let detail):
                return ("E_UNKNOWN", "failed to create event: \(detail)")
            }
        }
        if let error = error as? ControlServerError {
            return (error.code, error.localizedDescription)
        }
        return ("E_UNKNOWN", error.localizedDescription)
    }

    private func resultObject(_ result: ActionResult) throws -> [String: Any] {
        [
            "id": result.id,
            "ok": result.ok,
            "error": result.error ?? NSNull(),
            "events": try result.events.map(encodableObject),
            "elapsedMs": result.elapsedMs
        ]
    }

    private func templateObject(_ template: ProfileTemplate) throws -> [String: Any] {
        let paramsData = Data(template.paramsJSON.utf8)
        let params = (try? JSONSerialization.jsonObject(with: paramsData)) ?? [:]
        return [
            "host": template.host,
            "elementSig": template.elementSig,
            "taskId": template.taskId ?? NSNull(),
            "actionType": template.actionType,
            "sampleSize": template.sampleSize,
            "confidence": template.confidence,
            "params": params,
            "updatedAt": template.updatedAt
        ]
    }

    private func observedEventObject(_ event: ObservedEvent) -> [String: Any] {
        [
            "id": event.id,
            "ts": event.ts,
            "type": event.type,
            "point": event.point.map { ["x": $0.x, "y": $0.y] } ?? NSNull(),
            "keyCode": event.keyCode.map { Int($0) } ?? NSNull()
        ]
    }

    private func inputMonitoringGranted() -> Bool {
        #if canImport(IOKit)
        return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        #else
        return false
        #endif
    }

    private func isoString(ms: Int64) -> String {
        isoFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0))
    }
}

private struct WireRequest {
    let id: String
    let method: String
    let params: [String: Any]
}

private struct WireRequestError: Error {
    let id: String?
    let code: String
    let message: String
}

private func parseRequest(_ line: String) throws -> WireRequest {
    let data = Data(line.utf8)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw WireRequestError(id: nil, code: "E_UNKNOWN", message: "request must be a JSON object")
    }
    let id = object["id"] as? String
    guard let method = object["method"] as? String else {
        throw WireRequestError(id: id, code: "E_UNKNOWN", message: "method is required")
    }
    return WireRequest(id: id ?? UUID().uuidString, method: method, params: object["params"] as? [String: Any] ?? [:])
}

private func encodeResponse(id: String?, ok: Bool, result: [String: Any]?, error: (String, String)?) -> String {
    var object: [String: Any] = [
        "id": id ?? NSNull(),
        "ok": ok
    ]
    if ok {
        object["result"] = result ?? [:]
    } else if let error {
        object["error"] = [
            "code": error.0,
            "message": error.1
        ]
    }

    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
        return #"{"id":null,"ok":false,"error":{"code":"E_UNKNOWN","message":"response encoding failed"}}"#
    }
    return text
}

private func encodableObject<T: Encodable>(_ value: T) throws -> Any {
    let data = try JSONEncoder().encode(value)
    return try JSONSerialization.jsonObject(with: data)
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

private func number(_ value: Any?) -> Double? {
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

private func point(_ object: [String: Any]?, name: String) throws -> CGPoint {
    guard let object, let x = number(object["x"]), let y = number(object["y"]) else {
        throw ControlServerError.coded("E_UNKNOWN", "point \(name) requires x and y")
    }
    return CGPoint(x: x, y: y)
}

private func parseOptionalPoint(_ object: [String: Any]?) -> TracePoint? {
    guard let object, let x = number(object["x"]), let y = number(object["y"]) else {
        return nil
    }
    return TracePoint(x: x, y: y)
}

private func parseTracePayload(
    eventId: String,
    eventType: String,
    params: [String: Any],
    observed: ObservedEvent?
) -> TracePayload? {
    guard let payloadObject = params["payload"] as? [String: Any] else {
        return nil
    }

    let payloadType = payloadObject["type"] as? String ?? eventType
    let payloadPoint = observed?.point.map { TracePoint(x: $0.x, y: $0.y) }
        ?? parseOptionalPoint(payloadObject["point"] as? [String: Any])
        ?? parseOptionalPoint(params["point"] as? [String: Any])
    let payloadKeyCode = observed?.keyCode
        ?? UInt16(number(payloadObject["keyCode"]) ?? number(params["keyCode"]) ?? 0)

    return TracePayload(
        eventId: eventId,
        type: payloadType,
        point: payloadPoint,
        keyCode: payloadKeyCode == 0 ? nil : payloadKeyCode,
        points: parseTracePoints(payloadObject["points"]),
        origin: parseOptionalPoint(payloadObject["origin"] as? [String: Any]),
        targetPoint: parseOptionalPoint(payloadObject["targetPoint"] as? [String: Any]),
        targetRadiusPx: number(payloadObject["targetRadiusPx"]),
        landingErrorPx: number(payloadObject["landingErrorPx"]),
        durationMs: number(payloadObject["durationMs"]),
        segmentMs: parseDoubleArray(payloadObject["segmentMs"]),
        hesitationMs: parseDoubleArray(payloadObject["hesitationMs"]),
        clickHoldMs: parseDoubleArray(payloadObject["clickHoldMs"]),
        interClickMs: parseDoubleArray(payloadObject["interClickMs"]),
        dwellMs: parseDoubleArray(payloadObject["dwellMs"]),
        interKeyMs: parseDoubleArray(payloadObject["interKeyMs"]),
        behaviorMode: (payloadObject["behaviorMode"] as? String).flatMap(HumanBehaviorMode.init(rawValue:)),
        flavor: (payloadObject["flavor"] as? String).flatMap(MotionFlavor.init(rawValue:)),
        straightness: number(payloadObject["straightness"]),
        turnJitter: number(payloadObject["turnJitter"]),
        pathLengthPx: number(payloadObject["pathLengthPx"]),
        speedPxS: number(payloadObject["speedPxS"])
    )
}

private func parseTracePoints(_ value: Any?) -> [TracePoint] {
    guard let objects = value as? [[String: Any]] else {
        return []
    }
    return objects.compactMap(parseOptionalPoint)
}

private func parseDoubleArray(_ value: Any?) -> [Double] {
    guard let values = value as? [Any] else {
        return []
    }
    return values.compactMap(number)
}

private func mouseButton(_ rawValue: String?) -> MouseButton {
    MouseButton(rawValue: rawValue ?? "left") ?? .left
}

private func scrollStyle(_ rawValue: String?) -> ScrollStyle {
    ScrollStyle(rawValue: rawValue ?? "wheel") ?? .wheel
}

private func optionalCGPoint(_ value: Any?, name: String) throws -> CGPoint? {
    guard let value else {
        return nil
    }
    guard let object = value as? [String: Any] else {
        throw ControlServerError.coded("E_UNKNOWN", "point \(name) requires x and y")
    }
    return try point(object, name: name)
}

private func trajectoryStyle(_ rawValue: Any?, fallbackMotionProfile: MotionProfile?) throws -> TrajectoryStyle {
    if let object = rawValue as? [String: Any] {
        let style = (object["style"] as? String) ?? (object["type"] as? String) ?? (object["mode"] as? String)
        let requestMotion = try parseMotionProfile(sources: [object["motion"], object["motionProfile"], object])
        let mergedMotion = fallbackMotionProfile?.merging(requestMotion) ?? requestMotion ?? fallbackMotionProfile
        if style?.lowercased() == "profile" {
            return .profile(
                TemplateReference(
                    id: (object["templateId"] as? String) ?? (object["profileId"] as? String) ?? (object["id"] as? String) ?? "request-profile",
                    motionProfile: mergedMotion
                )
            )
        }
        return trajectoryStyle(style, fallbackMotionProfile: mergedMotion)
    }
    return trajectoryStyle(rawValue as? String, fallbackMotionProfile: fallbackMotionProfile)
}

private func trajectoryStyle(_ rawValue: String?, fallbackMotionProfile: MotionProfile?) -> TrajectoryStyle {
    switch rawValue?.lowercased() {
    case "linear":
        return .linear
    case "bezier":
        return .bezier
    case "profile":
        return .profile(TemplateReference(id: "request-profile", motionProfile: fallbackMotionProfile))
    default:
        return .wind
    }
}

private func primitiveProfile(from primitive: [String: Any]) throws -> PrimitiveProfile? {
    let profileObject = primitive["profile"] as? [String: Any]
    let origin = try optionalCGPoint(profileObject?["origin"] ?? primitive["origin"], name: "origin")
    let landingZone = try parseLandingZone(
        profileObject?["landingZone"] ?? profileObject?["landing_zone"] ?? primitive["landingZone"] ?? primitive["landing_zone"],
        fallback: [
            "center": profileObject?["landingCenter"] ?? primitive["landingCenter"],
            "width": profileObject?["landingWidth"] ?? primitive["landingWidth"],
            "height": profileObject?["landingHeight"] ?? primitive["landingHeight"],
            "radius": profileObject?["landingRadius"] ?? primitive["landingRadius"]
        ]
    )
    let motionProfile = try parseMotionProfile(
        sources: [
            primitive["via"],
            primitive["motion"],
            primitive["motionProfile"],
            primitive,
            profileObject?["motion"],
            profileObject?["motionProfile"],
            profileObject
        ]
    )
    if origin == nil, landingZone == nil, motionProfile == nil {
        return nil
    }
    return PrimitiveProfile(origin: origin, landingZone: landingZone, motionProfile: motionProfile)
}

private let fixedPointOnlyForbiddenKeys: Set<String> = [
    "region",
    "landingZone",
    "landing_zone",
    "landingCenter",
    "landing_center",
    "landingWidth",
    "landing_width",
    "landingHeight",
    "landing_height",
    "landingRadius",
    "landing_radius",
    "targetSpreadPx",
    "target_spread_px"
]

private func assertFixedPointOnlyPayload(_ value: Any?, path: String = "primitive") throws {
    guard let value else {
        return
    }
    if let object = value as? [String: Any] {
        for (key, nestedValue) in object {
            if fixedPointOnlyForbiddenKeys.contains(key) {
                throw ControlServerError.coded(
                    "E_FIXED_POINT_ONLY",
                    "VirtualHID 只接受固定落点，\(path).\(key) 必须由上游预先解析为精确点"
                )
            }
            try assertFixedPointOnlyPayload(nestedValue, path: "\(path).\(key)")
        }
        return
    }
    if let array = value as? [Any] {
        for (index, item) in array.enumerated() {
            try assertFixedPointOnlyPayload(item, path: "\(path)[\(index)]")
        }
    }
}

private func parseMotionProfile(sources: [Any?]) throws -> MotionProfile? {
    var profile: MotionProfile?
    for source in sources {
        guard let parsed = try parseMotionProfile(source) else {
            continue
        }
        profile = profile?.merging(parsed) ?? parsed
    }
    return profile
}

private func parseMotionProfile(_ value: Any?) throws -> MotionProfile? {
    guard let object = value as? [String: Any] else {
        return nil
    }
    var profile: MotionProfile?
    if let nested = object["motion"] as? [String: Any], let parsed = try parseDirectMotionProfile(nested) {
        profile = parsed
    }
    if let nested = object["motionProfile"] as? [String: Any], let parsed = try parseDirectMotionProfile(nested) {
        profile = profile?.merging(parsed) ?? parsed
    }
    if let parsed = try parseDirectMotionProfile(object) {
        profile = profile?.merging(parsed) ?? parsed
    }
    return profile
}

private func parseDirectMotionProfile(_ object: [String: Any]) throws -> MotionProfile? {
    let flavor = try parseMotionFlavor(object["flavor"] ?? object["trajectoryFlavor"])
    let behaviorBlend = try parseBehaviorBlend(
        object["behaviorBlend"] ?? object["behaviorMode"] ?? object["behavior"]
    )
    let profile = MotionProfile(
        flavor: flavor,
        behaviorBlend: behaviorBlend,
        moveSpeedPxS: try parseDoubleRange(object["moveSpeedPxS"] ?? object["speedPxS"], name: "moveSpeedPxS"),
        dragSpeedPxS: try parseDoubleRange(object["dragSpeedPxS"], name: "dragSpeedPxS"),
        pointCount: try parseIntRange(object["pointCount"], name: "pointCount"),
        overshootProbability: number(object["overshootProbability"]),
        wind: number(object["wind"]),
        gravity: number(object["gravity"]),
        maxStep: number(object["maxStep"]),
        jitter: number(object["jitter"]),
        controlSpread: number(object["controlSpread"]),
        targetSpreadPx: number(object["targetSpreadPx"]),
        hesitationProbability: number(object["hesitationProbability"]),
        hesitationMs: try parseIntRange(object["hesitationMs"], name: "hesitationMs"),
        settleMs: try parseIntRange(object["settleMs"], name: "settleMs"),
        detourProbability: number(object["detourProbability"]),
        clickHoldMs: try parseIntRange(object["clickHoldMs"], name: "clickHoldMs"),
        interClickMs: try parseIntRange(object["interClickMs"], name: "interClickMs"),
        dwellMsMean: number(object["dwellMsMean"]),
        interKeyMsMean: number(object["interKeyMsMean"]),
        straightnessMean: number(object["straightnessMean"]),
        turnJitterMean: number(object["turnJitterMean"])
    )
    if profile == MotionProfile() {
        return nil
    }
    return profile
}

private func parseMotionFlavor(_ value: Any?) throws -> MotionFlavor? {
    guard let raw = value as? String else {
        return nil
    }
    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard let flavor = MotionFlavor(rawValue: normalized) else {
        throw ControlServerError.coded("E_UNKNOWN", "unsupported motion flavor \(raw)")
    }
    return flavor
}

private func parseBehaviorBlend(_ value: Any?) throws -> BehaviorBlend? {
    if let raw = value as? String {
        guard let mode = normalizedBehaviorMode(raw) else {
            throw ControlServerError.coded("E_UNKNOWN", "unsupported behavior mode \(raw)")
        }
        return behaviorBlend(for: mode)
    }
    guard let object = value as? [String: Any] else {
        return nil
    }
    let blend = BehaviorBlend(
        idle: number(object["idle"]) ?? 0,
        normal: number(object["normal"]) ?? 0,
        flow: number(object["flow"]) ?? 0,
        lowEfficiency: number(object["lowEfficiency"]) ?? number(object["low_efficiency"]) ?? number(object["low-efficiency"]) ?? 0
    )
    return blend == BehaviorBlend(idle: 0, normal: 0, flow: 0, lowEfficiency: 0) ? nil : blend
}

private func normalizedBehaviorMode(_ raw: String) -> HumanBehaviorMode? {
    HumanBehaviorMode(
        rawValue: raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    )
}

private func behaviorBlend(for mode: HumanBehaviorMode) -> BehaviorBlend {
    switch mode {
    case .idle:
        return BehaviorBlend(idle: 1, normal: 0, flow: 0, lowEfficiency: 0)
    case .normal:
        return BehaviorBlend(idle: 0, normal: 1, flow: 0, lowEfficiency: 0)
    case .flow:
        return BehaviorBlend(idle: 0, normal: 0, flow: 1, lowEfficiency: 0)
    case .lowEfficiency:
        return BehaviorBlend(idle: 0, normal: 0, flow: 0, lowEfficiency: 1)
    }
}

private func parseDoubleRange(_ value: Any?, name: String) throws -> DoubleRange? {
    if let scalar = number(value) {
        return DoubleRange(min: scalar, max: scalar)
    }
    if let array = value as? [Any], array.count == 2,
       let first = number(array[0]),
       let second = number(array[1]) {
        return DoubleRange(min: min(first, second), max: max(first, second))
    }
    guard let object = value as? [String: Any],
          let minValue = number(object["min"] ?? object["lower"]),
          let maxValue = number(object["max"] ?? object["upper"]) else {
        if value == nil {
            return nil
        }
        throw ControlServerError.coded("E_UNKNOWN", "\(name) requires min/max")
    }
    return DoubleRange(min: Swift.min(minValue, maxValue), max: Swift.max(minValue, maxValue))
}

private func parseIntRange(_ value: Any?, name: String) throws -> IntRange? {
    if let scalar = intValue(value) {
        return IntRange(min: scalar, max: scalar)
    }
    if let array = value as? [Any], array.count == 2,
       let first = intValue(array[0]),
       let second = intValue(array[1]) {
        return IntRange(min: min(first, second), max: max(first, second))
    }
    guard let object = value as? [String: Any],
          let minValue = intValue(object["min"] ?? object["lower"]),
          let maxValue = intValue(object["max"] ?? object["upper"]) else {
        if value == nil {
            return nil
        }
        throw ControlServerError.coded("E_UNKNOWN", "\(name) requires min/max")
    }
    return IntRange(min: Swift.min(minValue, maxValue), max: Swift.max(minValue, maxValue))
}

private func parseLandingZone(_ value: Any?, fallback: [String: Any?] = [:]) throws -> LandingZone? {
    let object = value as? [String: Any]
    let center = try optionalCGPoint(object?["center"] ?? fallback["center"] ?? nil, name: "landingZone.center")
    let width = number(object?["width"] ?? object?["w"] ?? fallback["width"] ?? nil)
    let height = number(object?["height"] ?? object?["h"] ?? fallback["height"] ?? nil)
    let radius = number(object?["radius"] ?? object?["r"] ?? fallback["radius"] ?? nil)
    if center == nil, width == nil, height == nil, radius == nil {
        return nil
    }
    return LandingZone(center: center, width: width, height: height, radius: radius)
}

private func parseOptionalCGPoint(_ object: [String: Any]?) -> CGPoint? {
    guard let object, let x = number(object["x"]), let y = number(object["y"]) else {
        return nil
    }
    return CGPoint(x: x, y: y)
}

private func mergedPrimitiveProfile(_ profile: PrimitiveProfile?, motionProfile: MotionProfile?) -> PrimitiveProfile? {
    guard profile != nil || motionProfile != nil else {
        return nil
    }
    let mergedMotion = motionProfile?.merging(profile?.motionProfile) ?? profile?.motionProfile
    return PrimitiveProfile(
        origin: profile?.origin,
        landingZone: profile?.landingZone,
        motionProfile: mergedMotion
    )
}

private func decodedMotionProfile(from template: ProfileTemplate) -> MotionProfile? {
    let data = Data(template.paramsJSON.utf8)
    let decoder = JSONDecoder()
    if let learned = try? decoder.decode(LearnedMotionTemplate.self, from: data) {
        return learned.motion
    }
    if let direct = try? decoder.decode(MotionProfile.self, from: data) {
        return direct
    }
    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        return nil
    }
    return try? parseMotionProfile(sources: [object["motion"], object["motionProfile"], object])
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private extension ActionPrimitive {
    var isPidSafeForControlServer: Bool {
        switch self {
        case .move, .scroll:
            return true
        case .click, .drag, .type, .key:
            return false
        }
    }
}
