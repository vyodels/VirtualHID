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

    func testBrowserChromeOverlayPreflightBlocksTargetAction() throws {
        let service = try makeService(
            browserChromeOverlayPreflightOverride: { _, _, _ in
                BrowserChromeOverlayPreflight(
                    status: "blocked",
                    overlayType: "chromePopup",
                    confidence: 0.91,
                    bounds: CodableRect(x: 100, y: 80, width: 160, height: 120),
                    overlapsTarget: true,
                    action: "blockTargetAction",
                    evidence: ["source=test"]
                )
            }
        )
        let response = service.handleLine(
            #"{"id":"overlay-block","method":"action","params":{"target":{"bundleId":"com.example.Browser","host":"example.com"},"context":{"host":"example.com","element":{"sig":"sig-fixed","role":"button"}},"options":{"dryRun":true},"primitives":[{"type":"click","at":{"x":120,"y":88},"button":"left"}]}}"#
        )
        let payload = try decode(response)
        let result = payload["result"] as? [String: Any]
        let preflight = (result?["preflight"] as? [String: Any])?["browserChromeOverlay"] as? [String: Any]
        let events = result?["events"] as? [[String: Any]]

        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(result?["ok"] as? Bool, false)
        XCTAssertEqual(result?["error"] as? String, "E_BROWSER_CHROME_OVERLAY_BLOCKED")
        XCTAssertEqual(events?.count, 0)
        XCTAssertEqual(preflight?["status"] as? String, "blocked")
        XCTAssertEqual(preflight?["overlayType"] as? String, "chromePopup")
        XCTAssertEqual(preflight?["overlapsTarget"] as? Bool, true)
    }

    func testActionRejectsUnsupportedBrowserChromeOverlayMode() throws {
        let service = try makeService()
        let response = service.handleLine(
            #"{"id":"overlay-mode","method":"action","params":{"target":{"bundleId":"com.example.Browser","host":"example.com"},"context":{"host":"example.com","element":{"sig":"sig-fixed","role":"button"}},"options":{"dryRun":true,"browserChromeOverlayPolicy":{"mode":"dismissSafe","dismissSafe":true}},"primitives":[{"type":"click","at":{"x":120,"y":88},"button":"left"}]}}"#
        )
        let payload = try decode(response)
        let error = payload["error"] as? [String: Any]

        XCTAssertEqual(payload["ok"] as? Bool, false)
        XCTAssertEqual(error?["code"] as? String, "E_PARAM_INVALID")
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

    func testProductionActionRejectsCallerSuppliedHumanizationKnobs() throws {
        let service = try makeService()
        let response = service.handleLine(
            #"{"id":"prod-humanization","method":"action","params":{"context":{"host":"example.com","element":{"sig":"sig-fixed","role":"button"}},"options":{"dryRun":false,"profile":{"pointCount":{"min":1,"max":1}}},"primitives":[{"type":"click","at":{"x":120,"y":88},"button":"left","profile":{"origin":{"x":120,"y":88},"motion":{"clickHoldMs":{"min":1,"max":1}}}}]}}"#
        )
        let payload = try decode(response)
        let error = payload["error"] as? [String: Any]

        XCTAssertEqual(payload["ok"] as? Bool, false)
        XCTAssertEqual(error?["code"] as? String, "E_HUMANIZATION_OWNERSHIP")
    }

    func testDryRunKeepsCallerHumanizationCompatibilityAndReturnsAudit() throws {
        let service = try makeService()
        let response = service.handleLine(
            #"{"id":"dry-humanization","method":"action","params":{"context":{"host":"example.com","element":{"sig":"sig-fixed","role":"button"}},"options":{"dryRun":true,"profile":{"clickHoldMs":{"min":80,"max":80}}},"primitives":[{"type":"click","at":{"x":120,"y":88},"button":"left","profile":{"origin":{"x":120,"y":88},"motion":{"clickHoldMs":{"min":80,"max":80}}}}]}}"#
        )
        let payload = try decode(response)
        let result = payload["result"] as? [String: Any]
        let audit = result?["humanizationAudit"] as? [String: Any]
        let timing = audit?["timingOwnership"] as? [String: Any]

        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(timing?["owner"] as? String, "VirtualHID")
        XCTAssertEqual(timing?["dryRunCompatibility"] as? Bool, true)
    }

    func testLearnedProfilePlaybackEmitsActionEventsToHidSink() throws {
        let store = try ProfileStore(path: ":memory:")
        let box = HIDSinkBox()
        let service = try makeService(profileStore: store, hidEventSink: BoxedHIDSink(box: box))
        _ = service.handleLine(
            #"{"id":"apply-learned","method":"profiles.apply","params":{"host":"example.com","elementSig":"sig-learned","taskId":"task","actionType":"click","sampleSize":9,"confidence":0.92,"params":{"version":2,"strategy":"profile","actionType":"click","sampleSize":9,"motion":{"flavor":"gentle","moveSpeedPxS":{"min":180,"max":320},"pointCount":{"min":18,"max":24},"wind":4.2,"jitter":0.22,"controlSpread":36,"detourProbability":0.18,"clickHoldMs":{"min":70,"max":128},"hesitationProbability":0.32,"hesitationMs":{"min":38,"max":118}}}}}"#
        )

        let response = service.handleLine(
            #"{"id":"learned-playback","method":"action","params":{"context":{"host":"example.com","taskId":"task","stage":"playback","element":{"sig":"sig-learned","role":"button"}},"options":{"dryRun":true,"postMode":"global"},"primitives":[{"type":"click","at":{"x":220,"y":150},"button":"left","profile":{"origin":{"x":28,"y":42}}}]}}"#
        )
        let payload = try decode(response)
        let result = payload["result"] as? [String: Any]
        let profiles = result?["profiles"] as? [String: Any]
        let events = result?["events"] as? [[String: Any]] ?? []
        let mouseMoves = events.filter { $0["type"] as? String == "mouseMoved" }

        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(profiles?["applied"] as? Bool, true)
        XCTAssertEqual((profiles?["templateIds"] as? [String])?.isEmpty, false)
        XCTAssertGreaterThanOrEqual(mouseMoves.count, 10)
        XCTAssertEqual(box.finished?.context.actionId, "learned-playback")
        XCTAssertEqual(box.finished?.events.count, events.count)
    }

    func testGlobalLearningProfileAppliesWhenElementSignatureIsMissing() throws {
        let store = try ProfileStore(path: ":memory:")
        let service = try makeService(profileStore: store)
        _ = service.handleLine(
            #"{"id":"apply-global","method":"profiles.apply","params":{"host":"__global__","elementSig":"","actionType":"click","sampleSize":12,"confidence":0.8,"params":{"version":2,"strategy":"profile","actionType":"click","sampleSize":12,"motion":{"pointCount":{"min":6,"max":6},"clickHoldMs":{"min":90,"max":90}}}}}"#
        )

        let payload = try decode(service.handleLine(
            #"{"id":"global-fallback","method":"action","params":{"context":{"host":"example.com","element":{"role":"button"}},"options":{"dryRun":true,"postMode":"global"},"primitives":[{"type":"click","at":{"x":220,"y":150},"button":"left","profile":{"origin":{"x":28,"y":42}}}]}}"#
        ))
        let result = payload["result"] as? [String: Any]
        let profiles = result?["profiles"] as? [String: Any]
        let audit = result?["humanizationAudit"] as? [String: Any]
        let profileAudit = audit?["profile"] as? [String: Any]

        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(profiles?["applied"] as? Bool, true)
        XCTAssertEqual(profiles?["fallbackType"] as? String, "global-learned-profile")
        XCTAssertEqual(profileAudit?["fallbackType"] as? String, "global-learned-profile")
    }

    func testLearnedProfileChangesMovementAndClickTimingAgainstDisabledProfiles() throws {
        let store = try ProfileStore(path: ":memory:")
        let service = try makeService(profileStore: store)
        let applyPayload = try decode(service.handleLine(
            #"{"id":"apply-effect","method":"profiles.apply","params":{"host":"example.com","elementSig":"sig-effect","taskId":"task","actionType":"click","sampleSize":12,"confidence":0.9,"params":{"version":2,"strategy":"profile","actionType":"click","sampleSize":12,"motion":{"flavor":"gentle","moveSpeedPxS":{"min":220,"max":280},"pointCount":{"min":6,"max":8},"wind":3.8,"jitter":0.18,"controlSpread":0.12,"detourProbability":0,"clickHoldMs":{"min":128,"max":136},"interClickMs":{"min":172,"max":188},"settleMs":{"min":38,"max":46}}}}}"#
        ))
        XCTAssertEqual(applyPayload["ok"] as? Bool, true)

        let learned = try decode(service.handleLine(
            #"{"id":"learned-effect","method":"action","params":{"context":{"host":"example.com","taskId":"task","stage":"effect","element":{"sig":"sig-effect","role":"button"}},"options":{"dryRun":true,"postMode":"global"},"primitives":[{"type":"click","at":{"x":240,"y":160},"button":"left","holdMs":40,"profile":{"origin":{"x":32,"y":48}}}]}}"#
        ))["result"] as? [String: Any]
        let baseline = try decode(service.handleLine(
            #"{"id":"baseline-effect","method":"action","params":{"context":{"host":"example.com","taskId":"task","stage":"effect","element":{"sig":"sig-effect","role":"button"}},"options":{"dryRun":true,"postMode":"global","disableProfiles":true},"primitives":[{"type":"click","at":{"x":240,"y":160},"button":"left","holdMs":40,"profile":{"origin":{"x":32,"y":48}}}]}}"#
        ))["result"] as? [String: Any]

        let learnedProfiles = learned?["profiles"] as? [String: Any]
        let baselineProfiles = baseline?["profiles"] as? [String: Any]
        let learnedEvents = learned?["events"] as? [[String: Any]] ?? []
        let baselineEvents = baseline?["events"] as? [[String: Any]] ?? []
        let learnedMoves = learnedEvents.filter { $0["type"] as? String == "mouseMoved" }
        let baselineMoves = baselineEvents.filter { $0["type"] as? String == "mouseMoved" }

        XCTAssertEqual(learnedProfiles?["applied"] as? Bool, true)
        XCTAssertEqual(baselineProfiles?["applied"] as? Bool, false)
        XCTAssertLessThanOrEqual(learnedMoves.count, 8)
        XCTAssertGreaterThanOrEqual(learnedMoves.count, 6)
        XCTAssertGreaterThan(baselineMoves.count, learnedMoves.count)
        XCTAssertGreaterThan((holdDurationMs(from: learnedEvents) ?? 0) - (holdDurationMs(from: baselineEvents) ?? 0), 70)
    }

    func testLearningStateIncludesTemplateSummaries() throws {
        let store = try ProfileStore(path: ":memory:")
        let service = try makeService(profileStore: store)
        let applyPayload = try decode(service.handleLine(
            #"{"id":"apply-summary","method":"profiles.apply","params":{"host":"__global__","elementSig":"","actionType":"click","sampleSize":12,"confidence":0.75,"params":{"version":2,"strategy":"profile","actionType":"click","sampleSize":12,"motion":{"pointCount":{"min":10,"max":14}}}}}"#
        ))
        XCTAssertEqual(applyPayload["ok"] as? Bool, true, String(describing: applyPayload))

        let payload = try decode(service.handleLine(#"{"id":"learning-state","method":"learning.state","params":{}}"#))
        let result = payload["result"] as? [String: Any]
        let templates = result?["templates"] as? [[String: Any]]

        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(result?["totalTemplates"] as? Int, 1)
        XCTAssertEqual(templates?.first?["host"] as? String, "__global__")
        XCTAssertEqual(templates?.first?["elementSig"] as? String, "")
        XCTAssertEqual(templates?.first?["actionType"] as? String, "click")
        XCTAssertEqual(templates?.first?["sampleSize"] as? Int, 12)
    }

    func testLearningDemoRunUsesRealLearnedTemplateAndReturnsActionEvidence() throws {
        let service = try makeService()
        try seedLearnedDemoProfiles(service: service, actions: ["click"])
        let response = service.handleLine(
            #"{"id":"learning-demo","method":"learning.demo.run","params":{"host":"example.com","elementSig":"sig-click-demo","taskId":"task-click-demo","actionType":"click","actionCount":2,"stepDelayMs":0}}"#
        )
        let payload = try decode(response)
        let result = payload["result"] as? [String: Any]
        let baseline = result?["baseline"] as? [String: Any]
        let actions = result?["actions"] as? [[String: Any]] ?? []
        let template = result?["template"] as? [String: Any]
        let safety = result?["safety"] as? [String: Any]
        let firstActionHumanization = actions.first?["humanization"] as? [String: Any]
        let firstActionMetrics = actions.first?["metrics"] as? [String: Any]
        let firstActionSteps = actions.first?["steps"] as? [[String: Any]] ?? []
        let firstActionTrajectory = actions.first?["trajectory"] as? [String: Any]
        let firstActionPrimitive = actions.first?["primitive"] as? [String: Any]
        let firstActionEventChain = actions.first?["eventChain"] as? [[String: Any]] ?? []
        let learningEffect = result?["learningEffect"] as? [String: Any]
        let activeFields = learningEffect?["activeFields"] as? [String]

        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(result?["ok"] as? Bool, true)
        XCTAssertEqual(result?["source"] as? String, "virtualhid-action-events")
        XCTAssertEqual(result?["mode"] as? String, "safe-dry-run-preview")
        XCTAssertEqual(safety?["dryRun"] as? Bool, true)
        XCTAssertEqual(safety?["realClickPosted"] as? Bool, false)
        XCTAssertEqual(result?["seededDemoTemplate"] as? Bool, false)
        XCTAssertEqual(template?["host"] as? String, "__global__")
        XCTAssertEqual(template?["elementSig"] as? String, "")
        XCTAssertEqual(baseline?["profileApplied"] as? Bool, false)
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(actions.allSatisfy { $0["profileApplied"] as? Bool == true }, true)
        XCTAssertEqual(actions.allSatisfy { ($0["mouseMoveCount"] as? Int ?? 0) > 0 }, true)
        XCTAssertEqual(actions.allSatisfy { ($0["mouseDownCount"] as? Int ?? 0) > 0 }, true)
        XCTAssertEqual(actions.allSatisfy { ($0["mouseUpCount"] as? Int ?? 0) > 0 }, true)
        XCTAssertEqual(firstActionHumanization?["profileApplied"] as? Bool, true)
        XCTAssertGreaterThan(firstActionMetrics?["pointCount"] as? Int ?? 0, 0)
        XCTAssertGreaterThan(firstActionMetrics?["pathLengthPx"] as? Double ?? 0, 0)
        XCTAssertEqual(firstActionPrimitive?["type"] as? String, "click")
        XCTAssertNotNil(firstActionPrimitive?["startPoint"])
        XCTAssertNotNil(firstActionPrimitive?["targetPoint"])
        XCTAssertGreaterThan(firstActionTrajectory?["pointCount"] as? Int ?? 0, 0)
        XCTAssertGreaterThan(firstActionEventChain.count, 0)
        XCTAssertTrue(firstActionSteps.contains { $0["phase"] as? String == "prepareMove" })
        XCTAssertTrue(firstActionSteps.contains { $0["phase"] as? String == "move" })
        XCTAssertTrue(firstActionSteps.contains { $0["phase"] as? String == "mouseDown" })
        XCTAssertTrue(firstActionSteps.contains { $0["phase"] as? String == "hold" })
        XCTAssertTrue(firstActionSteps.contains { $0["phase"] as? String == "mouseUp" })
        XCTAssertTrue(firstActionSteps.contains { $0["phase"] as? String == "verifyLanding" })
        XCTAssertTrue(activeFields?.contains("pointCount") == true)
        XCTAssertTrue(activeFields?.contains("clickHoldMs") == true)
    }

    func testLearningDemoStepRequiresRealLearnedTemplate() throws {
        let service = try makeService()
        let response = service.handleLine(
            #"{"id":"demo-step-missing","method":"learning.demo.step","params":{"action":"click"}}"#
        )
        let payload = try decode(response)
        let error = payload["error"] as? [String: Any]

        XCTAssertEqual(payload["ok"] as? Bool, false)
        XCTAssertEqual(error?["code"] as? String, "E_PROFILE_MISS")
    }

    func testLearningDemoStepIsManualRepeatableAndActionScoped() throws {
        let service = try makeService()
        try seedLearnedDemoProfiles(service: service)
        for action in ["move", "click", "dblclick", "drag", "scroll", "keyboard"] {
            let response = service.handleLine(
                #"{"id":"demo-step-\#(action)","method":"learning.demo.step","params":{"action":"\#(action)"}}"#
            )
            let payload = try decode(response)
            let result = payload["result"] as? [String: Any]
            let manual = result?["manualControl"] as? [String: Any]
            let safety = result?["safety"] as? [String: Any]
            let actions = result?["actions"] as? [[String: Any]] ?? []
            let firstAction = actions.first
            let steps = firstAction?["steps"] as? [[String: Any]] ?? []

            XCTAssertEqual(payload["ok"] as? Bool, true)
            XCTAssertEqual(result?["ok"] as? Bool, true)
            XCTAssertEqual(result?["mode"] as? String, "manual-safe-dry-run-preview")
            XCTAssertEqual(result?["demoAction"] as? String, action)
            XCTAssertEqual(result?["seededDemoTemplate"] as? Bool, false)
            XCTAssertEqual(manual?["maxActiveDemo"] as? Int, 1)
            XCTAssertEqual(manual?["autoAdvance"] as? Bool, false)
            XCTAssertEqual(manual?["repeatable"] as? Bool, true)
            XCTAssertEqual(safety?["dryRun"] as? Bool, true)
            XCTAssertEqual(safety?["realClickPosted"] as? Bool, false)
            XCTAssertEqual(actions.count, 1)
            XCTAssertEqual(firstAction?["demoAction"] as? String, action)
            XCTAssertTrue(steps.contains { $0["phase"] as? String == "prepareMove" } || action == "scroll")
        }

        let stopPayload = try decode(service.handleLine(#"{"id":"demo-stop","method":"learning.demo.stop","params":{}}"#))
        XCTAssertEqual(stopPayload["ok"] as? Bool, true)
    }

    func testLearningDemoStepClickFocusIsClickSpecificAndReturnsFullEventChainEvidence() throws {
        let service = try makeService()
        try seedLearnedDemoProfiles(service: service, actions: ["click"])

        let payload = try decode(service.handleLine(
            #"{"id":"demo-step-click-chain","method":"learning.demo.step","params":{"action":"click"}}"#
        ))
        let result = payload["result"] as? [String: Any]
        let action = result?["action"] as? [String: Any]
        let focus = action?["currentFocus"] as? [String: Any]
        let steps = action?["steps"] as? [[String: Any]] ?? []
        let moveStep = steps.first { $0["phase"] as? String == "move" }
        let evidence = action?["eventChainEvidence"] as? [String: Any]
        let chain = evidence?["chain"] as? [[String: Any]] ?? []
        let eventTypes = evidence?["eventTypes"] as? [String] ?? []

        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(result?["demoAction"] as? String, "click")
        XCTAssertEqual(action?["demoAction"] as? String, "click")
        XCTAssertEqual(focus?["action"] as? String, "click")
        XCTAssertTrue((focus?["title"] as? String ?? "").contains("点击"))
        XCTAssertFalse((focus?["title"] as? String ?? "").contains("滑动轨迹"))
        XCTAssertEqual(moveStep?["role"] as? String, "targetingPrelude")
        XCTAssertFalse((moveStep?["title"] as? String ?? "").contains("滑动轨迹"))
        XCTAssertFalse(steps.contains { step in
            ((step["title"] as? String) ?? "").contains("滑动轨迹")
                || ((step["detail"] as? String) ?? "").contains("滑动轨迹")
        })
        XCTAssertEqual(evidence?["complete"] as? Bool, true)
        XCTAssertEqual(evidence?["eventCount"] as? Int, action?["eventCount"] as? Int)
        XCTAssertEqual(chain.count, action?["eventCount"] as? Int)
        XCTAssertTrue(eventTypes.contains("mouseMoved"))
        XCTAssertTrue(eventTypes.contains { $0.contains("MouseDown") })
        XCTAssertTrue(eventTypes.contains { $0.contains("MouseUp") })
        XCTAssertTrue(steps.contains { $0["phase"] as? String == "mouseDown" })
        XCTAssertTrue(steps.contains { $0["phase"] as? String == "hold" })
        XCTAssertTrue(steps.contains { $0["phase"] as? String == "mouseUp" })
    }

    func testLearningDemoStepRandomizesPointsUnlessReuseRequested() throws {
        let service = try makeService()
        try seedLearnedDemoProfiles(service: service, actions: ["click"])

        let firstPayload = try decode(service.handleLine(
            #"{"id":"demo-step-random-a","method":"learning.demo.step","params":{"action":"click"}}"#
        ))
        let secondPayload = try decode(service.handleLine(
            #"{"id":"demo-step-random-b","method":"learning.demo.step","params":{"action":"click"}}"#
        ))
        let reusePayload = try decode(service.handleLine(
            #"{"id":"demo-step-reuse","method":"learning.demo.step","params":{"action":"click","reuseLastPoints":true}}"#
        ))

        let firstRequested = learningDemoRequested(firstPayload)
        let secondRequested = learningDemoRequested(secondPayload)
        let reuseRequested = learningDemoRequested(reusePayload)

        XCTAssertEqual(firstPayload["ok"] as? Bool, true)
        XCTAssertEqual(secondPayload["ok"] as? Bool, true)
        XCTAssertEqual(reusePayload["ok"] as? Bool, true)
        XCTAssertEqual(firstRequested?["pointMode"] as? String, "random")
        XCTAssertEqual(secondRequested?["pointMode"] as? String, "random")
        XCTAssertEqual(reuseRequested?["pointMode"] as? String, "reused-last")
        XCTAssertNotEqual(pointSignature(firstRequested?["startPoint"]), pointSignature(secondRequested?["startPoint"]))
        XCTAssertNotEqual(pointSignature(firstRequested?["targetPoint"]), pointSignature(secondRequested?["targetPoint"]))
        XCTAssertEqual(pointSignature(secondRequested?["startPoint"]), pointSignature(reuseRequested?["startPoint"]))
        XCTAssertEqual(pointSignature(secondRequested?["targetPoint"]), pointSignature(reuseRequested?["targetPoint"]))
    }

    func testLearningInspectReturnsObservableLearningData() throws {
        let service = try makeService()
        try seedLearnedDemoProfiles(service: service, actions: ["click"])

        let payload = try decode(service.handleLine(#"{"id":"learning-inspect","method":"learning.inspect","params":{"limit":4}}"#))
        let result = payload["result"] as? [String: Any]
        let capture = result?["eventCapture"] as? [String: Any]
        let recentTraces = result?["recentTraces"] as? [[String: Any]]
        let templates = result?["templates"] as? [[String: Any]]
        let definitions = result?["definitions"] as? [String: Any]

        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertNotNil(capture?["eventTapRunning"])
        XCTAssertGreaterThan(recentTraces?.count ?? 0, 0)
        XCTAssertGreaterThan(templates?.count ?? 0, 0)
        XCTAssertNotNil(definitions?["scope"])
    }

    func testLearningTeachingStartStopAliasesSessionWithTeachingSemantics() throws {
        let service = try makeService()

        let startPayload = try decode(service.handleLine(
            #"{"id":"teaching-start","method":"learning.teaching.start","params":{"label":"现场教学：完整点击","host":"teaching.local","targetAction":"click"}}"#
        ))
        let startResult = startPayload["result"] as? [String: Any]
        let activeSession = startResult?["activeSession"] as? [String: Any]
        let settings = startResult?["settings"] as? [String: Any]

        XCTAssertEqual(startPayload["ok"] as? Bool, true)
        XCTAssertEqual(settings?["enabled"] as? Bool, true)
        XCTAssertEqual(activeSession?["label"] as? String, "现场教学：完整点击")
        XCTAssertEqual(activeSession?["host"] as? String, "teaching.local")
        XCTAssertEqual(activeSession?["targetAction"] as? String, "click")

        let stopPayload = try decode(service.handleLine(#"{"id":"teaching-stop","method":"learning.teaching.stop","params":{"commit":true}}"#))
        let stopResult = stopPayload["result"] as? [String: Any]

        XCTAssertEqual(stopPayload["ok"] as? Bool, true)
        XCTAssertEqual(stopResult?["discardedSamples"] as? Int, 0)
    }

    func testLearningTeachingNextGeneratesGuideAndUpdatesTargetAction() throws {
        let service = try makeService()

        _ = try decode(service.handleLine(
            #"{"id":"teaching-start","method":"learning.teaching.start","params":{"label":"现场教学","host":"__global__","targetAction":"move"}}"#
        ))
        let payload = try decode(service.handleLine(
            #"{"id":"teaching-next","method":"learning.teaching.next","params":{"action":"drag"}}"#
        ))
        let result = payload["result"] as? [String: Any]
        let guide = result?["guide"] as? [String: Any]
        let teaching = result?["teaching"] as? [String: Any]
        let state = result?["state"] as? [String: Any]
        let activeSession = state?["activeSession"] as? [String: Any]

        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(guide?["action"] as? String, "drag")
        XCTAssertNotNil(guide?["startPoint"])
        XCTAssertNotNil(guide?["targetPoint"])
        XCTAssertEqual(teaching?["title"] as? String, "拖拽")
        XCTAssertEqual(activeSession?["targetAction"] as? String, "drag")
    }

    func testLearningTeachingNextCyclesActionsAndKeepsGuideInsideProvidedBounds() throws {
        let service = try makeService()
        let rect = CGRect(x: 120, y: 140, width: 520, height: 360)
        let boundsJSON = #"{"x":120,"y":140,"width":520,"height":360}"#
        let expectedActions = ["move", "click", "drag", "scroll", "dblclick", "keyboard", "move"]

        _ = try decode(service.handleLine(
            #"{"id":"teaching-start","method":"learning.teaching.start","params":{"label":"现场教学","host":"__global__"}}"#
        ))

        for (index, expectedAction) in expectedActions.enumerated() {
            let payload = try decode(service.handleLine(
                #"{"id":"teaching-next-\#(index)","method":"learning.teaching.next","params":{"teachingBounds":\#(boundsJSON)}}"#
            ))
            let result = payload["result"] as? [String: Any]
            let guide = result?["guide"] as? [String: Any]
            let bounds = guide?["bounds"] as? [String: Any]
            let operationArea = guide?["operationArea"] as? [String: Any]

            XCTAssertEqual(payload["ok"] as? Bool, true)
            XCTAssertEqual(guide?["action"] as? String, expectedAction)
            assertPoint(guide?["startPoint"], inside: rect)
            assertPoint(guide?["targetPoint"], inside: rect)
            assertRect(operationArea, inside: rect)
            XCTAssertNotNil(guide?["startLabel"])
            XCTAssertNotNil(guide?["targetLabel"])
            XCTAssertNotNil(guide?["operationLabel"])
            XCTAssertNotNil(guide?["completionHint"])
            XCTAssertEqual(bounds?["x"] as? Double, rect.minX)
            XCTAssertEqual(bounds?["y"] as? Double, rect.minY)
            XCTAssertEqual(bounds?["width"] as? Double, rect.width)
            XCTAssertEqual(bounds?["height"] as? Double, rect.height)
        }
    }

    func testLearningInspectOnlyShowsGlobalAbilityTemplates() throws {
        let service = try makeService()
        try seedTemplateInventory(service: service, count: 13)
        let visibleClickPayload = try decode(service.handleLine(try profilesApplyLine(
            id: "apply-visible-click",
            host: "__global__",
            elementSig: "",
            taskId: nil,
            actionType: "click",
            sampleSize: 18
        )))
        XCTAssertEqual(visibleClickPayload["ok"] as? Bool, true, String(describing: visibleClickPayload))
        let visibleMovePayload = try decode(service.handleLine(try profilesApplyLine(
            id: "apply-visible-move",
            host: "__global__",
            elementSig: "",
            taskId: nil,
            actionType: "move",
            sampleSize: 21
        )))
        XCTAssertEqual(visibleMovePayload["ok"] as? Bool, true, String(describing: visibleMovePayload))
        let hiddenGlobalTaskPayload = try decode(service.handleLine(try profilesApplyLine(
            id: "apply-hidden-global-task",
            host: "__global__",
            elementSig: "",
            taskId: "management-learning-demo",
            actionType: "drag",
            sampleSize: 30
        )))
        XCTAssertEqual(hiddenGlobalTaskPayload["ok"] as? Bool, true, String(describing: hiddenGlobalTaskPayload))

        let inspectPayload = try decode(service.handleLine(#"{"id":"learning-inspect-all","method":"learning.inspect","params":{}}"#))
        let inspectResult = inspectPayload["result"] as? [String: Any]
        let inspectTemplates = inspectResult?["templates"] as? [[String: Any]] ?? []
        let statePayload = try decode(service.handleLine(#"{"id":"learning-state-all","method":"learning.state","params":{}}"#))
        let stateResult = statePayload["result"] as? [String: Any]
        let stateTemplates = stateResult?["templates"] as? [[String: Any]] ?? []

        XCTAssertEqual(inspectPayload["ok"] as? Bool, true)
        XCTAssertEqual(inspectResult?["totalTemplates"] as? Int, 2)
        XCTAssertEqual(inspectResult?["returnedTemplates"] as? Int, 2)
        XCTAssertEqual(Set(inspectTemplates.compactMap { $0["host"] as? String }), Set(["__global__"]))
        XCTAssertEqual(Set(inspectTemplates.compactMap { $0["elementSig"] as? String }), Set([""]))
        XCTAssertEqual(Set(inspectTemplates.compactMap { $0["taskId"] as? String }), Set<String>())
        XCTAssertEqual(Set(inspectTemplates.compactMap { $0["actionType"] as? String }), Set(["click", "move"]))
        XCTAssertEqual(statePayload["ok"] as? Bool, true)
        XCTAssertEqual(stateResult?["totalTemplates"] as? Int, 2)
        XCTAssertEqual(stateTemplates.count, 2)
    }

    func testTraceCommitPayloadPreservesRawHIDFieldsForRebuild() throws {
        let store = try ProfileStore(path: ":memory:")
        let service = try makeService(profileStore: store)

        for index in 0..<5 {
            let scroll = try traceCommitLine(
                id: "scroll-\(index)",
                host: "example.com",
                sig: "sig-scroll",
                task: "task-scroll",
                traceType: "scroll",
                payload: [
                    "type": "scrollWheel",
                    "point": ["x": 100, "y": 120],
                    "scrollDeltas": [
                        ["dx": 0, "dy": -120 - index],
                        ["dx": 0, "dy": -72 - index]
                    ],
                    "scrollIntervalsMs": [42 + index],
                    "modifierFlags": [1 << 17],
                    "eventTimeline": ["scrollWheel", "scrollWheel"]
                ]
            )
            let click = try traceCommitLine(
                id: "click-\(index)",
                host: "example.com",
                sig: "sig-click",
                task: "task-click",
                traceType: "click",
                payload: [
                    "type": "leftMouseUp",
                    "point": ["x": 130, "y": 150],
                    "clickHoldMs": [54 + index],
                    "doubleClickIntervalMs": [180 + index],
                    "eventTimeline": ["leftMouseDown", "leftMouseUp", "leftMouseDown", "leftMouseUp"]
                ]
            )
            let type = try traceCommitLine(
                id: "type-\(index)",
                host: "example.com",
                sig: "sig-type",
                task: "task-type",
                traceType: "type",
                payload: [
                    "type": "keyUp",
                    "keyCode": 12,
                    "dwellMs": [70 + index],
                    "interKeyMs": [96 + index],
                    "modifierFlags": [1 << 17],
                    "flagsChangedKeyCodes": [56],
                    "comboKeyCodes": [56, 12],
                    "repeatCount": 1,
                    "eventTimeline": ["flagsChanged", "keyDown", "keyUp"]
                ]
            )

            XCTAssertEqual(try decode(service.handleLine(scroll))["ok"] as? Bool, true)
            XCTAssertEqual(try decode(service.handleLine(click))["ok"] as? Bool, true)
            XCTAssertEqual(try decode(service.handleLine(type))["ok"] as? Bool, true)
        }

        XCTAssertEqual(try decode(service.handleLine(#"{"id":"rebuild","method":"profiles.rebuild","params":{"host":"example.com"}}"#))["ok"] as? Bool, true)

        let scrollRaw = try rawHIDObject(service: service, host: "example.com", sig: "sig-scroll", task: "task-scroll", action: "scroll")
        XCTAssertNotNil(scrollRaw["scrollDeltaY"])
        XCTAssertNotNil(scrollRaw["scrollIntervalsMs"])
        XCTAssertEqual(scrollRaw["modifierFlags"] as? [Int], [1 << 17])

        let clickRaw = try rawHIDObject(service: service, host: "example.com", sig: "sig-click", task: "task-click", action: "click")
        XCTAssertNotNil(clickRaw["doubleClickIntervalMs"])
        XCTAssertTrue((clickRaw["eventTimeline"] as? [String] ?? []).contains("leftMouseDown"))

        let typeRaw = try rawHIDObject(service: service, host: "example.com", sig: "sig-type", task: "task-type", action: "type")
        XCTAssertEqual(typeRaw["modifierFlags"] as? [Int], [1 << 17])
        XCTAssertEqual(typeRaw["flagsChangedKeyCodes"] as? [Int], [56])
        XCTAssertEqual(typeRaw["comboKeyCodes"] as? [[Int]], [[12, 56]])
    }

    func testTypeChineseDoesNotDefaultToWholeTextPaste() throws {
        let service = try makeService()
        let response = service.handleLine(
            #"{"id":"zh-type","method":"action","params":{"context":{"host":"example.com","element":{"sig":"sig-input","role":"textbox"}},"options":{"dryRun":true},"primitives":[{"type":"type","text":"你好"}]}}"#
        )
        let payload = try decode(response)
        let result = payload["result"] as? [String: Any]
        let events = result?["events"] as? [[String: Any]]
        let input = result?["input"] as? [String: Any]
        let diagnostics = input?["fallbackDiagnostics"] as? [[String: Any]]

        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(result?["ok"] as? Bool, false)
        XCTAssertEqual(result?["error"] as? String, "E_INPUT_FALLBACK_REQUIRED")
        XCTAssertEqual(events?.contains { $0["type"] as? String == "pasteText" }, false)
        XCTAssertEqual(diagnostics?.first?["path"] as? String, "chineseImeCharByChar")
        XCTAssertEqual(diagnostics?.first?["fallback"] as? String, "pasteText")
        XCTAssertTrue(diagnostics?.first?["fallbackReason"] != nil)
    }

    func testLongTypeTextIsChunkedWithoutPasteFallback() throws {
        let service = try makeService()
        let text = String(repeating: "abc123 ", count: 14)
        let response = service.handleLine(
            #"{"id":"long-type","method":"action","params":{"context":{"host":"example.com","element":{"sig":"sig-input","role":"textbox"}},"options":{"dryRun":true},"primitives":[{"type":"type","text":"\#(text)"}]}}"#
        )
        let payload = try decode(response)
        let result = payload["result"] as? [String: Any]
        let events = result?["events"] as? [[String: Any]]
        let input = result?["input"] as? [String: Any]
        let diagnostics = input?["fallbackDiagnostics"] as? [[String: Any]]

        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(result?["ok"] as? Bool, true)
        XCTAssertEqual(events?.contains { $0["type"] as? String == "pasteText" }, false)
        XCTAssertEqual(diagnostics?.first?["path"] as? String, "chunkedKeyboardCharByChar")
        XCTAssertTrue((diagnostics?.first?["chunks"] as? Int ?? 0) > 1)
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
        targetResolverOverride: ((TargetDescriptor?) throws -> BrowserTarget)? = nil,
        browserChromeOverlayPreflightOverride: ((BrowserTarget, [ActionPrimitive], BrowserChromeOverlayPolicy) -> BrowserChromeOverlayPreflight)? = nil
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
            targetResolverOverride: targetResolverOverride,
            browserChromeOverlayPreflightOverride: browserChromeOverlayPreflightOverride
        )
    }

    private func decode(_ text: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
    }

    private func learningDemoRequested(_ payload: [String: Any]) -> [String: Any]? {
        let result = payload["result"] as? [String: Any]
        let action = result?["action"] as? [String: Any]
        return action?["requested"] as? [String: Any]
    }

    private func pointSignature(_ value: Any?) -> String? {
        guard let point = value as? [String: Any],
              let x = point["x"] as? Double,
              let y = point["y"] as? Double
        else {
            return nil
        }
        return "\(Int(x.rounded())):\(Int(y.rounded()))"
    }

    private func assertPoint(_ value: Any?, inside rect: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        guard let point = value as? [String: Any],
              let x = point["x"] as? Double,
              let y = point["y"] as? Double
        else {
            XCTFail("missing point", file: file, line: line)
            return
        }
        XCTAssertGreaterThanOrEqual(x, rect.minX, file: file, line: line)
        XCTAssertLessThanOrEqual(x, rect.maxX, file: file, line: line)
        XCTAssertGreaterThanOrEqual(y, rect.minY, file: file, line: line)
        XCTAssertLessThanOrEqual(y, rect.maxY, file: file, line: line)
    }

    private func assertRect(_ value: Any?, inside rect: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        guard let object = value as? [String: Any],
              let x = object["x"] as? Double,
              let y = object["y"] as? Double,
              let width = object["width"] as? Double,
              let height = object["height"] as? Double
        else {
            XCTFail("missing rect", file: file, line: line)
            return
        }
        XCTAssertGreaterThanOrEqual(x, rect.minX, file: file, line: line)
        XCTAssertGreaterThanOrEqual(y, rect.minY, file: file, line: line)
        XCTAssertLessThanOrEqual(x + width, rect.maxX, file: file, line: line)
        XCTAssertLessThanOrEqual(y + height, rect.maxY, file: file, line: line)
        XCTAssertGreaterThan(width, 0, file: file, line: line)
        XCTAssertGreaterThan(height, 0, file: file, line: line)
    }

    private func seedLearnedDemoProfiles(
        service: ControlService,
        actions: Set<String> = ["move", "click", "drag", "scroll", "type"]
    ) throws {
        for index in 0..<25 {
            let start = ["x": 40 + index * 3, "y": 60 + index * 2]
            let mid = ["x": 132 + index * 4, "y": 104 + index * 5]
            let end = ["x": 260 + index * 5, "y": 166 + index * 3]
            let path = [start, mid, end]

            if actions.contains("move") {
                let line = try traceCommitLine(
                    id: "demo-move-\(index)",
                    host: "example.com",
                    sig: "sig-move-demo",
                    task: "task-move-demo",
                    traceType: "move",
                    payload: [
                        "type": "mouseMoved",
                        "point": end,
                        "points": path,
                        "origin": start,
                        "targetPoint": end,
                        "durationMs": 360 + index * 18,
                        "segmentMs": [120 + index, 128 + index],
                        "straightness": 0.78,
                        "turnJitter": 0.24
                    ]
                )
                XCTAssertEqual(try decode(service.handleLine(line))["ok"] as? Bool, true)
            }

            if actions.contains("click") {
                let line = try traceCommitLine(
                    id: "demo-click-\(index)",
                    host: "example.com",
                    sig: "sig-click-demo",
                    task: "task-click-demo",
                    traceType: "click",
                    payload: [
                        "type": "leftMouseUp",
                        "point": end,
                        "points": path,
                        "origin": start,
                        "targetPoint": end,
                        "durationMs": 420 + index * 16,
                        "segmentMs": [108 + index, 142 + index, 86 + index],
                        "clickHoldMs": [74 + index * 3],
                        "interClickMs": [158 + index * 4],
                        "doubleClickIntervalMs": [174 + index * 5],
                        "eventTimeline": ["leftMouseDown", "leftMouseUp", "leftMouseDown", "leftMouseUp"],
                        "straightness": 0.74,
                        "turnJitter": 0.28
                    ]
                )
                XCTAssertEqual(try decode(service.handleLine(line))["ok"] as? Bool, true)
            }

            if actions.contains("drag") {
                let line = try traceCommitLine(
                    id: "demo-drag-\(index)",
                    host: "example.com",
                    sig: "sig-drag-demo",
                    task: "task-drag-demo",
                    traceType: "drag",
                    payload: [
                        "type": "leftMouseDragged",
                        "point": end,
                        "points": path,
                        "origin": start,
                        "targetPoint": end,
                        "durationMs": 560 + index * 20,
                        "segmentMs": [146 + index, 172 + index, 152 + index],
                        "clickHoldMs": [112 + index * 4],
                        "eventTimeline": ["leftMouseDown", "leftMouseDragged", "leftMouseUp"],
                        "straightness": 0.70,
                        "turnJitter": 0.32
                    ]
                )
                XCTAssertEqual(try decode(service.handleLine(line))["ok"] as? Bool, true)
            }

            if actions.contains("scroll") {
                let line = try traceCommitLine(
                    id: "demo-scroll-\(index)",
                    host: "example.com",
                    sig: "sig-scroll-demo",
                    task: "task-scroll-demo",
                    traceType: "scroll",
                    payload: [
                        "type": "scrollWheel",
                        "point": start,
                        "durationMs": 230 + index * 15,
                        "scrollDeltas": [
                            ["dx": 0, "dy": -132 - index * 6],
                            ["dx": 0, "dy": -82 - index * 4],
                            ["dx": 0, "dy": -38 - index * 2]
                        ],
                        "scrollIntervalsMs": [34 + index, 48 + index],
                        "eventTimeline": ["scrollWheel", "scrollWheel", "scrollWheel"]
                    ]
                )
                XCTAssertEqual(try decode(service.handleLine(line))["ok"] as? Bool, true)
            }

            if actions.contains("type") {
                let line = try traceCommitLine(
                    id: "demo-type-\(index)",
                    host: "example.com",
                    sig: "sig-type-demo",
                    task: "task-type-demo",
                    traceType: "type",
                    payload: [
                        "type": "keyUp",
                        "keyCode": 9,
                        "durationMs": 320 + index * 12,
                        "dwellMs": [64 + index * 3],
                        "interKeyMs": [102 + index * 4],
                        "modifierFlags": [1 << 17],
                        "flagsChangedKeyCodes": [56],
                        "comboKeyCodes": [56, 9],
                        "repeatCount": 1,
                        "eventTimeline": ["flagsChanged", "keyDown", "keyUp"]
                    ]
                )
                XCTAssertEqual(try decode(service.handleLine(line))["ok"] as? Bool, true)
            }
        }

        let payload = try decode(service.handleLine(#"{"id":"rebuild-demo","method":"profiles.rebuild","params":{"host":"example.com"}}"#))
        XCTAssertEqual(payload["ok"] as? Bool, true)
        try publishSeededTemplatesAsGlobal(service: service, sourceHost: "example.com", actions: actions)
    }

    private func publishSeededTemplatesAsGlobal(
        service: ControlService,
        sourceHost: String,
        actions: Set<String>
    ) throws {
        let listPayload = try decode(service.handleLine(#"{"id":"list-seeded","method":"profiles.list","params":{"host":"\#(sourceHost)"}}"#))
        let result = listPayload["result"] as? [String: Any]
        let templates = result?["templates"] as? [[String: Any]] ?? []
        for template in templates {
            guard let actionType = template["actionType"] as? String,
                  actions.contains(actionType),
                  let params = template["params"] as? [String: Any]
            else {
                continue
            }
            let line = try profilesApplyLine(
                id: "apply-global-\(actionType)",
                host: "__global__",
                elementSig: "",
                taskId: nil,
                actionType: actionType,
                sampleSize: template["sampleSize"] as? Int ?? 25,
                confidence: template["confidence"] as? Double ?? 0.8,
                params: params
            )
            let payload = try decode(service.handleLine(line))
            XCTAssertEqual(payload["ok"] as? Bool, true, String(describing: payload))
        }
    }

    private func seedTemplateInventory(service: ControlService, count: Int) throws {
        for templateIndex in 0..<count {
            for sampleIndex in 0..<5 {
                let x = 80 + templateIndex * 6 + sampleIndex
                let y = 120 + templateIndex * 4 + sampleIndex
                let start = ["x": x, "y": y]
                let mid = ["x": x + 60, "y": y + 24]
                let end = ["x": x + 118, "y": y + 42]
                let line = try traceCommitLine(
                    id: "inventory-\(templateIndex)-\(sampleIndex)",
                    host: "example.com",
                    sig: "sig-inventory-\(templateIndex)",
                    task: "task-inventory-\(templateIndex)",
                    traceType: "click",
                    payload: [
                        "type": "leftMouseUp",
                        "point": end,
                        "points": [start, mid, end],
                        "origin": start,
                        "targetPoint": end,
                        "durationMs": 380 + sampleIndex * 12,
                        "segmentMs": [96 + sampleIndex, 118 + sampleIndex],
                        "clickHoldMs": [62 + sampleIndex],
                        "eventTimeline": ["leftMouseDown", "leftMouseUp"]
                    ]
                )
                XCTAssertEqual(try decode(service.handleLine(line))["ok"] as? Bool, true)
            }
        }

        let payload = try decode(service.handleLine(#"{"id":"rebuild-inventory","method":"profiles.rebuild","params":{"host":"example.com"}}"#))
        XCTAssertEqual(payload["ok"] as? Bool, true)
    }

    private func profilesApplyLine(
        id: String,
        host: String,
        elementSig: String,
        taskId: String?,
        actionType: String,
        sampleSize: Int,
        confidence: Double = 0.85,
        params: [String: Any]? = nil
    ) throws -> String {
        var applyParams: [String: Any] = [
            "host": host,
            "elementSig": elementSig,
            "actionType": actionType,
            "sampleSize": sampleSize,
            "confidence": confidence,
            "params": params ?? [
                "version": 2,
                "strategy": "profile",
                "actionType": actionType,
                "sampleSize": sampleSize,
                "motion": [
                    "pointCount": ["min": 8, "max": 16],
                    "speedPxS": ["min": 180, "max": 760]
                ]
            ]
        ]
        if let taskId {
            applyParams["taskId"] = taskId
        }
        let object: [String: Any] = [
            "id": id,
            "method": "profiles.apply",
            "params": applyParams
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func traceCommitLine(
        id: String,
        host: String,
        sig: String,
        task: String,
        traceType: String,
        payload: [String: Any]
    ) throws -> String {
        let object: [String: Any] = [
            "id": id,
            "method": "trace.commit",
            "params": [
                "eventId": id,
                "host": host,
                "elementSig": sig,
                "taskId": task,
                "traceType": traceType,
                "payload": payload
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func rawHIDObject(service: ControlService, host: String, sig: String, task: String, action: String) throws -> [String: Any] {
        let response = service.handleLine(
            #"{"id":"get","method":"profiles.get","params":{"host":"\#(host)","sig":"\#(sig)","taskId":"\#(task)","actionType":"\#(action)"}}"#
        )
        let payload = try decode(response)
        let result = payload["result"] as? [String: Any]
        let template = result?["template"] as? [String: Any]
        let params = template?["params"] as? [String: Any]
        return params?["rawHID"] as? [String: Any] ?? [:]
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

private func holdDurationMs(from events: [[String: Any]]) -> Double? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let down = events.first(where: { ($0["type"] as? String)?.contains("MouseDown") == true }),
          let up = events.first(where: { ($0["type"] as? String)?.contains("MouseUp") == true }),
          let downTimestamp = down["timestamp"] as? String,
          let upTimestamp = up["timestamp"] as? String,
          let downDate = formatter.date(from: downTimestamp),
          let upDate = formatter.date(from: upTimestamp) else {
        return nil
    }
    return upDate.timeIntervalSince(downDate) * 1000
}
