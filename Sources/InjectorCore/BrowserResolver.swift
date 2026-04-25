import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public struct BrowserTarget {
    public let app: NSRunningApplication
    public let pid: pid_t
    public let bundleIdentifier: String
    public let windowId: Int?
    public let windowTitle: String?
    public let frame: CGRect
    public let viewportFrame: CGRect?
    public let viewportFrameSource: String?

    public init(
        app: NSRunningApplication,
        pid: pid_t,
        bundleIdentifier: String,
        windowId: Int? = nil,
        windowTitle: String?,
        frame: CGRect,
        viewportFrame: CGRect? = nil,
        viewportFrameSource: String? = nil
    ) {
        self.app = app
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.windowId = windowId
        self.windowTitle = windowTitle
        self.frame = frame
        self.viewportFrame = viewportFrame
        self.viewportFrameSource = viewportFrameSource
    }
}

private final class ViewportFrameCache {
    private struct Entry {
        let value: (frame: CGRect, source: String)
        let expiresAt: Date
    }

    private let ttl: TimeInterval
    private let lock = NSLock()
    private var values: [String: Entry] = [:]

    init(ttl: TimeInterval) {
        self.ttl = ttl
    }

    func get(_ key: String) -> (frame: CGRect, source: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = values[key] else {
            return nil
        }
        if entry.expiresAt <= Date() {
            values.removeValue(forKey: key)
            return nil
        }
        return entry.value
    }

    func set(_ value: (frame: CGRect, source: String), for key: String) {
        lock.lock()
        values[key] = Entry(value: value, expiresAt: Date().addingTimeInterval(ttl))
        lock.unlock()
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
    private static let viewportCache = ViewportFrameCache(ttl: 2.0)

    public static func ensureAccessibilityTrusted(prompt: Bool = true) throws {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            return
        }
        throw BrowserResolverError.permissionDenied
    }

    public static func resolve(
        bundleIdentifiers: [String],
        descriptor: TargetDescriptor? = nil,
        promptForPermission: Bool = true
    ) throws -> BrowserTarget {
        try ensureAccessibilityTrusted(prompt: promptForPermission)
        var resolvedTargets = [BrowserTarget]()
        var sawRunningApp = false
        var lastWindowError: BrowserResolverError?

        let requestedBundleIdentifiers = descriptor?.bundleId.map { [$0] } ?? bundleIdentifiers
        let useFocusedBrowserWindow = requiresFocusedBrowserWindow(descriptor)
        for bundleIdentifier in requestedBundleIdentifiers {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .filter { !$0.isTerminated }
                .sorted {
                    let lhsFrontmost = FocusController.isFrontmost(app: $0)
                    let rhsFrontmost = FocusController.isFrontmost(app: $1)
                    if lhsFrontmost != rhsFrontmost {
                        return lhsFrontmost && !rhsFrontmost
                    }
                    return ($0.activationPolicy.rawValue, $0.processIdentifier) > ($1.activationPolicy.rawValue, $1.processIdentifier)
                }

            guard !apps.isEmpty else {
                continue
            }
            sawRunningApp = true

            for app in apps {
                do {
                    if useFocusedBrowserWindow {
                        _ = FocusController.ensureFrontmost(app: app, timeout: 0.8)
                    }
                    let window = try resolveMainWindow(
                        for: app,
                        bundleIdentifier: bundleIdentifier,
                        descriptor: descriptor,
                        focusedOnly: useFocusedBrowserWindow
                    )
                    resolvedTargets.append(
                        BrowserTarget(
                            app: app,
                            pid: app.processIdentifier,
                            bundleIdentifier: bundleIdentifier,
                            windowId: window.windowId,
                            windowTitle: window.title,
                            frame: window.frame,
                            viewportFrame: window.viewportFrame,
                            viewportFrameSource: window.viewportFrameSource
                        )
                    )
                } catch BrowserResolverError.windowNotFound {
                    lastWindowError = .windowNotFound(bundleIdentifier)
                    continue
                }
            }
        }

        if let frontmost = resolvedTargets.first(where: { FocusController.isFrontmost(app: $0.app) }) {
            return frontmost
        }
        if let target = resolvedTargets.first {
            return target
        }
        if let lastWindowError, sawRunningApp {
            throw lastWindowError
        }
        throw BrowserResolverError.appNotFound(bundleIdentifiers.joined(separator: ", "))
    }

