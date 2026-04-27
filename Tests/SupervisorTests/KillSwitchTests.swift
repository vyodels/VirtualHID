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
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published[0].source, "user-passive")
        XCTAssertEqual(published[0].host, "__global__")
        XCTAssertEqual(published[0].actionType, "move")
        XCTAssertEqual(published[0].eventType, "mouseMoved")
        XCTAssertTrue(published[0].pathSkeleton.count >= 3)
        XCTAssertTrue((published[0].speedPxS ?? 0) > 0)
        XCTAssertTrue((published[0].straightness ?? 0) < 1)

        _ = observer.appendSynthetic(type: "leftMouseDown", point: ObservedPoint(x: 96, y: 64), ts: 1_240)
        _ = observer.appendSynthetic(type: "leftMouseUp", point: ObservedPoint(x: 96, y: 64), ts: 1_305)

        XCTAssertEqual(published.count, 2)
        XCTAssertEqual(published[1].source, "user-passive")
        XCTAssertEqual(published[1].host, "__global__")
        XCTAssertEqual(published[1].actionType, "click")
        XCTAssertTrue(published[1].pathSkeleton.count >= 3)
        XCTAssertEqual(published[1].clickHoldMs.first, 65)

        _ = observer.startLearningSession(label: nil, host: "training.local", targetAction: nil)
        _ = observer.appendSynthetic(type: "mouseMoved", point: ObservedPoint(x: 10, y: 10), ts: 2_000)
        _ = observer.appendSynthetic(type: "mouseMoved", point: ObservedPoint(x: 34, y: 18), ts: 2_070)
        _ = observer.appendSynthetic(type: "mouseMoved", point: ObservedPoint(x: 58, y: 30), ts: 2_150)
        XCTAssertEqual(published.count, 3, "teaching movement samples are persisted automatically")
        XCTAssertEqual(published[2].source, "user-teaching")
        XCTAssertEqual(published[2].host, "__global__")
        XCTAssertEqual(published[2].actionType, "move")

        _ = observer.appendSynthetic(type: "leftMouseDown", point: ObservedPoint(x: 76, y: 44), ts: 2_230)
        _ = observer.appendSynthetic(type: "leftMouseUp", point: ObservedPoint(x: 76, y: 44), ts: 2_300)
        XCTAssertEqual(published.count, 4, "teaching click samples are persisted automatically")
        XCTAssertEqual(published[3].source, "user-teaching")
        XCTAssertEqual(published[3].host, "__global__")
        XCTAssertEqual(published[3].actionType, "click")

        let stop = observer.stopLearningSession(commit: true)
        XCTAssertEqual(stop.committedSamples.count, 0)
        XCTAssertEqual(published.count, 4)

        _ = observer.appendSynthetic(type: "keyDown", keyCode: 12, ts: 3_000)
        _ = observer.appendSynthetic(type: "keyUp", keyCode: 12, ts: 3_082)
        XCTAssertEqual(published.count, 5)
        XCTAssertEqual(published[4].actionType, "type")
        XCTAssertEqual(published[4].keyCode, 12)
        XCTAssertEqual(published[4].dwellMs.first, 82)
    }

    func testTeachingSessionOnlyPublishesCurrentTargetActionSamples() {
        let observer = PassiveObserver()
        var published = [PassiveGestureSample]()
        observer.learningSampleHandler = { sample in
            published.append(sample)
        }

        _ = observer.configureLearning(enabled: true, mode: .passive)
        _ = observer.startLearningSession(label: "现场教学：移动轨迹", host: nil, targetAction: "move")
        _ = observer.appendSynthetic(type: "leftMouseDown", point: ObservedPoint(x: 20, y: 20), ts: 1_000)
        _ = observer.appendSynthetic(type: "leftMouseUp", point: ObservedPoint(x: 20, y: 20), ts: 1_060)
        XCTAssertEqual(published.count, 0, "move teaching must ignore unrelated click samples")

        _ = observer.appendSynthetic(type: "mouseMoved", point: ObservedPoint(x: 10, y: 10), ts: 1_200)
        _ = observer.appendSynthetic(type: "mouseMoved", point: ObservedPoint(x: 42, y: 28), ts: 1_280)
        _ = observer.appendSynthetic(type: "mouseMoved", point: ObservedPoint(x: 84, y: 56), ts: 1_370)
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published[0].actionType, "move")
        XCTAssertEqual(published[0].source, "user-teaching")

        _ = observer.updateLearningSession(label: "现场教学：键盘输入", host: nil, targetAction: "keyboard")
        _ = observer.appendSynthetic(type: "mouseMoved", point: ObservedPoint(x: 100, y: 60), ts: 1_600)
        _ = observer.appendSynthetic(type: "mouseMoved", point: ObservedPoint(x: 142, y: 78), ts: 1_680)
        _ = observer.appendSynthetic(type: "mouseMoved", point: ObservedPoint(x: 184, y: 96), ts: 1_770)
        XCTAssertEqual(published.count, 1, "keyboard teaching must ignore unrelated move samples")

        _ = observer.appendSynthetic(type: "keyDown", keyCode: 12, ts: 1_900)
        _ = observer.appendSynthetic(type: "keyUp", keyCode: 12, ts: 1_990)
        XCTAssertEqual(published.count, 2)
        XCTAssertEqual(published[1].actionType, "type")
    }

    func testPassiveLearningCapturesFullRawInputSpectrum() {
        let observer = PassiveObserver()
        var published = [PassiveGestureSample]()
        observer.learningSampleHandler = { sample in
            published.append(sample)
        }

        _ = observer.configureLearning(enabled: true, mode: .passive)
        let shiftMask: UInt64 = 1 << 17
        _ = observer.appendSynthetic(type: "leftMouseDown", point: ObservedPoint(x: 20, y: 20), ts: 1_000, modifierFlags: shiftMask)
        _ = observer.appendSynthetic(type: "leftMouseDragged", point: ObservedPoint(x: 44, y: 30), ts: 1_070, modifierFlags: shiftMask)
        _ = observer.appendSynthetic(type: "leftMouseDragged", point: ObservedPoint(x: 80, y: 48), ts: 1_150, modifierFlags: shiftMask)
        _ = observer.appendSynthetic(type: "leftMouseUp", point: ObservedPoint(x: 108, y: 68), ts: 1_230, modifierFlags: shiftMask)

        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published[0].actionType, "drag")
        XCTAssertEqual(published[0].eventTimeline, ["movePrelude", "leftMouseDown", "drag", "leftMouseUp"])
        XCTAssertTrue(published[0].pathSkeleton.count >= 3)
        XCTAssertTrue((published[0].speedPxS ?? 0) > 0)
        XCTAssertTrue(published[0].modifierFlags.contains(shiftMask))

        _ = observer.appendSynthetic(
            type: "scrollWheel",
            point: ObservedPoint(x: 120, y: 70),
            ts: 1_400,
            scrollDeltaX: 0,
            scrollDeltaY: -5,
            modifierFlags: shiftMask
        )
        _ = observer.appendSynthetic(
            type: "scrollWheel",
            point: ObservedPoint(x: 120, y: 70),
            ts: 1_455,
            scrollDeltaX: 0,
            scrollDeltaY: -3,
            modifierFlags: shiftMask
        )

        XCTAssertEqual(published.count, 3)
        XCTAssertEqual(published[2].actionType, "scroll")
        XCTAssertEqual(published[2].scrollDeltas.map(\.dy), [-5, -3])
        XCTAssertEqual(published[2].scrollIntervalsMs.first, 55)
        XCTAssertTrue(published[2].modifierFlags.contains(shiftMask))

        _ = observer.appendSynthetic(type: "leftMouseDown", point: ObservedPoint(x: 130, y: 80), ts: 1_700)
        _ = observer.appendSynthetic(type: "leftMouseUp", point: ObservedPoint(x: 130, y: 80), ts: 1_745)
        _ = observer.appendSynthetic(type: "leftMouseDown", point: ObservedPoint(x: 132, y: 82), ts: 1_910)
        _ = observer.appendSynthetic(type: "leftMouseUp", point: ObservedPoint(x: 132, y: 82), ts: 1_958)

        XCTAssertEqual(published.count, 5)
        XCTAssertEqual(published[4].actionType, "click")
        XCTAssertEqual(published[4].doubleClickIntervalMs.first, 213)
        XCTAssertEqual(published[4].interClickMs.first, 213)

        _ = observer.appendSynthetic(type: "flagsChanged", keyCode: 56, ts: 2_100, modifierFlags: shiftMask)
        _ = observer.appendSynthetic(type: "keyDown", keyCode: 0, ts: 2_150, modifierFlags: shiftMask)
        _ = observer.appendSynthetic(type: "keyDown", keyCode: 0, ts: 2_210, modifierFlags: shiftMask, isRepeat: true)
        _ = observer.appendSynthetic(type: "keyUp", keyCode: 0, ts: 2_260, modifierFlags: shiftMask)

        XCTAssertEqual(published.count, 7)
        XCTAssertEqual(published[5].actionType, "key")
        XCTAssertEqual(published[5].flagsChangedKeyCodes, [56])
        XCTAssertEqual(published[6].actionType, "type")
        XCTAssertEqual(published[6].keyCode, 0)
        XCTAssertEqual(published[6].dwellMs.first, 110)
        XCTAssertEqual(published[6].repeatCount, 1)
        XCTAssertTrue(published[6].modifierFlags.contains(shiftMask))
        XCTAssertTrue(published[6].comboKeyCodes.contains(0))
    }
}
