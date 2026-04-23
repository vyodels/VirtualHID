import AppKit
import CoreGraphics
import Foundation
import InjectorCore
import os

public final class KillSwitch {
    private let lock = NSLock()
    private let windowSeconds: TimeInterval
    private var escBuffer = [Date]()
    private var active = false
    private var triggerDate: Date?
    private let logger = Logger(subsystem: "com.vyodels.virtualhid", category: "kill-switch")

    public var onTrigger: (() -> Void)?

    public init(windowSeconds: TimeInterval = 1.5) {
        self.windowSeconds = windowSeconds
    }

    public var isActive: Bool {
        lock.withLock { active }
    }

    public var triggeredAt: Date? {
        lock.withLock { triggerDate }
    }

    public func feed(_ event: CGEvent, type: CGEventType) {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let sourceUserData = event.getIntegerValueField(.eventSourceUserData)
        feedKeyEvent(type: type, keyCode: keyCode, sourceUserData: sourceUserData)
    }

    public func feedKeyEvent(
        type: CGEventType,
        keyCode: CGKeyCode,
        sourceUserData: Int64 = 0,
        now: Date = Date()
    ) {
        guard type == .keyDown else {
            return
        }
        guard keyCode == 0x35 else {
            return
        }
        guard sourceUserData != EventPoster.defaultMarkValue else {
            return
        }

        let shouldTrigger = lock.withLock {
            escBuffer.append(now)
            escBuffer = escBuffer.filter { now.timeIntervalSince($0) <= windowSeconds }
            return escBuffer.count >= 5 && !active
        }

        if shouldTrigger {
            trigger()
        }
    }

    public func unlock() {
        lock.withLock {
            active = false
            triggerDate = nil
            escBuffer.removeAll()
        }
    }

    private func trigger() {
        let shouldNotify = lock.withLock { () -> Bool in
            guard !active else {
                return false
            }
            active = true
            triggerDate = Date()
            escBuffer.removeAll()
            return true
        }

        guard shouldNotify else {
            return
        }

        logger.error("Kill switch triggered")
        releaseAllModifiers()
        releaseAllMouseButtons()
        NSSound.beep()
        onTrigger?()
    }

    private func releaseAllModifiers() {
        let modifierCodes: [CGKeyCode] = [
            0x37, 0x38, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x39
        ]

        for code in modifierCodes {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
                continue
            }
            event.setIntegerValueField(.eventSourceUserData, value: EventPoster.defaultMarkValue)
            event.post(tap: .cgSessionEventTap)
        }
    }

    private func releaseAllMouseButtons() {
        let location = CGEvent(source: nil)?.location ?? .zero
        let releases: [(CGEventType, CGMouseButton)] = [
            (.leftMouseUp, .left),
            (.rightMouseUp, .right),
            (.otherMouseUp, .center)
        ]

        for (type, button) in releases {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: button) else {
                continue
            }
            event.setIntegerValueField(.eventSourceUserData, value: EventPoster.defaultMarkValue)
            event.post(tap: .cgSessionEventTap)
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