    private struct ResolvedWindow {
        let title: String?
        let frame: CGRect
        let windowId: Int?
        let viewportFrame: CGRect?
        let viewportFrameSource: String?
    }

    private static func resolveMainWindow(
        for app: NSRunningApplication,
        bundleIdentifier: String,
        descriptor: TargetDescriptor?,
        focusedOnly: Bool
    ) throws -> ResolvedWindow {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.2)
        if let focusedWindow = copyAXElementAttribute(of: axApp, name: kAXFocusedWindowAttribute),
           let resolved = resolveWindow(focusedWindow, pid: app.processIdentifier),
           matches(resolved, descriptor: descriptor) {
            return resolved
        }

        if focusedOnly {
            throw BrowserResolverError.windowNotFound(bundleIdentifier)
        }

        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
        if status == .success, let windows = value as? [AXUIElement], !windows.isEmpty {
            for window in windows {
                if let resolved = resolveWindow(window, pid: app.processIdentifier), matches(resolved, descriptor: descriptor) {
                    return resolved
                }
            }
        }

        if let fallback = resolveCGWindow(for: app.processIdentifier, descriptor: descriptor) {
            return fallback
        }

        throw BrowserResolverError.windowNotFound(bundleIdentifier)
    }

    private static func resolveWindow(_ window: AXUIElement, pid: pid_t) -> ResolvedWindow? {
        AXUIElementSetMessagingTimeout(window, 0.2)
        guard let frame = copyFrame(of: window), frame.width > 200, frame.height > 200 else {
            return nil
        }
        let minimized = copyBoolAttribute(of: window, name: kAXMinimizedAttribute)
        let hidden = copyBoolAttribute(of: window, name: kAXHiddenAttribute)
        if minimized == true || hidden == true {
            return nil
        }
        let title = copyStringAttribute(of: window, name: kAXTitleAttribute)
        let windowId = intAttribute(of: window, name: "AXWindowNumber")
        let cacheKey = viewportCacheKey(pid: pid, windowId: windowId, title: title, frame: frame)
        let viewport = resolveWebViewportFrame(in: window, windowFrame: frame, cacheKey: cacheKey)
        return ResolvedWindow(
            title: title,
            frame: frame,
            windowId: windowId,
            viewportFrame: viewport?.frame,
            viewportFrameSource: viewport?.source
        )
    }

    private static func matches(_ window: ResolvedWindow, descriptor: TargetDescriptor?) -> Bool {
        guard let descriptor else {
            return true
        }
        // Browser windowId/tabId/host are page identities, not macOS window identifiers.
        // Keep macOS targeting grounded in bundle/title/AX window evidence.
        if let requestedTitle = descriptor.windowTitle, window.title?.contains(requestedTitle) != true {
            return false
        }
        return true
    }

    private static func requiresFocusedBrowserWindow(_ descriptor: TargetDescriptor?) -> Bool {
        guard let descriptor else {
            return false
        }
        if descriptor.windowTitle != nil {
            return false
        }
        return descriptor.host != nil || descriptor.tabId != nil || descriptor.windowId != nil
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

    private static func intAttribute(of element: AXUIElement, name: String) -> Int? {
        if let value = copyAttribute(element, name: name) as? Int {
            return value
        }
        if let value = copyAttribute(element, name: name) as? NSNumber {
            return value.intValue
        }
        return nil
    }

    private static func resolveCGWindow(for pid: pid_t, descriptor: TargetDescriptor?) -> ResolvedWindow? {
        guard
            let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else {
            return nil
        }

        for window in windowList {
            guard let ownerPid = window[kCGWindowOwnerPID as String] as? pid_t, ownerPid == pid else {
                continue
            }
            let windowId = window[kCGWindowNumber as String] as? Int
            guard let boundsValue = window[kCGWindowBounds as String] as? [String: Any] else {
                continue
            }

            let cfBounds = boundsValue as CFDictionary
            guard let frame = CGRect(dictionaryRepresentation: cfBounds), frame.width > 200, frame.height > 200 else {
                continue
            }

            let title = window[kCGWindowName as String] as? String
            if let requestedTitle = descriptor?.windowTitle, title?.contains(requestedTitle) != true {
                continue
            }
            return ResolvedWindow(
                title: title,
                frame: frame,
                windowId: windowId,
                viewportFrame: nil,
                viewportFrameSource: nil
            )
        }

        return nil
    }

    private static func resolveWebViewportFrame(in window: AXUIElement, windowFrame: CGRect, cacheKey: String?) -> (frame: CGRect, source: String)? {
        if let cacheKey, let cached = viewportCache.get(cacheKey) {
            return cached
        }
        let candidates = collectViewportCandidates(from: window, windowFrame: windowFrame)
        if let webArea = candidates
            .filter({ $0.role == "AXWebArea" })
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
            if let cacheKey {
                viewportCache.set((webArea.frame, "AXWebArea"), for: cacheKey)
            }
            return (webArea.frame, "AXWebArea")
        }
        if let scrollArea = candidates
            .filter({ $0.role == "AXScrollArea" })
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
            if let cacheKey {
                viewportCache.set((scrollArea.frame, "AXScrollArea"), for: cacheKey)
            }
            return (scrollArea.frame, "AXScrollArea")
        }
        if let contentGroup = candidates
            .filter({ $0.role == "AXGroup" && $0.source == "AXGroupContentArea" })
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
            if let cacheKey {
                viewportCache.set((contentGroup.frame, contentGroup.source), for: cacheKey)
            }
            return (contentGroup.frame, contentGroup.source)
        }
        return nil
    }

    private static func viewportCacheKey(pid: pid_t, windowId: Int?, title: String?, frame: CGRect) -> String {
        [
            String(pid),
            windowId.map(String.init) ?? "no-window-id",
            title ?? "no-title",
            String(Int(frame.origin.x.rounded())),
            String(Int(frame.origin.y.rounded())),
            String(Int(frame.width.rounded())),
            String(Int(frame.height.rounded()))
        ].joined(separator: "|")
    }

    private struct ViewportCandidate {
        let role: String
        let source: String
        let frame: CGRect
    }

    private static func collectViewportCandidates(from root: AXUIElement, windowFrame: CGRect) -> [ViewportCandidate] {
        var candidates = [ViewportCandidate]()
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var visited = 0
        let maxDepth = 6
        let maxVisited = 120
        let deadline = Date().addingTimeInterval(0.75)

        while !queue.isEmpty, visited < maxVisited, Date() < deadline {
            let current = queue.removeFirst()
            visited += 1
            AXUIElementSetMessagingTimeout(current.element, 0.08)

            if let role = copyStringAttribute(of: current.element, name: kAXRoleAttribute),
               let frame = copyFrame(of: current.element) {
                let subrole = copyStringAttribute(of: current.element, name: kAXSubroleAttribute)
                if (role == "AXWebArea" || role == "AXScrollArea"),
                   isPlausibleViewportFrame(frame, within: windowFrame) {
                    candidates.append(ViewportCandidate(role: role, source: role, frame: frame))
                } else if role == "AXGroup",
                          subrole != "AXApplicationGroup",
                          isPlausibleContentGroupFrame(frame, within: windowFrame) {
                    candidates.append(ViewportCandidate(role: role, source: "AXGroupContentArea", frame: frame))
                }
            }

            guard current.depth < maxDepth else {
                continue
            }
            guard let children = copyAttribute(current.element, name: kAXChildrenAttribute) as? [AXUIElement] else {
                continue
            }
            for child in children.prefix(40) {
                queue.append((child, current.depth + 1))
            }
        }

        return candidates
    }

    private static func isPlausibleViewportFrame(_ frame: CGRect, within windowFrame: CGRect) -> Bool {
        guard frame.width >= 200, frame.height >= 120 else {
            return false
        }
        guard frame.intersects(windowFrame) else {
            return false
        }
        let intersection = frame.intersection(windowFrame)
        let frameArea = frame.width * frame.height
        let intersectionArea = intersection.width * intersection.height
        return frameArea > 0 && intersectionArea / frameArea > 0.80
    }

    private static func isPlausibleContentGroupFrame(_ frame: CGRect, within windowFrame: CGRect) -> Bool {
        guard isPlausibleViewportFrame(frame, within: windowFrame) else {
            return false
        }
        guard frame.width >= windowFrame.width * 0.60, frame.height >= windowFrame.height * 0.40 else {
            return false
        }
        guard frame.minY >= windowFrame.minY + 40 else {
            return false
        }
        return abs(frame.maxY - windowFrame.maxY) <= 4
    }
}
