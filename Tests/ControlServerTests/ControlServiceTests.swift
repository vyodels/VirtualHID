import Foundation
import AppKit
import XCTest
import ControlServer
import InjectorCore
import ProfileStore
import Supervisor

@objcMembers
final class ControlServiceTests: XCTestCase {
    func testActionAcceptsLandingZoneAndReturnsHidSelectedFinalPoint() {
        let service = try! makeService()
        let response = service.handleLine(
            #"{"id":"1","method":"action","params":{"context":{"host":"example.com","element":{"sig":"sig-fixed","role":"button"}},"options":{"dryRun":true},"primitives":[{"type":"click","at":{"x":120,"y":88},"button":"left","profile":{"landingZone":{"center":{"x":120,"y":88},"radius":10}}}]}}"#
        )
        let payload = try! decode(response)
        XCTAssertEqual(payload["ok"] as? Bool, true)
        let result = payload["result"] as? [String: Any]
        let events = result?["events"] as? [[String: Any]]
        let verification = result?["verification"] as? [String: Any]
        let finalLocation = events?.last?["location"] as? [String: Any]
        let finalX = finalLocation?["x"] as? Double
        let finalY = finalLocation?["y"] as? Double

        XCTAssertEqual(verification?["pointerWithinTolerance"] as? Bool, true)
        XCTAssertTrue(finalX != nil)
        XCTAssertTrue(finalY != nil)
        if let finalX, let finalY {
            XCTAssertTrue(hypot(finalX - 120, finalY - 88) <= 10)
        }
    }

    func testDryRunActionsDoNotSleepThroughRequestedHolds() {
        let service = try! makeService()
        let action = #"{"method":"action","params":{"context":{"host":"example.com","element":{"sig":"sig-fixed","role":"button"}},"options":{"dryRun":true},"primitives":[{"type":"key","keyCode":0,"holdMs":220}]}}"#
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "com.vyodels.virtualhid.control.tests", attributes: .concurrent)
        let startedAt = Date()

        for index in 0..<2 {
            group.enter()
            queue.async {
                let line = action.replacingOccurrences(of: #"{"method""#, with: #"{"id":"\#(index)","method""#)
                let response = service.handleLine(line)
                let payload = try! self.decode(response)
                XCTAssertEqual(payload["ok"] as? Bool, true)
                group.leave()
            }
        }

        group.wait()
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        XCTAssertTrue(elapsedMs < 220, "dry-run actions should not sleep through holdMs; elapsedMs=\(elapsedMs)")
    }

    func testDryRunEventsUseSyntheticTimelineForHoldAndInterClickDurations() throws {
        let service = try makeService()
        let response = service.handleLine(
            #"{"id":"timing","method":"action","params":{"context":{"host":"example.com","element":{"sig":"sig-timing","role":"button"}},"options":{"dryRun":true},"primitives":[{"type":"click","at":{"x":120,"y":88},"button":"left","holdMs":70,"count":2,"profile":{"origin":{"x":120,"y":88},"motion":{"clickHoldMs":{"min":70,"max":70},"interClickMs":{"min":140,"max":140},"settleMs":{"min":30,"max":30}}}}]}}"#
        )
        let payload = try decode(response)
        let result = payload["result"] as? [String: Any]
        let learning = result?["daemonLearning"] as? [String: Any]
        let fingerprint = learning?["replayFingerprint"] as? [String: Any]
        let segmentMs = fingerprint?["segmentMs"] as? [Double]
        let clickHoldMs = fingerprint?["clickHoldMs"] as? [Double]
        let interClickMs = fingerprint?["interClickMs"] as? [Double]

        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(clickHoldMs?.count, 2)
        for hold in clickHoldMs ?? [] {
            XCTAssertEqual(hold, 70, accuracy: 1)
        }
        // Replay inter-click is measured between click-up events; it therefore includes
        // the configured pause plus the next click hold.
        XCTAssertEqual(interClickMs?.count, 1)
        XCTAssertEqual(interClickMs?.first ?? 0, 210, accuracy: 1)
        XCTAssertTrue(segmentMs?.contains { abs($0 - 70) < 1 } == true)
        XCTAssertTrue(segmentMs?.contains { abs($0 - 140) < 1 } == true)
    }

