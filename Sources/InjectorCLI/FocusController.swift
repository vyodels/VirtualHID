import AppKit
import Foundation

enum FocusController {
    @discardableResult
    static func activate(app: NSRunningApplication) -> Bool {
        app.activate(options: [.activateIgnoringOtherApps])
    }

    static func launchTextEdit() throws -> NSRunningApplication {
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

    static func waitForApp(_ app: NSRunningApplication, timeout: TimeInterval = 4) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !app.isTerminated {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    static func sleep(milliseconds: Int) {
        Thread.sleep(forTimeInterval: TimeInterval(milliseconds) / 1000.0)
    }
}
