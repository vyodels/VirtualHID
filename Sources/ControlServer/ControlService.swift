import AppKit
import ApplicationServices
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
        bundleIdentifiers: [String] = ["com.google.Chrome", "org.chromium.Chromium", "com.microsoft.edgemac", "com.apple.Safari"],
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
    private let hidEventSink: HIDEventSink?
    private let targetResolverOverride: ((TargetDescriptor?) throws -> BrowserTarget)?
    private let actionQueue = DispatchQueue(label: "com.vyodels.virtualhid.control.actions")
    private let lock = NSLock()
    private let isoFormatter: ISO8601DateFormatter
    private var currentExecutor: ActionExecutor?
    private var lastAction: [String: Any]?
    private var lastPostUsed: String?
    private var persistedLearningSamples = 0
    private static let managementLearningDemoHost = "virtualhid-management-demo.local"
    private static let managementLearningDemoBaselineHost = "virtualhid-management-demo-baseline.local"
    private static let managementLearningDemoSig = "management-learning-demo-target"
    private static let managementLearningDemoTask = "management-learning-demo"

    public init(
        configuration: ControlServerConfiguration,
        supervisor: SupervisorService,
        profileStore: ProfileStore,
        hidEventSink: HIDEventSink? = nil,
        targetResolverOverride: ((TargetDescriptor?) throws -> BrowserTarget)? = nil
    ) {
        self.configuration = configuration
        self.supervisor = supervisor
        self.profileStore = profileStore
        self.hidEventSink = hidEventSink
        self.targetResolverOverride = targetResolverOverride
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoFormatter = formatter
        self.supervisor.killSwitch.onTrigger = { [weak self] in
            self?.cancelCurrentAction()
        }
        self.supervisor.observer.learningSampleHandler = { [weak self] sample in
            self?.persistPassiveLearningSample(sample)
        }
    }

    public func handleLine(_ line: String) -> String {
        do {
            let request = try parseRequest(line)
            let result = try handle(method: request.method, params: request.params, requestId: request.id)
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
            ],
            "learning": [
                "settings": (try? encodableObject(supervisor.observer.learningState.settings)) ?? NSNull(),
                "activeSession": (try? encodableObject(supervisor.observer.learningState.activeSession)) ?? NSNull(),
                "producedSamples": supervisor.observer.learningState.producedSamples,
                "pendingTrainingSamples": supervisor.observer.learningState.pendingTrainingSamples,
                "persistedSamples": lock.withLock { persistedLearningSamples }
            ]
        ]
    }

    private func handle(method: String, params: [String: Any], requestId: String) throws -> [String: Any] {
        switch method {
        case "state":
            return snapshot()
        case "action":
            return try handleAction(params, requestId: requestId)
        case "stop":
            cancelCurrentAction()
            return ["stopped": true]
        case "unlock":
            supervisor.unlock()
            let modifiers = supervisor.modifierSnapshot()
            return [
                "killSwitch": ["active": false],
                "modifiers": [
                    "shift": modifiers.shift,
                    "cmd": modifiers.cmd,
                    "opt": modifiers.opt,
                    "ctrl": modifiers.ctrl,
                    "fn": modifiers.fn,
                    "stuck": modifiers.stuck
                ]
            ]
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
        case "profiles.apply":
            return try handleProfilesApply(params)
        case "trace.tail":
            return handleTraceTail(params)
        case "trace.commit":
            return try handleTraceCommit(params)
        case "learning.state":
            return try handleLearningState()
        case "learning.configure":
            return try handleLearningConfigure(params)
        case "learning.session.start":
            return try handleLearningSessionStart(params)
        case "learning.session.stop":
            return try handleLearningSessionStop(params)
        case "learning.demo.run":
            return try handleLearningDemoRun(params)
        case "hud.state":
            return handleHUDState()
        case "hud.configure":
            return handleHUDConfigure(params)
        default:
            throw ControlServerError.coded("E_UNKNOWN", "unknown method \(method)")
        }
    }

    private func handleHUDState() -> [String: Any] {
        guard let control = hidEventSink as? HIDVisualizationControl else {
            return [
                "available": false,
                "enabled": false,
                "lockedOff": false,
                "settings": NSNull()
            ]
        }
        return control.hidVisualizationState()
    }

    private func handleHUDConfigure(_ params: [String: Any]) -> [String: Any] {
        guard let control = hidEventSink as? HIDVisualizationControl else {
            return [
                "available": false,
                "enabled": false,
                "lockedOff": false,
                "settings": NSNull()
            ]
        }
        return control.hidVisualizationConfigure(params)
    }

    private func handleAction(_ params: [String: Any], requestId: String, allowInternalSelfTarget: Bool = false) throws -> [String: Any] {
        try actionQueue.sync {
            try performAction(params, requestId: requestId, allowInternalSelfTarget: allowInternalSelfTarget)
        }
    }

    private func performAction(_ params: [String: Any], requestId: String, allowInternalSelfTarget: Bool = false) throws -> [String: Any] {
        guard !supervisor.killSwitch.isActive else {
            let triggeredAt = supervisor.killSwitch.triggeredAt.map { isoFormatter.string(from: $0) } ?? "unknown"
            throw ControlServerError.coded("E_KILL_SWITCH", "user triggered kill switch at \(triggeredAt)")
        }

        let requestedPrimitives = try parsePrimitives(params["primitives"] as? [[String: Any]])
        let contextObject = try normalizedActionContext(params)
        let context = try parseActionContext(contextObject)
        let actionId = params["id"] as? String ?? requestId
        let targetDescriptor = try parseTargetDescriptor(params["target"] as? [String: Any])
        let geometryRequest = try parseViewportGeometry(params["geometry"] as? [String: Any])
        let target = try resolveTarget(descriptor: targetDescriptor, allowInternalSelfTarget: allowInternalSelfTarget)
        let geometryResolution: ViewportGeometryResolution?
        do {
            geometryResolution = try geometryRequest.map {
                try ViewportGeometryResolver.resolve(request: $0, target: target)
            }
        } catch {
            let mapped = mapError(error)
            throw ControlServerError.coded(mapped.0, mapped.1)
        }
        let geometry = geometryResolution?.geometry
        let planned = ExecutionPlanner.plan(
            target: targetDescriptor,
            geometry: geometry,
            primitives: requestedPrimitives
        )
        if planned.plan.requiresViewportResample {
            throw ControlServerError.coded(
                "E_VIEWPORT_RESAMPLE_REQUIRED",
                "target requires scrolling before final action; caller must resample browser viewport/scrollOffset and submit the updated target instead of executing a stale screen point"
            )
        }
        let primitives = planned.primitives
        let options = parseOptions(params["options"] as? [String: Any])
        let semanticEvidence = parseSemanticEvidence(params)
        let requestedMode = options.postMode ?? configuration.defaultPostMode
        let usedMode = inferredPostRoute(for: primitives, requestedMode: requestedMode).rawValue
        let profileResult = applyProfiles(to: primitives, context: context)
        let executor = ActionExecutor(target: target, defaultPostMode: configuration.defaultPostMode, eventSink: hidEventSink)
        let browserChromeOverlayPreflight = try handleBrowserChromeOverlayPreflight(
            target: target,
            primitives: profileResult.primitives,
            options: options
        )
        let observerStartId = supervisor.observer.tail(limit: 1).last?.id
        let observerWasEnabled = supervisor.observer.isEnabled

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
            let observedEvents = supervisor.observer.tail(sinceEventId: observerStartId, limit: 80)
            let observerEvidence = observerEvidence(
                result: result,
                observedEvents: observedEvents,
                observerEnabled: observerWasEnabled,
                dryRun: options.dryRun,
                sinceEventId: observerStartId
            )
            let evidence = OutcomeVerifier.evidence(
                result: result,
                expectedFinalPoint: expectedFinalPoint(from: profileResult.primitives),
                focusConfirmed: FocusController.isFrontmost(app: target.app),
                observerEcho: observerEvidence.status == "echoed",
                observer: observerEvidence,
                semantic: semanticEvidence,
                tolerancePx: expectedFinalTolerancePx(from: profileResult.primitives)
            )
            hidEventSink?.hidActionDidFinish(
                HIDActionVisualSummary(
                    context: visualContext(
                        actionId: actionId,
                        target: target,
                        options: options,
                        primitives: profileResult.primitives,
                        postMode: usedMode
                    ),
                    events: result.events,
                    verification: evidence
                )
            )
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
            enriched["daemonLearning"] = daemonLearningObject(
                result: result,
                context: context,
                primitives: profileResult.primitives,
                options: options,
                evidence: evidence
            )
            enriched["targetApp"] = targetEvidenceObject(target)
            enriched["plan"] = try encodableObject(planned.plan)
            if let geometryResolution {
                enriched["mapping"] = mappingObject(geometryResolution)
            }
            enriched["preflight"] = [
                "browserChromeOverlay": browserChromeOverlayPreflight.object
            ]
            enriched["verification"] = try encodableObject(evidence)
            return enriched
        } catch {
            let mapped = mapError(error)
            hidEventSink?.hidActionDidFail(actionId: actionId, errorCode: mapped.0)
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

    private func handleProfilesApply(_ params: [String: Any]) throws -> [String: Any] {
        let host = params["host"] as? String
        let elementSig = params["elementSig"] as? String ?? params["element_sig"] as? String ?? params["sig"] as? String
        let taskId = params["taskId"] as? String ?? params["task_id"] as? String
        let actionType = params["actionType"] as? String ?? params["action_type"] as? String
        guard let host, let elementSig, let actionType else {
            throw ControlServerError.coded("E_CONTEXT_REQUIRED", "profiles.apply requires host, elementSig, and actionType")
        }
        let paramsJSON: String
        if let object = params["params"] as? [String: Any] {
            let data = try JSONSerialization.data(withJSONObject: object)
            paramsJSON = String(data: data, encoding: .utf8) ?? "{}"
        } else if let raw = params["paramsJSON"] as? String ?? params["params_json"] as? String {
            paramsJSON = raw
        } else {
            throw ControlServerError.coded("E_CONTEXT_REQUIRED", "profiles.apply requires params or paramsJSON")
        }
        let template = try profileStore.applyTemplate(
            host: host,
            elementSig: elementSig,
            taskId: taskId,
            actionType: actionType,
            sampleSize: intValue(params["sampleSize"] ?? params["sample_size"]) ?? 1,
            confidence: number(params["confidence"]) ?? 0.5,
            paramsJSON: paramsJSON
        )
        return ["template": try templateObject(template)]
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

    private func handleLearningState() throws -> [String: Any] {
        var state = try encodableObject(supervisor.observer.learningState) as? [String: Any] ?? [:]
        state["persistedSamples"] = lock.withLock { persistedLearningSamples }
        state["totalTemplates"] = (try? profileStore.totalTemplates()) ?? 0
        state["traceCount"] = (try? profileStore.traceCount()) ?? 0
        state["lastLearnedAt"] = (try? profileStore.lastLearnedAtMs()).flatMap { $0.map(isoString(ms:)) } ?? NSNull()
        state["templates"] = (try? profileStore.listTemplates().prefix(8).map(learningTemplateSummaryObject)) ?? []
        return state
    }

    private func handleLearningConfigure(_ params: [String: Any]) throws -> [String: Any] {
        let mode = parsePassiveLearningMode(params["mode"])
        let state = supervisor.observer.configureLearning(
            enabled: params["enabled"] as? Bool,
            mode: mode
        )
        var object = try encodableObject(state) as? [String: Any] ?? [:]
        object["persistedSamples"] = lock.withLock { persistedLearningSamples }
        return object
    }

    private func handleLearningSessionStart(_ params: [String: Any]) throws -> [String: Any] {
        let state = supervisor.observer.startLearningSession(
            label: nonEmptyString(params["label"]),
            host: nonEmptyString(params["host"]),
            targetAction: nonEmptyString(params["targetAction"] ?? params["target_action"])
        )
        return try encodableObject(state) as? [String: Any] ?? [:]
    }

    private func handleLearningSessionStop(_ params: [String: Any]) throws -> [String: Any] {
        let commit = params["commit"] as? Bool ?? true
        let result = supervisor.observer.stopLearningSession(commit: commit)
        if commit, !result.committedSamples.isEmpty {
            _ = try? profileStore.rebuild(host: result.committedSamples.last?.host)
        }
        var object = try encodableObject(result) as? [String: Any] ?? [:]
        object["persistedSamples"] = lock.withLock { persistedLearningSamples }
        object["generatedTemplates"] = (try? profileStore.totalTemplates()) ?? 0
        return object
    }

    private func handleLearningDemoRun(_ params: [String: Any]) throws -> [String: Any] {
        let actionCount = max(1, min(intValue(params["actionCount"] ?? params["action_count"]) ?? 3, 6))
        let stepDelayMs = max(0, min(intValue(params["stepDelayMs"] ?? params["step_delay_ms"]) ?? 650, 2_500))
        let seedDemoTemplate = params["seedDemoTemplate"] as? Bool
            ?? params["seed_demo_template"] as? Bool
            ?? false
        var template = try confidentLearningTemplate(from: params)
        var seededDemoTemplate = false
        if seedDemoTemplate || template == nil {
            _ = try seedManagementLearningDemoTemplate()
            seededDemoTemplate = true
            if seedDemoTemplate {
                template = try confidentLearningTemplate(from: params)
            }
            if template == nil {
                template = try? profileStore.lookupTemplate(
                    host: Self.managementLearningDemoHost,
                    sig: Self.managementLearningDemoSig,
                    taskId: Self.managementLearningDemoTask,
                    actionType: "click"
                )
            }
        }
        guard let template else {
            throw ControlServerError.coded("E_PROFILE_MISS", "no learned template is available for management demo")
        }

        let target = selfTarget()
        let viewport = target.viewportFrame ?? target.frame
        let width = max(Double(viewport.width), 420)
        let height = max(Double(viewport.height), 320)
        let points = managementDemoPoints(width: width, height: height, count: actionCount)
        let baselineParams = try managementDemoActionParams(
            template: template,
            width: width,
            height: height,
            origin: points[0].origin,
            target: points[0].target,
            requestId: "management-learning-demo-baseline",
            baseline: true
        )
        let baseline = try handleAction(
            baselineParams,
            requestId: "management-learning-demo-baseline",
            allowInternalSelfTarget: true
        )
        if stepDelayMs > 0 {
            Thread.sleep(forTimeInterval: Double(stepDelayMs) / 1_000)
        }

        var actions = [[String: Any]]()
        for (index, point) in points.enumerated() {
            let actionId = "management-learning-demo-\(index + 1)"
            let result = try handleAction(
                try managementDemoActionParams(
                    template: template,
                    width: width,
                    height: height,
                    origin: point.origin,
                    target: point.target,
                    requestId: actionId,
                    baseline: false
                ),
                requestId: actionId,
                allowInternalSelfTarget: true
            )
            actions.append(learningDemoActionSummary(result))
            if stepDelayMs > 0, index < points.count - 1 {
                Thread.sleep(forTimeInterval: Double(stepDelayMs) / 1_000)
            }
        }

        let baselineSummary = learningDemoActionSummary(baseline)
        let profilesApplied = actions.allSatisfy { $0["profileApplied"] as? Bool == true }
        let hasMotion = actions.allSatisfy { ($0["mouseMoveCount"] as? Int ?? 0) > 0 }
        return [
            "ok": profilesApplied && hasMotion && (baselineSummary["profileApplied"] as? Bool != true),
            "source": "virtualhid-action-events",
            "target": [
                "bundleId": target.bundleIdentifier,
                "pid": Int(target.pid),
                "viewportFrame": rectObject(target.viewportFrame),
                "selfTarget": true
            ],
            "template": learningTemplateSummaryObject(template),
            "seededDemoTemplate": seededDemoTemplate,
            "baseline": baselineSummary,
            "actions": actions,
            "assertions": [
                "baselineProfileNotApplied": baselineSummary["profileApplied"] as? Bool != true,
                "learnedProfilesApplied": profilesApplied,
                "learnedActionsHaveMouseMovement": hasMotion
            ]
        ]
    }

    private func confidentLearningTemplate(from params: [String: Any]) throws -> ProfileTemplate? {
        let host = nonEmptyString(params["host"])
        let sig = nonEmptyString(params["elementSig"] ?? params["element_sig"] ?? params["sig"])
        let actionType = nonEmptyString(params["actionType"] ?? params["action_type"])
        let taskId = nonEmptyString(params["taskId"] ?? params["task_id"])
        return try profileStore.listTemplates(host: host)
            .filter { template in
                template.confidence >= 0.5
                    && ["click", "move", "drag"].contains(template.actionType)
                    && (sig == nil || template.elementSig == sig)
                    && (actionType == nil || template.actionType == actionType)
                    && (taskId == nil || template.taskId == taskId)
            }
            .first
    }

    private func seedManagementLearningDemoTemplate() throws -> AggregateReport {
        _ = try profileStore.forget(host: Self.managementLearningDemoHost, sig: Self.managementLearningDemoSig)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        for index in 0..<30 {
            let origin = CGPoint(x: 70 + Double(index % 5) * 7, y: 78 + Double(index % 4) * 9)
            let target = CGPoint(x: 370 + Double(index % 6) * 6, y: 250 + Double(index % 5) * 8)
            let control = CGPoint(
                x: 190 + Double(index % 4) * 18,
                y: 120 + Double(index % 6) * 14
            )
            let path = [
                origin,
                CGPoint(x: (origin.x + control.x) / 2, y: control.y - 18),
                control,
                CGPoint(x: (control.x + target.x) / 2, y: control.y + 52),
                target
            ]
            let pathLength = zip(path.dropLast(), path.dropFirst()).map { hypot($0.0.x - $0.1.x, $0.0.y - $0.1.y) }.reduce(0, +)
            let durationMs = 420 + Double(index % 7) * 34
            _ = try profileStore.insertTrace(
                TraceInput(
                    ts: nowMs + Int64(index),
                    source: "management-center-demo",
                    host: Self.managementLearningDemoHost,
                    elementSig: Self.managementLearningDemoSig,
                    taskId: Self.managementLearningDemoTask,
                    stage: "seed",
                    actionType: "click",
                    payload: TracePayload(
                        eventId: "management-learning-demo-\(index)",
                        type: "leftMouseUp",
                        point: tracePoint(target),
                        points: path.map(tracePoint),
                        origin: tracePoint(origin),
                        targetPoint: tracePoint(target),
                        targetRadiusPx: 5 + Double(index % 4),
                        landingErrorPx: 1.2 + Double(index % 5) * 0.7,
                        durationMs: durationMs,
                        segmentMs: [82, 96 + Double(index % 5) * 6, 118, 130 + Double(index % 3) * 9],
                        hesitationMs: index.isMultiple(of: 4) ? [44 + Double(index % 5) * 12] : [],
                        clickHoldMs: [62 + Double(index % 6) * 9],
                        interClickMs: [142 + Double(index % 5) * 16],
                        straightness: 0.78 + Double(index % 6) * 0.018,
                        turnJitter: 0.22 + Double(index % 5) * 0.045,
                        pathLengthPx: pathLength,
                        speedPxS: pathLength / max(durationMs / 1_000, 0.1)
                    )
                )
            )
        }
        return try profileStore.rebuild(host: Self.managementLearningDemoHost)
    }

    private func managementDemoPoints(width: Double, height: Double, count: Int) -> [(origin: CGPoint, target: CGPoint)] {
        let minX = max(56, width * 0.12)
        let maxX = min(width - 56, width * 0.84)
        let minY = max(64, height * 0.16)
        let maxY = min(height - 64, height * 0.72)
        return (0..<count).map { index in
            let progress = Double(index) / Double(max(count - 1, 1))
            let origin = CGPoint(
                x: minX + (maxX - minX) * (0.10 + 0.18 * Double(index % 3)),
                y: maxY - (maxY - minY) * (0.15 + 0.21 * Double(index % 2))
            )
            let target = CGPoint(
                x: minX + (maxX - minX) * (0.58 + 0.28 * progress),
                y: minY + (maxY - minY) * (0.22 + 0.36 * Double((index + 1) % 3) / 2.0)
            )
            return (origin, target)
        }
    }

    private func managementDemoActionParams(
        template: ProfileTemplate,
        width: Double,
        height: Double,
        origin: CGPoint,
        target: CGPoint,
        requestId: String,
        baseline: Bool
    ) throws -> [String: Any] {
        let host = baseline ? Self.managementLearningDemoBaselineHost : template.host
        let sig = baseline ? "\(template.elementSig)-baseline" : template.elementSig
        let primitive: [String: Any]
        switch template.actionType {
        case "move":
            primitive = [
                "type": "move",
                "to": pointObject(target),
                "durationMs": 420,
                "profile": ["origin": pointObject(origin)]
            ]
        case "drag":
            primitive = [
                "type": "drag",
                "from": pointObject(origin),
                "to": pointObject(target),
                "button": "left"
            ]
        default:
            primitive = [
                "type": "click",
                "at": pointObject(target),
                "button": "left",
                "holdMs": 82,
                "profile": ["origin": pointObject(origin)]
            ]
        }
        return [
            "id": requestId,
            "geometry": [
                "coordSpace": "viewport",
                "pageScale": 1,
                "scrollOffset": ["x": 0, "y": 0],
                "viewportSize": ["x": 0, "y": 0, "width": width, "height": height]
            ],
            "context": [
                "host": host,
                "element": ["sig": sig, "role": "button"],
                "taskId": template.taskId ?? Self.managementLearningDemoTask,
                "stage": baseline ? "baseline" : "management-center-demo"
            ],
            "options": [
                "dryRun": true,
                "postMode": "global",
                "browserChromeOverlayPolicy": "off",
                "timeoutMs": 8_000
            ],
            "primitives": [primitive]
        ]
    }

    private func learningDemoActionSummary(_ result: [String: Any]) -> [String: Any] {
        let events = result["events"] as? [[String: Any]] ?? []
        let profiles = result["profiles"] as? [String: Any] ?? [:]
        let verification = result["verification"] as? [String: Any] ?? [:]
        let mouseMoves = events.filter { $0["type"] as? String == "mouseMoved" }
        return [
            "id": result["id"] ?? NSNull(),
            "ok": result["ok"] as? Bool ?? false,
            "profileApplied": profiles["applied"] as? Bool ?? false,
            "templateIds": profiles["templateIds"] ?? [],
            "eventCount": events.count,
            "mouseMoveCount": mouseMoves.count,
            "expectedPointer": verification["expectedPointer"] ?? NSNull(),
            "finalPointer": verification["finalPointer"] ?? NSNull()
        ]
    }

    private func learningTemplateSummaryObject(_ template: ProfileTemplate) -> [String: Any] {
        [
            "host": template.host,
            "elementSig": template.elementSig,
            "taskId": template.taskId ?? NSNull(),
            "actionType": template.actionType,
            "sampleSize": template.sampleSize,
            "confidence": template.confidence,
            "updatedAt": template.updatedAt,
            "updatedAtText": isoString(ms: template.updatedAt)
        ]
    }

    private func cancelCurrentAction() {
        lock.withLock {
            currentExecutor?.cancel()
        }
    }

    private func persistPassiveLearningSample(_ sample: PassiveGestureSample) {
        do {
            _ = try profileStore.insertTrace(Self.traceInput(from: sample))
            let shouldRebuild = lock.withLock { () -> Bool in
                persistedLearningSamples += 1
                return persistedLearningSamples.isMultiple(of: 5)
            }
            if shouldRebuild {
                _ = try? profileStore.rebuild(host: sample.host)
            }
        } catch {
            // Learning is opportunistic and must never break HID execution.
        }
    }

    private static func traceInput(from sample: PassiveGestureSample) -> TraceInput {
        TraceInput(
            ts: sample.ts,
            source: sample.source,
            host: sample.host,
            elementSig: nil,
            taskId: sample.taskId,
            stage: sample.stage,
            actionType: sample.actionType,
            payload: TracePayload(
                eventId: sample.id,
                type: sample.eventType,
                point: sample.point.map { TracePoint(x: $0.x, y: $0.y) },
                keyCode: nil,
                points: sample.pathSkeleton.map { TracePoint(x: $0.x, y: $0.y) },
                origin: sample.pathSkeleton.first.map { TracePoint(x: $0.x, y: $0.y) },
                targetPoint: sample.pathSkeleton.last.map { TracePoint(x: $0.x, y: $0.y) },
                durationMs: sample.durationMs,
                segmentMs: sample.segmentMs,
                hesitationMs: sample.hesitationMs,
                clickHoldMs: sample.clickHoldMs,
                interClickMs: sample.interClickMs,
                straightness: sample.straightness,
                turnJitter: sample.turnJitter,
                pathLengthPx: sample.pathLengthPx,
                speedPxS: sample.speedPxS
            )
        )
    }

    private func resolveTarget(descriptor: TargetDescriptor?, allowInternalSelfTarget: Bool = false) throws -> BrowserTarget {
        if let targetResolverOverride {
            return try targetResolverOverride(descriptor)
        }
        if configuration.allowSelfTarget || allowInternalSelfTarget {
            return selfTarget()
        }
        do {
            return try BrowserResolver.resolve(
                bundleIdentifiers: configuration.bundleIdentifiers,
                descriptor: descriptor
            )
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
                "windowTitle": target.windowTitle ?? NSNull(),
                "viewportFrame": rectObject(target.viewportFrame),
                "viewportSource": target.viewportFrameSource ?? NSNull()
            ]
        }

        for bundleId in configuration.bundleIdentifiers {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
                .filter { !$0.isTerminated }
            if let app = apps.first {
                let target = try? BrowserResolver.resolve(
                    bundleIdentifiers: [bundleId],
                    descriptor: TargetDescriptor(bundleId: bundleId),
                    promptForPermission: false
                )
                return [
                    "bundleId": bundleId,
                    "pid": Int(app.processIdentifier),
                    "frontmost": FocusController.isFrontmost(app: app),
                    "windowTitle": target?.windowTitle ?? NSNull(),
                    "viewportFrame": rectObject(target?.viewportFrame),
                    "viewportSource": target?.viewportFrameSource ?? NSNull()
                ]
            }
        }

        return [
            "bundleId": configuration.bundleIdentifiers.first ?? NSNull(),
            "pid": NSNull(),
            "frontmost": false,
            "windowTitle": NSNull(),
            "viewportFrame": NSNull(),
            "viewportSource": NSNull()
        ]
    }

    private func targetEvidenceObject(_ target: BrowserTarget) -> [String: Any] {
        [
            "bundleId": target.bundleIdentifier,
            "pid": Int(target.pid),
            "frontmost": FocusController.isFrontmost(app: target.app),
            "windowTitle": target.windowTitle ?? NSNull(),
            "windowId": target.windowId ?? NSNull(),
            "browserWindowId": target.browserWindowId ?? NSNull(),
            "tabId": target.tabId ?? NSNull(),
            "host": target.host ?? NSNull(),
            "url": target.url ?? NSNull(),
            "windowFrame": rectObject(target.frame),
            "viewportFrame": rectObject(target.viewportFrame),
            "viewportSource": target.viewportFrameSource ?? NSNull()
        ]
    }

    private func visualContext(
        actionId: String,
        target: BrowserTarget,
        options: ActionOptions,
        primitives: [ActionPrimitive],
        postMode: String? = nil
    ) -> HIDActionVisualContext {
        return HIDActionVisualContext(
            actionId: actionId,
            bundleIdentifier: target.bundleIdentifier,
            pid: target.pid,
            windowTitle: target.windowTitle,
            windowFrame: CodableRect(
                x: target.frame.origin.x,
                y: target.frame.origin.y,
                width: target.frame.width,
                height: target.frame.height
            ),
            dryRun: options.dryRun,
            postMode: postMode ?? (options.postMode ?? configuration.defaultPostMode).rawValue,
            actionTypes: primitives.map(\.actionTypeName)
        )
    }

    private func selfTarget() -> BrowserTarget {
        let app = NSRunningApplication.current
        let frame = selfTargetVisibleFrame()
        return BrowserTarget(
            app: app,
            pid: app.processIdentifier,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.vyodels.virtualhid.daemon",
            windowTitle: nil,
            frame: frame,
            viewportFrame: frame,
            viewportFrameSource: "self-target-visible-screen"
        )
    }

    private func selfTargetVisibleFrame() -> CGRect {
        guard let screen = NSScreen.main else {
            return CGRect(x: 0, y: 0, width: 1440, height: 900)
        }
        let frame = screen.frame
        let visible = screen.visibleFrame
        let topInset = max(0, frame.maxY - visible.maxY)
        return CGRect(
            x: visible.minX,
            y: frame.minY + topInset,
            width: visible.width,
            height: visible.height
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
            url: object["url"] as? String,
            element: ActionContext.Element(
                sig: elementObject?["sig"] as? String,
                role: elementObject?["role"] as? String
            ),
            taskId: object["taskId"] as? String,
            stage: object["stage"] as? String,
            hints: ActionContext.Hints(urgency: hintsObject?["urgency"] as? String)
        )
    }

    private func normalizedActionContext(_ params: [String: Any]) throws -> [String: Any] {
        var context = params["context"] as? [String: Any] ?? [:]
        let target = params["target"] as? [String: Any]
        let contextHost = nonEmptyString(context["host"])
        let targetHost = nonEmptyString(target?["host"])
        if let contextHost, let targetHost, contextHost != targetHost {
            throw ControlServerError.coded("E_CONTEXT_MISMATCH", "context.host must match target.host for web targets")
        }
        if contextHost == nil, let targetHost {
            context["host"] = targetHost
        }
        if context.isEmpty {
            throw ControlServerError.coded("E_CONTEXT_REQUIRED", "missing required field context.host")
        }
        return context
    }

    private func parseOptions(_ object: [String: Any]?) -> ActionOptions {
        guard let object else {
            return ActionOptions(postMode: configuration.defaultPostMode)
        }
        let postMode = (object["postMode"] as? String).flatMap(PostMode.init(rawValue:))
        return ActionOptions(
            postMode: postMode,
            timeoutMs: intValue(object["timeoutMs"]),
            dryRun: object["dryRun"] as? Bool ?? false,
            browserChromeOverlayPolicy: browserChromeOverlayPolicy(from: object)
        )
    }

    private func browserChromeOverlayPolicy(from object: [String: Any]) -> BrowserChromeOverlayPolicy {
        if let raw = nonEmptyString(
            object["browserChromeOverlayPolicy"]
                ?? object["chromeOverlayPolicy"]
                ?? object["transientOverlayPolicy"]
        )?.lowercased(), let policy = BrowserChromeOverlayPolicy(rawValue: raw) {
            return policy
        }
        if let force = object["dismissBrowserChromeOverlays"] as? Bool
            ?? object["dismissTransientOverlays"] as? Bool {
            return force ? .force : .off
        }
        return .auto
    }

    private func handleBrowserChromeOverlayPreflight(
        target: BrowserTarget,
        primitives: [ActionPrimitive],
        options: ActionOptions
    ) throws -> BrowserChromeOverlayPreflightResult {
        let policy = options.browserChromeOverlayPolicy
        guard policy != .off else {
            return BrowserChromeOverlayPreflightResult(policy: policy, status: "off")
        }
        guard isBrowserPageTarget(target) else {
            return BrowserChromeOverlayPreflightResult(policy: policy, status: "notApplicable", reason: "target is not a browser page")
        }
        guard primitives.contains(where: \.canBeOccludedByBrowserChrome) else {
            return BrowserChromeOverlayPreflightResult(policy: policy, status: "notApplicable", reason: "action has no page-facing primitive")
        }

        let detection: BrowserChromeOverlayDetection
        switch policy {
        case .force:
            detection = BrowserChromeOverlayDetection(available: false, count: 0, roles: [], reason: "forced by caller")
        case .auto:
            detection = detectBrowserChromeTransientOverlays(target: target)
            guard detection.count > 0 else {
                return BrowserChromeOverlayPreflightResult(
                    policy: policy,
                    status: detection.available ? "clear" : "detectionUnavailable",
                    reason: detection.reason,
                    detection: detection
                )
            }
        case .off:
            return BrowserChromeOverlayPreflightResult(policy: policy, status: "off")
        }

        if options.dryRun {
            return BrowserChromeOverlayPreflightResult(
                policy: policy,
                status: "dryRun",
                attempted: true,
                method: "escape",
                reason: policy == .force ? "forced by caller" : "transient browser chrome overlay detected",
                detection: detection
            )
        }

        try postEscapeToDismissBrowserChrome(target: target)
        return BrowserChromeOverlayPreflightResult(
            policy: policy,
            status: "dismissed",
            attempted: true,
            method: "escape",
            reason: policy == .force ? "forced by caller" : "transient browser chrome overlay detected",
            detection: detection
        )
    }

    private func isBrowserPageTarget(_ target: BrowserTarget) -> Bool {
        let browserBundleIds: Set<String> = [
            "com.google.Chrome",
            "org.chromium.Chromium",
            "com.microsoft.edgemac",
            "com.apple.Safari"
        ]
        guard browserBundleIds.contains(target.bundleIdentifier) else {
            return false
        }
        return target.host != nil || target.url != nil || target.tabId != nil
    }

    private func detectBrowserChromeTransientOverlays(target: BrowserTarget) -> BrowserChromeOverlayDetection {
        let axApp = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(axApp, 0.2)
        guard let windows = copyAXElementArrayAttribute(of: axApp, name: kAXWindowsAttribute as String) else {
            return BrowserChromeOverlayDetection(available: false, count: 0, roles: [], reason: "AX windows unavailable")
        }

        var roles = [String]()
        for window in windows {
            let role = copyStringAttribute(of: window, name: kAXRoleAttribute as String) ?? ""
            let subrole = copyStringAttribute(of: window, name: kAXSubroleAttribute as String) ?? ""
            guard let frame = copyFrame(of: window), frame.intersects(target.frame) else {
                continue
            }
            guard isTransientBrowserChromeWindow(role: role, subrole: subrole, frame: frame, targetFrame: target.frame) else {
                continue
            }
            roles.append(subrole.isEmpty ? role : "\(role):\(subrole)")
        }

        return BrowserChromeOverlayDetection(
            available: true,
            count: roles.count,
            roles: roles,
            reason: roles.isEmpty ? nil : "non-standard browser chrome window overlaps target"
        )
    }

    private func isTransientBrowserChromeWindow(role: String, subrole: String, frame: CGRect, targetFrame: CGRect) -> Bool {
        guard frame.width >= 16, frame.height >= 16, frame.width <= targetFrame.width, frame.height <= targetFrame.height else {
            return false
        }
        if role == kAXWindowRole as String && subrole == kAXStandardWindowSubrole as String {
            return false
        }
        let transientRoles: Set<String> = [
            "AXDialog",
            "AXHelpTag",
            "AXMenu",
            "AXPopover",
            "AXSheet",
            kAXMenuRole as String
        ]
        if transientRoles.contains(role) {
            return true
        }
        return subrole.localizedCaseInsensitiveContains("popover")
            || subrole.localizedCaseInsensitiveContains("dialog")
            || subrole.localizedCaseInsensitiveContains("sheet")
            || subrole.localizedCaseInsensitiveContains("menu")
    }

    private func postEscapeToDismissBrowserChrome(target: BrowserTarget) throws {
        guard FocusController.ensureFrontmost(app: target.app, timeout: 1.2) else {
            throw PosterError.notFrontmost
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false) else {
            throw ActionExecutionError.eventCreationFailed("escape")
        }
        let poster = EventPoster(mode: .global, targetPid: target.pid)
        _ = try poster.post(down, type: .keyDown, frontmost: FocusController.isFrontmost(app: target.app))
        _ = try poster.post(up, type: .keyUp, frontmost: FocusController.isFrontmost(app: target.app))
        FocusController.sleep(milliseconds: 80)
    }

    private func parsePrimitives(_ array: [[String: Any]]?) throws -> [ActionPrimitive] {
        guard let array, !array.isEmpty else {
            throw ControlServerError.coded("E_PRIMITIVES_REQUIRED", "hid_action requires non-empty primitives derived from browser clickPoint or another observed target region; target/context-only calls are invalid")
        }

        return try array.map { primitive in
            guard let type = primitive["type"] as? String else {
                throw ControlServerError.coded("E_PRIMITIVE_INVALID", "primitive.type is required")
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
            case "pasteText":
                return .pasteText(
                    text: primitive["text"] as? String ?? "",
                    restoreClipboard: primitive["restoreClipboard"] as? Bool ?? true,
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

    private func observerEvidence(
        result: ActionResult,
        observedEvents: [ObservedEvent],
        observerEnabled: Bool,
        dryRun: Bool,
        sinceEventId: String?
    ) -> OutcomeEvidence.Observer {
        if dryRun {
            return OutcomeEvidence.Observer(
                status: "dryRunNotObserved",
                observedEvents: 0,
                matchedEvents: 0,
                sinceEventId: sinceEventId,
                detail: "dry-run returns planned HID events without posting CGEvents"
            )
        }
        guard observerEnabled else {
            return OutcomeEvidence.Observer(
                status: "notEnabled",
                observedEvents: 0,
                matchedEvents: 0,
                sinceEventId: sinceEventId,
                detail: "PassiveObserver was not enabled for this action"
            )
        }
        let matched = matchedObservedEvents(injected: result.events, observed: observedEvents)
        if matched > 0 {
            return OutcomeEvidence.Observer(
                status: "echoed",
                observedEvents: observedEvents.count,
                matchedEvents: matched,
                sinceEventId: sinceEventId
            )
        }
        return OutcomeEvidence.Observer(
            status: "notObserved",
            observedEvents: observedEvents.count,
            matchedEvents: 0,
            sinceEventId: sinceEventId,
            detail: "VirtualHID marks its own CGEvents, and PassiveObserver filters self-marked events; semantic success must be confirmed by Agent/browser"
        )
    }

    private func matchedObservedEvents(injected: [InjectedEvent], observed: [ObservedEvent]) -> Int {
        var remaining = observed
        var matched = 0
        for injectedEvent in injected {
            guard let index = remaining.firstIndex(where: { observedEventMatches(injected: injectedEvent, observed: $0) }) else {
                continue
            }
            matched += 1
            remaining.remove(at: index)
        }
        return matched
    }

    private func observedEventMatches(injected: InjectedEvent, observed: ObservedEvent) -> Bool {
        guard injected.type == observed.type else {
            return false
        }
        guard let injectedPoint = injected.location, let observedPoint = observed.point else {
            return true
        }
        return hypot(injectedPoint.x - observedPoint.x, injectedPoint.y - observedPoint.y) <= 3
    }

    private func parseSemanticEvidence(_ params: [String: Any]) -> OutcomeEvidence.Semantic {
        let object = params["semantic"] as? [String: Any]
            ?? params["semanticConfirmation"] as? [String: Any]
            ?? params["semantic_confirmation"] as? [String: Any]
        guard let object else {
            return .notProvided()
        }
        let verified = object["verified"] as? Bool
        let status = object["status"] as? String
            ?? verified.map { $0 ? "verified" : "rejected" }
            ?? "provided"
        return OutcomeEvidence.Semantic(
            status: status,
            verified: verified,
            source: object["source"] as? String,
            detail: object["detail"] as? String ?? object["reason"] as? String
        )
    }

    private func daemonLearningObject(
        result: ActionResult,
        context: ActionContext,
        primitives: [ActionPrimitive],
        options: ActionOptions,
        evidence: OutcomeEvidence
    ) -> [String: Any] {
        guard !ProfileStore.isSensitiveRole(context.element?.role) else {
            return ["committed": false, "reason": "sensitive_role"]
        }
        guard let input = replayTraceInput(result: result, context: context, primitives: primitives, options: options, evidence: evidence) else {
            return ["committed": false, "reason": "no_replay_path"]
        }
        let instructionKey = replayInstructionKey(context: context, actionType: input.actionType)
        do {
            let commit = try profileStore.commitReplayTrace(input: input, instructionKey: instructionKey)
            return [
                "committed": true,
                "traceId": commit.traceId,
                "replayId": commit.replayId,
                "instructionKey": instructionKey,
                "replayFingerprint": try encodableObject(commit.fingerprint)
            ]
        } catch {
            return [
                "committed": false,
                "reason": "commit_failed",
                "error": error.localizedDescription
            ]
        }
    }

    private func replayTraceInput(
        result: ActionResult,
        context: ActionContext,
        primitives: [ActionPrimitive],
        options: ActionOptions,
        evidence: OutcomeEvidence
    ) -> TraceInput? {
        let points = result.events.compactMap {
            $0.location.map { TracePoint(x: $0.x, y: $0.y) }
        }
        guard !points.isEmpty || result.events.contains(where: { $0.virtualKey != nil }) else {
            return nil
        }
        let actionType = primitives.first.map(profileActionType(for:)) ?? "action"
        let finalPoint = evidence.finalPointer.map { TracePoint(x: $0.x, y: $0.y) }
        let expectedPoint = evidence.expectedPointer.map { TracePoint(x: $0.x, y: $0.y) }
        let landingError: Double?
        if let finalPoint, let expectedPoint {
            landingError = hypot(finalPoint.x - expectedPoint.x, finalPoint.y - expectedPoint.y)
        } else {
            landingError = nil
        }
        return TraceInput(
            ts: Int64(Date().timeIntervalSince1970 * 1000),
            source: options.dryRun ? "hid-dry-run" : "hid",
            host: context.host,
            elementSig: context.element?.sig,
            taskId: context.taskId,
            stage: context.stage,
            actionType: actionType,
            payload: TracePayload(
                eventId: result.id,
                type: result.events.last?.type ?? actionType,
                point: finalPoint,
                keyCode: result.events.compactMap(\.virtualKey).last,
                points: points,
                origin: points.first,
                targetPoint: expectedPoint,
                landingErrorPx: landingError,
                durationMs: Double(result.elapsedMs),
                segmentMs: replaySegmentDurations(from: result.events),
                clickHoldMs: replayHoldDurations(from: result.events),
                interClickMs: replayInterClickDurations(from: result.events)
            )
        )
    }

    private func replayInstructionKey(context: ActionContext, actionType: String) -> String {
        [
            context.taskId,
            context.stage,
            context.element?.sig,
            actionType
        ]
        .compactMap { value -> String? in
            guard let value, !value.isEmpty else {
                return nil
            }
            return value
        }
        .joined(separator: ":")
    }

    private func replaySegmentDurations(from events: [InjectedEvent]) -> [Double] {
        eventDates(events).adjacentPairs().map { max(0, $1.timeIntervalSince($0) * 1000) }
    }

    private func replayHoldDurations(from events: [InjectedEvent]) -> [Double] {
        pairedDurations(events: events, startTypes: ["leftMouseDown", "rightMouseDown", "otherMouseDown", "keyDown"], endTypes: ["leftMouseUp", "rightMouseUp", "otherMouseUp", "keyUp"])
    }

    private func replayInterClickDurations(from events: [InjectedEvent]) -> [Double] {
        let upDates = events.filter { ["leftMouseUp", "rightMouseUp", "otherMouseUp"].contains($0.type) }.compactMap(eventDate)
        return upDates.adjacentPairs().map { max(0, $1.timeIntervalSince($0) * 1000) }
    }

    private func pairedDurations(events: [InjectedEvent], startTypes: Set<String>, endTypes: Set<String>) -> [Double] {
        var starts = [Date]()
        var durations = [Double]()
        for event in events {
            guard let date = eventDate(event) else {
                continue
            }
            if startTypes.contains(event.type) {
                starts.append(date)
            } else if endTypes.contains(event.type), let start = starts.popLast() {
                durations.append(max(0, date.timeIntervalSince(start) * 1000))
            }
        }
        return durations
    }

    private func eventDates(_ events: [InjectedEvent]) -> [Date] {
        events.compactMap(eventDate)
    }

    private func eventDate(_ event: InjectedEvent) -> Date? {
        isoFormatter.date(from: event.timestamp)
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
            case .pasteText(let text, let restoreClipboard, let profile):
                return .pasteText(
                    text: text,
                    restoreClipboard: restoreClipboard,
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
        case .type, .pasteText, .key:
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
            case .timedOut(let timeoutMs):
                return ("E_TIMEOUT", "injector action exceeded timeoutMs=\(timeoutMs)")
            case .eventCreationFailed(let detail):
                return ("E_UNKNOWN", "failed to create event: \(detail)")
            }
        }
        if let error = error as? ViewportGeometryResolverError {
            switch error {
            case .unresolvedViewport:
                return ("E_VIEWPORT_UNRESOLVED", error.localizedDescription)
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

private struct BrowserChromeOverlayDetection {
    let available: Bool
    let count: Int
    let roles: [String]
    let reason: String?
}

private struct BrowserChromeOverlayPreflightResult {
    let policy: BrowserChromeOverlayPolicy
    let status: String
    let attempted: Bool
    let method: String?
    let reason: String?
    let detection: BrowserChromeOverlayDetection?

    init(
        policy: BrowserChromeOverlayPolicy,
        status: String,
        attempted: Bool = false,
        method: String? = nil,
        reason: String? = nil,
        detection: BrowserChromeOverlayDetection? = nil
    ) {
        self.policy = policy
        self.status = status
        self.attempted = attempted
        self.method = method
        self.reason = reason
        self.detection = detection
    }

    var object: [String: Any] {
        [
            "policy": policy.rawValue,
            "status": status,
            "attempted": attempted,
            "method": method ?? NSNull(),
            "reason": reason ?? NSNull(),
            "detection": detection.map {
                [
                    "available": $0.available,
                    "count": $0.count,
                    "roles": $0.roles,
                    "reason": $0.reason ?? NSNull()
                ] as [String: Any]
            } ?? NSNull()
        ]
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

private func nonEmptyString(_ value: Any?) -> String? {
    guard let string = value as? String else {
        return nil
    }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func parsePassiveLearningMode(_ value: Any?) -> PassiveLearningMode? {
    guard let raw = nonEmptyString(value) else {
        return nil
    }
    return PassiveLearningMode(rawValue: raw.lowercased().replacingOccurrences(of: "_", with: "-"))
        ?? PassiveLearningMode(rawValue: raw.lowercased())
}

private func copyAXElementArrayAttribute(of element: AXUIElement, name: String) -> [AXUIElement]? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value as? [AXUIElement]
}

private func copyStringAttribute(of element: AXUIElement, name: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value as? String
}

private func copyFrame(of element: AXUIElement) -> CGRect? {
    guard
        let positionValue = copyAXValueAttribute(of: element, name: kAXPositionAttribute as String),
        let sizeValue = copyAXValueAttribute(of: element, name: kAXSizeAttribute as String)
    else {
        return nil
    }
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetType(positionValue) == .cgPoint, AXValueGetValue(positionValue, .cgPoint, &position) else {
        return nil
    }
    guard AXValueGetType(sizeValue) == .cgSize, AXValueGetValue(sizeValue, .cgSize, &size) else {
        return nil
    }
    return CGRect(origin: position, size: size)
}

private func copyAXValueAttribute(of element: AXUIElement, name: String) -> AXValue? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else {
        return nil
    }
    return (value as! AXValue)
}

private func point(_ object: [String: Any]?, name: String) throws -> CGPoint {
    guard let object, let x = number(object["x"]), let y = number(object["y"]) else {
        throw ControlServerError.coded("E_UNKNOWN", "point \(name) requires x and y")
    }
    return CGPoint(x: x, y: y)
}

private func pointObject(_ point: CGPoint) -> [String: Double] {
    ["x": point.x, "y": point.y]
}

private func tracePoint(_ point: CGPoint) -> TracePoint {
    TracePoint(x: point.x, y: point.y)
}

private func parseOptionalPoint(_ object: [String: Any]?) -> TracePoint? {
    guard let object, let x = number(object["x"]), let y = number(object["y"]) else {
        return nil
    }
    return TracePoint(x: x, y: y)
}

private func parseTargetDescriptor(_ object: [String: Any]?) throws -> TargetDescriptor? {
    guard let object else {
        return nil
    }
    let target = TargetDescriptor(
        bundleId: object["bundleId"] as? String ?? object["bundle_id"] as? String,
        windowId: intValue(object["windowId"] ?? object["window_id"]),
        windowTitle: object["windowTitle"] as? String ?? object["window_title"] as? String,
        tabId: intValue(object["tabId"] ?? object["tab_id"]),
        host: object["host"] as? String
    )
    if target.bundleId == nil, target.windowId == nil, target.windowTitle == nil, target.tabId == nil, target.host == nil {
        throw ControlServerError.coded("E_CONTEXT_REQUIRED", "target requires at least one of bundleId, windowId, tabId, host")
    }
    return target
}

private func parseViewportGeometry(_ object: [String: Any]?) throws -> ViewportGeometryRequest? {
    guard let object else {
        return nil
    }
    let coordSpace = CoordinateSpace(
        rawValue: (object["coordSpace"] as? String ?? object["coord_space"] as? String ?? "viewport")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    )
    guard let coordSpace else {
        throw ControlServerError.coded("E_UNKNOWN", "geometry.coordSpace must be screen, viewport, or document")
    }
    let viewportObject = object["viewportInScreen"] as? [String: Any]
        ?? object["viewport_in_screen"] as? [String: Any]
    let viewportInScreen = try optionalRect(viewportObject, name: "geometry.viewportInScreen")
    let scrollOffset = parseOptionalCGPoint(
        object["scrollOffset"] as? [String: Any] ?? object["scroll_offset"] as? [String: Any]
    ).map { CodablePoint(x: $0.x, y: $0.y) } ?? CodablePoint(x: 0, y: 0)
    let viewportSize = try optionalRect(
        object["viewportSize"] as? [String: Any] ?? object["viewport_size"] as? [String: Any],
        name: "geometry.viewportSize"
    )
    return ViewportGeometryRequest(
        coordSpace: coordSpace,
        callerViewportInScreen: viewportInScreen,
        pageScale: number(object["pageScale"] ?? object["page_scale"]) ?? 1,
        scrollOffset: scrollOffset,
        viewportSize: viewportSize
    )
}

private func rect(_ object: [String: Any], name: String) throws -> CodableRect {
    guard
        let x = number(object["x"] ?? object["left"]),
        let y = number(object["y"] ?? object["top"]),
        let width = number(object["width"] ?? object["w"]),
        let height = number(object["height"] ?? object["h"])
    else {
        throw ControlServerError.coded("E_UNKNOWN", "\(name) requires x/y/width/height")
    }
    return CodableRect(x: x, y: y, width: width, height: height)
}

private func optionalRect(_ object: [String: Any]?, name: String) throws -> CodableRect? {
    guard let object else {
        return nil
    }
    return try rect(object, name: name)
}

private func mappingObject(_ resolution: ViewportGeometryResolution) -> [String: Any] {
    let geometry = resolution.geometry
    return [
        "coordSpace": geometry.coordSpace.rawValue,
        "viewportInScreen": [
            "x": geometry.viewportInScreen.x,
            "y": geometry.viewportInScreen.y,
            "width": geometry.viewportInScreen.width,
            "height": geometry.viewportInScreen.height
        ],
        "viewportSource": resolution.viewportSource,
        "ignoredCallerViewportInScreen": resolution.ignoredCallerViewportInScreen,
        "pageScale": geometry.pageScale,
        "scrollOffset": [
            "x": geometry.scrollOffset.x,
            "y": geometry.scrollOffset.y
        ],
        "viewportSize": geometry.viewportSize.map {
            [
                "x": $0.x,
                "y": $0.y,
                "width": $0.width,
                "height": $0.height
            ]
        } as Any? ?? NSNull()
    ]
}

private func rectObject(_ rect: CGRect?) -> Any {
    guard let rect else {
        return NSNull()
    }
    return [
        "x": rect.origin.x,
        "y": rect.origin.y,
        "width": rect.width,
        "height": rect.height
    ]
}

private func expectedFinalPoint(from primitives: [ActionPrimitive]) -> CGPoint? {
    for primitive in primitives.reversed() {
        switch primitive {
        case .move(let to, _, _, let profile):
            return expectedLandingCenter(base: to, profile: profile)
        case .click(let at, _, _, _, let profile):
            return expectedLandingCenter(base: at, profile: profile)
        case .drag(_, let to, _, _, let profile):
            return expectedLandingCenter(base: to, profile: profile)
        case .scroll(let at, _, _, _):
            return at
        case .type, .pasteText, .key:
            continue
        }
    }
    return nil
}

private func expectedFinalTolerancePx(from primitives: [ActionPrimitive]) -> Double {
    for primitive in primitives.reversed() {
        switch primitive {
        case .move(_, _, _, let profile),
             .click(_, _, _, _, let profile),
             .drag(_, _, _, _, let profile):
            if let tolerance = landingTolerancePx(profile?.landingZone) {
                return tolerance
            }
            return 2
        case .scroll:
            return 2
        case .type, .pasteText, .key:
            continue
        }
    }
    return 2
}

private func expectedLandingCenter(base: CGPoint, profile: PrimitiveProfile?) -> CGPoint {
    profile?.landingZone?.center ?? base
}

private func landingTolerancePx(_ zone: LandingZone?) -> Double? {
    guard let zone else {
        return nil
    }
    if let radius = zone.radius, radius > 0 {
        return radius
    }
    let halfWidth = max((zone.width ?? 0) / 2, 0)
    let halfHeight = max((zone.height ?? 0) / 2, 0)
    if halfWidth > 0 || halfHeight > 0 {
        return hypot(halfWidth, halfHeight)
    }
    return nil
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

private extension Array {
    func adjacentPairs() -> [(Element, Element)] {
        guard count > 1 else {
            return []
        }
        return zip(self, dropFirst()).map { ($0, $1) }
    }
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
            "center": profileObject?["landingCenter"] ?? profileObject?["landing_center"] ?? primitive["landingCenter"] ?? primitive["landing_center"],
            "width": profileObject?["landingWidth"] ?? profileObject?["landing_width"] ?? primitive["landingWidth"] ?? primitive["landing_width"],
            "height": profileObject?["landingHeight"] ?? profileObject?["landing_height"] ?? primitive["landingHeight"] ?? primitive["landing_height"],
            "radius": profileObject?["landingRadius"] ?? profileObject?["landing_radius"] ?? primitive["landingRadius"] ?? primitive["landing_radius"]
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
                    "VirtualHID 只接受固定锚点或 landingZone，\(path).\(key) 必须由上游预先解析为精确锚点"
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
        case .click, .drag, .type, .pasteText, .key:
            return false
        }
    }

    var canBeOccludedByBrowserChrome: Bool {
        switch self {
        case .move:
            return false
        case .click, .drag, .scroll, .type, .pasteText, .key:
            return true
        }
    }
}
