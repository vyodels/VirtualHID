import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public enum FocusController {
    private static let activationLock = NSLock()
    private static var lastActivationPid: pid_t?
    private static var lastActivationAt: Date?

    @discardableResult
    public static func activate(app: NSRunningApplication) -> Bool {
        if app.activate(options: [.activateIgnoringOtherApps]) {
            return true
        }

        guard let bundleIdentifier = app.bundleIdentifier else {
            return false
        }
        return activateViaAppleScript(bundleIdentifier: bundleIdentifier)
    }

    public static func ensureFrontmost(app: NSRunningApplication, timeout: TimeInterval = 0.8) -> Bool {
        if isFrontmost(app: app) {
            return true
        }

        let now = Date()
        let cooldownRemaining = activationLock.withLock { () -> TimeInterval in
            guard lastActivationPid == app.processIdentifier, let lastActivationAt else {
                return 0
            }
            return max(0, 0.18 - now.timeIntervalSince(lastActivationAt))
        }
        if cooldownRemaining > 0, waitUntilFrontmost(app: app, timeout: min(timeout, cooldownRemaining)) {
            return true
        }

        activationLock.withLock {
            lastActivationPid = app.processIdentifier
            lastActivationAt = Date()
        }
        _ = activate(app: app)
        if waitUntilFrontmost(app: app, timeout: timeout) {
            return true
        }
        _ = activateProcessViaSystemEvents(pid: app.processIdentifier)
        return waitUntilFrontmost(app: app, timeout: timeout)
    }

    private static func waitUntilFrontmost(app: NSRunningApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() <= deadline {
            if isFrontmost(app: app) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return isFrontmost(app: app)
    }

    public static func isFrontmost(app: NSRunningApplication) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    public static func isFrontmostWindow(
        app: NSRunningApplication,
        windowId: Int?,
        windowTitle: String? = nil,
        windowFrame: CGRect? = nil
    ) -> Bool {
        guard isFrontmost(app: app),
              let frontmost = frontmostWindow(),
              frontmost.ownerPid == app.processIdentifier
        else {
            return false
        }
        if let windowTitle, !windowTitle.isEmpty, frontmost.title?.contains(windowTitle) == true {
            return true
        }
        if let windowId {
            if frontmost.windowId == windowId {
                return true
            }
            if let windowFrame, framesApproximatelyMatch(frontmost.frame, windowFrame) {
                return true
            }
            return false
        }
        if let windowFrame, framesApproximatelyMatch(frontmost.frame, windowFrame) {
            return true
        }
        return true
    }

    public static func isTopVisibleWindow(
        app: NSRunningApplication,
        windowId: Int?,
        windowTitle: String? = nil,
        windowFrame: CGRect? = nil
    ) -> Bool {
        for window in onScreenWindows() {
            guard window.ownerPid == app.processIdentifier else {
                continue
            }
            if let windowTitle, !windowTitle.isEmpty {
                if window.title?.contains(windowTitle) == true {
                    return true
                }
                continue
            }
            if let windowId {
                if window.windowId == windowId {
                    return true
                }
                if let windowFrame {
                    return framesApproximatelyMatch(window.frame, windowFrame)
                }
                return false
            }
            if let windowFrame {
                return framesApproximatelyMatch(window.frame, windowFrame)
            }
            return true
        }
        return false
    }

    public static func ensureFrontmostWindow(
        app: NSRunningApplication,
        windowId: Int?,
        windowTitle: String? = nil,
        windowFrame: CGRect? = nil,
        timeout: TimeInterval = 1.2
    ) -> Bool {
        if !ensureFrontmost(app: app, timeout: timeout) {
            if let windowFrame {
                _ = raiseWindowViaAX(pid: app.processIdentifier, windowFrame: windowFrame)
                _ = raiseWindowViaSystemEvents(pid: app.processIdentifier, windowFrame: windowFrame)
                if waitUntilFrontmostWindow(app: app, windowId: windowId, windowTitle: windowTitle, windowFrame: windowFrame, timeout: timeout) {
                    return true
                }
            }
            return false
        }
        if windowId == nil, (windowTitle == nil || windowTitle?.isEmpty == true) {
            guard let windowFrame else {
                return true
            }
            return isFrontmostWindow(app: app, windowId: windowId, windowTitle: windowTitle, windowFrame: windowFrame)
        }
        if !isFrontmostWindow(app: app, windowId: windowId, windowTitle: windowTitle, windowFrame: windowFrame) {
            if let bundleIdentifier = app.bundleIdentifier,
               let windowTitle,
               !windowTitle.isEmpty {
                _ = raiseWindowViaAppleScript(bundleIdentifier: bundleIdentifier, windowTitle: windowTitle)
            }
            if let windowFrame {
                _ = raiseWindowViaAX(pid: app.processIdentifier, windowFrame: windowFrame)
                _ = raiseWindowViaSystemEvents(pid: app.processIdentifier, windowFrame: windowFrame)
            }
        }
        return waitUntilFrontmostWindow(app: app, windowId: windowId, windowTitle: windowTitle, windowFrame: windowFrame, timeout: timeout)
    }

    public static func launchTextEdit() throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        var launched: NSRunningApplication?
        var launchError: Error?
        let semaphore = DispatchSemaphore(value: 0)

        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/TextEdit.app"), configuration: configuration) { app, error in
            launched = app
            launchError = error
            semaphore.signal()
        }

        semaphore.wait()

        if let launchError {
            throw launchError
        }
        guard let launched else {
            throw NSError(domain: "FocusController", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法启动 TextEdit"])
        }
        return launched
    }

    public static func waitForApp(_ app: NSRunningApplication, timeout: TimeInterval = 4) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !app.isTerminated {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    public static func sleep(milliseconds: Int) {
        Thread.sleep(forTimeInterval: TimeInterval(milliseconds) / 1000.0)
    }

    @discardableResult
    private static func activateViaAppleScript(bundleIdentifier: String) -> Bool {
        guard let script = NSAppleScript(source: "tell application id \"\(bundleIdentifier)\" to activate") else {
            return false
        }

        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return error == nil
    }

    @discardableResult
    private static func activateProcessViaSystemEvents(pid: pid_t) -> Bool {
        let source = """
        tell application "System Events"
          set frontmost of first process whose unix id is \(pid) to true
        end tell
        """
        guard let script = NSAppleScript(source: source) else {
            return false
        }

        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return error == nil
    }

    @discardableResult
    private static func raiseWindowViaAppleScript(bundleIdentifier: String, windowTitle: String) -> Bool {
        let escapedBundleIdentifier = appleScriptStringLiteral(bundleIdentifier)
        let escapedWindowTitle = appleScriptStringLiteral(windowTitle)
        let source = """
        tell application id \(escapedBundleIdentifier)
          activate
          repeat with w in windows
            if (title of w as text) contains \(escapedWindowTitle) then
              set index of w to 1
              exit repeat
            end if
          end repeat
        end tell
        """
        guard let script = NSAppleScript(source: source) else {
            return false
        }

        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return error == nil
    }

    private static func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func waitUntilFrontmostWindow(
        app: NSRunningApplication,
        windowId: Int?,
        windowTitle: String?,
        windowFrame: CGRect? = nil,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() <= deadline {
            if isFrontmostWindow(app: app, windowId: windowId, windowTitle: windowTitle, windowFrame: windowFrame) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return isFrontmostWindow(app: app, windowId: windowId, windowTitle: windowTitle, windowFrame: windowFrame)
    }

    private static func frontmostWindow() -> (ownerPid: pid_t, windowId: Int?, title: String?, frame: CGRect?)? {
        onScreenWindows().first
    }

    private static func onScreenWindows() -> [(ownerPid: pid_t, windowId: Int?, title: String?, frame: CGRect?)] {
        guard
            let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else {
            return []
        }

        var result: [(ownerPid: pid_t, windowId: Int?, title: String?, frame: CGRect?)] = []
        for window in windowList {
            let layer = (window[kCGWindowLayer as String] as? Int) ?? 0
            guard layer == 0 else {
                continue
            }
            let alpha = (window[kCGWindowAlpha as String] as? Double) ?? 1
            guard alpha > 0 else {
                continue
            }
            guard let ownerPid = window[kCGWindowOwnerPID as String] as? pid_t else {
                continue
            }
            let windowId = window[kCGWindowNumber as String] as? Int
            let title = window[kCGWindowName as String] as? String
            let frame: CGRect?
            if let boundsValue = window[kCGWindowBounds as String] as? [String: Any] {
                frame = CGRect(dictionaryRepresentation: boundsValue as CFDictionary)
            } else {
                frame = nil
            }
            result.append((ownerPid: ownerPid, windowId: windowId, title: title, frame: frame))
        }

        return result
    }

    @discardableResult
    private static func raiseWindowViaAX(pid: pid_t, windowFrame: CGRect) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)

        var focusedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
           let focusedWindow = focusedValue,
           CFGetTypeID(focusedWindow) == AXUIElementGetTypeID() {
            let focusedElement = unsafeBitCast(focusedWindow, to: AXUIElement.self)
            if axFrame(of: focusedElement).map({ framesApproximatelyMatch($0, windowFrame) }) == true {
            _ = AXUIElementPerformAction(focusedElement, kAXRaiseAction as CFString)
            _ = AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, focusedElement)
            return true
            }
        }

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else {
            return false
        }

        for window in windows {
            guard axFrame(of: window).map({ framesApproximatelyMatch($0, windowFrame) }) == true else {
                continue
            }
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            _ = AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, window)
            return true
        }
        return false
    }

    private static func axFrame(of element: AXUIElement) -> CGRect? {
        AXUIElementSetMessagingTimeout(element, 0.3)
        guard
            let positionValue = axValueAttribute(of: element, name: kAXPositionAttribute),
            let sizeValue = axValueAttribute(of: element, name: kAXSizeAttribute)
        else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetType(positionValue) == .cgPoint,
              AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetType(sizeValue) == .cgSize,
              AXValueGetValue(sizeValue, .cgSize, &size)
        else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func axValueAttribute(of element: AXUIElement, name: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }
        return unsafeBitCast(value, to: AXValue.self)
    }

    @discardableResult
    private static func raiseWindowViaSystemEvents(pid: pid_t, windowFrame: CGRect) -> Bool {
        let x = Int(windowFrame.minX.rounded())
        let y = Int(windowFrame.minY.rounded())
        let width = Int(windowFrame.width.rounded())
        let height = Int(windowFrame.height.rounded())
        let source = """
        tell application "System Events"
          tell (first process whose unix id is \(pid))
            set frontmost to true
            repeat with w in windows
              try
                set windowPosition to position of w
                set windowSize to size of w
                set dx to abs((item 1 of windowPosition) - \(x))
                set dy to abs((item 2 of windowPosition) - \(y))
                set dw to abs((item 1 of windowSize) - \(width))
                set dh to abs((item 2 of windowSize) - \(height))
                if dx < 32 and dy < 32 and dw < 64 and dh < 64 then
                  perform action "AXRaise" of w
                  exit repeat
                end if
              end try
            end repeat
          end tell
        end tell
        """
        guard let script = NSAppleScript(source: source) else {
            return false
        }

        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return error == nil
    }

    private static func framesApproximatelyMatch(_ lhs: CGRect?, _ rhs: CGRect) -> Bool {
        guard let lhs else {
            return false
        }
        let originTolerance: CGFloat = 24
        let sizeTolerance: CGFloat = 48
        return abs(lhs.origin.x - rhs.origin.x) <= originTolerance
            && abs(lhs.origin.y - rhs.origin.y) <= originTolerance
            && abs(lhs.width - rhs.width) <= sizeTolerance
            && abs(lhs.height - rhs.height) <= sizeTolerance
    }

}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
