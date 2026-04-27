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

    func testLearnedPathSkeletonAndSegmentsAffectDryRunMoveShapeAndTiming() throws {
        let executor = ActionExecutor(target: testTarget())
        let profile = MotionProfile(
            pointCount: IntRange(min: 5, max: 5),
            hesitationProbability: 0,
            pathSkeleton: [
                LearnedPathPoint(x: 0, y: 0),
                LearnedPathPoint(x: 50, y: 80),
                LearnedPathPoint(x: 100, y: 0)
            ],
            segmentMs: [
                IntRange(min: 20, max: 20),
                IntRange(min: 180, max: 180),
                IntRange(min: 20, max: 20),
                IntRange(min: 180, max: 180)
            ]
        )

        let result = try executor.execute(
            ActionRequest(
                id: "learned-path",
                primitives: [
                    .move(
                        to: CGPoint(x: 220, y: 20),
                        via: .profile(TemplateReference(id: "learned-path", motionProfile: profile)),
                        durationMs: 520,
                        profile: PrimitiveProfile(origin: CGPoint(x: 20, y: 20))
                    )
                ],
                context: ActionContext(host: "example.com", element: .init(sig: "sig-move", role: "button")),
                options: ActionOptions(postMode: .global, dryRun: true)
            )
        )

        let points = result.events.compactMap { $0.location }
        let yValues = points.map { $0.y }
        let deltas = timestampDeltas(result.events)

        XCTAssertEqual(result.events.count, 5)
        XCTAssertEqual(points.first?.x, 20)
        XCTAssertEqual(points.last?.x, 220)
        XCTAssertGreaterThan(yValues.max() ?? 0, 70)
        XCTAssertGreaterThan(deltas.max() ?? 0, 100)
        XCTAssertLessThan(deltas.min() ?? 0, 100)
    }

    func testLearnedDoubleClickProfileControlsDryRunDownUpIntervals() throws {
        let executor = ActionExecutor(target: testTarget())
        let profile = MotionProfile(
            clickHoldMs: IntRange(min: 30, max: 30),
            doubleClickHoldMs: IntRange(min: 64, max: 64),
            doubleClickInterClickMs: IntRange(min: 310, max: 310),
            doubleClickSecondOffsetPx: DoubleRange(min: 2, max: 4)
        )

        let result = try executor.execute(
            ActionRequest(
                id: "learned-dblclick",
                primitives: [
                    .click(
                        at: CGPoint(x: 180, y: 140),
                        button: .left,
                        holdMs: 30,
                        count: 2,
                        profile: PrimitiveProfile(origin: CGPoint(x: 180, y: 140), motionProfile: profile)
                    )
                ],
                context: ActionContext(host: "example.com", element: .init(sig: "sig-click", role: "button")),
                options: ActionOptions(postMode: .global, dryRun: true)
            )
        )

        XCTAssertEqual(result.events.map(\.type), ["leftMouseDown", "leftMouseUp", "leftMouseDown", "leftMouseUp"])
        let deltas = timestampDeltas(result.events)
        XCTAssertEqual(deltas[0], 64, accuracy: 1)
        XCTAssertEqual(deltas[1], 310, accuracy: 1)
        XCTAssertEqual(deltas[2], 64, accuracy: 1)
        let firstClick = result.events[0].location
        let secondClick = result.events[2].location
        XCTAssertNotEqual(firstClick, secondClick)
    }

    func testLearnedKeyboardRangesAffectTypeDryRunTiming() throws {
        let executor = ActionExecutor(target: testTarget())
        let profile = MotionProfile(
            dwellMs: IntRange(min: 210, max: 210),
            interKeyMs: IntRange(min: 260, max: 320)
        )

        let result = try executor.execute(
            ActionRequest(
                id: "learned-type",
                primitives: [
                    .type(
                        text: "ab",
                        layout: .us,
                        profile: PrimitiveProfile(motionProfile: profile)
                    )
                ],
                context: ActionContext(host: "example.com", element: .init(sig: "sig-type", role: "textbox")),
                options: ActionOptions(postMode: .global, dryRun: true)
            )
        )

        XCTAssertEqual(result.events.map(\.type), ["keyDown", "keyUp", "keyDown", "keyUp"])
        let deltas = timestampDeltas(result.events)
        XCTAssertEqual(deltas[0], 210, accuracy: 1)
        XCTAssertGreaterThan(deltas[1], 180)
        XCTAssertEqual(deltas[2], 210, accuracy: 1)
    }

    func testLearnedScrollProfileControlsDryRunBurstTiming() throws {
        let executor = ActionExecutor(target: testTarget())
        let profile = MotionProfile(
            scrollDeltaY: DoubleRange(min: 90, max: 90),
            scrollStepCount: IntRange(min: 4, max: 4),
            scrollStepDelayMs: IntRange(min: 75, max: 75),
            scrollInertiaDecay: DoubleRange(min: 0.6, max: 0.6)
        )

        let result = try executor.execute(
            ActionRequest(
                id: "learned-scroll",
                primitives: [
                    .scroll(
                        at: CGPoint(x: 100, y: 120),
                        dx: 0,
                        dy: -120,
                        style: .wheel,
                        profile: PrimitiveProfile(motionProfile: profile)
                    )
                ],
                context: ActionContext(host: "example.com", element: .init(sig: "sig-scroll", role: "list")),
                options: ActionOptions(postMode: .global, dryRun: true)
            )
        )

        XCTAssertEqual(result.events.map(\.type), ["scrollWheel", "scrollWheel", "scrollWheel", "scrollWheel"])
        for delta in timestampDeltas(result.events) {
            XCTAssertEqual(delta, 75, accuracy: 1)
        }
    }
}

private func testTarget() -> BrowserTarget {
    let app = NSRunningApplication.current
    return BrowserTarget(
        app: app,
        pid: app.processIdentifier,
        bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.vyodels.virtualhid.tests",
        windowTitle: nil,
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900)
    )
}

private func timestampDeltas(_ events: [InjectedEvent]) -> [Double] {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let dates = events.compactMap { formatter.date(from: $0.timestamp) }
    return zip(dates.dropFirst(), dates).map { next, previous in
        next.timeIntervalSince(previous) * 1000
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
