import CoreGraphics
import Foundation
import Supervisor
import XCTest

final class KillSwitchTests: XCTestCase {
    func testSelfMarkedEscDoesNotTrigger() {
        let killSwitch = KillSwitch()

        for _ in 0..<100 {
            killSwitch.feedKeyEvent(type: .keyDown, keyCode: 0x35, sourceUserData: 0x56484944)
        }

        XCTAssertEqual(killSwitch.isActive, false)
    }

    func testFiveEscTriggersAndUnlockClears() {
        let killSwitch = KillSwitch()

        for index in 0..<5 {
            killSwitch.feedKeyEvent(
                type: .keyDown,
                keyCode: 0x35,
                sourceUserData: 0,
                now: Date(timeIntervalSince1970: Double(index) * 0.1)
            )
        }

        XCTAssertEqual(killSwitch.isActive, true)
        killSwitch.unlock()
        XCTAssertEqual(killSwitch.isActive, false)
    }

    func testSupervisorUnlockClearsTrackedModifierState() {
        let supervisor = SupervisorService()
        supervisor.feedKeyEvent(
            type: .keyDown,
            keyCode: 0x37,
            sourceUserData: 0,
            now: Date(timeIntervalSince1970: 0)
        )
        supervisor.feedKeyEvent(
            type: .keyDown,
            keyCode: 0x38,
            sourceUserData: 0,
            now: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(supervisor.modifierSnapshot().cmd, true)
        XCTAssertEqual(supervisor.modifierSnapshot().shift, true)

        supervisor.unlock()
        let snapshot = supervisor.modifierSnapshot()
        XCTAssertEqual(snapshot.cmd, false)
        XCTAssertEqual(snapshot.shift, false)
        XCTAssertEqual(snapshot.stuck, [])
        XCTAssertEqual(supervisor.killSwitch.isActive, false)
    }

    func testPassiveLearningBuildsCompactMouseAndKeyboardGestureSamplesAutomatically() {
        let observer = PassiveObserver()
        var published = [PassiveGestureSample]()
        observer.learningSampleHandler = { sample in
            published.append(sample)
        }

        _ = observer.configureLearning(enabled: true, mode: .passive)
        _ = observer.appendSynthetic(type: "mouseMoved", point: ObservedPoint(x: 0, y: 0), ts: 1_000)
        _ = observer.appendSynthetic(type: "mouseMoved", point: ObservedPoint(x: 28, y: 12), ts: 1_080)
        _ = observer.appendSynthetic(type: "mouseMoved", point: ObservedPoint(x: 68, y: 42), ts: 1_170)
        _ = observer.appendSynthetic(type: "leftMouseDown", point: ObservedPoint(x: 96, y: 64), ts: 1_240)
        _ = observer.appendSynthetic(type: "leftMouseUp", point: ObservedPoint(x: 96, y: 64), ts: 1_305)

        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published[0].source, "user-passive")
        XCTAssertEqual(published[0].host, "__global__")
        XCTAssertEqual(published[0].actionType, "click")
        XCTAssertTrue(published[0].pathSkeleton.count >= 3)
        XCTAssertEqual(published[0].clickHoldMs.first, 65)
        XCTAssertTrue((published[0].speedPxS ?? 0) > 0)
        XCTAssertTrue((published[0].straightness ?? 0) < 1)

        _ = observer.startLearningSession(label: nil, host: "training.local", targetAction: nil)
        _ = observer.appendSynthetic(type: "mouseMoved", point: ObservedPoint(x: 10, y: 10), ts: 2_000)
        _ = observer.appendSynthetic(type: "mouseMoved", point: ObservedPoint(x: 34, y: 18), ts: 2_070)
        _ = observer.appendSynthetic(type: "leftMouseDown", point: ObservedPoint(x: 58, y: 30), ts: 2_130)
        _ = observer.appendSynthetic(type: "leftMouseUp", point: ObservedPoint(x: 58, y: 30), ts: 2_200)
        XCTAssertEqual(published.count, 2, "focused capture samples are persisted automatically")
        XCTAssertEqual(published[1].source, "user-focused")
        XCTAssertEqual(published[1].host, "training.local")

        let stop = observer.stopLearningSession(commit: true)
        XCTAssertEqual(stop.committedSamples.count, 0)
        XCTAssertEqual(published.count, 2)

        _ = observer.appendSynthetic(type: "keyDown", keyCode: 12, ts: 3_000)
        _ = observer.appendSynthetic(type: "keyUp", keyCode: 12, ts: 3_082)
        XCTAssertEqual(published.count, 3)
        XCTAssertEqual(published[2].actionType, "type")
        XCTAssertEqual(published[2].keyCode, 12)
        XCTAssertEqual(published[2].dwellMs.first, 82)
    }
}
