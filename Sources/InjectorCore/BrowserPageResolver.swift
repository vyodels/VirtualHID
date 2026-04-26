import AppKit
import Foundation

public struct BrowserPageTarget: Equatable {
    public let bundleId: String
    public let windowId: Int?
    public let windowTitle: String?
    public let tabId: Int?
    public let tabIndex: Int
    public let tabTitle: String?
    public let url: String?
    public let host: String?
    public let active: Bool

    public init(
        bundleId: String,
        windowId: Int?,
        windowTitle: String?,
        tabId: Int?,
        tabIndex: Int,
        tabTitle: String?,
        url: String?,
        host: String?,
        active: Bool
    ) {
        self.bundleId = bundleId
        self.windowId = windowId
        self.windowTitle = windowTitle
        self.tabId = tabId
        self.tabIndex = tabIndex
        self.tabTitle = tabTitle
        self.url = url
        self.host = host
        self.active = active
    }
}

public struct BrowserPageResolution: Equatable {
    public let page: BrowserPageTarget
    public let target: TargetResolution

    public init(page: BrowserPageTarget, target: TargetResolution) {
        self.page = page
        self.target = target
    }
}

public protocol BrowserPageScriptRunning {
    func runAppleScript(_ source: String) throws -> String
}

public enum BrowserPageResolverError: Error, Equatable, LocalizedError {
    case unsupportedBrowser(String)
    case automationFailed(String)
    case malformedOutput(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedBrowser(let bundleId):
            return "browser page activation is not supported for \(bundleId)"
        case .automationFailed(let message):
            return "browser automation failed: \(message)"
        case .malformedOutput(let line):
            return "browser automation returned malformed row: \(line)"
        }
    }
}

public struct OsaScriptRunner: BrowserPageScriptRunning {
    public init() {}

    public func runAppleScript(_ source: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()

        let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw BrowserPageResolverError.automationFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return stdout
    }
}

public enum BrowserPageResolver {
    private static let fieldSeparator = "\u{1F}"
    private static let rowSeparator = "\u{1E}"

    public static func requiresPageResolution(_ descriptor: TargetDescriptor?) -> Bool {
        descriptor?.windowId != nil || descriptor?.tabId != nil || descriptor?.host != nil
    }

    public static func supports(bundleId: String) -> Bool {
        browserKind(bundleId: bundleId) != nil
    }

    public static func resolve(
        descriptor: TargetDescriptor,
        bundleIdentifiers: [String],
        runner: BrowserPageScriptRunning = OsaScriptRunner(),
        requireRunningApplications: Bool = true
    ) throws -> BrowserPageResolution {
        let runningBundles = bundleIdentifiers.filter { bundleId in
            supports(bundleId: bundleId)
                && (!requireRunningApplications || !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty)
        }
        guard !runningBundles.isEmpty else {
            throw TargetResolverV2Error.noCandidate
        }

        var pages = [BrowserPageTarget]()
        for bundleId in runningBundles {
            pages.append(contentsOf: try listPages(bundleId: bundleId, runner: runner))
        }

        let weakMatches = pages.filter { weakPageMatch(descriptor: descriptor, page: $0) }
        if descriptor.windowId == nil, descriptor.tabId == nil, weakMatches.count > 1 {
            throw TargetResolverV2Error.ambiguous(weakMatches.map(candidate(for:)))
        }

        let candidates = pages.map {
            TargetCandidate(
                bundleId: $0.bundleId,
                windowId: $0.windowId,
                windowTitle: $0.windowTitle ?? $0.tabTitle,
                tabId: $0.tabId,
                host: $0.host,
                frontmost: $0.active
            )
        }
        let resolution = try TargetResolverV2.resolve(descriptor: descriptor, candidates: candidates)
        guard let page = pages.first(where: { candidate(for: $0) == resolution.candidate }) else {
            throw TargetResolverV2Error.noCandidate
        }
        try activate(page: page, runner: runner)
        return BrowserPageResolution(page: page, target: resolution)
    }

    public static func listPages(
        bundleId: String,
        runner: BrowserPageScriptRunning = OsaScriptRunner()
    ) throws -> [BrowserPageTarget] {
        guard let kind = browserKind(bundleId: bundleId) else {
            throw BrowserPageResolverError.unsupportedBrowser(bundleId)
        }
        let output = try runner.runAppleScript(listScript(bundleId: bundleId, kind: kind))
        return try parseListOutput(output, bundleId: bundleId)
    }