    func testActionUsesVirtualHidViewportFrameInsteadOfCallerViewportOrigin() {
        let service = try! makeService()
        let response = service.handleLine(
            #"{"id":"geo","method":"action","params":{"target":{"bundleId":"com.example.Browser","tabId":17,"host":"example.com"},"geometry":{"coordSpace":"viewport","viewportInScreen":{"x":930,"y":-1324,"width":1000,"height":700},"pageScale":1,"scrollOffset":{"x":0,"y":0}},"context":{"host":"example.com","url":"https://example.com/jobs","element":{"sig":"sig-fixed","role":"button"}},"options":{"dryRun":true},"primitives":[{"type":"click","at":{"x":220,"y":160},"button":"left"}]}}"#
        )
        let payload = try! decode(response)
        XCTAssertEqual(payload["ok"] as? Bool, true)
        let result = payload["result"] as? [String: Any]
        let plan = result?["plan"] as? [String: Any]
        let mapping = result?["mapping"] as? [String: Any]
        let verification = result?["verification"] as? [String: Any]
        let events = result?["events"] as? [[String: Any]]
        let selfFrame = selfTargetVisibleFrame()

        XCTAssertEqual(plan?["geometryApplied"] as? Bool, true)
        XCTAssertEqual(mapping?["viewportSource"] as? String, "self-target-visible-screen")
        XCTAssertEqual(mapping?["ignoredCallerViewportInScreen"] as? Bool, true)
        XCTAssertTrue((plan?["steps"] as? [[String: Any]])?.count ?? 0 >= 2)
        XCTAssertEqual(verification?["pointerWithinTolerance"] as? Bool, true)
        XCTAssertEqual(((events?.last?["location"] as? [String: Any])?["x"] as? Double), selfFrame.origin.x + 220)
        XCTAssertEqual(((events?.last?["location"] as? [String: Any])?["y"] as? Double), selfFrame.origin.y + 160)
    }

    func testActionAcceptsViewportGeometryWithoutViewportInScreen() {
        let service = try! makeService()
        let response = service.handleLine(
            #"{"id":"viewport-no-origin","method":"action","params":{"target":{"bundleId":"com.example.Browser","host":"example.com"},"geometry":{"coordSpace":"viewport","pageScale":1},"context":{"host":"example.com","element":{"sig":"sig-fixed","role":"button"}},"options":{"dryRun":true},"primitives":[{"type":"click","at":{"x":220,"y":160},"button":"left"}]}}"#
        )
        let payload = try! decode(response)
        XCTAssertEqual(payload["ok"] as? Bool, true)
        let result = payload["result"] as? [String: Any]
        let mapping = result?["mapping"] as? [String: Any]
        let plan = result?["plan"] as? [String: Any]

        XCTAssertEqual(plan?["geometryApplied"] as? Bool, true)
        XCTAssertEqual(mapping?["viewportSource"] as? String, "self-target-visible-screen")
        XCTAssertEqual(mapping?["ignoredCallerViewportInScreen"] as? Bool, false)
    }

