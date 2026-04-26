import CoreGraphics
@testable import HIDVisualization
import InjectorCore
import XCTest

final class HIDOverlayTrackingTests: XCTestCase {
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
}