    static func parseListOutput(_ output: String, bundleId: String) throws -> [BrowserPageTarget] {
        let rows = output.components(separatedBy: rowSeparator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return try rows.map { row in
            let fields = row.components(separatedBy: fieldSeparator)
            guard fields.count == 7 else {
                throw BrowserPageResolverError.malformedOutput(row)
            }
            let windowId = Int(fields[0])
            let windowTitle = emptyToNil(fields[1])
            let tabId = Int(fields[2])
            let tabIndex = Int(fields[3]) ?? 1
            let active = fields[4].lowercased() == "true"
            let tabTitle = emptyToNil(fields[5])
            let url = emptyToNil(fields[6])
            return BrowserPageTarget(
                bundleId: bundleId,
                windowId: windowId,
                windowTitle: windowTitle,
                tabId: tabId,
                tabIndex: tabIndex,
                tabTitle: tabTitle,
                url: url,
                host: normalizedHost(from: url),
                active: active
            )
        }
    }

    static func activate(page: BrowserPageTarget, runner: BrowserPageScriptRunning = OsaScriptRunner()) throws {
        guard let kind = browserKind(bundleId: page.bundleId) else {
            throw BrowserPageResolverError.unsupportedBrowser(page.bundleId)
        }
        _ = try runner.runAppleScript(activationScript(page: page, kind: kind))
    }

    private static func candidate(for page: BrowserPageTarget) -> TargetCandidate {
        TargetCandidate(
            bundleId: page.bundleId,
            windowId: page.windowId,
            windowTitle: page.windowTitle ?? page.tabTitle,
            tabId: page.tabId,
            host: page.host,
            frontmost: page.active
        )
    }

    private static func weakPageMatch(descriptor: TargetDescriptor, page: BrowserPageTarget) -> Bool {
        if let bundleId = descriptor.bundleId, bundleId != page.bundleId {
            return false
        }
        if let host = descriptor.host, host != page.host {
            return false
        }
        if let title = descriptor.windowTitle,
           page.windowTitle?.contains(title) != true,
           page.tabTitle?.contains(title) != true {
            return false
        }
        return descriptor.host != nil || descriptor.windowTitle != nil
    }

    private enum BrowserKind {
        case chromium
        case safari
    }

    private static func browserKind(bundleId: String) -> BrowserKind? {
        switch bundleId {
        case "com.google.Chrome", "org.chromium.Chromium", "com.microsoft.edgemac":
            return .chromium
        case "com.apple.Safari":
            return .safari
        default:
            return nil
        }
    }

    private static func listScript(bundleId: String, kind: BrowserKind) -> String {
        switch kind {
        case .chromium:
            return """
            tell application id \(quoted(bundleId))
              set fieldSep to ASCII character 31
              set rowSep to ASCII character 30
              set output to ""
              repeat with w in windows
                set windowId to (id of w as text)
                set activeIndex to active tab index of w
                set windowTitle to title of active tab of w
                repeat with i from 1 to count of tabs of w
                  set t to tab i of w
                  set tabId to (id of t as text)
                  set isActive to ((i as integer) is (activeIndex as integer))
                  set output to output & windowId & fieldSep & windowTitle & fieldSep & tabId & fieldSep & (i as text) & fieldSep & (isActive as text) & fieldSep & (title of t) & fieldSep & (URL of t) & rowSep
                end repeat
              end repeat
              return output
            end tell
            """
        case .safari:
            return """
            tell application id \(quoted(bundleId))
              set fieldSep to ASCII character 31
              set rowSep to ASCII character 30
              set output to ""
              repeat with w in windows
                set windowId to (id of w as text)
                set activeIndex to 1
                set windowTitle to ""
                repeat with i from 1 to count of tabs of w
                  set t to tab i of w
                  if t is current tab of w then
                    set activeIndex to i
                    set windowTitle to name of t
                  end if
                end repeat
                repeat with i from 1 to count of tabs of w
                  set t to tab i of w
                  set tabId to (i as text)
                  set isActive to ((i as integer) is (activeIndex as integer))
                  set output to output & windowId & fieldSep & windowTitle & fieldSep & tabId & fieldSep & (i as text) & fieldSep & (isActive as text) & fieldSep & (name of t) & fieldSep & (URL of t) & rowSep
                end repeat
              end repeat
              return output
            end tell
            """
        }
    }

    private static func activationScript(page: BrowserPageTarget, kind: BrowserKind) -> String {
        let bundleId = quoted(page.bundleId)
        let windowSelector: String
        if let windowId = page.windowId {
            windowSelector = "window id \(windowId)"
        } else {
            windowSelector = "window 1"
        }
        switch kind {
        case .chromium:
            return """
            tell application id \(bundleId)
              activate
              set targetWindow to \(windowSelector)
              set index of targetWindow to 1
              set active tab index of targetWindow to \(page.tabIndex)
            end tell
            """
        case .safari:
            return """
            tell application id \(bundleId)
              activate
              set targetWindow to \(windowSelector)
              set current tab of targetWindow to tab \(page.tabIndex) of targetWindow
              set index of targetWindow to 1
            end tell
            """
        }
    }

    private static func normalizedHost(from url: String?) -> String? {
        guard let url, let components = URLComponents(string: url), let host = components.host else {
            return nil
        }
        let normalizedHost = host.lowercased()
        guard let port = components.port else {
            return normalizedHost
        }
        return "\(normalizedHost):\(port)"
    }

    private static func emptyToNil(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    private static func quoted(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
