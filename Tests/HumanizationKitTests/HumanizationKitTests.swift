import Foundation
import XCTest
@testable import HumanizationKit

@objcMembers
final class HumanizationKitTests: XCTestCase {
    func testWindMouseProducesJitterAndOvershootCorrection() {
        var rng = SeededRandomNumberGenerator(seed: 11)
        var params = WindMouseParams()
        params.wind = 9
        params.overshootProbability = 1

        let path = WindMouse.path(
            from: HumanPoint(x: 0, y: 0),
            to: HumanPoint(x: 120, y: 0),
            params: params,
            rng: &rng
        )

        XCTAssertTrue(path.count > 10)
        XCTAssertEqual(path.last, HumanPoint(x: 120, y: 0))
        XCTAssertTrue(path.contains { $0.x > 120 })
        XCTAssertTrue(path.contains { abs($0.y) > 0.01 })
    }

    func testWindMouseSameInputVariesBySeed() {
        var firstRng = SeededRandomNumberGenerator(seed: 1)
        var secondRng = SeededRandomNumberGenerator(seed: 2)
        let start = HumanPoint(x: 10, y: 10)
        let end = HumanPoint(x: 200, y: 120)

        let first = WindMouse.resampledPath(from: start, to: end, count: 20, rng: &firstRng)
        let second = WindMouse.resampledPath(from: start, to: end, count: 20, rng: &secondRng)

        XCTAssertEqual(first.count, 20)
        XCTAssertEqual(second.count, 20)
        XCTAssertTrue(first != second)
    }

    func testWindMouseStepsShrinkNearTarget() {
        var rng = SeededRandomNumberGenerator(seed: 7)
        var params = WindMouseParams()
        params.wind = 1
        params.overshootProbability = 0
        let path = WindMouse.path(
            from: HumanPoint(x: 0, y: 0),
            to: HumanPoint(x: 180, y: 0),
            params: params,
            rng: &rng
        )

        let steps = zip(path.dropFirst(), path).map { next, previous in
            hypot(next.x - previous.x, next.y - previous.y)
        }
        let head = average(Array(steps.prefix(6)))
        let tail = average(Array(steps.suffix(6)))
        XCTAssertTrue(tail < head)
    }

    func testKeystrokeRhythmMapsAsciiAndRanges() {
        var rng = SeededRandomNumberGenerator(seed: 42)
        let schedule = KeystrokeRhythm.schedule(for: "ab C1", rng: &rng)

        XCTAssertEqual(schedule.count, 5)
        XCTAssertEqual(schedule[0].keyCode, 0)
        XCTAssertEqual(schedule[1].keyCode, 11)
        XCTAssertEqual(schedule[2].keyCode, 49)
        XCTAssertEqual(schedule[3].keyCode, 8)
        XCTAssertTrue(schedule[3].modifiers.contains(.shift))
        XCTAssertEqual(schedule[4].keyCode, 18)
        XCTAssertEqual(schedule[0].delayBeforeMs, 0)
        XCTAssertTrue(schedule.dropFirst().allSatisfy { $0.delayBeforeMs > 0 })
        XCTAssertTrue(schedule.allSatisfy { (40...180).contains($0.dwellMs) })
    }

    private func average(_ values: [Double]) -> Double {
        guard values.isEmpty == false else {
            return 0
        }
        return values.reduce(0, +) / Double(values.count)
    }
}
