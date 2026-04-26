import AppKit
import Foundation
import ControlServer
import CoreGraphics
import HIDVisualization
import InjectorCore
import ProfileStore
import Supervisor

struct DaemonConfiguration {
    var socketPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("virtualhid.sock")
    var dbPath: String?
    var bundleIdentifiers = ["com.google.Chrome", "org.chromium.Chromium", "com.microsoft.edgemac", "com.apple.Safari"]
    var defaultPostMode = PostMode.global
    var startEventTap = true
    var allowSelfTarget = false
    var allowSelfTargetDaemon = false
    var visualizeHID = false
    var hudControl = false
    var hudLockedOff = false
    var hudSettings = HIDOverlaySettings()
    var smoke: String?
}

enum DaemonArguments {
    static func parse(_ arguments: [String]) -> DaemonConfiguration {
        var configuration = DaemonConfiguration()
        var requestedHUD = false
        var disabledHUD = false
        var requestedHUDControl = false
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--socket-path":
                if let value = iterator.next() {
                    configuration.socketPath = value
                }
            case "--db-path":
                if let value = iterator.next() {
                    configuration.dbPath = value
                }
            case "--bundle":
                if let value = iterator.next() {
                    configuration.bundleIdentifiers = value.split(separator: ",").map(String.init)
                }
            case "--default-post-mode":
                if let value = iterator.next(), let mode = PostMode(rawValue: value) {
                    configuration.defaultPostMode = mode
                }
            case "--no-event-tap":
                configuration.startEventTap = false
            case "--self-target":
                configuration.allowSelfTarget = true
            case "--allow-self-target-daemon":
                configuration.allowSelfTargetDaemon = true
            case "--visualize-hid":
                requestedHUD = true
            case "--no-hud":
                disabledHUD = true
            case "--hud-control":
                requestedHUDControl = true
            case "--hud-clear-delay":
                if let value = iterator.next(), let seconds = Double(value), seconds.isFinite, seconds > 0 {
                    configuration.hudSettings.clearDelaySeconds = seconds
                }
            case "--hud-show":
                if let value = iterator.next() {
                    applyHUDComponents(value, visible: true, settings: &configuration.hudSettings)
                }
            case "--hud-hide":
                if let value = iterator.next() {
                    applyHUDComponents(value, visible: false, settings: &configuration.hudSettings)
                }
            case "--smoke-kill-switch":
                configuration.smoke = "kill-switch"
            case "--smoke-observer":
                configuration.smoke = "observer"
            case "--smoke-profile-learn":
                configuration.smoke = "profile-learn"
            case "--smoke-learning":
                configuration.smoke = "learning"
            case "--smoke-hud-contract":
                configuration.smoke = "hud-contract"
            case "--smoke-hud-ui":
                configuration.smoke = "hud-ui"
            default:
                continue
            }
        }
        if ProcessInfo.processInfo.environment["VIRTUALHID_VISUALIZE_HID"] == "1" {
            requestedHUD = true
        }
        if ProcessInfo.processInfo.environment["VIRTUALHID_NO_HUD"] == "1" {
            disabledHUD = true
        }
        if ProcessInfo.processInfo.environment["VIRTUALHID_HUD_CONTROL"] == "1" {
            requestedHUDControl = true
        }
        if let seconds = environmentDouble("VIRTUALHID_HUD_CLEAR_DELAY_SECONDS", defaultValue: nil) {
            configuration.hudSettings.clearDelaySeconds = seconds
        }
        if let value = ProcessInfo.processInfo.environment["VIRTUALHID_HUD_SHOW"] {
            applyHUDComponents(value, visible: true, settings: &configuration.hudSettings)
        }
        if let value = ProcessInfo.processInfo.environment["VIRTUALHID_HUD_HIDE"] {
            applyHUDComponents(value, visible: false, settings: &configuration.hudSettings)
        }
        configuration.hudLockedOff = disabledHUD
        configuration.visualizeHID = requestedHUD && !disabledHUD
        configuration.hudControl = (requestedHUD || requestedHUDControl) && !disabledHUD
        if ProcessInfo.processInfo.environment["VIRTUALHID_ALLOW_SELF_TARGET_DAEMON"] == "1" {
            configuration.allowSelfTargetDaemon = true
        }
        return configuration
    }
}

enum DaemonLaunchError: Error, LocalizedError {
    case selfTargetRequiresExplicitOverride

