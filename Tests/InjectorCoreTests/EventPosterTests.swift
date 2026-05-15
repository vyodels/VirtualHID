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

        let route = try! poster.resolveRoute(type: .keyDown, frontmost: true)

        XCTAssertEqual(route, .global)
        XCTAssertTrue(backend.calls.isEmpty)
    }

    func testGlobalRejectsWhenNotFrontmost() {
        let backend = RecordingBackend()
        let poster = EventPoster(mode: .global, targetPid: 42, backend: backend)

        XCTAssertThrowsError(try poster.resolveRoute(type: .keyDown, frontmost: false)) { error in
            XCTAssertEqual(error as? PosterError, .notFrontmost)
        }
        XCTAssertTrue(backend.calls.isEmpty)
    }

    func testPidPostsMouseMove() {
        let backend = RecordingBackend()
        let poster = EventPoster(mode: .pid, targetPid: 77, backend: backend)

        let route = try! poster.resolveRoute(type: .mouseMoved, frontmost: false)

        XCTAssertEqual(route, .pid)
        XCTAssertTrue(backend.calls.isEmpty)
    }

    func testPidRejectsClick() {
        let backend = RecordingBackend()
        let poster = EventPoster(mode: .pid, targetPid: 77, backend: backend)

        XCTAssertThrowsError(try poster.resolveRoute(type: .leftMouseDown, frontmost: false)) { error in
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

    func testHidEventSinkReceivesOnlyRecordedEvents() {
        let app = NSRunningApplication.current
        let target = BrowserTarget(
            app: app,
            pid: app.processIdentifier,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.vyodels.virtualhid.tests",
            windowTitle: nil,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )
        let sink = RecordingHIDSink()
        let executor = ActionExecutor(target: target, eventSink: sink)

        let result = try! executor.execute(
            ActionRequest(
                id: "sink-click",
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

        XCTAssertEqual(sink.started?.actionId, "sink-click")
        XCTAssertEqual(sink.recorded, result.events)
        XCTAssertEqual(sink.started?.actionTypes, ["click"])
        XCTAssertEqual(sink.started?.dryRun, true)
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

    func testLandingZoneLetsVirtualHidChooseFinalLandingPoint() {
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
        let landingCenter = CGPoint(x: 324, y: 243)
        let profile = PrimitiveProfile(
            origin: CGPoint(x: 40, y: 60),
            landingZone: LandingZone(center: landingCenter, width: 16, height: 10)
        )

        let result = try! executor.execute(
            ActionRequest(
                id: "hid-selected-landing-point",
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
        XCTAssertTrue(finalLocation != nil)
        if let finalLocation {
            XCTAssertTrue(abs(finalLocation.x - Double(landingCenter.x)) <= 8)
            XCTAssertTrue(abs(finalLocation.y - Double(landingCenter.y)) <= 5)
        }
    }

    func testKeyPrimitiveAcceptsActionLevelRhythmProfile() {
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
                id: "key-action-profile",
                primitives: [
                    .key(chord: KeyChord(keyCode: 0), holdMs: 45, profile: nil)
                ],
                context: ActionContext(host: "example.com", element: .init(sig: "sig-key", role: "button")),
                options: ActionOptions(
                    postMode: .global,
                    dryRun: true,
                    rhythmProfile: MotionProfile(clickHoldMs: IntRange(min: 90, max: 90))
                )
            )
        )

        XCTAssertEqual(result.ok, true)
        XCTAssertEqual(result.events.map(\.type), ["keyDown", "keyUp"])
        let holdMs = elapsedMs(from: result.events[0].timestamp, to: result.events[1].timestamp)
        XCTAssertTrue((85...130).contains(holdMs), "expected action rhythmProfile clickHoldMs to drive key hold, got \(holdMs)ms")
    }
}

private func elapsedMs(from start: String, to end: String) -> Int {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let startDate = formatter.date(from: start), let endDate = formatter.date(from: end) else {
        return -1
    }
    return Int(endDate.timeIntervalSince(startDate) * 1000)
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

private final class RecordingHIDSink: HIDEventSink {
    private(set) var started: HIDActionVisualContext?
    private(set) var recorded: [InjectedEvent] = []

    func hidActionDidStart(_ context: HIDActionVisualContext) {
        started = context
    }

    func hidActionDidRecord(_ event: InjectedEvent, context: HIDActionVisualContext) {
        recorded.append(event)
    }
}
