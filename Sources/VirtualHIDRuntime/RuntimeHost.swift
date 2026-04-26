import AppKit
import ControlServer
import Foundation
import HIDVisualization
import InjectorCore
import ProfileStore
import Supervisor

public enum VirtualHIDRuntimePaths {
    public static var applicationSupportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("VirtualHID", isDirectory: true)
    }

    public static var defaultSocketPath: String {
        applicationSupportDirectory
            .appendingPathComponent("virtualhid.sock")
            .path
    }
}

public struct VirtualHIDRuntimeConfiguration {
    public var socketPath: String
    public var dbPath: String?
    public var bundleIdentifiers: [String]
    public var defaultPostMode: PostMode
    public var startEventTap: Bool
    public var allowSelfTarget: Bool
    public var hudAvailable: Bool
    public var hudEnabled: Bool
    public var hudLockedOff: Bool
    public var hudSettings: HIDOverlaySettings

    public init(
        socketPath: String = VirtualHIDRuntimePaths.defaultSocketPath,
        dbPath: String? = nil,
        bundleIdentifiers: [String] = ["com.google.Chrome", "org.chromium.Chromium", "com.microsoft.edgemac", "com.apple.Safari"],
        defaultPostMode: PostMode = .global,
        startEventTap: Bool = true,
        allowSelfTarget: Bool = false,
        hudAvailable: Bool = true,
        hudEnabled: Bool = true,
        hudLockedOff: Bool = false,
        hudSettings: HIDOverlaySettings = HIDOverlaySettings()
    ) {
        self.socketPath = socketPath
        self.dbPath = dbPath
        self.bundleIdentifiers = bundleIdentifiers
        self.defaultPostMode = defaultPostMode
        self.startEventTap = startEventTap
        self.allowSelfTarget = allowSelfTarget
        self.hudAvailable = hudAvailable
        self.hudEnabled = hudEnabled && !hudLockedOff
        self.hudLockedOff = hudLockedOff
        self.hudSettings = hudSettings
    }

    public static func appDefault(environment: [String: String] = ProcessInfo.processInfo.environment) -> VirtualHIDRuntimeConfiguration {
        let bundles = (environment["VIRTUALHID_BUNDLES"] ?? "com.google.Chrome,org.chromium.Chromium,com.microsoft.edgemac,com.apple.Safari")
            .split(separator: ",")
            .map(String.init)
        var settings = HIDOverlaySettings()
        if let seconds = environmentDouble("VIRTUALHID_HUD_CLEAR_DELAY_SECONDS", environment: environment) {
            settings.clearDelaySeconds = seconds
        }
        if let value = environment["VIRTUALHID_HUD_SHOW"] {
            applyHUDComponents(value, visible: true, settings: &settings)
        }
        if let value = environment["VIRTUALHID_HUD_HIDE"] {
            applyHUDComponents(value, visible: false, settings: &settings)
        }
        let lockedOff = environment["VIRTUALHID_NO_HUD"] == "1"
        return VirtualHIDRuntimeConfiguration(
            socketPath: environment["VIRTUALHID_SOCKET"] ?? VirtualHIDRuntimePaths.defaultSocketPath,
            bundleIdentifiers: bundles,
            hudAvailable: true,
            hudEnabled: !lockedOff,
            hudLockedOff: lockedOff,
            hudSettings: settings
        )
    }
}

public final class VirtualHIDRuntimeHost {
    public let configuration: VirtualHIDRuntimeConfiguration
    public let supervisor: SupervisorService
    public let profileStore: ProfileStore
    public let overlay: HIDOverlayController?
    public let service: ControlService
    public let server: SocketServer

    private var started = false

    public init(configuration: VirtualHIDRuntimeConfiguration = VirtualHIDRuntimeConfiguration()) throws {
        self.configuration = configuration
        let supervisor = SupervisorService()
        let profileStore = try ProfileStore(path: try Self.profileStorePath(configuration.dbPath))
        let overlay = configuration.hudAvailable
            ? HIDOverlayController(
                settings: configuration.hudSettings,
                enabled: configuration.hudEnabled,
                lockedOff: configuration.hudLockedOff
            )
            : nil
        let service = ControlService(
            configuration: ControlServerConfiguration(
                bundleIdentifiers: configuration.bundleIdentifiers,
                defaultPostMode: configuration.defaultPostMode,
                allowSelfTarget: configuration.allowSelfTarget
            ),
            supervisor: supervisor,
            profileStore: profileStore,
            hidEventSink: overlay
        )
        self.supervisor = supervisor
        self.profileStore = profileStore
        self.overlay = overlay
        self.service = service
        self.server = SocketServer(socketPath: configuration.socketPath, service: service)
    }

    public func start() throws {
        guard !started else {
            return
        }
        if configuration.startEventTap {
            do {
                try supervisor.startEventTap(promptForPermission: false)
            } catch {
                fputs("WARN: supervisor event tap unavailable: \(error.localizedDescription)\n", stderr)
            }
        }
        try server.start()
        started = true
    }

    public func stop() {
        supervisor.stopEventTap()
        server.stop()
        started = false
    }

    public func call(method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        let request: [String: Any] = [
            "id": "runtime-\(UUID().uuidString)",
            "method": method,
            "params": params
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        let line = String(decoding: data, as: UTF8.self)
        let response = service.handleLine(line)
        return try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any] ?? [:]
    }

    public static func profileStorePath(_ override: String?) throws -> String {
        if let override {
            return override
        }
        let base = VirtualHIDRuntimePaths.applicationSupportDirectory
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("profile.sqlite").path
    }
}

private func environmentDouble(_ name: String, environment: [String: String]) -> Double? {
    guard let value = environment[name],
          let parsed = Double(value),
          parsed.isFinite,
          parsed > 0
    else {
        return nil
    }
    return parsed
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
        case "window", "window-frame", "frame", "target-window", "windowframe":
            settings.showWindowFrame = visible
        case "diagnostic", "hud-active":
            settings.showDiagnostic = visible
        case "trail", "trajectory", "path":
            settings.showTrail = visible
        case "trail-points", "trajectory-points", "points", "path-points", "trailpoints":
            settings.showTrailPoints = visible
        case "expected", "expected-point", "target", "target-point", "expectedpoint":
            settings.showExpectedPoint = visible
        case "actual", "actual-point", "final", "final-point", "landing", "landing-point", "actualpoint":
            settings.showActualPoint = visible
        case "click", "clicks", "click-effects", "mouse-click", "clickeffects":
            settings.showClickEffects = visible
        case "drag", "drags", "drag-effects", "drageffects":
            settings.showDragEffects = visible
        case "scroll", "scrolls", "scroll-effects", "wheel", "scrolleffects":
            settings.showScrollEffects = visible
        case "keyboard", "key", "keys", "type", "typing", "paste", "paste-text", "keyboard-effects", "keyboardeffects":
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
