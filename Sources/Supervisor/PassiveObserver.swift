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
    public let scrollDeltaX: Double?
    public let scrollDeltaY: Double?
    public let modifierFlags: UInt64?
    public let isRepeat: Bool

    public init(
        id: String,
        ts: Int64,
        type: String,
        point: ObservedPoint?,
        keyCode: CGKeyCode?,
        scrollDeltaX: Double? = nil,
        scrollDeltaY: Double? = nil,
        modifierFlags: UInt64? = nil,
        isRepeat: Bool = false
    ) {
        self.id = id
        self.ts = ts
        self.type = type
        self.point = point
        self.keyCode = keyCode
        self.scrollDeltaX = scrollDeltaX
        self.scrollDeltaY = scrollDeltaY
        self.modifierFlags = modifierFlags
        self.isRepeat = isRepeat
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
    private let learningRecorder = PassiveLearningRecorder()
    private var counter: Int64 = 0
    private var buffer = [ObservedEvent]()
    private var enabled = false
    private var host: String?
    private var taskId: String?
    private let logger = Logger(subsystem: "com.vyodels.virtualhid", category: "observer")
    public var learningSampleHandler: ((PassiveGestureSample) -> Void)?

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

    public var learningState: PassiveLearningState {
        lock.withLock { learningRecorder.state }
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

    public func configureLearning(enabled: Bool?, mode: PassiveLearningMode?) -> PassiveLearningState {
        lock.withLock {
            learningRecorder.configure(enabled: enabled, mode: mode)
        }
    }

    public func startLearningSession(label: String?, host: String?, targetAction: String?) -> PassiveLearningState {
        lock.withLock {
            learningRecorder.startSession(label: label, host: host, targetAction: targetAction)
        }
    }

    public func stopLearningSession(commit: Bool) -> PassiveLearningStopResult {
        let result = lock.withLock {
            learningRecorder.stopSession(commit: commit)
        }
        if commit {
            publishLearningSamples(result.committedSamples)
        }
        return result
    }

    public func feed(_ event: CGEvent, type: CGEventType, now: Date = Date()) {
        guard event.getIntegerValueField(.eventSourceUserData) != EventPoster.defaultMarkValue else {
            return
        }
        guard let observed = observedEvent(from: event, type: type, now: now) else {
            return
        }

        let samples = lock.withLock {
            let samples = learningRecorder.record(event: observed, host: host, taskId: taskId)
            if enabled {
                buffer.append(observed)
                trimLocked(nowMs: observed.ts)
            }
            return samples
        }
        publishLearningSamples(samples)
    }

    public func appendSynthetic(
        type: String,
        point: ObservedPoint? = nil,
        keyCode: CGKeyCode? = nil,
        ts: Int64? = nil,
        scrollDeltaX: Double? = nil,
        scrollDeltaY: Double? = nil,
        modifierFlags: UInt64? = nil,
        isRepeat: Bool = false
    ) -> ObservedEvent {
        let nowMs = ts ?? currentTimeMs()
        let result = lock.withLock {
            counter += 1
            let event = ObservedEvent(
                id: "evt-\(nowMs)-\(counter)",
                ts: nowMs,
                type: type,
                point: point,
                keyCode: keyCode,
                scrollDeltaX: scrollDeltaX,
                scrollDeltaY: scrollDeltaY,
                modifierFlags: modifierFlags,
                isRepeat: isRepeat
            )
            buffer.append(event)
            trimLocked(nowMs: nowMs)
            let samples = learningRecorder.record(event: event, host: host, taskId: taskId)
            return (event: event, samples: samples)
        }
        publishLearningSamples(result.samples)
        return result.event
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
        if type == .keyDown || type == .keyUp || type == .flagsChanged {
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
                keyCode: keyCode,
                scrollDeltaX: type == .scrollWheel ? Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)) : nil,
                scrollDeltaY: type == .scrollWheel ? Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)) : nil,
                modifierFlags: (type == .keyDown || type == .keyUp || type == .flagsChanged) ? event.flags.rawValue : nil,
                isRepeat: type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
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
        case .flagsChanged:
            return "flagsChanged"
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

    private func publishLearningSamples(_ samples: [PassiveGestureSample]) {
        guard !samples.isEmpty else {
            return
        }
        for sample in samples {
            learningSampleHandler?(sample)
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