    func testActionRejectsViewportMappingWhenViewportUnresolved() {
        let app = NSRunningApplication.current
        let service = try! makeService(
            allowSelfTarget: false,
            targetResolverOverride: { _ in
                BrowserTarget(
                    app: app,
                    pid: app.processIdentifier,
                    bundleIdentifier: "com.google.Chrome",
                    windowTitle: "Jobs",
                    frame: CGRect(x: 10, y: 20, width: 1000, height: 800),
                    viewportFrame: nil,
                    viewportFrameSource: nil
                )
            }
        )
        let response = service.handleLine(
            #"{"id":"viewport-unresolved","method":"action","params":{"target":{"bundleId":"com.google.Chrome","host":"example.com"},"geometry":{"coordSpace":"viewport","viewportInScreen":{"x":930,"y":-1324,"width":1000,"height":700}},"context":{"host":"example.com","element":{"sig":"sig-fixed","role":"button"}},"options":{"dryRun":true},"primitives":[{"type":"click","at":{"x":220,"y":160},"button":"left"}]}}"#
        )
        let payload = try! decode(response)
        let error = payload["error"] as? [String: Any]

        XCTAssertEqual(payload["ok"] as? Bool, false)
        XCTAssertEqual(error?["code"] as? String, "E_VIEWPORT_UNRESOLVED")
    }

    func testActionRejectsViewportTargetThatRequiresResampleBeforeBlindClick() {
        let service = try! makeService()
        let response = service.handleLine(
            #"{"id":"needs-resample","method":"action","params":{"target":{"bundleId":"com.example.Browser","host":"example.com"},"geometry":{"coordSpace":"document","scrollOffset":{"x":0,"y":0},"viewportSize":{"x":0,"y":0,"width":400,"height":300}},"context":{"host":"example.com","element":{"sig":"sig-fixed","role":"button"}},"options":{"dryRun":true},"primitives":[{"type":"click","at":{"x":220,"y":920},"button":"left"}]}}"#
        )
        let payload = try! decode(response)
        let error = payload["error"] as? [String: Any]

        XCTAssertEqual(payload["ok"] as? Bool, false)
        XCTAssertEqual(error?["code"] as? String, "E_VIEWPORT_RESAMPLE_REQUIRED")
    }

    func testActionAcceptsScreenGeometryWithoutViewport() {
        let service = try! makeService()
        let response = service.handleLine(
            #"{"id":"screen-geo","method":"action","params":{"target":{"bundleId":"com.example.Browser","host":"example.com"},"geometry":{"coordSpace":"screen"},"context":{"host":"example.com","element":{"sig":"sig-fixed","role":"button"}},"options":{"dryRun":true},"primitives":[{"type":"click","at":{"x":220,"y":160},"button":"left"}]}}"#
        )
        let payload = try! decode(response)
        XCTAssertEqual(payload["ok"] as? Bool, true)
        let result = payload["result"] as? [String: Any]
        let plan = result?["plan"] as? [String: Any]
        let events = result?["events"] as? [[String: Any]]

        XCTAssertEqual(plan?["geometryApplied"] as? Bool, false)
        XCTAssertEqual(((events?.last?["location"] as? [String: Any])?["x"] as? Double), 220)
        XCTAssertEqual(((events?.last?["location"] as? [String: Any])?["y"] as? Double), 160)
    }

    func testActionPublishesHidVisualizationSummaryFromReturnedEvents() {
        let sink = RecordingHIDSink()
        let service = try! makeService(hidEventSink: sink)
        let response = service.handleLine(
            #"{"id":"viz","method":"action","params":{"context":{"host":"example.com","element":{"sig":"sig-fixed","role":"button"}},"options":{"dryRun":true},"primitives":[{"type":"click","at":{"x":120,"y":88},"button":"left"}]}}"#
        )
        let payload = try! decode(response)
        let result = payload["result"] as? [String: Any]
        let events = result?["events"] as? [[String: Any]]
        let verification = result?["verification"] as? [String: Any]

        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(sink.finished?.context.actionId, "viz")
        XCTAssertEqual(sink.finished?.events.count, events?.count)
        XCTAssertEqual(sink.finished?.verification.expectedPointer?.x, (verification?["expectedPointer"] as? [String: Any])?["x"] as? Double)
        XCTAssertEqual(sink.finished?.verification.finalPointer?.y, (verification?["finalPointer"] as? [String: Any])?["y"] as? Double)
    }

