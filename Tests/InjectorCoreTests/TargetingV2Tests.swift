import CoreGraphics
import Foundation
import AppKit
import XCTest
@testable import InjectorCore

@objcMembers
final class TargetingV2Tests: XCTestCase {
    func testTargetResolverPrefersExactTabAndHost() throws {
        let descriptor = TargetDescriptor(
            bundleId: "com.example.Browser",
            windowId: 42,
            tabId: 7,
            host: "example.com"
        )
        let candidates = [
            TargetCandidate(bundleId: "com.example.Browser", windowId: 42, tabId: 8, host: "example.com", frontmost: true),
            TargetCandidate(bundleId: "com.example.Browser", windowId: 42, tabId: 7, host: "example.com", frontmost: false)
        ]

        let resolution = try TargetResolverV2.resolve(descriptor: descriptor, candidates: candidates)

        XCTAssertEqual(resolution.candidate.tabId, 7)
        XCTAssertEqual(resolution.activationRequired, true)
        XCTAssertTrue(resolution.confidence > 0.9)
    }

    func testViewportMapperConvertsDocumentPointToScreenPoint() {
        let geometry = ViewportGeometry(
            coordSpace: .document,
            viewportInScreen: CodableRect(x: 100, y: 80, width: 1200, height: 800),
            pageScale: 2,
            scrollOffset: CodablePoint(x: 20, y: 300),
            viewportSize: CodableRect(x: 0, y: 0, width: 600, height: 400)
        )

        let mapped = ViewportMapper.map(
            point: CGPoint(x: 220, y: 380),
            coordinateSpace: .document,
            geometry: geometry
        )

        XCTAssertEqual(mapped.viewportPoint.x, 200)
        XCTAssertEqual(mapped.viewportPoint.y, 80)
        XCTAssertEqual(mapped.screenPoint.x, 500)
        XCTAssertEqual(mapped.screenPoint.y, 240)
        XCTAssertEqual(mapped.alreadyVisible, true)
    }

    func testViewportGeometryResolverUsesVirtualHidViewportFrameOverCallerScreenOrigin() {
        let app = NSRunningApplication.current
        let target = BrowserTarget(
            app: app,
            pid: app.processIdentifier,
            bundleIdentifier: "com.google.Chrome",
            windowTitle: nil,
            frame: CGRect(x: 10, y: 20, width: 1000, height: 800),
            viewportFrame: CGRect(x: 40, y: 90, width: 900, height: 650),
            viewportFrameSource: "AXWebArea"
        )
        let request = ViewportGeometryRequest(
            coordSpace: .viewport,
            callerViewportInScreen: CodableRect(x: 930, y: -1324, width: 1200, height: 800),
            pageScale: 1,
            viewportSize: CodableRect(x: 0, y: 0, width: 900, height: 650)
        )

        let resolution = try! ViewportGeometryResolver.resolve(request: request, target: target)
        let planned = ExecutionPlanner.plan(
            target: TargetDescriptor(bundleId: "com.google.Chrome", host: "example.com"),
            geometry: resolution.geometry,
            primitives: [.click(at: CGPoint(x: 220, y: 79), button: .left, holdMs: 40, count: 1, profile: nil)]
        )

        XCTAssertEqual(resolution.viewportSource, "AXWebArea")
        XCTAssertEqual(resolution.ignoredCallerViewportInScreen, true)
        XCTAssertEqual(resolution.geometry.viewportInScreen.x, 40)
        XCTAssertEqual(resolution.geometry.viewportInScreen.y, 90)
        if case .click(let at, _, _, _, _) = planned.primitives[0] {
            XCTAssertEqual(at.x, 260)
            XCTAssertEqual(at.y, 169)
        } else {
            XCTFail("expected mapped click")
        }
    }

