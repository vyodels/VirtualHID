import Foundation
import InjectorCore

struct Configuration {
    let bundleIdentifiers: [String]
    let scenarioNames: [String]
    let resultsDirectory: URL
    let keyInput: String
    let dryRun: Bool
}

enum ConfigurationParser {
    static func parse(arguments: [String]) -> Configuration {
        var bundleIdentifiers = ["com.google.Chrome", "org.chromium.Chromium", "com.microsoft.edgemac"]
        var scenarioNames = [
            "mouse_move_click_active",
            "mouse_drag_active",
            "keyboard_type_active",
            "mouse_move_click_blur",
            "keyboard_type_blur"
        ]
        var resultsDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("results", isDirectory: true)
        var keyInput = "abc123"
        var dryRun = false

        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--bundle":
                if let value = iterator.next() {
                    bundleIdentifiers = value.split(separator: ",").map { String($0) }
                }
            case "--scenarios":
                if let value = iterator.next() {
                    scenarioNames = value.split(separator: ",").map { String($0) }
                }
            case "--results-dir":
                if let value = iterator.next() {
                    resultsDirectory = URL(fileURLWithPath: value, isDirectory: true)
                }
            case "--key-input":
                if let value = iterator.next() {
                    keyInput = value
                }
            case "--dry-run":
                dryRun = true
            default:
                continue
            }
        }

        return Configuration(
            bundleIdentifiers: bundleIdentifiers,
            scenarioNames: scenarioNames,
            resultsDirectory: resultsDirectory,
            keyInput: keyInput,
            dryRun: dryRun
        )
    }
}

do {
    let configuration = ConfigurationParser.parse(arguments: CommandLine.arguments)
    try FileManager.default.createDirectory(at: configuration.resultsDirectory, withIntermediateDirectories: true)
    let target = try BrowserResolver.resolve(bundleIdentifiers: configuration.bundleIdentifiers)
    print("Resolved target: pid=\(target.pid) bundle=\(target.bundleIdentifier) title=\(target.windowTitle ?? "<unknown>") frame=\(NSStringFromRect(target.frame))")

    let runner = ScenarioRunner(
        target: target,
        resultsDirectory: configuration.resultsDirectory,
        keyInput: configuration.keyInput,
        dryRun: configuration.dryRun
    )
    for scenarioName in configuration.scenarioNames {
        let result = try runner.run(named: scenarioName)
        let summaryData = try JSONEncoder.pretty.encode(result)
        if let summary = String(data: summaryData, encoding: .utf8) {
            print(summary)
        }
    }
} catch {
    fputs("ERROR: \(error.localizedDescription)\n", stderr)
    exit(1)
}
