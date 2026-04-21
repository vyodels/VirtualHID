import AppKit
import CoreGraphics
import Foundation

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

struct InjectedEvent: Codable {
    let type: String
    let location: CodablePoint?
    let key: String?
    let virtualKey: CGKeyCode?
    let timestamp: String
}

struct CodablePoint: Codable {
    let x: Double
    let y: Double
}

struct CodableRect: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct ScenarioRunner {
    let target: BrowserTarget
    let resultsDirectory: URL
    let keyInput: String

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
        let points = interpolatedPath(from: point(xFactor: 0.25, yFactor: 0.32), to: point(xFactor: 0.72, yFactor: 0.58), steps: 18)
        var events = [InjectedEvent]()

        for point in points {
            try postMouse(type: .mouseMoved, location: point, button: .left)
            events.append(record(type: "mouseMoved", location: point))
            FocusController.sleep(milliseconds: 28)
        }

        let clickPoint = points.last ?? point(xFactor: 0.72, yFactor: 0.58)
        try postMouse(type: .leftMouseDown, location: clickPoint, button: .left)
        events.append(record(type: "leftMouseDown", location: clickPoint))
        FocusController.sleep(milliseconds: 45)
        try postMouse(type: .leftMouseUp, location: clickPoint, button: .left)
        events.append(record(type: "leftMouseUp", location: clickPoint))
        FocusController.sleep(milliseconds: 120)

        let end = isoFormatter.string(from: Date())
        let result = ScenarioResult(
            scenario: active ? "mouse_move_click_active" : "mouse_move_click_blur",
            targetPid: target.pid,
            targetBundleId: target.bundleIdentifier,
            targetWindowTitle: target.windowTitle,
            targetFrame: codableRect(target.frame),
            startTime: start,
            endTime: end,
            events: events
        )
        try persist(result)
        return result
    }

    private func runMouseDrag(active: Bool) throws -> ScenarioResult {
        try prepareFocus(active: active)
        let start = isoFormatter.string(from: Date())
        let startPoint = point(xFactor: 0.70, yFactor: 0.76)
        let endPoint = point(xFactor: 0.44, yFactor: 0.48)
        let dragPath = interpolatedPath(from: startPoint, to: endPoint, steps: 16)
        var events = [InjectedEvent]()

        try postMouse(type: .mouseMoved, location: startPoint, button: .left)
        events.append(record(type: "mouseMoved", location: startPoint))
        FocusController.sleep(milliseconds: 36)
        try postMouse(type: .leftMouseDown, location: startPoint, button: .left)
        events.append(record(type: "leftMouseDown", location: startPoint))
        FocusController.sleep(milliseconds: 48)

        for point in dragPath {
            try postMouse(type: .leftMouseDragged, location: point, button: .left)
            events.append(record(type: "leftMouseDragged", location: point))
            FocusController.sleep(milliseconds: 28)
        }

        let releasePoint = dragPath.last ?? endPoint
        try postMouse(type: .leftMouseUp, location: releasePoint, button: .left)
        events.append(record(type: "leftMouseUp", location: releasePoint))
        FocusController.sleep(milliseconds: 120)

        let end = isoFormatter.string(from: Date())
        let result = ScenarioResult(
            scenario: "mouse_drag_active",
            targetPid: target.pid,
            targetBundleId: target.bundleIdentifier,
            targetWindowTitle: target.windowTitle,
            targetFrame: codableRect(target.frame),
            startTime: start,
            endTime: end,
            events: events
        )
        try persist(result)
        return result
    }

    private func runKeyboardType(active: Bool) throws -> ScenarioResult {
        try prepareFocus(active: active)
        let start = isoFormatter.string(from: Date())
        var events = [InjectedEvent]()

        for scalar in keyInput.unicodeScalars {
            guard let key = KeyMap.characterEvent(for: scalar) else {
                continue
            }
            try postKeyboard(keyCode: key.keyCode, keyDown: true)
            events.append(record(type: "keyDown", key: String(scalar), virtualKey: key.keyCode))
            FocusController.sleep(milliseconds: 32)
            try postKeyboard(keyCode: key.keyCode, keyDown: false)
            events.append(record(type: "keyUp", key: String(scalar), virtualKey: key.keyCode))
            FocusController.sleep(milliseconds: 42)
        }

        let end = isoFormatter.string(from: Date())
        let result = ScenarioResult(
            scenario: active ? "keyboard_type_active" : "keyboard_type_blur",
            targetPid: target.pid,
            targetBundleId: target.bundleIdentifier,
            targetWindowTitle: target.windowTitle,
            targetFrame: codableRect(target.frame),
            startTime: start,
            endTime: end,
            events: events
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

    private func postMouse(type: CGEventType, location: CGPoint, button: CGMouseButton) throws {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: button) else {
            throw NSError(domain: "ScenarioRunner", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法创建鼠标事件：\(type.rawValue)"])
        }
        event.setIntegerValueField(.eventSourceUserData, value: 0x56484944)
        event.postToPid(target.pid)
    }

    private func postKeyboard(keyCode: CGKeyCode, keyDown: Bool) throws {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown) else {
            throw NSError(domain: "ScenarioRunner", code: 4, userInfo: [NSLocalizedDescriptionKey: "无法创建键盘事件：\(keyCode)"])
        }
        event.setIntegerValueField(.eventSourceUserData, value: 0x56484944)
        event.postToPid(target.pid)
    }

    private func point(xFactor: CGFloat, yFactor: CGFloat) -> CGPoint {
        CGPoint(
            x: target.frame.minX + target.frame.width * xFactor,
            y: target.frame.minY + target.frame.height * yFactor
        )
    }

    private func interpolatedPath(from start: CGPoint, to end: CGPoint, steps: Int) -> [CGPoint] {
        guard steps > 1 else { return [start, end] }
        return (0..<steps).map { index in
            let progress = CGFloat(index) / CGFloat(steps - 1)
            let eased = progress * progress * (3 - 2 * progress)
            return CGPoint(
                x: start.x + (end.x - start.x) * eased,
                y: start.y + (end.y - start.y) * eased
            )
        }
    }

    private func record(type: String, location: CGPoint? = nil, key: String? = nil, virtualKey: CGKeyCode? = nil) -> InjectedEvent {
        InjectedEvent(
            type: type,
            location: location.map { CodablePoint(x: $0.x, y: $0.y) },
            key: key,
            virtualKey: virtualKey,
            timestamp: isoFormatter.string(from: Date())
        )
    }

    private func codableRect(_ rect: CGRect) -> CodableRect {
        CodableRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }
}

enum KeyMap {
    private static let mapping: [UnicodeScalar: CGKeyCode] = [
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4,
        "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35,
        "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7,
        "y": 16, "z": 6,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
        " ": 49
    ]

    struct CharacterEvent {
        let keyCode: CGKeyCode
    }

    static func characterEvent(for scalar: UnicodeScalar) -> CharacterEvent? {
        guard let keyCode = mapping[UnicodeScalar(scalar.properties.lowercaseMapping) ?? scalar] ?? mapping[scalar] else {
            return nil
        }
        return CharacterEvent(keyCode: keyCode)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
