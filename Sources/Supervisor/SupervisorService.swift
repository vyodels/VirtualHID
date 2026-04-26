import CoreGraphics
import Foundation
import InjectorCore

public struct ModifierSnapshot: Codable, Equatable {
    public let shift: Bool
    public let cmd: Bool
    public let opt: Bool
    public let ctrl: Bool
    public let fn: Bool
    public let stuck: [String]

    public init(shift: Bool, cmd: Bool, opt: Bool, ctrl: Bool, fn: Bool, stuck: [String]) {
        self.shift = shift
        self.cmd = cmd
        self.opt = opt
        self.ctrl = ctrl
        self.fn = fn
        self.stuck = stuck
    }
}

public struct SupervisorSnapshot: Codable, Equatable {
    public let online: Bool
    public let observing: Bool
    public let observingHost: String?

    public init(online: Bool, observing: Bool, observingHost: String?) {
        self.online = online
        self.observing = observing
        self.observingHost = observingHost
    }
}

public final class SupervisorService {
    public let killSwitch: KillSwitch
    public let observer: PassiveObserver

    private let lock = NSLock()
    private let modifierTracker = ModifierTracker()
    private var eventTap: EventTap?
    private var online = true

    public init(killSwitch: KillSwitch = KillSwitch(), observer: PassiveObserver = PassiveObserver()) {
        self.killSwitch = killSwitch
        self.observer = observer
    }

    public func startEventTap(promptForPermission: Bool = false) throws {
        let eventTypes: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .mouseMoved,
            .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .scrollWheel
        ]
        let mask = eventTypes.reduce(CGEventMask(0)) { partial, type in
            partial | CGEventMask(1 << type.rawValue)
        }

        if promptForPermission, !EventTap.isAccessibilityTrusted(prompt: true) {
            throw EventTapError.accessibilityPermissionMissing
        }

        let tap = EventTap(eventsOfInterest: mask)
        try tap.start { [weak self] (type: CGEventType, event: CGEvent) in
            self?.feed(event, type: type)
            return Unmanaged.passUnretained(event)
        }

        lock.withLock {
            eventTap = tap
            online = true
        }
    }

    public func stopEventTap() {
        let tap = lock.withLock { () -> EventTap? in
            let tap = eventTap
            eventTap = nil
            return tap
        }
        tap?.stop()
    }

    public func feed(_ event: CGEvent, type: CGEventType) {
        modifierTracker.feed(event, type: type)
        killSwitch.feed(event, type: type)
        observer.feed(event, type: type)
    }

    public func feedKeyEvent(type: CGEventType, keyCode: CGKeyCode, sourceUserData: Int64 = 0, now: Date = Date()) {
        modifierTracker.feedKeyEvent(type: type, keyCode: keyCode, sourceUserData: sourceUserData, now: now)
        killSwitch.feedKeyEvent(type: type, keyCode: keyCode, sourceUserData: sourceUserData, now: now)
    }

    public func snapshot() -> SupervisorSnapshot {
        SupervisorSnapshot(
            online: lock.withLock { online },
            observing: observer.isEnabled,
            observingHost: observer.observingHost
        )
    }

    public func modifierSnapshot() -> ModifierSnapshot {
        modifierTracker.snapshot()
    }

    public func unlock() {
        killSwitch.unlock()
        modifierTracker.reset()
    }
}

private final class ModifierTracker {
    private struct Press {
        let name: String
        let date: Date
    }

    private let lock = NSLock()
    private var pressed = [CGKeyCode: Press]()

    func feed(_ event: CGEvent, type: CGEventType) {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let sourceUserData = event.getIntegerValueField(.eventSourceUserData)
        feedKeyEvent(type: type, keyCode: keyCode, sourceUserData: sourceUserData)
    }

    func feedKeyEvent(type: CGEventType, keyCode: CGKeyCode, sourceUserData: Int64, now: Date = Date()) {
        guard sourceUserData != EventPoster.defaultMarkValue else {
            return
        }
        guard let name = Self.modifierName(for: keyCode) else {
            return
        }

        lock.withLock {
            if type == .keyDown || type == .flagsChanged {
                pressed[keyCode] = Press(name: name, date: now)
            } else if type == .keyUp {
                pressed.removeValue(forKey: keyCode)
            }
        }
    }

    func snapshot() -> ModifierSnapshot {
        lock.withLock {
            let now = Date()
            let names = Set(pressed.values.map(\.name))
            let stuck = pressed.values
                .filter { now.timeIntervalSince($0.date) > 10 }
                .map(\.name)
                .sorted()
            return ModifierSnapshot(
                shift: names.contains("shift"),
                cmd: names.contains("cmd"),
                opt: names.contains("opt"),
                ctrl: names.contains("ctrl"),
                fn: names.contains("fn"),
                stuck: stuck
            )
        }
    }

    func reset() {
        lock.withLock {
            pressed.removeAll()
        }
    }

    private static func modifierName(for keyCode: CGKeyCode) -> String? {
        switch keyCode {
        case 0x38, 0x3C:
            return "shift"
        case 0x37:
            return "cmd"
        case 0x3A, 0x3D:
            return "opt"
        case 0x3B, 0x3E:
            return "ctrl"
        case 0x3F:
            return "fn"
        default:
            return nil
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
