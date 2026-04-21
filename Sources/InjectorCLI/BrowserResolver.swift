import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct BrowserTarget {
    let app: NSRunningApplication
    let pid: pid_t
    let bundleIdentifier: String
    let windowTitle: String?
    let frame: CGRect
}

enum BrowserResolverError: Error, LocalizedError {
    case appNotFound(String)
    case permissionDenied
    case windowNotFound(String)

    var errorDescription: String? {
        switch self {
        case .appNotFound(let bundleId):
            return "未找到运行中的浏览器：\(bundleId)"
        case .permissionDenied:
            return "缺少 Accessibility 权限，无法读取目标窗口信息"
        case .windowNotFound(let bundleId):
            return "未找到可见窗口：\(bundleId)"
        }
    }
}

enum BrowserResolver {
    static func ensureAccessibilityTrusted() throws {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            return
        }
        throw BrowserResolverError.permissionDenied
    }

    static func resolve(bundleIdentifiers: [String]) throws -> BrowserTarget {
        try ensureAccessibilityTrusted()

        for bundleIdentifier in bundleIdentifiers {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .filter { !$0.isTerminated }
                .sorted { ($0.activationPolicy.rawValue, $0.processIdentifier) > ($1.activationPolicy.rawValue, $1.processIdentifier) }

            if let app = apps.first {
                let window = try resolveMainWindow(for: app, bundleIdentifier: bundleIdentifier)
                return BrowserTarget(
                    app: app,
                    pid: app.processIdentifier,
                    bundleIdentifier: bundleIdentifier,
                    windowTitle: window.title,
                    frame: window.frame
                )
            }
        }

        throw BrowserResolverError.appNotFound(bundleIdentifiers.joined(separator: ", "))
    }

    private static func resolveMainWindow(for app: NSRunningApplication, bundleIdentifier: String) throws -> (title: String?, frame: CGRect) {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
        guard status == .success, let windows = value as? [AXUIElement], !windows.isEmpty else {
            throw BrowserResolverError.windowNotFound(bundleIdentifier)
        }

        for window in windows {
            guard let frame = copyFrame(of: window), frame.width > 200, frame.height > 200 else {
                continue
            }
            let minimized = copyBoolAttribute(of: window, name: kAXMinimizedAttribute)
            let hidden = copyBoolAttribute(of: window, name: kAXHiddenAttribute)
            if minimized == true || hidden == true {
                continue
            }
            let title = copyStringAttribute(of: window, name: kAXTitleAttribute)
            return (title, frame)
        }

        throw BrowserResolverError.windowNotFound(bundleIdentifier)
    }

    private static func copyFrame(of element: AXUIElement) -> CGRect? {
        guard
            let positionValue = copyAttribute(element, name: kAXPositionAttribute) as? AXValue,
            let sizeValue = copyAttribute(element, name: kAXSizeAttribute) as? AXValue
        else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetType(positionValue) == .cgPoint, AXValueGetValue(positionValue, .cgPoint, &position) else {
            return nil
        }
        guard AXValueGetType(sizeValue) == .cgSize, AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func copyAttribute(_ element: AXUIElement, name: String) -> AnyObject? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard status == .success else {
            return nil
        }
        return value
    }

    private static func copyStringAttribute(of element: AXUIElement, name: String) -> String? {
        copyAttribute(element, name: name) as? String
    }

    private static func copyBoolAttribute(of element: AXUIElement, name: String) -> Bool? {
        copyAttribute(element, name: name) as? Bool
    }
}