    func testActionVerificationDistinguishesObserverAndSemanticLayers() {
        let service = try! makeService()
        let response = service.handleLine(
            #"{"id":"layers","method":"action","params":{"context":{"host":"example.com","element":{"sig":"sig-fixed","role":"button"}},"semantic":{"verified":true,"source":"browser_snapshot"},"options":{"dryRun":true},"primitives":[{"type":"click","at":{"x":120,"y":88},"button":"left"}]}}"#
        )
        let payload = try! decode(response)
        let result = payload["result"] as? [String: Any]
        let verification = result?["verification"] as? [String: Any]
        let observer = verification?["observer"] as? [String: Any]
        let semantic = verification?["semantic"] as? [String: Any]
        let injection = verification?["injection"] as? [String: Any]

        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(injection?["status"] as? String, "emitted")
        XCTAssertEqual(observer?["status"] as? String, "dryRunNotObserved")
        XCTAssertEqual(semantic?["status"] as? String, "verified")
        XCTAssertEqual(semantic?["verified"] as? Bool, true)
        XCTAssertEqual(semantic?["source"] as? String, "browser_snapshot")
    }

    func testActionPersistsDaemonReplayFingerprint() throws {
        let store = try ProfileStore(path: ":memory:")
        let service = try makeService(profileStore: store)
        let response = service.handleLine(
            #"{"id":"learn-action","method":"action","params":{"context":{"host":"example.com","taskId":"task","stage":"stage","element":{"sig":"sig-fixed","role":"button"}},"options":{"dryRun":true},"primitives":[{"type":"click","at":{"x":120,"y":88},"button":"left"}]}}"#
        )
        let payload = try decode(response)
        let result = payload["result"] as? [String: Any]
        let learning = result?["daemonLearning"] as? [String: Any]

        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(learning?["committed"] as? Bool, true)
        XCTAssertEqual(learning?["instructionKey"] as? String, "task:stage:sig-fixed:click")
        XCTAssertEqual(try store.traceCount(host: "example.com"), 1)
        XCTAssertEqual(try store.listReplayFingerprints(host: "example.com", instructionKey: "task:stage:sig-fixed:click").count, 1)
    }

    func testProfilesApplyWritesTemplate() throws {
        let store = try ProfileStore(path: ":memory:")
        let service = try makeService(profileStore: store)
        let response = service.handleLine(
            #"{"id":"apply","method":"profiles.apply","params":{"host":"example.com","elementSig":"sig-apply","taskId":"task","actionType":"click","sampleSize":10,"confidence":0.66,"params":{"version":2,"strategy":"analysis-patch","actionType":"click","sampleSize":10,"motion":{"moveSpeedPxS":{"min":120,"max":240},"pointCount":{"min":8,"max":12}}}}}"#
        )
        let payload = try decode(response)
        let result = payload["result"] as? [String: Any]
        let template = result?["template"] as? [String: Any]

        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(template?["confidence"] as? Double, 0.66)
        XCTAssertEqual(try store.lookupTemplate(host: "example.com", sig: "sig-apply", taskId: "task", actionType: "click").sampleSize, 10)
    }

    func testTypeFallsBackToPasteTextForChinese() throws {
        let service = try makeService()
        let response = service.handleLine(
            #"{"id":"zh-type","method":"action","params":{"context":{"host":"example.com","element":{"sig":"sig-input","role":"textbox"}},"options":{"dryRun":true},"primitives":[{"type":"type","text":"你好"}]}}"#
        )
        let payload = try decode(response)
        let result = payload["result"] as? [String: Any]
        let events = result?["events"] as? [[String: Any]]

        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(events?.first?["type"] as? String, "pasteText")
        XCTAssertEqual(events?.contains { $0["type"] as? String == "keyDown" && $0["virtualKey"] as? Int == 9 }, true)
    }

