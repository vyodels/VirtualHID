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
    public let browserWindowId: Int?
    public let tabId: Int?
    public let host: String?
    public let url: String?
    public let frame: CGRect
    public let viewportFrame: CGRect?
    public let viewportFrameSource: String?

    public init(
        app: NSRunningApplication,
        pid: pid_t,
        bundleIdentifier: String,
        windowId: Int? = nil,
        windowTitle: String?,
        browserWindowId: Int? = nil,
        tabId: Int? = nil,
        host: String? = nil,
        url: String? = nil,
        frame: CGRect,
        viewportFrame: CGRect? = nil,
        viewportFrameSource: String? = nil
    ) {
        self.app = app
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.windowId = windowId
        self.windowTitle = windowTitle
        self.browserWindowId = browserWindowId
        self.tabId = tabId
        self.host = host
        self.url = url
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
    case unresolvedBrowserPageTarget(String)

    public var errorDescription: String? {
        switch self {
        case .appNotFound(let bundleId):
            return "未找到运行中的浏览器：\(bundleId)"
        case .permissionDenied:
            return "缺少 Accessibility 权限，无法读取目标窗口信息"
        case .windowNotFound(let bundleId):
            return "未找到可见窗口：\(bundleId)"
        case .unresolvedBrowserPageTarget(let reason):
            return reason
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
        expectedViewportSize: CGSize? = nil,
        promptForPermission: Bool = true
    ) throws -> BrowserTarget {
        try ensureAccessibilityTrusted(prompt: promptForPermission)
        var resolvedTargets = [BrowserTarget]()
        var sawRunningApp = false
        var lastWindowError: BrowserResolverError?

        let requestedBundleIdentifiers = descriptor?.bundleId.map { [$0] } ?? bundleIdentifiers
        let pageResolution = try resolvePageIfNeeded(
            descriptor: descriptor,
            bundleIdentifiers: requestedBundleIdentifiers
        )
        let pageTarget = pageResolution?.page
        let targetBundleIdentifiers = pageTarget.map { [$0.bundleId] } ?? requestedBundleIdentifiers
        let windowDescriptor = macOSWindowDescriptor(for: descriptor, pageTarget: pageTarget)
        let useFocusedBrowserWindow = pageTarget != nil || requiresFocusedBrowserWindow(descriptor)
        let raiseMatchedWindow = requiresBrowserWindowRaise(descriptor)
        for bundleIdentifier in targetBundleIdentifiers {
            let apps = runningApplications(bundleIdentifier: bundleIdentifier, waitForRegistration: pageTarget != nil)
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
            if shouldRejectUnresolvedPageTarget(descriptor: descriptor, pageTarget: pageTarget, appCount: apps.count) {
                throw BrowserResolverError.unresolvedBrowserPageTarget(
                    "无法把 browser target 解析到具体 Chrome 页面，拒绝回退到 frontmost 窗口以避免错窗输入。"
                    + " 当前存在多个同 bundle 浏览器进程；请复用 browser MCP 所在 Chrome，或在 target 中传入 browser_snapshot target.title/windowTitle。"
                )
            }

            for app in apps {
                do {
                    if useFocusedBrowserWindow {
                        _ = FocusController.ensureFrontmost(app: app, timeout: 0.8)
                    }
                    let window: ResolvedWindow
                    do {
                        window = try resolveMainWindow(
                            for: app,
                            bundleIdentifier: bundleIdentifier,
                            descriptor: windowDescriptor,
                            expectedViewportSize: expectedViewportSize,
                            focusedOnly: useFocusedBrowserWindow,
                            raiseMatchedWindow: raiseMatchedWindow
                        )
                    } catch BrowserResolverError.windowNotFound where pageTarget != nil {
                        window = try resolveMainWindow(
                            for: app,
                            bundleIdentifier: bundleIdentifier,
                            descriptor: windowDescriptor,
                            expectedViewportSize: expectedViewportSize,
                            focusedOnly: false,
                            raiseMatchedWindow: raiseMatchedWindow
                        )
                    } catch BrowserResolverError.windowNotFound where useFocusedBrowserWindow {
                        // Some Chrome sessions do not expose AXFocusedWindow even after
                        // AppleScript activates the requested tab/window. Page identity
                        // remains grounded in BrowserPageResolver; this fallback only
                        // recovers macOS window/viewport evidence.
                        window = try resolveMainWindow(
                            for: app,
                            bundleIdentifier: bundleIdentifier,
                            descriptor: windowDescriptor,
                            expectedViewportSize: expectedViewportSize,
                            focusedOnly: false,
                            raiseMatchedWindow: raiseMatchedWindow
                        )
                    }
                    resolvedTargets.append(
                        BrowserTarget(
                            app: app,
                            pid: app.processIdentifier,
                            bundleIdentifier: bundleIdentifier,
                            windowId: window.windowId,
                            windowTitle: window.title ?? pageTarget?.windowTitle ?? pageTarget?.tabTitle,
                            browserWindowId: pageTarget?.windowId,
                            tabId: pageTarget?.tabId ?? descriptor?.tabId,
                            host: pageTarget?.host ?? descriptor?.host,
                            url: pageTarget?.url,
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

            if let fallback = resolveCGWindowAcrossRunningProcesses(
                bundleIdentifier: bundleIdentifier,
                descriptor: windowDescriptor,
                expectedViewportSize: expectedViewportSize
            ) {
                resolvedTargets.append(
                    BrowserTarget(
                        app: fallback.app,
                        pid: fallback.app.processIdentifier,
                        bundleIdentifier: bundleIdentifier,
                        windowId: fallback.window.windowId,
                        windowTitle: fallback.window.title,
                        browserWindowId: pageTarget?.windowId,
                        tabId: pageTarget?.tabId ?? descriptor?.tabId,
                        host: pageTarget?.host ?? descriptor?.host,
                        url: pageTarget?.url,
                        frame: fallback.window.frame,
                        viewportFrame: fallback.window.viewportFrame,
                        viewportFrameSource: fallback.window.viewportFrameSource
                    )
                )
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

    static func shouldRejectUnresolvedPageTarget(
        descriptor: TargetDescriptor?,
        pageTarget: BrowserPageTarget?,
        appCount: Int
    ) -> Bool {
        guard pageTarget == nil, appCount > 1, let descriptor else {
            return false
        }
        guard descriptor.host != nil || descriptor.tabId != nil else {
            return false
        }
        // Browser extension window/tab ids are not macOS window ids. If the
        // AppleScript page resolver cannot bind the browser page and multiple
        // Chrome processes exist, only explicit browser-derived native window
        // evidence gives AX/CG lookup a process-independent way to choose the
        // correct native window.
        return descriptor.windowTitle == nil && descriptor.browserWindowBounds == nil
    }

    static func macOSWindowDescriptor(for descriptor: TargetDescriptor?, pageTarget: BrowserPageTarget?) -> TargetDescriptor? {
        guard let pageTarget else {
            guard let descriptor else {
                return nil
            }
            if descriptor.host != nil || descriptor.tabId != nil {
                return TargetDescriptor(
                    bundleId: descriptor.bundleId,
                    windowTitle: descriptor.windowTitle,
                    browserWindowBounds: descriptor.browserWindowBounds
                )
            }
            return descriptor
        }
        let title = descriptor?.windowTitle ?? pageTarget.windowTitle ?? pageTarget.tabTitle
        return TargetDescriptor(
            bundleId: pageTarget.bundleId,
            windowTitle: title,
            tabId: pageTarget.tabId ?? descriptor?.tabId,
            host: pageTarget.host ?? descriptor?.host,
            browserWindowBounds: descriptor?.browserWindowBounds
        )
    }

    private static func runningApplications(bundleIdentifier: String, waitForRegistration: Bool) -> [NSRunningApplication] {
        let attempts = waitForRegistration ? 20 : 1
        for attempt in 0..<attempts {
            let direct = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            let workspace = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleIdentifier }
            let merged = (direct + workspace).reduce(into: [pid_t: NSRunningApplication]()) { result, app in
                if !app.isTerminated {
                    result[app.processIdentifier] = app
                }
            }
            let apps = Array(merged.values)
            if !apps.isEmpty || attempt == attempts - 1 {
                return apps
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return []
    }

    private static func resolvePageIfNeeded(
        descriptor: TargetDescriptor?,
        bundleIdentifiers: [String]
    ) throws -> BrowserPageResolution? {
        guard let descriptor, BrowserPageResolver.requiresPageResolution(descriptor) else {
            return nil
        }
        do {
            return try BrowserPageResolver.resolve(
                descriptor: descriptor,
                bundleIdentifiers: bundleIdentifiers
            )
        } catch TargetResolverV2Error.noCandidate {
            if let fallbackDescriptor = browserPageFallbackDescriptor(for: descriptor) {
                do {
                    return try BrowserPageResolver.resolve(
                        descriptor: fallbackDescriptor,
                        bundleIdentifiers: bundleIdentifiers
                    )
                } catch TargetResolverV2Error.noCandidate {
                    return nil
                } catch BrowserPageResolverError.automationFailed {
                    return nil
                }
            }
            // Browser MCP already owns tab selection. Some Chrome sessions expose
            // AX/CG windows but not AppleScript windows, so page activation must
            // be best-effort instead of blocking HID execution.
            return nil
        } catch BrowserPageResolverError.automationFailed {
            return nil
        }
    }

    private static func browserPageFallbackDescriptor(for descriptor: TargetDescriptor) -> TargetDescriptor? {
        guard descriptor.host != nil else {
            return nil
        }
        let fallback = TargetDescriptor(
            bundleId: descriptor.bundleId,
            windowTitle: descriptor.windowTitle,
            host: descriptor.host,
            browserWindowBounds: descriptor.browserWindowBounds
        )
        return fallback == descriptor ? nil : fallback
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
        expectedViewportSize: CGSize?,
        focusedOnly: Bool,
        raiseMatchedWindow: Bool = false
    ) throws -> ResolvedWindow {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.2)
        if let focusedWindow = copyAXElementAttribute(of: axApp, name: kAXFocusedWindowAttribute),
           let resolved = resolveWindow(focusedWindow, pid: app.processIdentifier),
           matches(resolved, descriptor: descriptor, expectedViewportSize: expectedViewportSize) {
            if raiseMatchedWindow {
                raiseWindow(focusedWindow, app: app)
            }
            return resolved
        }

        if focusedOnly {
            throw BrowserResolverError.windowNotFound(bundleIdentifier)
        }

        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
        if status == .success, let windows = value as? [AXUIElement], !windows.isEmpty {
            for window in windows {
                if let resolved = resolveWindow(window, pid: app.processIdentifier),
                   matches(resolved, descriptor: descriptor, expectedViewportSize: expectedViewportSize) {
                    if raiseMatchedWindow {
                        raiseWindow(window, app: app)
                    }
                    return resolved
                }
            }
        }

        if let fallback = resolveCGWindow(for: app.processIdentifier, descriptor: descriptor, expectedViewportSize: expectedViewportSize) {
            return fallback
        }

        throw BrowserResolverError.windowNotFound(bundleIdentifier)
    }

    private static func requiresBrowserWindowRaise(_ descriptor: TargetDescriptor?) -> Bool {
        guard let descriptor else {
            return false
        }
        return descriptor.host != nil
            || descriptor.tabId != nil
            || descriptor.windowId != nil
            || descriptor.windowTitle != nil
    }

    private static func raiseWindow(_ window: AXUIElement, app: NSRunningApplication) {
        _ = FocusController.ensureFrontmost(app: app, timeout: 1.0)
        AXUIElementSetMessagingTimeout(window, 0.2)
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute as CFString, window)
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

    private static func matches(_ window: ResolvedWindow, descriptor: TargetDescriptor?, expectedViewportSize: CGSize? = nil) -> Bool {
        guard let descriptor else {
            return true
        }
        if descriptor.browserWindowBounds != nil,
           !browserWindowBoundsMatches(window: window, descriptor: descriptor) {
            return false
        }
        if descriptor.browserWindowBounds != nil {
            return true
        }
        // Browser page identity is resolved and activated before AX window lookup.
        // The AX step stays grounded in macOS window evidence.
        if let requestedTitle = descriptor.windowTitle, window.title?.contains(requestedTitle) != true,
           !viewportSizeMatches(window: window, expectedViewportSize: expectedViewportSize) {
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

    private static func resolveCGWindow(
        for pid: pid_t,
        descriptor: TargetDescriptor?,
        expectedViewportSize: CGSize? = nil
    ) -> ResolvedWindow? {
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

            let fallbackViewport = browserContentFallbackFrame(windowFrame: frame)
            let resolved = ResolvedWindow(
                title: window[kCGWindowName as String] as? String,
                frame: frame,
                windowId: windowId,
                viewportFrame: fallbackViewport,
                viewportFrameSource: fallbackViewport == nil ? nil : "browserWindowContentHeuristic"
            )
            if !matches(resolved, descriptor: descriptor, expectedViewportSize: expectedViewportSize) {
                continue
            }
            return resolved
        }

        return nil
    }

    private static func resolveCGWindowAcrossRunningProcesses(
        bundleIdentifier: String,
        descriptor: TargetDescriptor?,
        expectedViewportSize: CGSize? = nil
    ) -> (app: NSRunningApplication, window: ResolvedWindow)? {
        guard (descriptor?.windowTitle != nil || descriptor?.browserWindowBounds != nil || expectedViewportSize != nil),
              let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else {
            return nil
        }

        for window in windowList {
            guard let ownerPid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let app = NSRunningApplication(processIdentifier: ownerPid),
                  app.bundleIdentifier == bundleIdentifier,
                  let boundsValue = window[kCGWindowBounds as String] as? [String: Any]
            else {
                continue
            }

            let cfBounds = boundsValue as CFDictionary
            guard let frame = CGRect(dictionaryRepresentation: cfBounds), frame.width > 200, frame.height > 200 else {
                continue
            }

            let windowId = window[kCGWindowNumber as String] as? Int
            let fallbackViewport = browserContentFallbackFrame(windowFrame: frame)
            let resolved = ResolvedWindow(
                title: window[kCGWindowName as String] as? String,
                frame: frame,
                windowId: windowId,
                viewportFrame: fallbackViewport,
                viewportFrameSource: fallbackViewport == nil ? nil : "browserWindowContentHeuristic"
            )
            if !matches(resolved, descriptor: descriptor, expectedViewportSize: expectedViewportSize) {
                continue
            }
            return (app, resolved)
        }

        return nil
    }

    private static func viewportSizeMatches(window: ResolvedWindow, expectedViewportSize: CGSize?) -> Bool {
        guard let expectedViewportSize,
              expectedViewportSize.width > 0,
              expectedViewportSize.height > 0,
              let viewportFrame = window.viewportFrame
        else {
            return false
        }
        return abs(viewportFrame.width - expectedViewportSize.width) <= 4
            && abs(viewportFrame.height - expectedViewportSize.height) <= 96
    }

    private static func browserWindowBoundsMatches(window: ResolvedWindow, descriptor: TargetDescriptor) -> Bool {
        guard let expected = descriptor.browserWindowBounds else {
            return false
        }
        let expectedFrame = CGRect(x: expected.x, y: expected.y, width: expected.width, height: expected.height)
        guard expectedFrame.width > 200, expectedFrame.height > 200 else {
            return false
        }
        let originTolerance: CGFloat = 160
        let sizeTolerance: CGFloat = 180
        return abs(window.frame.origin.x - expectedFrame.origin.x) <= originTolerance
            && abs(window.frame.origin.y - expectedFrame.origin.y) <= originTolerance
            && abs(window.frame.width - expectedFrame.width) <= sizeTolerance
            && abs(window.frame.height - expectedFrame.height) <= sizeTolerance
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
        if let fallback = browserContentFallbackFrame(windowFrame: windowFrame) {
            if let cacheKey {
                viewportCache.set((fallback, "browserWindowContentHeuristic"), for: cacheKey)
            }
            return (fallback, "browserWindowContentHeuristic")
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
        let maxDepth = 9
        let maxVisited = 420
        let deadline = Date().addingTimeInterval(1.5)

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

    private static func browserContentFallbackFrame(windowFrame: CGRect) -> CGRect? {
        guard windowFrame.width >= 300, windowFrame.height >= 240 else {
            return nil
        }
        let topChromeHeight = min(max(windowFrame.height * 0.08, 88), 132)
        let frame = CGRect(
            x: windowFrame.minX,
            y: windowFrame.minY + topChromeHeight,
            width: windowFrame.width,
            height: windowFrame.height - topChromeHeight
        )
        guard frame.height >= 120 else {
            return nil
        }
        return frame
    }
}
