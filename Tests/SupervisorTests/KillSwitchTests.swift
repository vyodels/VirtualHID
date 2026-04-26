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
}
