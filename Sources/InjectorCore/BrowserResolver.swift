import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public struct BrowserTarget {
    public let app: NSRunningApplication
    public let pid: pid_t
    public let bundleIdentifier: String
    public let windowTitle: String?
    public let frame: CGRect

    public init(app: NSRunningApplication, pid: pid_t, bundleIdentifier: String, windowTitle: String?, frame: CGRect) {
        self.app = app
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.frame = frame
    }
}

public enum BrowserResolverError: Error, LocalizedError {
    case appNotFound(String)
    case permissionDenied
    case windowNotFound(String)

    public var errorDescription: String? {
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

public enum BrowserResolver {
    public static func ensureAccessibilityTrusted(prompt: Bool = true) throws {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            return
        }
        throw BrowserResolverError.permissionDenied
    }

    public static func resolve(bundleIdentifiers: [String]) throws -> BrowserTarget {
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
        if let focusedWindow = copyAXElementAttribute(of: axApp, name: kAXFocusedWindowAttribute),
           let resolved = resolveWindow(focusedWindow) {
            return resolved
        }

        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
        if status == .success, let windows = value as? [AXUIElement], !windows.isEmpty {
            for window in windows {
                if let resolved = resolveWindow(window) {
                    return resolved
                }
            }
        }

        if let fallback = resolveCGWindow(for: app.processIdentifier) {
            return fallback
        }

        throw BrowserResolverError.windowNotFound(bundleIdentifier)
    }

    private static func resolveWindow(_ window: AXUIElement) -> (title: String?, frame: CGRect)? {
        guard let frame = copyFrame(of: window), frame.width > 200, frame.height > 200 else {
            return nil
        }
        let minimized = copyBoolAttribute(of: window, name: kAXMinimizedAttribute)
        let hidden = copyBoolAttribute(of: window, name: kAXHiddenAttribute)
        if minimized == true || hidden == true {
            return nil
        }
        let title = copyStringAttribute(of: window, name: kAXTitleAttribute)
        return (title, frame)
    }

    private static func copyFrame(of element: AXUIElement) -> CGRect? {
        guard
            let positionValue = copyAXValueAttribute(of: element, name: kAXPositionAttribute),
            let sizeValue = copyAXValueAttribute(of: element, name: kAXSizeAttribute)
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

    private static func copyAXValueAttribute(of element: AXUIElement, name: String) -> AXValue? {
        guard let value = copyAttribute(element, name: name) else {
            return nil
        }
        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXValue.self)
    }

    private static func copyAXElementAttribute(of element: AXUIElement, name: String) -> AXUIElement? {
        guard let value = copyAttribute(element, name: name) else {
            return nil
        }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func copyStringAttribute(of element: AXUIElement, name: String) -> String? {
        copyAttribute(element, name: name) as? String
    }

    private static func copyBoolAttribute(of element: AXUIElement, name: String) -> Bool? {
        copyAttribute(element, name: name) as? Bool
    }

    private static func resolveCGWindow(for pid: pid_t) -> (title: String?, frame: CGRect)? {
        guard
            let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else {
            return nil
        }

        for window in windowList {
            guard let ownerPid = window[kCGWindowOwnerPID as String] as? pid_t, ownerPid == pid else {
                continue
            }
            guard let boundsValue = window[kCGWindowBounds as String] as? [String: Any] else {
                continue
            }

            let cfBounds = boundsValue as CFDictionary
            guard let frame = CGRect(dictionaryRepresentation: cfBounds), frame.width > 200, frame.height > 200 else {
                continue
            }

            let title = window[kCGWindowName as String] as? String
            return (title, frame)
        }

        return nil
    }
}