    func testExplicitPasteTextPrimitiveDoesNotExposeTextInEvents() throws {
        let service = try makeService()
        let response = service.handleLine(
            #"{"id":"paste","method":"action","params":{"context":{"host":"example.com","element":{"sig":"sig-input","role":"textbox"}},"options":{"dryRun":true},"primitives":[{"type":"pasteText","text":"候选人","restoreClipboard":true}]}}"#
        )
        let payload = try decode(response)
        let result = payload["result"] as? [String: Any]
        let events = result?["events"] as? [[String: Any]]

        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(events?.first?["type"] as? String, "pasteText")
        XCTAssertEqual(events?.contains { ($0["key"] as? String) == "候选人" }, false)
    }

    func testControlServiceRetainsHidVisualizationSinkForDaemonLifetime() {
        let box = HIDSinkBox()
        let service = try! makeServiceWithEphemeralHIDSink(box: box)
        let response = service.handleLine(
            #"{"id":"retained-viz","method":"action","params":{"context":{"host":"example.com","element":{"sig":"sig-fixed","role":"button"}},"options":{"dryRun":true},"primitives":[{"type":"click","at":{"x":120,"y":88},"button":"left","profile":{"origin":{"x":120,"y":88}}}]}}"#
        )
        let payload = try! decode(response)

        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(box.finished?.context.actionId, "retained-viz")
        XCTAssertEqual(box.finished?.events.count, 2)
    }

    func testActionDerivesContextHostFromTargetHostForWebTargets() {
        let service = try! makeService()
        let response = service.handleLine(
            #"{"id":"target-host","method":"action","params":{"target":{"tabId":17,"host":"example.com"},"context":{"element":{"sig":"sig-fixed","role":"button"}},"options":{"dryRun":true},"primitives":[{"type":"click","at":{"x":120,"y":88},"button":"left"}]}}"#
        )
        let payload = try! decode(response)

        XCTAssertEqual(payload["ok"] as? Bool, true)
    }

    func testActionRejectsMismatchedContextAndTargetHost() {
        let service = try! makeService()
        let response = service.handleLine(
            #"{"id":"host-mismatch","method":"action","params":{"target":{"tabId":17,"host":"example.com"},"context":{"host":"other.example","element":{"sig":"sig-fixed","role":"button"}},"options":{"dryRun":true},"primitives":[{"type":"click","at":{"x":120,"y":88},"button":"left"}]}}"#
        )
        let payload = try! decode(response)
        let error = payload["error"] as? [String: Any]

        XCTAssertEqual(payload["ok"] as? Bool, false)
        XCTAssertEqual(error?["code"] as? String, "E_CONTEXT_MISMATCH")
    }

    func testActionCanForceBrowserChromeOverlayPreflightWithoutContaminatingEvents() {
        let service = try! makeServiceWithBrowserTargetOverride()
        let response = service.handleLine(
            #"{"id":"overlay-force","method":"action","params":{"target":{"bundleId":"com.google.Chrome","tabId":17,"host":"example.com"},"context":{"host":"example.com","element":{"sig":"sig-fixed","role":"button"}},"options":{"dryRun":true,"browserChromeOverlayPolicy":"force"},"primitives":[{"type":"click","at":{"x":120,"y":88},"button":"left"}]}}"#
        )
        let payload = try! decode(response)
        let result = payload["result"] as? [String: Any]
        let preflight = ((result?["preflight"] as? [String: Any])?["browserChromeOverlay"] as? [String: Any])
        let events = result?["events"] as? [[String: Any]]

        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(preflight?["policy"] as? String, "force")
        XCTAssertEqual(preflight?["status"] as? String, "dryRun")
        XCTAssertEqual(preflight?["attempted"] as? Bool, true)
        XCTAssertEqual(preflight?["method"] as? String, "escape")
        XCTAssertEqual(events?.contains { ($0["virtualKey"] as? Int) == 53 }, false)
    }

