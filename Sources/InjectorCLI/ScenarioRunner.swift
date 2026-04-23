import AppKit
import CoreGraphics
import Foundation
import InjectorCore

struct ScenarioResult: Codable {
    let scenario: String
    let targetPid: pid_t
    let targetBundleId: String
    let targetWindowTitle: String?
    let targetFrame: CodableRect
    let startTime: String
    let endTime: String
    let events: [InjectedEvent]
}

struct ScenarioRunner {
    let target: BrowserTarget
    let resultsDirectory: URL
    let keyInput: String
    let dryRun: Bool
    let executor: ActionExecutor

    init(target: BrowserTarget, resultsDirectory: URL, keyInput: String, dryRun: Bool) {
        self.target = target
        self.resultsDirectory = resultsDirectory
        self.keyInput = keyInput
        self.dryRun = dryRun
        self.executor = ActionExecutor(target: target, defaultPostMode: .global)
    }

    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func run(named name: String) throws -> ScenarioResult {
        switch name {
        case "mouse_move_click_active":
            return try runMouseMoveClick(active: true)
        case "mouse_drag_active":
            return try runMouseDrag(active: true)
        case "keyboard_type_active":
            return try runKeyboardType(active: true)
        case "mouse_move_click_blur":
            return try runMouseMoveClick(active: false)
        case "keyboard_type_blur":
            return try runKeyboardType(active: false)
        default:
            throw NSError(domain: "ScenarioRunner", code: 2, userInfo: [NSLocalizedDescriptionKey: "未知场景：\(name)"])
        }
    }

    func persist(_ result: ScenarioResult) throws {
        let fileURL = resultsDirectory.appendingPathComponent("\(result.scenario).json")
        let data = try JSONEncoder.pretty.encode(result)
        try data.write(to: fileURL)
    }

    private func runMouseMoveClick(active: Bool) throws -> ScenarioResult {
        try prepareFocus(active: active)
        let start = isoFormatter.string(from: Date())
        let clickPoint = point(xFactor: 0.72, yFactor: 0.58)
        let primitives = [
            ActionPrimitive.move(to: clickPoint, via: .wind, durationMs: 560, profile: nil),
            .click(at: clickPoint, button: .left, holdMs: 45, count: 1, profile: nil)
        ]
        let actionResult = try executor.execute(
            request(
                for: active ? "mouse_move_click_active" : "mouse_move_click_blur",
                primitives: primitives
            )
        )

        let end = isoFormatter.string(from: Date())
        let result = ScenarioResult(
            scenario: active ? "mouse_move_click_active" : "mouse_move_click_blur",
            targetPid: target.pid,
            targetBundleId: target.bundleIdentifier,
            targetWindowTitle: target.windowTitle,
            targetFrame: codableRect(target.frame),
            startTime: start,
            endTime: end,
            events: actionResult.events
        )
        try persist(result)
        return result
    }

    private func runMouseDrag(active: Bool) throws -> ScenarioResult {
        try prepareFocus(active: active)
        let start = isoFormatter.string(from: Date())
        let startPoint = point(xFactor: 0.70, yFactor: 0.76)
        let endPoint = point(xFactor: 0.44, yFactor: 0.48)
        let actionResult = try executor.execute(
            request(
                for: "mouse_drag_active",
                primitives: [.drag(from: startPoint, to: endPoint, button: .left, via: .wind, profile: nil)]
            )
        )

        let end = isoFormatter.string(from: Date())
        let result = ScenarioResult(
            scenario: "mouse_drag_active",
            targetPid: target.pid,
            targetBundleId: target.bundleIdentifier,
            targetWindowTitle: target.windowTitle,
            targetFrame: codableRect(target.frame),
            startTime: start,
            endTime: end,
            events: actionResult.events
        )
        try persist(result)
        return result
    }

    private func runKeyboardType(active: Bool) throws -> ScenarioResult {
        try prepareFocus(active: active)
        let start = isoFormatter.string(from: Date())
        let actionResult = try executor.execute(
            request(
                for: active ? "keyboard_type_active" : "keyboard_type_blur",
                primitives: [.type(text: keyInput, layout: .us, profile: nil)]
            )
        )

        let end = isoFormatter.string(from: Date())
        let result = ScenarioResult(
            scenario: active ? "keyboard_type_active" : "keyboard_type_blur",
            targetPid: target.pid,
            targetBundleId: target.bundleIdentifier,
            targetWindowTitle: target.windowTitle,
            targetFrame: codableRect(target.frame),
            startTime: start,
            endTime: end,
            events: actionResult.events
        )
        try persist(result)
        return result
    }

    private func prepareFocus(active: Bool) throws {
        if active {
            _ = FocusController.activate(app: target.app)
            FocusController.sleep(milliseconds: 260)
            return
        }

        let textEdit = try FocusController.launchTextEdit()
        FocusController.waitForApp(textEdit)
        _ = FocusController.activate(app: textEdit)
        FocusController.sleep(milliseconds: 420)
    }

    private func request(for id: String, primitives: [ActionPrimitive]) -> ActionRequest {
        ActionRequest(
            id: id,
            primitives: primitives,
            context: ActionContext(
                host: "scenario.local",
                url: "about:scenario/\(id)",
                element: ActionContext.Element(sig: id, role: "test-scenario")
            ),
            options: ActionOptions(postMode: .global, dryRun: dryRun)
        )
    }

    private func point(xFactor: CGFloat, yFactor: CGFloat) -> CGPoint {
        CGPoint(
            x: target.frame.minX + target.frame.width * xFactor,
            y: target.frame.minY + target.frame.height * yFactor
        )
    }

    private func codableRect(_ rect: CGRect) -> CodableRect {
        CodableRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }
}
