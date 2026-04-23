import AppKit
import CoreGraphics
import Foundation
import HumanizationKit
import XCTest
@testable import InjectorCore

@objcMembers
final class EventPosterTests: XCTestCase {
    func testGlobalPostsWhenFrontmost() {
        let backend = RecordingBackend()
        let poster = EventPoster(mode: .global, targetPid: 42, backend: backend)
        let event = try! XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))

        let route = try! poster.post(event, type: .keyDown, frontmost: true)

        XCTAssertEqual(route, .global)
        XCTAssertEqual(backend.calls, [.global])
        XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), EventPoster.defaultMarkValue)
    }

    func testGlobalRejectsWhenNotFrontmost() {
        let backend = RecordingBackend()
        let poster = EventPoster(mode: .global, targetPid: 42, backend: backend)
        let event = try! XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))

        XCTAssertThrowsError(try poster.post(event, type: .keyDown, frontmost: false)) { error in
            XCTAssertEqual(error as? PosterError, .notFrontmost)
        }
        XCTAssertTrue(backend.calls.isEmpty)
    }

    func testPidPostsMouseMove() {
        let backend = RecordingBackend()
        let poster = EventPoster(mode: .pid, targetPid: 77, backend: backend)
        let event = try! XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: .zero, mouseButton: .left))

        let route = try! poster.post(event, type: .mouseMoved, frontmost: false)

        XCTAssertEqual(route, .pid)
        XCTAssertEqual(backend.calls, [.pid(77)])
    }

    func testPidRejectsClick() {
        let backend = RecordingBackend()
        let poster = EventPoster(mode: .pid, targetPid: 77, backend: backend)
        let event = try! XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left))

        XCTAssertThrowsError(try poster.post(event, type: .leftMouseDown, frontmost: false)) { error in
            XCTAssertEqual(error as? PosterError, .postModeUnsupported(.leftMouseDown))
        }
        XCTAssertTrue(backend.calls.isEmpty)
    }

    func testDryRunClickIncludesPreludeMoveEventsWhenOriginProvided() {
        let app = NSRunningApplication.current
        let target = BrowserTarget(
            app: app,
            pid: app.processIdentifier,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.vyodels.virtualhid.tests",
            windowTitle: nil,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )
        let executor = ActionExecutor(target: target)

        let result = try! executor.execute(
            ActionRequest(
                id: "click-prelude",
                primitives: [
                    .click(
                        at: CGPoint(x: 180, y: 140),
                        button: .left,
                        holdMs: 40,
                        count: 1,
                        profile: PrimitiveProfile(origin: CGPoint(x: 20, y: 20))
                    )
                ],
                context: ActionContext(host: "example.com", element: .init(sig: "sig-click", role: "button")),
                options: ActionOptions(postMode: .global, dryRun: true)
            )
        )

        XCTAssertTrue(result.events.count > 3)
        XCTAssertEqual(result.events.first?.type, "mouseMoved")
        XCTAssertEqual(result.events.suffix(2).map(\.type), ["leftMouseDown", "leftMouseUp"])
    }

    func testTargetSpreadDoesNotShiftFinalLandingPoint() {
        let app = NSRunningApplication.current
        let target = BrowserTarget(
            app: app,
            pid: app.processIdentifier,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.vyodels.virtualhid.tests",
            windowTitle: nil,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )
        let executor = ActionExecutor(target: target)
        let requestedPoint = CGPoint(x: 320, y: 240)
        let profile = PrimitiveProfile(
            origin: CGPoint(x: 40, y: 60),
            motionProfile: MotionProfile(targetSpreadPx: 24)
        )

        let result = try! executor.execute(
            ActionRequest(
                id: "fixed-target-point",
                primitives: [
                    .click(
                        at: requestedPoint,
                        button: .left,
                        holdMs: 40,
                        count: 1,
                        profile: profile
                    )
                ],
                context: ActionContext(host: "example.com", element: .init(sig: "sig-click", role: "button")),
                options: ActionOptions(postMode: .global, dryRun: true)
            )
        )

        let finalLocation = result.events.last?.location
        XCTAssertEqual(finalLocation?.x, requestedPoint.x)
        XCTAssertEqual(finalLocation?.y, requestedPoint.y)
    }
}

private final class RecordingBackend: EventPostingBackend {
    enum Call: Equatable {
        case global
        case pid(pid_t)
    }

    private(set) var calls: [Call] = []

    func postGlobal(_ event: CGEvent) {
        calls.append(.global)
    }

    func postToPid(_ event: CGEvent, pid: pid_t) {
        calls.append(.pid(pid))
    }
}
