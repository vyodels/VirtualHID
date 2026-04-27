import AppKit
import CoreGraphics
@testable import HIDVisualization
import InjectorCore
import XCTest

final class HIDOverlayTrackingTests: XCTestCase {
    func testTrailPointsIncludeFinalActualPointWithoutDuplicate() {
        let finalPoint = CodablePoint(x: 140, y: 160)
        let events = [
            injectedEvent(type: "mouseMoved", x: 20, y: 40, offsetMs: 0),
            injectedEvent(type: "mouseMoved", x: 80, y: 120, offsetMs: 12)
        ]

        let trail = hidOverlayTrailPoints(events: events, actual: finalPoint)

        XCTAssertEqual(trail.map(\.x), [20, 80, 140])
        XCTAssertEqual(trail.last, finalPoint)
        XCTAssertEqual(hidOverlayTrailPoints(events: events + [injectedEvent(type: "mouseMoved", x: 140, y: 160, offsetMs: 24)], actual: finalPoint).count, 3)
    }

    func testPersistentDryRunHistoryKeepsCompletedFrameAcrossReplayPrefixesUntilClear() {
        let context = visualContext(actionId: "management-center-click")
        let actual = CodablePoint(x: 120, y: 140)
        let events = [
            injectedEvent(type: "mouseMoved", x: 20, y: 40, offsetMs: 0),
            injectedEvent(type: "mouseMoved", x: 70, y: 90, offsetMs: 16),
            injectedEvent(type: "leftMouseDown", x: 110, y: 130, offsetMs: 32),
            injectedEvent(type: "leftMouseUp", x: 110, y: 130, offsetMs: 64)
        ]
        let view = HIDOverlayView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 240),
            screenFrame: NSRect(x: 0, y: 0, width: 320, height: 240),
            settings: HIDOverlaySettings(persistent: true)
        )

        view.render(frame(context: context, events: events, actual: actual))
        var snapshot = view.snapshotForTesting()
        XCTAssertEqual(snapshot.currentEventCount, events.count)
        XCTAssertEqual(snapshot.currentTrailPoints.last, actual)
        XCTAssertEqual(snapshot.historyEventCounts, [events.count])
        XCTAssertEqual(snapshot.historyTrailPoints.first?.last, actual)

        view.render(frame(context: context, events: Array(events.prefix(1)), actual: nil))
        snapshot = view.snapshotForTesting()
        XCTAssertEqual(snapshot.currentEventCount, 1)
        XCTAssertEqual(snapshot.historyEventCounts, [events.count])
        XCTAssertEqual(snapshot.historyTrailPoints.first?.last, actual)

        view.clearTransientState()
        snapshot = view.snapshotForTesting()
        XCTAssertEqual(snapshot.currentEventCount, events.count)
        XCTAssertEqual(snapshot.currentTrailPoints.last, actual)
        XCTAssertEqual(snapshot.historyEventCounts, [events.count])

        view.render(frame(context: context, events: events, actual: actual))
        snapshot = view.snapshotForTesting()
        XCTAssertEqual(snapshot.currentEventCount, events.count)
        XCTAssertEqual(snapshot.historyEventCounts, [events.count])

        view.clearAll()
        snapshot = view.snapshotForTesting()
        XCTAssertNil(snapshot.currentEventCount)
        XCTAssertTrue(snapshot.historyEventCounts.isEmpty)
        XCTAssertTrue(snapshot.historyTrailPoints.isEmpty)
    }

    func testPersistentLiveHistoryKeepsCompletedFrameAcrossTransientClearsAndPrefixes() {
        let context = visualContext(actionId: "live-management-center-click", dryRun: false)
        let actual = CodablePoint(x: 210, y: 170)
        let events = [
            injectedEvent(type: "mouseMoved", x: 30, y: 50, offsetMs: 0),
            injectedEvent(type: "mouseMoved", x: 120, y: 110, offsetMs: 18),
            injectedEvent(type: "leftMouseDown", x: 205, y: 165, offsetMs: 34),
            injectedEvent(type: "leftMouseUp", x: 205, y: 165, offsetMs: 70)
        ]
        let view = HIDOverlayView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 240),
            screenFrame: NSRect(x: 0, y: 0, width: 320, height: 240),
            settings: HIDOverlaySettings(persistent: true)
        )

        view.render(frame(context: context, events: events, actual: actual))
        var snapshot = view.snapshotForTesting()
        XCTAssertEqual(snapshot.currentEventCount, events.count)
        XCTAssertEqual(snapshot.currentTrailPoints.last, actual)
        XCTAssertEqual(snapshot.historyEventCounts, [events.count])
        XCTAssertEqual(snapshot.historyTrailPoints.first?.last, actual)

        view.clearTransientState()
        snapshot = view.snapshotForTesting()
        XCTAssertEqual(snapshot.currentEventCount, events.count)
        XCTAssertEqual(snapshot.currentTrailPoints.last, actual)
        XCTAssertEqual(snapshot.historyEventCounts, [events.count])

        view.render(frame(context: context, events: Array(events.prefix(1)), actual: nil))
        snapshot = view.snapshotForTesting()
        XCTAssertEqual(snapshot.currentEventCount, 1)
        XCTAssertEqual(snapshot.historyEventCounts, [events.count])
        XCTAssertEqual(snapshot.historyTrailPoints.first?.last, actual)
    }

    func testBestTrackedWindowMatchPrefersTitleMatch() {
        let target = trackedTarget(title: "Candidate Detail", frame: CGRect(x: 100, y: 80, width: 900, height: 700))
        let windows = [
            HIDWindowSnapshot(pid: 42, title: "Recruit Agent", frame: CGRect(x: 100, y: 80, width: 900, height: 700)),
            HIDWindowSnapshot(pid: 42, title: "Candidate Detail", frame: CGRect(x: 420, y: 120, width: 1000, height: 760))
        ]

        let match = bestTrackedWindowMatch(target: target, windows: windows)

        XCTAssertEqual(match?.title, "Candidate Detail")
        XCTAssertEqual(match?.frame, CGRect(x: 420, y: 120, width: 1000, height: 760))
    }

    func testBestTrackedWindowMatchClosesWhenTitledTargetDisappears() {
        let target = trackedTarget(title: "Candidate Detail", frame: CGRect(x: 100, y: 80, width: 900, height: 700))
        let windows = [
            HIDWindowSnapshot(pid: 42, title: "Recruit Agent", frame: CGRect(x: 900, y: 80, width: 900, height: 700))
        ]

        XCTAssertNil(bestTrackedWindowMatch(target: target, windows: windows))
    }

    func testBestTrackedWindowMatchAllowsNearbyMoveWhenTitleChanges() {
        let target = trackedTarget(title: "Candidate Detail", frame: CGRect(x: 100, y: 80, width: 900, height: 700))
        let moved = HIDWindowSnapshot(pid: 42, title: "New Page Title", frame: CGRect(x: 138, y: 96, width: 920, height: 710))

        let match = bestTrackedWindowMatch(target: target, windows: [moved])

        XCTAssertEqual(match, moved)
    }

    func testBestTrackedWindowMatchUsesNearestUntitledWindow() {
        let target = trackedTarget(title: nil, frame: CGRect(x: 100, y: 80, width: 900, height: 700))
        let near = HIDWindowSnapshot(pid: 42, title: nil, frame: CGRect(x: 130, y: 110, width: 900, height: 700))
        let far = HIDWindowSnapshot(pid: 42, title: nil, frame: CGRect(x: 1400, y: 900, width: 900, height: 700))

        let match = bestTrackedWindowMatch(target: target, windows: [far, near])

        XCTAssertEqual(match, near)
    }

    private func trackedTarget(title: String?, frame: CGRect) -> HIDTrackedTarget {
        HIDTrackedTarget(
            pid: 42,
            title: title,
            frame: frame,
            context: HIDActionVisualContext(
                actionId: "action-1",
                bundleIdentifier: "com.example.Target",
                pid: 42,
                windowTitle: title,
                windowFrame: CodableRect(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height),
                dryRun: false,
                postMode: "global",
                actionTypes: ["click"]
            )
        )
    }

    private func visualContext(actionId: String, dryRun: Bool = true) -> HIDActionVisualContext {
        HIDActionVisualContext(
            actionId: actionId,
            bundleIdentifier: "com.example.Target",
            pid: 42,
            windowTitle: "Demo",
            windowFrame: CodableRect(x: 0, y: 0, width: 320, height: 240),
            dryRun: dryRun,
            postMode: "global",
            actionTypes: ["click"]
        )
    }

    private func frame(context: HIDActionVisualContext, events: [InjectedEvent], actual: CodablePoint?) -> HIDOverlayFrame {
        HIDOverlayFrame(
            context: context,
            events: events,
            expected: actual,
            actual: actual,
            errorCode: nil,
            stepTitle: nil,
            stepDetail: nil
        )
    }

    private func injectedEvent(type: String, x: Double, y: Double, offsetMs: Int) -> InjectedEvent {
        InjectedEvent(
            type: type,
            location: CodablePoint(x: x, y: y),
            key: nil,
            virtualKey: nil,
            timestamp: "2026-04-27T00:00:00.\(String(format: "%03d", offsetMs))Z"
        )
    }
}
