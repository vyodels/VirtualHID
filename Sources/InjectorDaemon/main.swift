import Foundation
import ControlServer
import CoreGraphics
import InjectorCore
import ProfileStore
import Supervisor

struct DaemonConfiguration {
    var socketPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("virtualhid.sock")
    var dbPath: String?
    var bundleIdentifiers = ["com.google.Chrome", "org.chromium.Chromium", "com.microsoft.edgemac"]
    var defaultPostMode = PostMode.global
    var startEventTap = true
    var allowSelfTarget = false
    var smoke: String?
}

enum DaemonArguments {
    static func parse(_ arguments: [String]) -> DaemonConfiguration {
        var configuration = DaemonConfiguration()
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
            case "--smoke-kill-switch":
                configuration.smoke = "kill-switch"
            case "--smoke-observer":
                configuration.smoke = "observer"
            case "--smoke-profile-learn":
                configuration.smoke = "profile-learn"
            default:
                continue
            }
        }
        return configuration
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
    default:
        try runDaemon(configuration: configuration)
    }
} catch {
    fputs("ERROR: \(error.localizedDescription)\n", stderr)
    exit(1)
}

private func runDaemon(configuration: DaemonConfiguration) throws {
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
    let service = ControlService(
        configuration: ControlServerConfiguration(
            bundleIdentifiers: configuration.bundleIdentifiers,
            defaultPostMode: configuration.defaultPostMode,
            allowSelfTarget: configuration.allowSelfTarget
        ),
        supervisor: supervisor,
        profileStore: store
    )
    let server = SocketServer(socketPath: configuration.socketPath, service: service)
    try server.start()
    print("vhid-daemon listening \(configuration.socketPath)")
    RunLoop.main.run()
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
