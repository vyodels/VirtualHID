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
        let point = observed?.point.map { TracePoint(x: $0.x, y: $0.y) } ?? parseOptionalPoint(params["point"] as? [String: Any])
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
            stage: params["stage"] as? String
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
            switch type {
            case "move":
                return .move(
                    to: try point(primitive["to"] as? [String: Any], name: "to"),
                    via: trajectoryStyle(primitive["via"] as? String),
                    durationMs: intValue(primitive["durationMs"])
                )
            case "click":
                return .click(
                    at: try point(primitive["at"] as? [String: Any], name: "at"),
                    button: mouseButton(primitive["button"] as? String),
                    holdMs: intValue(primitive["holdMs"]),
                    count: intValue(primitive["count"]) ?? 1
                )
            case "drag":
                return .drag(
                    from: try point(primitive["from"] as? [String: Any], name: "from"),
                    to: try point(primitive["to"] as? [String: Any], name: "to"),
                    button: mouseButton(primitive["button"] as? String),
                    via: trajectoryStyle(primitive["via"] as? String)
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
                    layout: KeyboardLayout(rawValue: primitive["layout"] as? String ?? "us") ?? .us
                )
            case "key":
                let keyCode = UInt16(number(primitive["keyCode"]) ?? number(primitive["virtualKey"]) ?? 0)
                return .key(chord: KeyChord(keyCode: keyCode), holdMs: intValue(primitive["holdMs"]))
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

            let reference = TemplateReference(id: "\(template.host):\(template.elementSig):\(template.actionType)")
            applied = true
            templateIds.append(reference.id)
            switch primitive {
            case .move(let to, _, let durationMs):
                return .move(to: to, via: .profile(reference), durationMs: durationMs)
            case .drag(let from, let to, let button, _):
                return .drag(from: from, to: to, button: button, via: .profile(reference))
            default:
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

private func trajectoryStyle(_ rawValue: String?) -> TrajectoryStyle {
    switch rawValue {
    case "linear":
        return .linear
    case "bezier":
        return .bezier
    case "profile":
        return .profile(TemplateReference(id: "request-profile"))
    default:
        return .wind
    }
}

private func mouseButton(_ rawValue: String?) -> MouseButton {
    MouseButton(rawValue: rawValue ?? "left") ?? .left
}

private func scrollStyle(_ rawValue: String?) -> ScrollStyle {
    ScrollStyle(rawValue: rawValue ?? "wheel") ?? .wheel
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
