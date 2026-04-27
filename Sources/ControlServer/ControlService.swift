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

private enum ManagementDemoAction: String, CaseIterable {
    case move
    case click
    case dblclick
    case drag
    case scroll
    case keyboard

    var templateActionType: String? {
        switch self {
        case .move:
            return "move"
        case .click, .dblclick:
            return "click"
        case .drag:
            return "drag"
        case .keyboard:
            return "type"
        case .scroll:
            return "scroll"
        }
    }

    var title: String {
        switch self {
        case .move:
            return "移动演示"
        case .click:
            return "完整点击演示"
        case .dblclick:
            return "双击演示"
        case .drag:
            return "完整拖拽演示"
        case .scroll:
            return "滚轮演示"
        case .keyboard:
            return "键盘事件演示"
        }
    }
}

private struct LearningDemoPointSpec {
    let startPoint: CGPoint
    let targetPoint: CGPoint
    let actualPointExpected: CGPoint
    let scrollDelta: CGVector?
    let text: String?
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
    private var activeLearningDemoId: String?
    private var lastLearningDemoStep: [String: Any]?
    private var lastLearningDemoPointSpecs = [String: LearningDemoPointSpec]()
    private static let managementLearningDemoBaselineHost = "virtualhid-management-demo-baseline.local"
    private static let managementLearningDemoDefaultTask = "management-learning-demo"

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
                "observingHost": supervisorSnapshot.observingHost as Any? ?? NSNull(),
                "eventTapRunning": supervisorSnapshot.eventTapRunning,
                "eventTapError": supervisorSnapshot.eventTapError as Any? ?? NSNull()
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
        case "learning.inspect":
            return try handleLearningInspect(params)
        case "learning.configure":
            return try handleLearningConfigure(params)
        case "learning.session.start":
            return try handleLearningSessionStart(params)
        case "learning.session.stop":
            return try handleLearningSessionStop(params)
        case "learning.demo.run":
            return try handleLearningDemoRun(params)
        case "learning.demo.step":
            return try handleLearningDemoStep(params)
        case "learning.demo.stop":
            return handleLearningDemoStop()
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
        let profileResult = options.disableProfiles
            ? (primitives: primitives, applied: false, templateIds: [])
            : applyProfiles(to: primitives, context: context)
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
        ensureEventTapForLearningIfNeeded()
        var state = try encodableObject(supervisor.observer.learningState) as? [String: Any] ?? [:]
        state["persistedSamples"] = lock.withLock { persistedLearningSamples }
        state["totalTemplates"] = (try? profileStore.totalTemplates()) ?? 0
        state["traceCount"] = (try? profileStore.traceCount()) ?? 0
        state["lastLearnedAt"] = (try? profileStore.lastLearnedAtMs()).flatMap { $0.map(isoString(ms:)) } ?? NSNull()
        state["templates"] = (try? profileStore.listTemplates().prefix(8).map(learningTemplateSummaryObject)) ?? []
        return state
    }

    private func handleLearningInspect(_ params: [String: Any]) throws -> [String: Any] {
        let limit = max(1, min(intValue(params["limit"] ?? params["n"]) ?? 8, 30))
        var object = try handleLearningState()
        let supervisorSnapshot = supervisor.snapshot()
        object["eventCapture"] = [
            "eventTapRunning": supervisorSnapshot.eventTapRunning,
            "eventTapError": supervisorSnapshot.eventTapError as Any? ?? NSNull(),
            "accessibility": EventTap.isAccessibilityTrusted(prompt: false),
            "inputMonitoring": inputMonitoringGranted(),
            "observing": supervisorSnapshot.observing,
            "observingHost": supervisorSnapshot.observingHost as Any? ?? NSNull()
        ]
        object["recentEvents"] = supervisor.observer.tail(limit: limit).map(observedEventObject)
        object["recentTraces"] = try profileStore.listTraceSummaries(limit: limit).map(traceSummaryObject)
        object["templates"] = try profileStore.listTemplates().prefix(limit).map(learningTemplateSummaryObject)
        object["definitions"] = [
            "scope": "适用范围用于归因学习结果；网页目标通常是 URL host，桌面目标可以是应用或全局键鼠能力。",
            "actionType": "动作类型来自真实键鼠事件链，例如点击、拖拽、滚动、键盘输入；模板只影响执行轨迹和节奏，不选择业务目标。",
            "continuousLearning": "开启键鼠输入学习分析后，真实事件会自动生成动作片段并实时入库。",
            "focusedCapture": "聚焦采集只是给一段练习窗口加范围标签；它不是另一套学习模式，也不需要手动保存。",
            "templates": "能力模板由历史片段聚合生成，包含速度、点数、停顿、按压、键盘 dwell/inter-key 等执行参数。"
        ]
        return object
    }

    private func handleLearningConfigure(_ params: [String: Any]) throws -> [String: Any] {
        let mode = parsePassiveLearningMode(params["mode"])
        let state = supervisor.observer.configureLearning(
            enabled: params["enabled"] as? Bool,
            mode: mode
        )
        ensureEventTapForLearningIfNeeded()
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
        ensureEventTapForLearningIfNeeded()
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
        var templateParams = params
        if nonEmptyString(templateParams["actionType"] ?? templateParams["action_type"]) == nil {
            templateParams["actionType"] = "click"
        }
        let template = try learnedDemoTemplate(from: templateParams)
        guard let template else {
            throw ControlServerError.coded(
                "E_PROFILE_MISS",
                "no applicable learned profile is available for this demo; collect enough input samples and rebuild profiles first"
            )
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
            actions.append(learningDemoActionSummary(result, phase: "learned", ordinal: index + 1, template: template))
            if stepDelayMs > 0, index < points.count - 1 {
                Thread.sleep(forTimeInterval: Double(stepDelayMs) / 1_000)
            }
        }

        let baselineSummary = learningDemoActionSummary(baseline, phase: "baseline", ordinal: 0, template: template)
        let profilesApplied = actions.allSatisfy { $0["profileApplied"] as? Bool == true }
        let hasMotion = actions.allSatisfy { ($0["mouseMoveCount"] as? Int ?? 0) > 0 }
        let hasClickEvents = actions.allSatisfy {
            ($0["mouseDownCount"] as? Int ?? 0) > 0 && ($0["mouseUpCount"] as? Int ?? 0) > 0
        }
        let baselineProfileNotApplied = baselineSummary["profileApplied"] as? Bool != true
        return [
            "ok": profilesApplied && baselineProfileNotApplied && hasClickEvents,
            "source": "virtualhid-action-events",
            "mode": "safe-dry-run-preview",
            "safety": [
                "dryRun": true,
                "realClickPosted": false,
                "realKeyboardPosted": false,
                "description": "VirtualHID only renders planned HID events in HUD; it does not post CGEvents during this demo."
            ],
            "target": [
                "bundleId": target.bundleIdentifier,
                "pid": Int(target.pid),
                "viewportFrame": rectObject(target.viewportFrame),
                "selfTarget": true
            ],
            "template": learningTemplateSummaryObject(template),
            "demoPlan": learningDemoPlanObject(template: template, actionCount: actionCount),
            "learningEffect": learningEffectObject(template: template),
            "seededDemoTemplate": false,
            "baseline": baselineSummary,
            "actions": actions,
            "assertions": [
                "baselineProfileNotApplied": baselineProfileNotApplied,
                "learnedProfilesApplied": profilesApplied,
                "learnedActionsHaveMouseMovement": hasMotion,
                "learnedActionsHaveClickEvents": hasClickEvents
            ],
            "warnings": [
                "missingMouseMove": hasMotion ? NSNull() as Any : "some safe preview actions contain click events but no mouseMoved events"
            ]
        ]
    }

    private func handleLearningDemoStep(_ params: [String: Any]) throws -> [String: Any] {
        let action = try managementDemoAction(from: params)
        let demoId = nonEmptyString(params["demoId"] ?? params["demo_id"])
            ?? "management-learning-demo-\(action.rawValue)"
        let replacedDemoId = beginLearningDemo(id: demoId)
        defer {
            finishLearningDemo(id: demoId)
        }

        let template = try managementDemoTemplate(for: action, params: params)
        guard let template else {
            throw ControlServerError.coded(
                "E_PROFILE_MISS",
                "no applicable learned profile is available for \(action.rawValue); collect enough input samples and rebuild profiles first"
            )
        }

        let target = selfTarget()
        let viewport = target.viewportFrame ?? target.frame
        let width = max(Double(viewport.width), 420)
        let height = max(Double(viewport.height), 320)
        let spec = managementDemoStepSpec(action: action, width: width, height: height, params: params)
        let requestId = "\(demoId)-\(action.rawValue)-\(Int(Date().timeIntervalSince1970 * 1000))"
        let actionParams = try managementDemoStepActionParams(
            action: action,
            template: template,
            width: width,
            height: height,
            spec: spec,
            requestId: requestId
        )
        let result = try handleAction(actionParams, requestId: requestId, allowInternalSelfTarget: true)
        let summary = learningDemoActionSummary(
            result,
            phase: "manual",
            ordinal: 1,
            template: template,
            demoAction: action,
            requested: spec
        )
        let response: [String: Any] = [
            "ok": result["ok"] as? Bool ?? false,
            "source": "virtualhid-action-events",
            "mode": "manual-safe-dry-run-preview",
            "manualControl": [
                "maxActiveDemo": 1,
                "autoAdvance": false,
                "repeatable": true,
                "replacedDemoId": (replacedDemoId as Any?) ?? NSNull()
            ] as [String: Any],
            "safety": [
                "dryRun": true,
                "realClickPosted": false,
                "realKeyboardPosted": false,
                "description": "Manual management demo renders planned HID events only; it does not post external clicks or keystrokes."
            ],
            "target": [
                "bundleId": target.bundleIdentifier,
                "pid": Int(target.pid),
                "viewportFrame": rectObject(target.viewportFrame),
                "selfTarget": true,
                "visibleScreen": true
            ],
            "demoAction": action.rawValue,
            "title": action.title,
            "template": learningTemplateSummaryObject(template),
            "learningEffect": learningEffectObject(template: template),
            "seededDemoTemplate": false,
            "action": summary,
            "actions": [summary],
            "lastActionOnly": true
        ]
        lock.withLock {
            lastLearningDemoStep = response
        }
        return response
    }

    private func handleLearningDemoStop() -> [String: Any] {
        let stopped = lock.withLock { () -> String? in
            let active = activeLearningDemoId
            activeLearningDemoId = nil
            return active
        }
        cancelCurrentAction()
        return [
            "ok": true,
            "stoppedDemoId": stopped ?? NSNull(),
            "lastStep": lock.withLock { lastLearningDemoStep as Any? ?? NSNull() }
        ]
    }

    private func beginLearningDemo(id: String) -> String? {
        let replaced = lock.withLock { () -> String? in
            let previous = activeLearningDemoId
            activeLearningDemoId = id
            return previous
        }
        if replaced != nil {
            cancelCurrentAction()
        }
        return replaced
    }

    private func finishLearningDemo(id: String) {
        lock.withLock {
            if activeLearningDemoId == id {
                activeLearningDemoId = nil
            }
        }
    }

    private func managementDemoAction(from params: [String: Any]) throws -> ManagementDemoAction {
        let raw = nonEmptyString(params["action"] ?? params["demoAction"] ?? params["actionType"] ?? params["action_type"])
            ?? "click"
        guard let action = ManagementDemoAction(rawValue: raw.lowercased()) else {
            throw ControlServerError.coded(
                "E_DEMO_ACTION_UNSUPPORTED",
                "learning.demo.step action must be one of \(ManagementDemoAction.allCases.map(\.rawValue).joined(separator: ", "))"
            )
        }
        return action
    }

    private func managementDemoTemplate(for action: ManagementDemoAction, params: [String: Any]) throws -> ProfileTemplate? {
        guard let actionType = action.templateActionType else {
            return nil
        }
        var scoped = params
        scoped["actionType"] = actionType
        return try learnedDemoTemplate(from: scoped)
    }

    private func learnedDemoTemplate(from params: [String: Any]) throws -> ProfileTemplate? {
        let host = nonEmptyString(params["host"])
        let sig = nonEmptyString(params["elementSig"] ?? params["element_sig"] ?? params["sig"])
        let actionType = nonEmptyString(params["actionType"] ?? params["action_type"])
        let taskId = nonEmptyString(params["taskId"] ?? params["task_id"])
        return try profileStore.listTemplates(host: host)
            .filter { template in
                ["click", "move", "drag", "type", "scroll"].contains(template.actionType)
                    && template.host != Self.managementLearningDemoBaselineHost
                    && template.confidence >= 0.5
                    && (sig == nil || template.elementSig == sig)
                    && (actionType == nil || template.actionType == actionType)
                    && (taskId == nil || template.taskId == taskId)
            }
            .sorted { lhs, rhs in
                if lhs.confidence != rhs.confidence {
                    return lhs.confidence > rhs.confidence
                }
                if lhs.sampleSize != rhs.sampleSize {
                    return lhs.sampleSize > rhs.sampleSize
                }
                return lhs.updatedAt > rhs.updatedAt
            }
            .first
    }

    private func managementDemoPoints(width: Double, height: Double, count: Int) -> [(origin: CGPoint, target: CGPoint)] {
        let minX = max(56, width * 0.12)
        let maxX = min(width - 56, width * 0.84)
        let minY = max(64, height * 0.16)
        let maxY = min(height - 64, height * 0.72)
        var rng = SystemRandomNumberGenerator()
        return (0..<count).map { index in
            let progress = Double(index) / Double(max(count - 1, 1))
            let origin = CGPoint(
                x: minX + (maxX - minX) * Double.random(in: 0.06..<0.38, using: &rng),
                y: maxY - (maxY - minY) * Double.random(in: 0.04..<0.34, using: &rng)
            )
            let target = CGPoint(
                x: minX + (maxX - minX) * min(0.92, Double.random(in: 0.52..<0.88, using: &rng) + progress * 0.04),
                y: minY + (maxY - minY) * Double.random(in: 0.18..<0.62, using: &rng)
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
                "taskId": template.taskId ?? Self.managementLearningDemoDefaultTask,
                "stage": baseline ? "baseline" : "management-center-demo"
            ],
            "options": [
                "dryRun": true,
                "disableProfiles": baseline,
                "postMode": "global",
                "browserChromeOverlayPolicy": "off",
                "timeoutMs": 8_000
            ],
            "primitives": [primitive]
        ]
    }

    private func managementDemoStepSpec(
        action: ManagementDemoAction,
        width: Double,
        height: Double,
        params: [String: Any]
    ) -> [String: Any] {
        let reuseLastPoints = boolValue(params["reuseLastPoints"] ?? params["reuse_last_points"] ?? params["reusePoints"]) ?? false
        let spec: LearningDemoPointSpec
        let pointMode: String
        if reuseLastPoints, let previous = lock.withLock({ lastLearningDemoPointSpecs[action.rawValue] }) {
            spec = previous
            pointMode = "reused-last"
        } else {
            spec = randomLearningDemoPointSpec(action: action, width: width, height: height)
            pointMode = "random"
            lock.withLock {
                lastLearningDemoPointSpecs[action.rawValue] = spec
            }
        }
        return [
            "action": action.rawValue,
            "pointMode": pointMode,
            "reuseLastPoints": reuseLastPoints,
            "startPoint": pointObject(spec.startPoint),
            "targetPoint": pointObject(spec.targetPoint),
            "actualPointExpected": pointObject(spec.actualPointExpected),
            "scrollDelta": spec.scrollDelta.map { ["dx": Int($0.dx), "dy": Int($0.dy)] } ?? NSNull(),
            "text": spec.text ?? NSNull()
        ]
    }

    private func randomLearningDemoPointSpec(action: ManagementDemoAction, width: Double, height: Double) -> LearningDemoPointSpec {
        var rng = SystemRandomNumberGenerator()
        let minX = max(48, width * 0.10)
        let maxX = min(width - 48, width * 0.88)
        let minY = max(64, height * 0.14)
        let maxY = min(height - 64, height * 0.78)
        let start = CGPoint(
            x: minX + (maxX - minX) * Double.random(in: 0.04..<0.42, using: &rng),
            y: minY + (maxY - minY) * Double.random(in: 0.56..<0.94, using: &rng)
        )
        let target = CGPoint(
            x: minX + (maxX - minX) * Double.random(in: 0.48..<0.94, using: &rng),
            y: minY + (maxY - minY) * Double.random(in: 0.08..<0.56, using: &rng)
        )
        switch action {
        case .drag:
            let end = CGPoint(
                x: minX + (maxX - minX) * Double.random(in: 0.50..<0.92, using: &rng),
                y: minY + (maxY - minY) * Double.random(in: 0.46..<0.88, using: &rng)
            )
            return LearningDemoPointSpec(startPoint: start, targetPoint: end, actualPointExpected: end, scrollDelta: nil, text: nil)
        case .scroll:
            let dy = -Int(Double.random(in: 96..<260, using: &rng).rounded())
            return LearningDemoPointSpec(startPoint: start, targetPoint: target, actualPointExpected: target, scrollDelta: CGVector(dx: 0, dy: dy), text: nil)
        case .keyboard:
            return LearningDemoPointSpec(startPoint: start, targetPoint: target, actualPointExpected: target, scrollDelta: nil, text: "vhid")
        default:
            return LearningDemoPointSpec(startPoint: start, targetPoint: target, actualPointExpected: target, scrollDelta: nil, text: nil)
        }
    }

    private func managementDemoStepActionParams(
        action: ManagementDemoAction,
        template: ProfileTemplate,
        width: Double,
        height: Double,
        spec: [String: Any],
        requestId: String
    ) throws -> [String: Any] {
        let origin = try point(spec["startPoint"] as? [String: Any], name: "startPoint")
        let target = try point(spec["targetPoint"] as? [String: Any], name: "targetPoint")
        let scrollDelta = spec["scrollDelta"] as? [String: Any]
        let scrollDy = number(scrollDelta?["dy"]) ?? -168
        let host = template.host
        let sig = template.elementSig
        let taskId = template.taskId ?? Self.managementLearningDemoDefaultTask
        let primitives: [[String: Any]]
        switch action {
        case .move:
            primitives = [[
                "type": "move",
                "to": pointObject(target),
                "profile": ["origin": pointObject(origin)]
            ]]
        case .click:
            primitives = [[
                "type": "click",
                "at": pointObject(target),
                "button": "left",
                "profile": ["origin": pointObject(origin)]
            ]]
        case .dblclick:
            primitives = [[
                "type": "click",
                "at": pointObject(target),
                "button": "left",
                "count": 2,
                "profile": ["origin": pointObject(origin)]
            ]]
        case .drag:
            primitives = [[
                "type": "drag",
                "from": pointObject(origin),
                "to": pointObject(target),
                "button": "left"
            ]]
        case .scroll:
            primitives = [
                [
                    "type": "move",
                    "to": pointObject(target),
                    "profile": ["origin": pointObject(CGPoint(x: max(40, origin.x - 120), y: origin.y))]
                ],
                ["type": "scroll", "at": pointObject(target), "dx": 0, "dy": scrollDy, "style": "wheel"]
            ]
        case .keyboard:
            primitives = [
                [
                    "type": "move",
                    "to": pointObject(target),
                    "profile": ["origin": pointObject(origin)]
                ],
                ["type": "type", "text": spec["text"] as? String ?? "vhid", "layout": "us"]
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
                "element": ["sig": sig, "role": action == .keyboard ? "textbox" : "button"],
                "taskId": taskId,
                "stage": "management-center-manual-demo"
            ],
            "options": [
                "dryRun": true,
                "postMode": "global",
                "browserChromeOverlayPolicy": "off",
                "timeoutMs": 8_000
            ],
            "primitives": primitives
        ]
    }

    private func learningDemoActionSummary(
        _ result: [String: Any],
        phase: String,
        ordinal: Int,
        template: ProfileTemplate?,
        demoAction: ManagementDemoAction? = nil,
        requested: [String: Any] = [:]
    ) -> [String: Any] {
        let events = result["events"] as? [[String: Any]] ?? []
        let profiles = result["profiles"] as? [String: Any] ?? [:]
        let verification = result["verification"] as? [String: Any] ?? [:]
        let mouseMoves = events.filter { $0["type"] as? String == "mouseMoved" }
        let mouseDowns = events.filter { ($0["type"] as? String)?.contains("MouseDown") == true }
        let mouseUps = events.filter { ($0["type"] as? String)?.contains("MouseUp") == true }
        let actionType = template?.actionType ?? demoAction?.templateActionType ?? primitiveType(events)
        var metrics = eventMetricsObject(events)
        let appliedFields: [String]
        if phase == "baseline" {
            appliedFields = []
        } else if let template {
            appliedFields = learningEffectFieldNames(template: template)
        } else {
            appliedFields = []
        }
        if demoAction == .scroll {
            metrics["scrollDelta"] = [
                "dx": 0,
                "dy": [-168, -92, -42],
                "totalDy": -302
            ]
        }
        var summary: [String: Any] = [
            "id": result["id"] ?? NSNull(),
            "ok": result["ok"] as? Bool ?? false,
            "phase": phase,
            "demoAction": demoAction?.rawValue ?? actionType,
            "title": demoAction?.title ?? (phase == "baseline" ? "对照动作：未使用键鼠习惯模板" : "学习动作 \(ordinal)：使用键鼠习惯模板"),
            "description": phase == "baseline"
                ? "用于对比的安全 dry-run，禁用模板，只展示基础拟人化轨迹。"
                : "使用历史样本聚合出的 MotionProfile 生成路线、速度、停顿和点击节奏。",
            "demonstrates": learningDemoDemonstrates(events: events),
            "profileApplied": profiles["applied"] as? Bool ?? false,
            "templateIds": profiles["templateIds"] ?? [],
            "learningEffect": [
                "templateApplied": profiles["applied"] as? Bool ?? false,
                "templateActionType": actionType,
                "appliedFields": appliedFields
            ],
            "humanization": [
                "profileApplied": profiles["applied"] as? Bool ?? false,
                "templateIds": profiles["templateIds"] ?? [],
                "eventChainTypes": events.compactMap { $0["type"] as? String }
            ],
            "primitive": learningDemoPrimitiveObject(events: events, verification: verification),
            "trajectory": learningDemoTrajectoryObject(events: events, metrics: metrics),
            "steps": learningDemoSteps(events: events, verification: verification),
            "eventChain": learningDemoEventChain(events),
            "metrics": metrics,
            "eventCount": events.count,
            "mouseMoveCount": mouseMoves.count,
            "mouseDownCount": mouseDowns.count,
            "mouseUpCount": mouseUps.count,
            "eventTypes": events.compactMap { $0["type"] as? String },
            "expectedPointer": verification["expectedPointer"] ?? NSNull(),
            "finalPointer": verification["finalPointer"] ?? NSNull()
        ]
        if !requested.isEmpty {
            summary["requested"] = requested
        }
        return summary
    }

    private func learningDemoPlanObject(template: ProfileTemplate, actionCount: Int) -> [String: Any] {
        [
            "source": "virtualhid-action-events",
            "safePreview": true,
            "actionCount": actionCount,
            "sequence": [
                "对照动作：禁用学习模板，生成基础轨迹和点击事件。",
                "学习动作：命中能力模板，生成带学习参数的移动轨迹。",
                "逐步展示：移动起点、滑动轨迹、按下、保持、松开、落点校验。"
            ],
            "templateScope": [
                "host": template.host,
                "elementSig": template.elementSig,
                "taskId": (template.taskId as Any?) ?? NSNull(),
                "actionType": template.actionType
            ]
        ]
    }

    private func learningEffectObject(template: ProfileTemplate) -> [String: Any] {
        [
            "learns": [
                "routeShape": ["pointCount", "straightnessMean", "turnJitterMean", "wind", "gravity", "maxStep", "jitter", "controlSpread", "detourProbability", "targetSpreadPx"],
                "movementTiming": ["moveSpeedPxS", "dragSpeedPxS", "hesitationProbability", "hesitationMs", "settleMs", "pathSkeleton", "segmentMs"],
                "clickTiming": ["clickHoldMs", "interClickMs", "doubleClickHoldMs", "doubleClickInterClickMs", "doubleClickSecondOffsetPx"],
                "scrollTiming": ["scrollDeltaX", "scrollDeltaY", "scrollStepCount", "scrollStepDelayMs", "scrollInertiaDecay"],
                "keyboardTiming": ["dwellMs", "interKeyMs", "modifierHoldMs", "keyRepeatDelayMs", "keyRepeatIntervalMs", "dwellMsMean", "interKeyMsMean"]
            ],
            "appliesThrough": [
                "applyProfiles merges matching ProfileTemplate MotionProfile into ActionPrimitive before ActionExecutor emits events.",
                "ActionExecutor uses MotionProfile for path generation, point count, timing curve, click hold, inter-click, settle, detour and key rhythm."
            ],
            "activeFields": learningEffectFieldNames(template: template)
        ]
    }

    private func learningEffectFieldNames(template: ProfileTemplate) -> [String] {
        guard let motion = decodedMotionProfile(from: template) else {
            return []
        }
        var fields = [String]()
        if motion.flavor != nil { fields.append("flavor") }
        if motion.behaviorBlend != nil { fields.append("behaviorBlend") }
        if motion.moveSpeedPxS != nil { fields.append("moveSpeedPxS") }
        if motion.dragSpeedPxS != nil { fields.append("dragSpeedPxS") }
        if motion.pointCount != nil { fields.append("pointCount") }
        if motion.overshootProbability != nil { fields.append("overshootProbability") }
        if motion.wind != nil { fields.append("wind") }
        if motion.gravity != nil { fields.append("gravity") }
        if motion.maxStep != nil { fields.append("maxStep") }
        if motion.jitter != nil { fields.append("jitter") }
        if motion.controlSpread != nil { fields.append("controlSpread") }
        if motion.targetSpreadPx != nil { fields.append("targetSpreadPx") }
        if motion.hesitationProbability != nil { fields.append("hesitationProbability") }
        if motion.hesitationMs != nil { fields.append("hesitationMs") }
        if motion.settleMs != nil { fields.append("settleMs") }
        if motion.detourProbability != nil { fields.append("detourProbability") }
        if motion.clickHoldMs != nil { fields.append("clickHoldMs") }
        if motion.interClickMs != nil { fields.append("interClickMs") }
        if motion.doubleClickHoldMs != nil { fields.append("doubleClickHoldMs") }
        if motion.doubleClickInterClickMs != nil { fields.append("doubleClickInterClickMs") }
        if motion.doubleClickSecondOffsetPx != nil { fields.append("doubleClickSecondOffsetPx") }
        if motion.scrollDeltaX != nil { fields.append("scrollDeltaX") }
        if motion.scrollDeltaY != nil { fields.append("scrollDeltaY") }
        if motion.scrollStepCount != nil { fields.append("scrollStepCount") }
        if motion.scrollStepDelayMs != nil { fields.append("scrollStepDelayMs") }
        if motion.scrollInertiaDecay != nil { fields.append("scrollInertiaDecay") }
        if motion.dwellMs != nil { fields.append("dwellMs") }
        if motion.interKeyMs != nil { fields.append("interKeyMs") }
        if motion.modifierHoldMs != nil { fields.append("modifierHoldMs") }
        if motion.keyRepeatDelayMs != nil { fields.append("keyRepeatDelayMs") }
        if motion.keyRepeatIntervalMs != nil { fields.append("keyRepeatIntervalMs") }
        if motion.pathSkeleton != nil { fields.append("pathSkeleton") }
        if motion.segmentMs != nil { fields.append("segmentMs") }
        if motion.dwellMsMean != nil { fields.append("dwellMsMean") }
        if motion.interKeyMsMean != nil { fields.append("interKeyMsMean") }
        if motion.straightnessMean != nil { fields.append("straightnessMean") }
        if motion.turnJitterMean != nil { fields.append("turnJitterMean") }
        return fields
    }

    private func learningDemoDemonstrates(events: [[String: Any]]) -> [String] {
        var capabilities = [String]()
        if events.contains(where: { $0["type"] as? String == "mouseMoved" }) {
            capabilities.append("mouseMoveTrajectory")
        }
        if events.contains(where: { ($0["type"] as? String)?.contains("MouseDown") == true }) {
            capabilities.append("mouseDown")
        }
        if !replayHoldDurations(from: injectedEvents(from: events)).isEmpty {
            capabilities.append("pressHoldDuration")
        }
        if events.contains(where: { ($0["type"] as? String)?.contains("MouseUp") == true }) {
            capabilities.append("mouseUp")
        }
        if events.contains(where: { $0["type"] as? String == "keyDown" || $0["type"] as? String == "keyUp" }) {
            capabilities.append("keyboardRhythm")
        }
        return capabilities
    }

    private func learningDemoPrimitiveObject(events: [[String: Any]], verification: [String: Any]) -> [String: Any] {
        let points = eventPoints(events)
        let down = events.first { ($0["type"] as? String)?.contains("MouseDown") == true }
        let up = events.first { ($0["type"] as? String)?.contains("MouseUp") == true }
        return [
            "type": primitiveType(events),
            "startPoint": (points.first.map(pointObject) as Any?) ?? NSNull(),
            "targetPoint": (pointObjectFromAny(verification["expectedPointer"]) as Any?) ?? (points.last.map(pointObject) as Any?) ?? NSNull(),
            "finalPoint": (pointObjectFromAny(verification["finalPointer"]) as Any?) ?? (points.last.map(pointObject) as Any?) ?? NSNull(),
            "mouseDownPoint": (eventPoint(from: down).map(pointObject) as Any?) ?? NSNull(),
            "mouseUpPoint": (eventPoint(from: up).map(pointObject) as Any?) ?? NSNull()
        ]
    }

    private func learningDemoTrajectoryObject(events: [[String: Any]], metrics: [String: Any]) -> [String: Any] {
        let points = eventPoints(events)
        return [
            "source": "virtualhid-action-events",
            "startPoint": (points.first.map(pointObject) as Any?) ?? NSNull(),
            "endPoint": (points.last.map(pointObject) as Any?) ?? NSNull(),
            "points": points.map(pointObject),
            "pointCount": points.count,
            "pathLengthPx": metrics["pathLengthPx"] ?? NSNull(),
            "durationMs": metrics["durationMs"] ?? NSNull(),
            "speedPxS": metrics["speedPxS"] ?? NSNull(),
            "straightness": metrics["straightness"] ?? NSNull(),
            "turnJitter": metrics["turnJitter"] ?? NSNull()
        ]
    }

    private func learningDemoEventChain(_ events: [[String: Any]]) -> [[String: Any]] {
        events.enumerated().map { index, event in
            [
                "index": index,
                "type": event["type"] as? String ?? "event",
                "location": event["location"] ?? NSNull(),
                "key": event["key"] ?? NSNull(),
                "virtualKey": event["virtualKey"] ?? NSNull(),
                "timestamp": event["timestamp"] ?? NSNull()
            ]
        }
    }

    private func learningDemoSteps(events: [[String: Any]], verification: [String: Any]) -> [[String: Any]] {
        var steps = [[String: Any]]()
        let points = eventPoints(events)
        let moveEvents = events.filter { $0["type"] as? String == "mouseMoved" }
        let movePoints = eventPoints(moveEvents)
        let expected = pointObjectFromAny(verification["expectedPointer"]) ?? points.last.map(pointObject)
        let final = pointObjectFromAny(verification["finalPointer"]) ?? points.last.map(pointObject)

        if let first = points.first {
            steps.append([
                "index": steps.count,
                "phase": "prepareMove",
                "title": "准备移动",
                "detail": "确认起点和预期终点，等待 VirtualHID 事件流。",
                "startPoint": pointObject(first),
                "targetPoint": (expected as Any?) ?? NSNull()
            ])
        }

        if let first = movePoints.first, let last = movePoints.last {
            let metrics = eventMetricsObject(moveEvents)
            steps.append([
                "index": steps.count,
                "phase": "move",
                "title": "滑动轨迹",
                "detail": "沿 VirtualHID 生成的 mouseMoved 点序列移动。",
                "startPoint": pointObject(first),
                "endPoint": pointObject(last),
                "pointCount": movePoints.count,
                "durationMs": metrics["durationMs"] ?? NSNull(),
                "pathLengthPx": metrics["pathLengthPx"] ?? NSNull()
            ])
        }

        let injected = injectedEvents(from: events)
        for (index, event) in events.enumerated() {
            guard let type = event["type"] as? String else {
                continue
            }
            if type.contains("MouseDown") {
                let hold = holdDurationFrom(events: injected, downIndex: index)
                steps.append([
                    "index": steps.count,
                    "phase": "mouseDown",
                    "title": "开始下压",
                    "detail": "生成 \(type)；演示为 dry-run，不投递真实点击。",
                    "eventIndex": index,
                    "point": event["location"] ?? NSNull()
                ])
                if let hold {
                    steps.append([
                        "index": steps.count,
                        "phase": "hold",
                        "title": "保持按压",
                        "detail": "保持按压 \(Int(hold.rounded()))ms。",
                        "durationMs": hold,
                        "point": event["location"] ?? NSNull()
                    ])
                }
            } else if type.contains("MouseUp") {
                steps.append([
                    "index": steps.count,
                    "phase": "mouseUp",
                    "title": "松开",
                    "detail": "生成 \(type)，完成一次点击时序。",
                    "eventIndex": index,
                    "point": event["location"] ?? NSNull()
                ])
            }
        }

        if expected != nil || final != nil {
            steps.append([
                "index": steps.count,
                "phase": "verifyLanding",
                "title": "落点校验",
                "detail": "对比预期目标落点和 VirtualHID 最终落点。",
                "expectedPointer": (expected as Any?) ?? NSNull(),
                "finalPointer": (final as Any?) ?? NSNull()
            ])
        }
        return steps
    }

    private func eventPoints(_ events: [[String: Any]]) -> [CGPoint] {
        events.compactMap(eventPoint)
    }

    private func eventPoint(from event: [String: Any]?) -> CGPoint? {
        guard let location = event?["location"] as? [String: Any],
              let x = number(location["x"]),
              let y = number(location["y"]) else {
            return nil
        }
        return CGPoint(x: x, y: y)
    }

    private func pointObjectFromAny(_ value: Any?) -> [String: Double]? {
        guard let object = value as? [String: Any],
              let x = number(object["x"]),
              let y = number(object["y"]) else {
            return nil
        }
        return ["x": x, "y": y]
    }

    private func primitiveType(_ events: [[String: Any]]) -> String {
        if events.contains(where: { ($0["type"] as? String)?.contains("MouseDown") == true }) {
            return "click"
        }
        if events.contains(where: { ($0["type"] as? String)?.contains("Dragged") == true }) {
            return "drag"
        }
        if events.contains(where: { $0["type"] as? String == "scrollWheel" }) {
            return "scroll"
        }
        if events.contains(where: { $0["type"] as? String == "keyDown" || $0["type"] as? String == "pasteText" }) {
            return "type"
        }
        return events.contains(where: { $0["type"] as? String == "mouseMoved" }) ? "move" : "action"
    }

    private func holdDurationFrom(events: [InjectedEvent], downIndex: Int) -> Double? {
        guard events.indices.contains(downIndex),
              events[downIndex].type.contains("MouseDown"),
              let downDate = eventDate(events[downIndex]) else {
            return nil
        }
        guard let up = events.dropFirst(downIndex + 1).first(where: { $0.type.contains("MouseUp") }),
              let upDate = eventDate(up) else {
            return nil
        }
        return max(0, upDate.timeIntervalSince(downDate) * 1000)
    }

    private func eventMetricsObject(_ events: [[String: Any]]) -> [String: Any] {
        let points = events.compactMap { event -> CGPoint? in
            guard let location = event["location"] as? [String: Any],
                  let x = number(location["x"]),
                  let y = number(location["y"]) else {
                return nil
            }
            return CGPoint(x: x, y: y)
        }
        let pathLength = zip(points.dropFirst(), points).reduce(0.0) { total, pair in
            total + hypot(pair.0.x - pair.1.x, pair.0.y - pair.1.y)
        }
        let durationMs = eventDurationMs(events)
        let straightness: Double?
        if let first = points.first, let last = points.last, pathLength > 0 {
            straightness = max(0, min(1, hypot(last.x - first.x, last.y - first.y) / pathLength))
        } else {
            straightness = nil
        }
        let speedPxS: Double?
        if let durationMs, durationMs > 0, pathLength > 0 {
            speedPxS = pathLength / durationMs * 1000
        } else {
            speedPxS = nil
        }
        return [
            "pointCount": points.count,
            "pathLengthPx": pathLength,
            "durationMs": durationMs as Any? ?? NSNull(),
            "speedPxS": speedPxS as Any? ?? NSNull(),
            "straightness": straightness as Any? ?? NSNull(),
            "turnJitter": turnJitter(points) as Any? ?? NSNull(),
            "clickHoldMs": replayHoldDurations(from: injectedEvents(from: events)),
            "interClickMs": replayInterClickDurations(from: injectedEvents(from: events))
        ]
    }

    private func injectedEvents(from events: [[String: Any]]) -> [InjectedEvent] {
        events.map { event in
            let location = (event["location"] as? [String: Any]).flatMap { pointObject -> CodablePoint? in
                guard let x = number(pointObject["x"]), let y = number(pointObject["y"]) else {
                    return nil
                }
                return CodablePoint(x: x, y: y)
            }
            let virtualKey = (event["virtualKey"] as? UInt16) ?? intValue(event["virtualKey"]).map(UInt16.init)
            return InjectedEvent(
                type: event["type"] as? String ?? "event",
                location: location,
                key: event["key"] as? String,
                virtualKey: virtualKey,
                timestamp: event["timestamp"] as? String ?? ""
            )
        }
    }

    private func eventDurationMs(_ events: [[String: Any]]) -> Double? {
        let dates = events.compactMap { event -> Date? in
            guard let timestamp = event["timestamp"] as? String else {
                return nil
            }
            return isoFormatter.date(from: timestamp)
        }
        guard let first = dates.first, let last = dates.last, last >= first else {
            return nil
        }
        return last.timeIntervalSince(first) * 1000
    }

    private func turnJitter(_ points: [CGPoint]) -> Double? {
        guard points.count > 2 else {
            return nil
        }
        var turns = [Double]()
        for index in 1..<(points.count - 1) {
            let previous = points[index - 1]
            let current = points[index]
            let next = points[index + 1]
            let a1 = atan2(current.y - previous.y, current.x - previous.x)
            let a2 = atan2(next.y - current.y, next.x - current.x)
            turns.append(abs(normalizeAngle(a2 - a1)) / Double.pi)
        }
        return turns.isEmpty ? nil : turns.reduce(0, +) / Double(turns.count)
    }

    private func normalizeAngle(_ value: Double) -> Double {
        var result = value
        while result > Double.pi {
            result -= Double.pi * 2
        }
        while result < -Double.pi {
            result += Double.pi * 2
        }
        return result
    }

    private func learningTemplateSummaryObject(_ template: ProfileTemplate) -> [String: Any] {
        var object: [String: Any] = [
            "host": template.host,
            "elementSig": template.elementSig,
            "taskId": template.taskId ?? NSNull(),
            "actionType": template.actionType,
            "sampleSize": template.sampleSize,
            "confidence": template.confidence,
            "updatedAt": template.updatedAt,
            "updatedAtText": isoString(ms: template.updatedAt)
        ]
        if let motion = decodedMotionProfile(from: template) {
            object["motion"] = motionSummaryObject(motion)
        }
        return object
    }

    private func motionSummaryObject(_ motion: MotionProfile) -> [String: Any] {
        [
            "flavor": motion.flavor?.rawValue ?? NSNull(),
            "behaviorBlend": motion.behaviorBlend.map { blend in
                [
                    "idle": blend.idle,
                    "normal": blend.normal,
                    "flow": blend.flow,
                    "lowEfficiency": blend.lowEfficiency
                ]
            } ?? NSNull(),
            "moveSpeedPxS": rangeObject(motion.moveSpeedPxS),
            "dragSpeedPxS": rangeObject(motion.dragSpeedPxS),
            "pointCount": rangeObject(motion.pointCount),
            "clickHoldMs": rangeObject(motion.clickHoldMs),
            "interClickMs": rangeObject(motion.interClickMs),
            "dwellMsMean": motion.dwellMsMean as Any? ?? NSNull(),
            "interKeyMsMean": motion.interKeyMsMean as Any? ?? NSNull(),
            "straightnessMean": motion.straightnessMean as Any? ?? NSNull(),
            "turnJitterMean": motion.turnJitterMean as Any? ?? NSNull(),
            "hesitationProbability": motion.hesitationProbability as Any? ?? NSNull(),
            "detourProbability": motion.detourProbability as Any? ?? NSNull(),
            "targetSpreadPx": motion.targetSpreadPx as Any? ?? NSNull()
        ]
    }

    private func rangeObject(_ range: IntRange?) -> Any {
        guard let range else {
            return NSNull()
        }
        return ["min": range.min, "max": range.max]
    }

    private func rangeObject(_ range: DoubleRange?) -> Any {
        guard let range else {
            return NSNull()
        }
        return ["min": range.min, "max": range.max]
    }

    private func cancelCurrentAction() {
        lock.withLock {
            currentExecutor?.cancel()
        }
    }

    private func ensureEventTapForLearningIfNeeded() {
        let learning = supervisor.observer.learningState
        guard learning.settings.enabled, learning.settings.mode != .off else {
            return
        }
        guard !supervisor.snapshot().eventTapRunning else {
            return
        }
        try? supervisor.startEventTap(promptForPermission: false)
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
                keyCode: sample.keyCode,
                points: sample.pathSkeleton.map { TracePoint(x: $0.x, y: $0.y) },
                origin: sample.pathSkeleton.first.map { TracePoint(x: $0.x, y: $0.y) },
                targetPoint: sample.pathSkeleton.last.map { TracePoint(x: $0.x, y: $0.y) },
                durationMs: sample.durationMs,
                segmentMs: sample.segmentMs,
                hesitationMs: sample.hesitationMs,
                clickHoldMs: sample.clickHoldMs,
                interClickMs: sample.interClickMs,
                dwellMs: sample.dwellMs,
                interKeyMs: sample.interKeyMs,
                scrollDeltas: sample.scrollDeltas.map { TraceScrollDelta(dx: $0.dx, dy: $0.dy) },
                scrollIntervalsMs: sample.scrollIntervalsMs,
                doubleClickIntervalMs: sample.doubleClickIntervalMs,
                modifierFlags: sample.modifierFlags,
                flagsChangedKeyCodes: sample.flagsChangedKeyCodes,
                comboKeyCodes: sample.comboKeyCodes,
                repeatCount: sample.repeatCount,
                eventTimeline: sample.eventTimeline,
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
            browserChromeOverlayPolicy: browserChromeOverlayPolicy(from: object),
            disableProfiles: object["disableProfiles"] as? Bool
                ?? object["disable_profiles"] as? Bool
                ?? false
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
                    style: scrollStyle(primitive["style"] as? String),
                    profile: profile
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
            case .scroll(let at, let dx, let dy, let style, let profile):
                return .scroll(
                    at: at,
                    dx: dx,
                    dy: dy,
                    style: style,
                    profile: mergedPrimitiveProfile(profile, motionProfile: motionProfile)
                )
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

    private func traceSummaryObject(_ trace: TraceSummary) -> [String: Any] {
        [
            "id": Int(trace.id),
            "ts": trace.ts,
            "tsText": isoString(ms: trace.ts),
            "source": trace.source,
            "host": trace.host,
            "elementSig": trace.elementSig as Any? ?? NSNull(),
            "taskId": trace.taskId as Any? ?? NSNull(),
            "stage": trace.stage as Any? ?? NSNull(),
            "actionType": trace.actionType,
            "eventType": trace.eventType,
            "pointCount": trace.pointCount,
            "durationMs": trace.durationMs as Any? ?? NSNull(),
            "clickHoldMs": trace.clickHoldMs,
            "interClickMs": trace.interClickMs,
            "dwellMs": trace.dwellMs,
            "interKeyMs": trace.interKeyMs,
            "pathLengthPx": trace.pathLengthPx as Any? ?? NSNull(),
            "speedPxS": trace.speedPxS as Any? ?? NSNull(),
            "straightness": trace.straightness as Any? ?? NSNull(),
            "turnJitter": trace.turnJitter as Any? ?? NSNull()
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
        case .scroll(let at, _, _, _, _):
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
        scrollDeltas: parseTraceScrollDeltas(payloadObject["scrollDeltas"]),
        scrollIntervalsMs: parseDoubleArray(payloadObject["scrollIntervalsMs"]),
        doubleClickIntervalMs: parseDoubleArray(payloadObject["doubleClickIntervalMs"]),
        modifierFlags: parseUInt64Array(payloadObject["modifierFlags"]),
        flagsChangedKeyCodes: parseUInt16Array(payloadObject["flagsChangedKeyCodes"]),
        comboKeyCodes: parseUInt16Array(payloadObject["comboKeyCodes"]),
        repeatCount: intValue(payloadObject["repeatCount"]) ?? 0,
        eventTimeline: parseStringArray(payloadObject["eventTimeline"]),
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

private func parseTraceScrollDeltas(_ value: Any?) -> [TraceScrollDelta] {
    guard let objects = value as? [[String: Any]] else {
        return []
    }
    return objects.compactMap { object in
        guard let dx = number(object["dx"]),
              let dy = number(object["dy"]) else {
            return nil
        }
        return TraceScrollDelta(dx: dx, dy: dy)
    }
}

private func parseUInt16Array(_ value: Any?) -> [UInt16] {
    guard let values = value as? [Any] else {
        return []
    }
    return values.compactMap { value in
        guard let int = intValue(value), int >= 0, int <= Int(UInt16.max) else {
            return nil
        }
        return UInt16(int)
    }
}

private func parseUInt64Array(_ value: Any?) -> [UInt64] {
    guard let values = value as? [Any] else {
        return []
    }
    return values.compactMap { value in
        if let uint = value as? UInt64 {
            return uint
        }
        guard let int = intValue(value), int >= 0 else {
            return nil
        }
        return UInt64(int)
    }
}

private func parseStringArray(_ value: Any?) -> [String] {
    guard let values = value as? [Any] else {
        return []
    }
    return values.compactMap { $0 as? String }
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
        return sanitizedMotionProfile(learned.motion)
    }
    if let direct = try? decoder.decode(MotionProfile.self, from: data) {
        return sanitizedMotionProfile(direct)
    }
    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        return nil
    }
    return (try? parseMotionProfile(sources: [object["motion"], object["motionProfile"], object])).map(sanitizedMotionProfile)
}

private func sanitizedMotionProfile(_ profile: MotionProfile) -> MotionProfile {
    var sanitized = profile
    if let controlSpread = sanitized.controlSpread, controlSpread > 1 {
        sanitized.controlSpread = min(max(controlSpread / 180.0, 0.05), 0.34)
    }
    return sanitized
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