    func testActionCanDisableBrowserChromeOverlayPreflight() {
        let service = try! makeServiceWithBrowserTargetOverride()
        let response = service.handleLine(
            #"{"id":"overlay-off","method":"action","params":{"target":{"bundleId":"com.google.Chrome","tabId":17,"host":"example.com"},"context":{"host":"example.com","element":{"sig":"sig-fixed","role":"button"}},"options":{"dryRun":true,"browserChromeOverlayPolicy":"off"},"primitives":[{"type":"click","at":{"x":120,"y":88},"button":"left"}]}}"#
        )
        let payload = try! decode(response)
        let result = payload["result"] as? [String: Any]
        let preflight = ((result?["preflight"] as? [String: Any])?["browserChromeOverlay"] as? [String: Any])

        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(preflight?["policy"] as? String, "off")
        XCTAssertEqual(preflight?["status"] as? String, "off")
        XCTAssertEqual(preflight?["attempted"] as? Bool, false)
    }

    func testActionRejectsMissingPrimitivesBeforeContextErrors() {
        let service = try! makeService()
        let response = service.handleLine(
            #"{"id":"missing-primitives","method":"action","params":{"context":{"host":"example.com"}}}"#
        )
        let payload = try! decode(response)
        let error = payload["error"] as? [String: Any]

        XCTAssertEqual(payload["ok"] as? Bool, false)
        XCTAssertEqual(error?["code"] as? String, "E_PRIMITIVES_REQUIRED")
    }

    func testActionRejectsEmptyPrimitives() {
        let service = try! makeService()
        let response = service.handleLine(
            #"{"id":"empty-primitives","method":"action","params":{"context":{"host":"example.com"},"primitives":[]}}"#
        )
        let payload = try! decode(response)
        let error = payload["error"] as? [String: Any]

        XCTAssertEqual(payload["ok"] as? Bool, false)
        XCTAssertEqual(error?["code"] as? String, "E_PRIMITIVES_REQUIRED")
    }

    func testActionRejectsPrimitiveWithoutType() {
        let service = try! makeService()
        let response = service.handleLine(
            #"{"id":"bad-primitive","method":"action","params":{"context":{"host":"example.com"},"primitives":[{}]}}"#
        )
        let payload = try! decode(response)
        let error = payload["error"] as? [String: Any]

        XCTAssertEqual(payload["ok"] as? Bool, false)
        XCTAssertEqual(error?["code"] as? String, "E_PRIMITIVE_INVALID")
    }