    var errorDescription: String? {
        switch self {
        case .selfTargetRequiresExplicitOverride:
            return "--self-target is only for VirtualHID smoke/self-test; workflow daemons must target Chrome or another configured app. Add --allow-self-target-daemon only for local smoke harnesses."
        }
    }
}

let configuration = DaemonArguments.parse(CommandLine.arguments)

do {
    switch configuration.smoke {
    case "kill-switch":
        try runKillSwitchSmoke()
    case "observer":
        try runObserverSmoke(configuration: configuration)
    case "profile-learn":
        try runProfileLearnSmoke(configuration: configuration)
    case "learning":
        try runLearningSmoke(configuration: configuration)
    case "hud-contract":
        try runHUDContractSmoke(configuration: configuration)
    case "hud-ui":
        try runHUDUISmoke(configuration: configuration)
    default:
        try runDaemon(configuration: configuration)
    }
} catch {
    fputs("ERROR: \(error.localizedDescription)\n", stderr)
    exit(1)
}

private func runDaemon(configuration: DaemonConfiguration) throws {
    if configuration.allowSelfTarget && !configuration.allowSelfTargetDaemon {
        throw DaemonLaunchError.selfTargetRequiresExplicitOverride
    }

    setbuf(stdout, nil)
    let supervisor = SupervisorService()
    if configuration.startEventTap {
        do {
            try supervisor.startEventTap(promptForPermission: false)
        } catch {
            fputs("WARN: supervisor event tap unavailable: \(error.localizedDescription)\n", stderr)
        }
    }

    let store = try ProfileStore(path: try profileStorePath(configuration.dbPath))
    let hidOverlay = configuration.hudControl
        ? HIDOverlayController(
            settings: configuration.hudSettings,
            enabled: configuration.visualizeHID,
            lockedOff: configuration.hudLockedOff
        )
        : nil
    if hidOverlay != nil {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
    let service = ControlService(
        configuration: ControlServerConfiguration(
            bundleIdentifiers: configuration.bundleIdentifiers,
            defaultPostMode: configuration.defaultPostMode,
            allowSelfTarget: configuration.allowSelfTarget
        ),
        supervisor: supervisor,
        profileStore: store,
        hidEventSink: hidOverlay
    )
    let server = SocketServer(socketPath: configuration.socketPath, service: service)
    try server.start()
    print("vhid-daemon listening \(configuration.socketPath)")
    if hidOverlay != nil {
        withExtendedLifetime(hidOverlay) {
            NSApplication.shared.run()
        }
    } else {
        RunLoop.main.run()
    }
}

private func runKillSwitchSmoke() throws {
    let supervisor = SupervisorService()
    for _ in 0..<100 {
        supervisor.feedKeyEvent(type: .keyDown, keyCode: 0x35, sourceUserData: EventPoster.defaultMarkValue)
    }
    let selfMarkedTriggered = supervisor.killSwitch.isActive

    for _ in 0..<5 {
        supervisor.feedKeyEvent(type: .keyDown, keyCode: 0x35, sourceUserData: 0)
    }
    let activeAfterRealEsc = supervisor.killSwitch.isActive
    supervisor.killSwitch.unlock()

    try printJSON([
        "selfMarkedTriggered": selfMarkedTriggered,
        "activeAfterRealEsc": activeAfterRealEsc,
        "activeAfterUnlock": supervisor.killSwitch.isActive
    ])
}

private func runObserverSmoke(configuration: DaemonConfiguration) throws {
    let supervisor = SupervisorService()
    let store = try ProfileStore(path: try profileStorePath(configuration.dbPath))
    let service = ControlService(
        configuration: ControlServerConfiguration(allowSelfTarget: true),
        supervisor: supervisor,
        profileStore: store
    )

    _ = service.handleLine(#"{"id":"1","method":"observe","params":{"enable":true,"host":"example.com","taskId":"smoke"}}"#)
    let event = supervisor.observer.appendSynthetic(type: "leftMouseDown", point: ObservedPoint(x: 100, y: 200))
    let tail = service.handleLine(#"{"id":"2","method":"trace.tail","params":{"n":10}}"#)
    let commitLine = #"{"id":"3","method":"trace.commit","params":{"eventId":"\#(event.id)","elementSig":"sig-smoke","role":"button","host":"example.com","taskId":"smoke","stage":"stage-1"}}"#
    let commit = service.handleLine(commitLine)
    let passwordLine = #"{"id":"4","method":"trace.commit","params":{"eventId":"password-event","elementSig":"sig-password","role":"password","host":"example.com"}}"#
    let password = service.handleLine(passwordLine)

    try printJSON([
        "tail": try jsonObject(tail),
        "commit": try jsonObject(commit),
        "password": try jsonObject(password),
        "traceCount": try store.traceCount(host: "example.com")
    ])
}

private func runProfileLearnSmoke(configuration: DaemonConfiguration) throws {
    let store = try ProfileStore(path: try profileStorePath(configuration.dbPath))
    for index in 0..<10 {
        _ = try store.insertTrace(
            TraceInput(
                ts: Int64(Date().timeIntervalSince1970 * 1000) + Int64(index),
                source: "user",
                host: "example.com",
                elementSig: "sig-learn",
                taskId: "task-learn",
                stage: "stage-\(index % 2)",
                actionType: "click",
                payload: TracePayload(
                    eventId: "learn-\(index)",
                    type: "leftMouseDown",
                    point: TracePoint(x: 100 + Double(index), y: 200 + Double(index)),
                    points: [TracePoint(x: 100 + Double(index), y: 200 + Double(index))]
                )
            )
        )
    }

    let report = try store.rebuild(host: "example.com")
    let template = try store.getTemplate(host: "example.com", sig: "sig-learn")
    let templatesBeforeForget = try store.totalTemplates()
    _ = try store.forget(host: "example.com", sig: nil)

    try printJSON([
        "report": [
            "scannedTraces": report.scannedTraces,
            "generatedTemplates": report.generatedTemplates,
            "updatedTemplates": report.updatedTemplates
        ],
        "template": [
            "host": template.host,
            "elementSig": template.elementSig,
            "actionType": template.actionType,
            "sampleSize": template.sampleSize,
            "confidence": template.confidence,
            "params": try JSONSerialization.jsonObject(with: Data(template.paramsJSON.utf8))
        ],
        "templatesBeforeForget": templatesBeforeForget,
        "templatesAfterForget": try store.totalTemplates()
    ])
}

private func runLearningSmoke(configuration: DaemonConfiguration) throws {
    let supervisor = SupervisorService()
    let store = try ProfileStore(path: try profileStorePath(configuration.dbPath))
    let service = ControlService(
        configuration: ControlServerConfiguration(allowSelfTarget: true),
        supervisor: supervisor,
        profileStore: store
    )

    let initial = service.handleLine(#"{"id":"learning-initial","method":"learning.state","params":{}}"#)
    _ = service.handleLine(#"{"id":"learning-on","method":"learning.configure","params":{"enabled":true,"mode":"passive"}}"#)
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    for index in 0..<5 {
        let base = nowMs + Int64(index * 1_000)
        _ = supervisor.observer.appendSynthetic(type: "mouseMoved", point: ObservedPoint(x: 10, y: 10), ts: base)
        _ = supervisor.observer.appendSynthetic(type: "mouseMoved", point: ObservedPoint(x: 42 + Double(index), y: 24 + Double(index)), ts: base + 80)
        _ = supervisor.observer.appendSynthetic(type: "mouseMoved", point: ObservedPoint(x: 88 + Double(index), y: 58 + Double(index)), ts: base + 170)
        _ = supervisor.observer.appendSynthetic(type: "leftMouseDown", point: ObservedPoint(x: 120 + Double(index), y: 82 + Double(index)), ts: base + 240)
        _ = supervisor.observer.appendSynthetic(type: "leftMouseUp", point: ObservedPoint(x: 120 + Double(index), y: 82 + Double(index)), ts: base + 305)
    }
    let passiveState = service.handleLine(#"{"id":"learning-passive","method":"learning.state","params":{}}"#)

    let start = service.handleLine(#"{"id":"training-start","method":"learning.session.start","params":{"label":"专项鼠标训练","host":"training.local","targetAction":"click"}}"#)
    for index in 0..<5 {
        let base = nowMs + Int64(20_000 + index * 900)
        _ = supervisor.observer.appendSynthetic(type: "mouseMoved", point: ObservedPoint(x: 30, y: 30), ts: base)
        _ = supervisor.observer.appendSynthetic(type: "mouseMoved", point: ObservedPoint(x: 62 + Double(index), y: 45 + Double(index % 2)), ts: base + 65)
        _ = supervisor.observer.appendSynthetic(type: "mouseMoved", point: ObservedPoint(x: 110 + Double(index), y: 78 + Double(index % 3)), ts: base + 160)
        _ = supervisor.observer.appendSynthetic(type: "leftMouseDown", point: ObservedPoint(x: 146 + Double(index), y: 108 + Double(index)), ts: base + 230)
        _ = supervisor.observer.appendSynthetic(type: "leftMouseUp", point: ObservedPoint(x: 146 + Double(index), y: 108 + Double(index)), ts: base + 302)
    }
    let stop = service.handleLine(#"{"id":"training-stop","method":"learning.session.stop","params":{"commit":true}}"#)
    let finalState = service.handleLine(#"{"id":"learning-final","method":"learning.state","params":{}}"#)
    let passiveTemplate = try? store.lookupTemplate(
        host: ProfileStore.globalLearningHost,
        sig: "",
        taskId: nil,
        actionType: "click"
    )
    let trainingTemplate = try? store.lookupTemplate(
        host: "training.local",
        sig: "",
        taskId: nil,
        actionType: "click"
    )

    try printJSON([
        "initial": try jsonObject(initial),
        "passiveState": try jsonObject(passiveState),
        "trainingStart": try jsonObject(start),
        "trainingStop": try jsonObject(stop),
        "finalState": try jsonObject(finalState),
        "traceCountGlobal": try store.traceCount(host: ProfileStore.globalLearningHost),
        "traceCountTraining": try store.traceCount(host: "training.local"),
        "passiveTemplate": passiveTemplate.map { [
            "host": $0.host,
            "elementSig": $0.elementSig,
            "actionType": $0.actionType,
            "sampleSize": $0.sampleSize,
            "confidence": $0.confidence
        ] } ?? NSNull(),
        "trainingTemplate": trainingTemplate.map { [
            "host": $0.host,
            "elementSig": $0.elementSig,
            "actionType": $0.actionType,
            "sampleSize": $0.sampleSize,
            "confidence": $0.confidence
        ] } ?? NSNull()
    ])
}

private func runHUDContractSmoke(configuration: DaemonConfiguration) throws {
    let sink = configuration.visualizeHID ? SmokeHIDSink() : nil
    let service = ControlService(
        configuration: ControlServerConfiguration(allowSelfTarget: true),
        supervisor: SupervisorService(),
        profileStore: try ProfileStore(path: ":memory:"),
        hidEventSink: sink
    )
    let response = service.handleLine(
        #"{"id":"hud-smoke","method":"action","params":{"context":{"host":"hud.local","element":{"sig":"hud-button","role":"button"},"taskId":"hud-acceptance","stage":"visualization"},"options":{"dryRun":true,"postMode":"global"},"primitives":[{"type":"click","at":{"x":160,"y":120},"button":"left","profile":{"origin":{"x":160,"y":120}}},{"type":"scroll","at":{"x":160,"y":160},"dx":0,"dy":-72,"style":"wheel"}]}}"#
    )
    let decoded = try jsonObject(response) as? [String: Any] ?? [:]
    let result = decoded["result"] as? [String: Any] ?? [:]
    let events = result["events"] as? [[String: Any]] ?? []
    let verification = result["verification"] as? [String: Any] ?? [:]
    let responseObject: [String: Any] = [
        "eventCount": events.count,
        "expectedPointer": verification["expectedPointer"] ?? NSNull(),
        "finalPointer": verification["finalPointer"] ?? NSNull()
    ]
    let callbackObject: [String: Any] = [
        "started": sink?.started?.actionId ?? NSNull(),
        "startedSource": sink?.started?.source ?? NSNull(),
        "actionTypes": sink?.started?.actionTypes ?? [],
        "recordedEvents": sink?.recorded.count ?? 0,
        "finishedEvents": sink?.finished?.events.count ?? 0,
        "failed": sink?.failed ?? NSNull(),
        "expectedPointer": smokePointObject(sink?.finished?.verification.expectedPointer),
        "finalPointer": smokePointObject(sink?.finished?.verification.finalPointer)
    ]
    let output: [String: Any] = [
        "hudEnabled": configuration.visualizeHID,
        "hudControlEnabled": configuration.hudControl,
        "hudLockedOff": configuration.hudLockedOff,
        "hudSettings": hudSettingsObject(configuration.hudSettings),
        "actionOk": decoded["ok"] as? Bool ?? false,
        "source": "virtualhid-action-events",
        "response": responseObject,
        "callback": callbackObject
    ]
    try printJSON(output)
}

private func runHUDUISmoke(configuration: DaemonConfiguration) throws {
    NSApplication.shared.setActivationPolicy(.accessory)
    let sink = HIDOverlayController(
        settings: configuration.hudSettings
    )
    let smokeTarget = try resolveHUDSmokeTarget(configuration: configuration)
    let service = ControlService(
        configuration: ControlServerConfiguration(
            bundleIdentifiers: configuration.bundleIdentifiers,
            defaultPostMode: configuration.defaultPostMode,
            allowSelfTarget: smokeTarget.usesSelfTarget
        ),
        supervisor: SupervisorService(),
        profileStore: try ProfileStore(path: ":memory:"),
        hidEventSink: sink
    )
    let line = try hudUISmokeActionLine(target: smokeTarget)
    let actionDelay = environmentDouble("VIRTUALHID_HUD_ACTION_DELAY_SECONDS", defaultValue: 0.15)
    let exitDelay = environmentDouble("VIRTUALHID_HUD_EXIT_DELAY_SECONDS", defaultValue: 3.4)
    DispatchQueue.main.asyncAfter(deadline: .now() + actionDelay) {
        print(service.handleLine(line))
        fflush(stdout)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + exitDelay) {
        NSApplication.shared.terminate(nil)
    }
    withExtendedLifetime(sink) {
        NSApplication.shared.run()
    }
}

private struct HUDSmokeTarget {
    let target: [String: Any]?
    let contextHost: String
    let viewportSize: CGSize
    let usesSelfTarget: Bool
}

private func resolveHUDSmokeTarget(configuration: DaemonConfiguration) throws -> HUDSmokeTarget {
    if configuration.allowSelfTarget {
        let frame = selfTargetVisibleFrame()
        return HUDSmokeTarget(
            target: nil,
            contextHost: "hud.local",
            viewportSize: frame.size,
            usesSelfTarget: true
        )
    }

    let descriptor = bestHUDSmokeBrowserDescriptor(bundleIdentifiers: configuration.bundleIdentifiers)
    let resolved = try BrowserResolver.resolve(
        bundleIdentifiers: configuration.bundleIdentifiers,
        descriptor: descriptor
    )
    _ = FocusController.ensureFrontmost(app: resolved.app, timeout: 1.0)
    let viewport = resolved.viewportFrame ?? resolved.frame
    var targetObject: [String: Any] = ["bundleId": resolved.bundleIdentifier]
    if let browserWindowId = resolved.browserWindowId {
        targetObject["windowId"] = browserWindowId
    }
    if let tabId = resolved.tabId {
        targetObject["tabId"] = tabId
    }
    if let host = resolved.host {
        targetObject["host"] = host
    }
    if resolved.host == nil, let title = resolved.windowTitle {
        targetObject["windowTitle"] = title
    }
    return HUDSmokeTarget(
        target: targetObject,
        contextHost: resolved.host ?? "hud.local",
        viewportSize: viewport.size,
        usesSelfTarget: false
    )
}

private func bestHUDSmokeBrowserDescriptor(bundleIdentifiers: [String]) -> TargetDescriptor? {
    for bundleId in bundleIdentifiers where BrowserPageResolver.supports(bundleId: bundleId) {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty else {
            continue
        }
        guard let pages = try? BrowserPageResolver.listPages(bundleId: bundleId), !pages.isEmpty else {
            continue
        }
        let page = pages.first(where: \.active) ?? pages[0]
        return TargetDescriptor(
            bundleId: page.bundleId,
            windowId: page.windowId,
            windowTitle: page.windowTitle ?? page.tabTitle,
            tabId: page.tabId,
            host: page.host
        )
    }
    if let bundleId = bundleIdentifiers.first(where: {
        !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
    }) {
        return TargetDescriptor(bundleId: bundleId)
    }
    return nil
}

private func hudUISmokeActionLine(target: HUDSmokeTarget) throws -> String {
    let width = max(target.viewportSize.width, 320)
    let height = max(target.viewportSize.height, 240)
    let origin = ["x": width * 0.18, "y": height * 0.48]
    let clickPoint = ["x": width * 0.58, "y": height * 0.50]
    let scrollPoint = ["x": width * 0.62, "y": height * 0.54]
    var params: [String: Any] = [
        "geometry": [
            "coordSpace": "viewport",
            "pageScale": 1,
            "scrollOffset": ["x": 0, "y": 0],
            "viewportSize": ["x": 0, "y": 0, "width": width, "height": height]
        ],
        "context": [
            "host": target.contextHost,
            "element": ["sig": "hud-visible-button", "role": "button"],
            "taskId": "hud-acceptance",
            "stage": "manual-ui"
        ],
        "options": ["dryRun": true, "postMode": "global"],
        "primitives": [
            [
                "type": "click",
                "at": clickPoint,
                "button": "left",
                "holdMs": 90,
                "profile": [
                    "origin": origin,
                    "motion": [
                        "pointCount": ["min": 34, "max": 42],
                        "moveSpeedPxS": ["min": 120, "max": 180],
                        "wind": 4.5,
                        "jitter": 0.45,
                        "controlSpread": 55,
                        "detourProbability": 0.25
                    ]
                ]
            ],
            [
                "type": "scroll",
                "at": scrollPoint,
                "dx": 0,
                "dy": -96,
                "style": "wheel"
            ]
        ]
    ]
    if let targetObject = target.target {
        params["target"] = targetObject
    }
    let request: [String: Any] = [
        "id": "hud-ui-smoke",
        "method": "action",
        "params": params
    ]
    let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
    return String(data: data, encoding: .utf8) ?? "{}"
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

private final class SmokeHIDSink: HIDEventSink {
    private(set) var started: HIDActionVisualContext?
    private(set) var recorded = [InjectedEvent]()
    private(set) var finished: HIDActionVisualSummary?
    private(set) var failed: String?

    func hidActionDidStart(_ context: HIDActionVisualContext) {
        started = context
    }

    func hidActionDidRecord(_ event: InjectedEvent, context: HIDActionVisualContext) {
        recorded.append(event)
    }

    func hidActionDidFinish(_ summary: HIDActionVisualSummary) {
        finished = summary
    }

    func hidActionDidFail(actionId: String, errorCode: String) {
        failed = "\(actionId):\(errorCode)"
    }
}

private func smokePointObject(_ point: CodablePoint?) -> Any {
    guard let point else {
        return NSNull()
    }
    return ["x": point.x, "y": point.y]
}

private func hudSettingsObject(_ settings: HIDOverlaySettings) -> [String: Any] {
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

private func applyHUDComponents(_ rawValue: String, visible: Bool, settings: inout HIDOverlaySettings) {
    for rawComponent in rawValue.split(separator: ",") {
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
        case "window", "window-frame", "frame", "target-window":
            settings.showWindowFrame = visible
        case "diagnostic", "hud-active":
            settings.showDiagnostic = visible
        case "trail", "trajectory", "path":
            settings.showTrail = visible
        case "trail-points", "trajectory-points", "points", "path-points":
            settings.showTrailPoints = visible
        case "expected", "expected-point", "target", "target-point":
            settings.showExpectedPoint = visible
        case "actual", "actual-point", "final", "final-point", "landing", "landing-point":
            settings.showActualPoint = visible
        case "click", "clicks", "click-effects", "mouse-click":
            settings.showClickEffects = visible
        case "drag", "drags", "drag-effects":
            settings.showDragEffects = visible
        case "scroll", "scrolls", "scroll-effects", "wheel":
            settings.showScrollEffects = visible
        case "keyboard", "key", "keys", "type", "typing", "paste", "paste-text", "keyboard-effects":
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

private func environmentDouble(_ name: String, defaultValue: Double?) -> Double? {
    guard let value = ProcessInfo.processInfo.environment[name],
          let parsed = Double(value),
          parsed.isFinite,
          parsed > 0
    else {
        return defaultValue
    }
    return parsed
}

private func environmentDouble(_ name: String, defaultValue: Double) -> Double {
    environmentDouble(name, defaultValue: Optional(defaultValue)) ?? defaultValue
}

private func profileStorePath(_ override: String?) throws -> String {
    if let override {
        return override
    }
    let base = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
        .appendingPathComponent("VirtualHID", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base.appendingPathComponent("profile.sqlite").path
}

private func printJSON(_ object: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8) ?? "{}")
}

private func jsonObject(_ line: String) throws -> Any {
    try JSONSerialization.jsonObject(with: Data(line.utf8))
}
