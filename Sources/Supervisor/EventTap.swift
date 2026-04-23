import ApplicationServices
import CoreGraphics
import Foundation

public enum EventTapError: Error, LocalizedError {
    case accessibilityPermissionMissing
    case creationFailed
    case alreadyRunning

    public var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing:
            return "Accessibility permission is required to listen for HID events"
        case .creationFailed:
            return "Failed to create CGEventTap"
        case .alreadyRunning:
            return "EventTap is already running"
        }
    }
}

public final class EventTap {
    public typealias Callback = (CGEventType, CGEvent) -> Unmanaged<CGEvent>?

    private final class CallbackBox {
        let callback: Callback

        init(callback: @escaping Callback) {
            self.callback = callback
        }
    }

    private let eventsOfInterest: CGEventMask
    private let queue = DispatchQueue(label: "com.vyodels.virtualhid.supervisor.eventtap")
    private let lifecycleLock = NSLock()
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var callbackBox: Unmanaged<CallbackBox>?
    private var running = false

    public init(eventsOfInterest: CGEventMask) {
        self.eventsOfInterest = eventsOfInterest
    }

    public static func isAccessibilityTrusted(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public func start(callback: @escaping Callback) throws {
        guard Self.isAccessibilityTrusted(prompt: false) else {
            throw EventTapError.accessibilityPermissionMissing
        }

        try lifecycleLock.withLock {
            if running {
                throw EventTapError.alreadyRunning
            }
            running = true
        }

        let startSemaphore = DispatchSemaphore(value: 0)
        var startError: EventTapError?

        queue.async { [weak self] in
            guard let self else {
                return
            }

            let box = Unmanaged.passRetained(CallbackBox(callback: callback))
            let userInfo = UnsafeMutableRawPointer(box.toOpaque())
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: self.eventsOfInterest,
                callback: { _, type, event, userInfo in
                    guard let userInfo else {
                        return Unmanaged.passUnretained(event)
                    }
                    let box = Unmanaged<CallbackBox>.fromOpaque(userInfo).takeUnretainedValue()
                    return box.callback(type, event) ?? Unmanaged.passUnretained(event)
                },
                userInfo: userInfo
            ) else {
                box.release()
                startError = .creationFailed
                self.lifecycleLock.withLock {
                    self.running = false
                }
                startSemaphore.signal()
                return
            }

            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            let runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)

            self.lifecycleLock.withLock {
                self.tap = tap
                self.source = source
                self.runLoop = runLoop
                self.callbackBox = box
            }
            startSemaphore.signal()
            CFRunLoopRun()
        }

        startSemaphore.wait()
        if let startError {
            throw startError
        }
    }

    public func stop() {
        var retainedBox: Unmanaged<CallbackBox>?
        var retainedRunLoop: CFRunLoop?
        var retainedTap: CFMachPort?
        var retainedSource: CFRunLoopSource?

        lifecycleLock.withLock {
            retainedBox = callbackBox
            retainedRunLoop = runLoop
            retainedTap = tap
            retainedSource = source

            callbackBox = nil
            runLoop = nil
            tap = nil
            source = nil
            running = false
        }

        if let retainedTap {
            CGEvent.tapEnable(tap: retainedTap, enable: false)
        }
        if let retainedRunLoop, let retainedSource {
            CFRunLoopRemoveSource(retainedRunLoop, retainedSource, .commonModes)
            CFRunLoopStop(retainedRunLoop)
        }
        retainedBox?.release()
    }

    deinit {
        stop()
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