    func testViewportMapperConvertsProfileOriginAndLandingZoneToScreenSpace() {
        let geometry = ViewportGeometry(
            coordSpace: .viewport,
            viewportInScreen: CodableRect(x: 100, y: 200, width: 1200, height: 800),
            pageScale: 2,
            viewportSize: CodableRect(x: 0, y: 0, width: 600, height: 400)
        )
        let primitive = ActionPrimitive.click(
            at: CGPoint(x: 20, y: 30),
            button: .left,
            holdMs: 40,
            count: 1,
            profile: PrimitiveProfile(
                origin: CGPoint(x: 5, y: 6),
                landingZone: LandingZone(center: CGPoint(x: 25, y: 35), width: 20, height: 10, radius: 8)
            )
        )

        let mapped = ViewportMapper.mapPrimitive(primitive, geometry: geometry).primitive

        if case .click(let at, _, _, _, let profile) = mapped {
            XCTAssertEqual(at.x, 140)
            XCTAssertEqual(at.y, 260)
            XCTAssertEqual(profile?.origin?.x, 110)
            XCTAssertEqual(profile?.origin?.y, 212)
            XCTAssertEqual(profile?.landingZone?.center?.x, 150)
            XCTAssertEqual(profile?.landingZone?.center?.y, 270)
            XCTAssertEqual(profile?.landingZone?.width, 40)
            XCTAssertEqual(profile?.landingZone?.height, 20)
            XCTAssertEqual(profile?.landingZone?.radius, 16)
        } else {
            XCTFail("expected mapped click")
        }
    }

    func testViewportGeometryResolverRejectsViewportMappingWithoutResolvedViewportFrame() {
        let app = NSRunningApplication.current
        let target = BrowserTarget(
            app: app,
            pid: app.processIdentifier,
            bundleIdentifier: "com.google.Chrome",
            windowTitle: "Jobs",
            frame: CGRect(x: 10, y: 20, width: 1000, height: 800),
            viewportFrame: nil,
            viewportFrameSource: nil
        )
        let request = ViewportGeometryRequest(
            coordSpace: .document,
            callerViewportInScreen: CodableRect(x: 930, y: -1324, width: 1200, height: 800),
            scrollOffset: CodablePoint(x: 0, y: 100)
        )

        XCTAssertThrowsError(try ViewportGeometryResolver.resolve(request: request, target: target)) { error in
            XCTAssertEqual(
                error as? ViewportGeometryResolverError,
                .unresolvedViewport(bundleIdentifier: "com.google.Chrome", windowTitle: "Jobs")
            )
        }
    }

    func testExecutionPlannerAddsActivationAndScrollBeforeClick() {
        let target = TargetDescriptor(bundleId: "com.example.Browser", tabId: 9, host: "example.com")
        let geometry = ViewportGeometry(
            coordSpace: .document,
            viewportInScreen: CodableRect(x: 10, y: 20, width: 400, height: 300),
            scrollOffset: CodablePoint(x: 0, y: 0),
            viewportSize: CodableRect(x: 0, y: 0, width: 400, height: 300)
        )

        let planned = ExecutionPlanner.plan(
            target: target,
            geometry: geometry,
            primitives: [
                .click(at: CGPoint(x: 120, y: 520), button: .left, holdMs: 40, count: 1, profile: nil)
            ]
        )

        XCTAssertEqual(planned.plan.geometryApplied, true)
        XCTAssertEqual(planned.plan.steps.count, 3)
        if case .activateTarget(let plannedTarget) = planned.plan.steps[0] {
            XCTAssertEqual(plannedTarget.tabId, 9)
        } else {
            XCTFail("expected activateTarget step")
        }
        if case .scroll(_, let dy) = planned.plan.steps[1] {
            XCTAssertTrue(dy > 0)
        } else {
            XCTFail("expected scroll step")
        }
    }

    func testOutcomeVerifierChecksFinalPointerTolerance() {
        let result = ActionResult(
            id: "verify",
            ok: true,
            error: nil,
            events: [
                InjectedEvent(type: "mouseMoved", location: CodablePoint(x: 10, y: 10), key: nil, virtualKey: nil, timestamp: "t"),
                InjectedEvent(type: "leftMouseUp", location: CodablePoint(x: 12, y: 11), key: nil, virtualKey: nil, timestamp: "t")
            ],
            elapsedMs: 20
        )

        let evidence = OutcomeVerifier.evidence(
            result: result,
            expectedFinalPoint: CGPoint(x: 12.5, y: 11.5),
            focusConfirmed: true,
            observerEcho: nil,
            tolerancePx: 2
        )

        XCTAssertEqual(evidence.injectedEvents, 2)
        XCTAssertEqual(evidence.pointerWithinTolerance, true)
        XCTAssertEqual(evidence.focusConfirmed, true)
    }
}
