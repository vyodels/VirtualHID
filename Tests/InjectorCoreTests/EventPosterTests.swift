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

    func testDryRunClickReplansFromCursorInterferenceBeforeMouseDown() throws {
        let targetPoint = CGPoint(x: 180, y: 140)
        let grabbedPoint = CGPoint(x: 24, y: 360)
        var cursorReads: [CGPoint?] = [targetPoint, grabbedPoint]
        let executor = ActionExecutor(
            target: testTarget(),
            cursorLocationProvider: {
                cursorReads.isEmpty ? nil : cursorReads.removeFirst()
            }
        )

        let result = try executor.execute(
            ActionRequest(
                id: "click-user-interference",
                primitives: [
                    .click(
                        at: targetPoint,
                        button: .left,
                        holdMs: 40,
                        count: 1,
                        profile: nil
                    )
                ],
                context: ActionContext(host: "example.com", element: .init(sig: "sig-click", role: "button")),
                options: ActionOptions(postMode: .global, dryRun: true)
            )
        )

        let eventTypes = result.events.map(\.type)
        let mouseDownIndex = try XCTUnwrap(eventTypes.firstIndex(of: "leftMouseDown"))
        let preDownMoves = result.events.prefix(mouseDownIndex).filter { $0.type == "mouseMoved" }

        XCTAssertGreaterThan(preDownMoves.count, 3)
        assertPoint(preDownMoves.first?.location, equals: grabbedPoint)
        assertPoint(preDownMoves.last?.location, equals: targetPoint)
    }

    func testDryRunMoveReplansWhenCursorIsGrabbedDuringTrajectory() throws {
        let start = CGPoint(x: 20, y: 80)
        let targetPoint = CGPoint(x: 320, y: 160)
        let grabbedPoint = CGPoint(x: 36, y: 420)
        var cursorReads: [CGPoint?] = [grabbedPoint]
        let executor = ActionExecutor(
            target: testTarget(),
            cursorLocationProvider: {
                cursorReads.isEmpty ? nil : cursorReads.removeFirst()
            }
        )

        let result = try executor.execute(
            ActionRequest(
                id: "move-user-interference",
                primitives: [
                    .move(
                        to: targetPoint,
                        via: .wind,
                        durationMs: nil,
                        profile: PrimitiveProfile(origin: start)
                    )
                ],
                context: ActionContext(host: "example.com", element: .init(sig: "sig-move", role: "button")),
                options: ActionOptions(postMode: .global, dryRun: true)
            )
        )

        let points = result.events.compactMap(\.location)

        XCTAssertGreaterThan(points.count, 4)
        assertPoint(points.first, equals: start)
        XCTAssertTrue(points.contains { point in
            hypot(point.x - grabbedPoint.x, point.y - grabbedPoint.y) <= 0.5
        })
        assertPoint(points.last, equals: targetPoint)
    }

    func testDryRunMoveFailsWhenCursorIsContinuouslyGrabbedAway() throws {
        let grabbedPoint = CGPoint(x: 36, y: 420)
        let executor = ActionExecutor(
            target: testTarget(),
            cursorLocationProvider: { grabbedPoint }
        )

        XCTAssertThrowsError(try executor.execute(
            ActionRequest(
                id: "move-continuous-user-interference",
                primitives: [
                    .move(
                        to: CGPoint(x: 320, y: 160),
                        via: .wind,
                        durationMs: nil,
                        profile: PrimitiveProfile(origin: CGPoint(x: 20, y: 80))
                    )
                ],
                context: ActionContext(host: "example.com", element: .init(sig: "sig-move", role: "button")),
                options: ActionOptions(postMode: .global, dryRun: true)
            )
        )) { error in
            guard case ActionExecutionError.cursorInterference = error else {
                return XCTFail("expected cursorInterference, got \(error)")
            }
        }
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

    func testLearnedPathSkeletonAndSegmentsProduceDenseSmoothNonUniformDryRunMove() throws {
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

        XCTAssertGreaterThanOrEqual(result.events.count, 18)
        XCTAssertEqual(points.first?.x, 20)
        XCTAssertEqual(points.last?.x, 220)
        XCTAssertGreaterThan(yValues.max() ?? 0, 70)
        XCTAssertLessThan(maxTurnRadians(points), 1.25)
        let maxDelta = deltas.max() ?? 0
        let minDelta = deltas.min() ?? 0
        XCTAssertGreaterThan(maxDelta, 20)
        XCTAssertGreaterThan(maxDelta, minDelta * 1.5)
    }

    func testLearnedPathSkeletonConstrainsShapeWithoutDeterministicReplay() throws {
        let profile = MotionProfile(
            pointCount: IntRange(min: 24, max: 24),
            hesitationProbability: 0,
            pathSkeleton: [
                LearnedPathPoint(x: 0, y: 0),
                LearnedPathPoint(x: 45, y: 72),
                LearnedPathPoint(x: 100, y: 0)
            ]
        )
        let primitive = ActionPrimitive.move(
            to: CGPoint(x: 260, y: 40),
            via: .profile(TemplateReference(id: "shape", motionProfile: profile)),
            durationMs: 520,
            profile: PrimitiveProfile(origin: CGPoint(x: 30, y: 40))
        )
        let first = try ActionExecutor(target: testTarget()).execute(
            ActionRequest(
                id: "shape-a",
                primitives: [primitive],
                context: ActionContext(host: "example.com", element: .init(sig: "sig-move", role: "button")),
                options: ActionOptions(postMode: .global, dryRun: true)
            )
        )
        let second = try ActionExecutor(target: testTarget()).execute(
            ActionRequest(
                id: "shape-b",
                primitives: [primitive],
                context: ActionContext(host: "example.com", element: .init(sig: "sig-move", role: "button")),
                options: ActionOptions(postMode: .global, dryRun: true)
            )
        )

        let firstPoints = first.events.compactMap { $0.location }
        let secondPoints = second.events.compactMap { $0.location }

        XCTAssertEqual(firstPoints.count, secondPoints.count)
        XCTAssertGreaterThan(firstPoints.map(\.y).max() ?? 0, 95)
        XCTAssertGreaterThan(secondPoints.map(\.y).max() ?? 0, 95)
        XCTAssertNotEqual(firstPoints, secondPoints)
        XCTAssertLessThan(averagePointDistance(firstPoints, secondPoints), 10)
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

    func testLearnedClickPreludeUsesProfileDurationInsteadOfTimeoutHeuristic() throws {
        let executor = ActionExecutor(target: testTarget())
        let profile = MotionProfile(
            moveSpeedPxS: DoubleRange(min: 90, max: 90),
            pointCount: IntRange(min: 8, max: 8),
            hesitationProbability: 0,
            settleMs: IntRange(min: 0, max: 0),
            clickHoldMs: IntRange(min: 40, max: 40)
        )

        let result = try executor.execute(
            ActionRequest(
                id: "learned-click-prelude-duration",
                primitives: [
                    .click(
                        at: CGPoint(x: 420, y: 100),
                        button: .left,
                        holdMs: 40,
                        count: 1,
                        profile: PrimitiveProfile(
                            origin: CGPoint(x: 20, y: 100),
                            motionProfile: profile
                        )
                    )
                ],
                context: ActionContext(host: "example.com", element: .init(sig: "sig-click", role: "button")),
                options: ActionOptions(postMode: .global, timeoutMs: 8_000, dryRun: true)
            )
        )

        let eventTypes = result.events.map(\.type)
        let mouseDownIndex = try XCTUnwrap(eventTypes.firstIndex(of: "leftMouseDown"))
        let preludeDeltas = Array(timestampDeltas(result.events).prefix(mouseDownIndex))

        XCTAssertGreaterThanOrEqual(result.events.prefix(mouseDownIndex).filter { $0.type == "mouseMoved" }.count, 8)
        XCTAssertGreaterThan(preludeDeltas.reduce(0, +), 1_000)
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

    func testKeyPrimitiveAcceptsActionLevelRhythmProfile() {
        let executor = ActionExecutor(target: testTarget())

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

private func assertPoint(_ point: CodablePoint?, equals expected: CGPoint, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(point?.x ?? .nan, expected.x, accuracy: 0.5, file: file, line: line)
    XCTAssertEqual(point?.y ?? .nan, expected.y, accuracy: 0.5, file: file, line: line)
}

private func maxTurnRadians(_ points: [CodablePoint]) -> Double {
    guard points.count > 2 else {
        return 0
    }
    return (1..<(points.count - 1)).map { index in
        let previous = points[index - 1]
        let current = points[index]
        let next = points[index + 1]
        let a1 = atan2(current.y - previous.y, current.x - previous.x)
        let a2 = atan2(next.y - current.y, next.x - current.x)
        var delta = abs(a2 - a1)
        while delta > Double.pi {
            delta = abs(delta - Double.pi * 2)
        }
        return delta
    }.max() ?? 0
}

private func averagePointDistance(_ left: [CodablePoint], _ right: [CodablePoint]) -> Double {
    let pairs = zip(left, right)
    var total = 0.0
    var count = 0
    for pair in pairs {
        total += hypot(pair.0.x - pair.1.x, pair.0.y - pair.1.y)
        count += 1
    }
    return count == 0 ? 0 : total / Double(count)
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
