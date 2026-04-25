import AppKit
import CoreGraphics
import Foundation

public enum FocusController {
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
        _ = activate(app: app)
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
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
            return true
        }
        return frontmostWindowOwnerPid() == app.processIdentifier
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

    private static func frontmostWindowOwnerPid() -> pid_t? {
        guard
            let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else {
            return nil
        }

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
            return ownerPid
        }

        return nil
    }

}
