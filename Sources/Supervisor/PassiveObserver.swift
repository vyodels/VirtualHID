import CoreGraphics
import Foundation
import InjectorCore
import os

public struct ObservedPoint: Codable, Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct ObservedEvent: Codable, Equatable {
    public let id: String
    public let ts: Int64
    public let type: String
    public let point: ObservedPoint?
    public let keyCode: CGKeyCode?

    public init(id: String, ts: Int64, type: String, point: ObservedPoint?, keyCode: CGKeyCode?) {
        self.id = id
        self.ts = ts
        self.type = type
        self.point = point
        self.keyCode = keyCode
    }
}

public enum PassiveObserverError: Error, LocalizedError {
    case hostRequired

    public var errorDescription: String? {
        switch self {
        case .hostRequired:
            return "observe enable requires host"
        }
    }
}

public final class PassiveObserver {
    private let lock = NSLock()
    private let retentionMs: Int64
    private var counter: Int64 = 0
    private var buffer = [ObservedEvent]()
    private var enabled = false
    private var host: String?
    private var taskId: String?
    private let logger = Logger(subsystem: "com.vyodels.virtualhid", category: "observer")

    public init(retentionSeconds: TimeInterval = 30) {
        self.retentionMs = Int64(retentionSeconds * 1000)
    }

    public var isEnabled: Bool {
        lock.withLock { enabled }
    }

    public var observingHost: String? {
        lock.withLock { host }
    }

    public var observingTaskId: String? {
        lock.withLock { taskId }
    }

    public func enable(host: String, taskId: String?) throws {
        guard !host.isEmpty else {
            throw PassiveObserverError.hostRequired
        }
        lock.withLock {
            enabled = true
            self.host = host
            self.taskId = taskId
            trimLocked(nowMs: currentTimeMs())
        }
    }

    public func disable() {
        lock.withLock {
            enabled = false
            host = nil
            taskId = nil
        }
    }

    public func feed(_ event: CGEvent, type: CGEventType, now: Date = Date()) {
        guard event.getIntegerValueField(.eventSourceUserData) != EventPoster.defaultMarkValue else {
            return
        }
        guard let observed = observedEvent(from: event, type: type, now: now) else {
            return
        }

        lock.withLock {
            guard enabled else {
                return
            }
            buffer.append(observed)
            trimLocked(nowMs: observed.ts)
        }
    }

    public func appendSynthetic(type: String, point: ObservedPoint? = nil, keyCode: CGKeyCode? = nil, ts: Int64? = nil) -> ObservedEvent {
        let nowMs = ts ?? currentTimeMs()
        return lock.withLock {
            counter += 1
            let event = ObservedEvent(
                id: "evt-\(nowMs)-\(counter)",
                ts: nowMs,
                type: type,
                point: point,
                keyCode: keyCode
            )
            buffer.append(event)
            trimLocked(nowMs: nowMs)
            return event
        }
    }

    public func tail(sinceEventId: String? = nil, limit: Int = 50) -> [ObservedEvent] {
        lock.withLock {
            trimLocked(nowMs: currentTimeMs())
            let events: [ObservedEvent]
            if let sinceEventId, let index = buffer.firstIndex(where: { $0.id == sinceEventId }) {
                events = Array(buffer.dropFirst(index + 1))
            } else {
                events = buffer
            }
            return Array(events.suffix(max(limit, 0)))
        }
    }

    public func event(id: String) -> ObservedEvent? {
        lock.withLock {
            trimLocked(nowMs: currentTimeMs())
            return buffer.first { $0.id == id }
        }
    }

    private func observedEvent(from event: CGEvent, type: CGEventType, now: Date) -> ObservedEvent? {
        let ts = Int64(now.timeIntervalSince1970 * 1000)
        let eventType = name(for: type)
        guard eventType != nil else {
            return nil
        }

        let keyCode: CGKeyCode?
        if type == .keyDown || type == .keyUp {
            keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        } else {
            keyCode = nil
        }

        let point: ObservedPoint?
        switch type {
        case .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel:
            point = ObservedPoint(x: Double(event.location.x), y: Double(event.location.y))
        default:
            point = nil
        }

        return lock.withLock {
            counter += 1
            return ObservedEvent(
                id: "evt-\(ts)-\(counter)",
                ts: ts,
                type: eventType ?? "unknown",
                point: point,
                keyCode: keyCode
            )
        }
    }

    private func name(for type: CGEventType) -> String? {
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
        case .keyDown:
            return "keyDown"
        case .keyUp:
            return "keyUp"
        default:
            return nil
        }
    }

    private func trimLocked(nowMs: Int64) {
        let threshold = nowMs - retentionMs
        buffer.removeAll { $0.ts < threshold }
    }

    private func currentTimeMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