    func testHUDStateReportsUnavailableWithoutVisualizationControl() {
        let service = try! makeService()
        let response = service.handleLine(#"{"id":"hud-state","method":"hud.state","params":{}}"#)
        let payload = try! decode(response)
        let result = payload["result"] as? [String: Any]

        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(result?["available"] as? Bool, false)
        XCTAssertEqual(result?["enabled"] as? Bool, false)
    }

    func testHUDConfigureUsesVisualizationControl() {
        let sink = ConfigurableHIDSink()
        let service = try! makeService(hidEventSink: sink)
        let response = service.handleLine(
            #"{"id":"hud-config","method":"hud.configure","params":{"enabled":true,"clearDelaySeconds":4.2,"settings":{"trail":false,"actualPoint":true,"persistent":false}}}"#
        )
        let payload = try! decode(response)
        let result = payload["result"] as? [String: Any]
        let settings = result?["settings"] as? [String: Any]

        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(result?["available"] as? Bool, true)
        XCTAssertEqual(result?["enabled"] as? Bool, true)
        XCTAssertEqual(settings?["trail"] as? Bool, false)
        XCTAssertEqual(settings?["actualPoint"] as? Bool, true)
        XCTAssertEqual(settings?["persistent"] as? Bool, false)
        XCTAssertEqual(settings?["clearDelaySeconds"] as? Double, 4.2)
    }

    private func makeService(
        allowSelfTarget: Bool = true,
        bundleIdentifiers: [String] = ["com.example.Browser"],
        profileStore: ProfileStore? = nil,
        hidEventSink: HIDEventSink? = nil,
        targetResolverOverride: ((TargetDescriptor?) throws -> BrowserTarget)? = nil
    ) throws -> ControlService {
        let store = try profileStore ?? ProfileStore(path: ":memory:")
        return ControlService(
            configuration: ControlServerConfiguration(
                bundleIdentifiers: bundleIdentifiers,
                allowSelfTarget: allowSelfTarget
            ),
            supervisor: SupervisorService(),
            profileStore: store,
            hidEventSink: hidEventSink,
            targetResolverOverride: targetResolverOverride
        )
    }

    private func decode(_ text: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
    }

    private func selfTargetVisibleFrame() -> CGRect {
        guard let screen = NSScreen.main else {
            return CGRect(x: 0, y: 0, width: 1440, height: 900)
        }
        let frame = screen.frame
        let visible = screen.visibleFrame
        let topInset = max(0, frame.maxY - visible.maxY)
        return CGRect(
            x: visible.minX,
            y: frame.minY + topInset,
            width: visible.width,
            height: visible.height
        )
    }

    private func makeServiceWithEphemeralHIDSink(box: HIDSinkBox) throws -> ControlService {
        let sink = BoxedHIDSink(box: box)
        return try makeService(hidEventSink: sink)
    }

    private func makeServiceWithBrowserTargetOverride() throws -> ControlService {
        let app = NSRunningApplication.current
        return try makeService(
            allowSelfTarget: false,
            targetResolverOverride: { descriptor in
                BrowserTarget(
                    app: app,
                    pid: app.processIdentifier,
                    bundleIdentifier: descriptor?.bundleId ?? "com.google.Chrome",
                    windowTitle: "Jobs",
                    browserWindowId: descriptor?.windowId,
                    tabId: descriptor?.tabId,
                    host: descriptor?.host,
                    url: "https://example.com/jobs",
                    frame: CGRect(x: 10, y: 20, width: 1000, height: 800),
                    viewportFrame: CGRect(x: 10, y: 80, width: 1000, height: 700),
                    viewportFrameSource: "test"
                )
            }
        )
    }
}

private final class RecordingHIDSink: HIDEventSink {
    private(set) var finished: HIDActionVisualSummary?

    func hidActionDidFinish(_ summary: HIDActionVisualSummary) {
        finished = summary
    }
}

private final class HIDSinkBox {
    var finished: HIDActionVisualSummary?
}

private final class BoxedHIDSink: HIDEventSink {
    private let box: HIDSinkBox

    init(box: HIDSinkBox) {
        self.box = box
    }

    func hidActionDidFinish(_ summary: HIDActionVisualSummary) {
        box.finished = summary
    }
}

private final class ConfigurableHIDSink: HIDEventSink, HIDVisualizationControl {
    private var enabled = false
    private var settings: [String: Any] = [
        "clearDelaySeconds": 2.4,
        "trail": true,
        "actualPoint": true,
        "persistent": true
    ]

    func hidVisualizationState() -> [String: Any] {
        [
            "available": true,
            "enabled": enabled,
            "lockedOff": false,
            "settings": settings
        ]
    }

    func hidVisualizationConfigure(_ params: [String: Any]) -> [String: Any] {
        if let enabled = params["enabled"] as? Bool {
            self.enabled = enabled
        }
        if let clearDelaySeconds = params["clearDelaySeconds"] as? Double {
            settings["clearDelaySeconds"] = clearDelaySeconds
        }
        if let incoming = params["settings"] as? [String: Any] {
            for (key, value) in incoming {
                settings[key] = value
            }
        }
        return hidVisualizationState()
    }
}
