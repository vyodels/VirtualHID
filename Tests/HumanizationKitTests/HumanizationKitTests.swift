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

    func testHumanTimingCurveUsesAccelerationCruiseDecelerationInsteadOfUniformSteps() {
        var rng = SeededRandomNumberGenerator(seed: 99)
        let path = (0..<18).map { index in
            HumanPoint(x: Double(index * 12), y: Double(index.isMultiple(of: 3) ? 2 : 0))
        }
        let profile = MotionProfile(
            flavor: .smooth,
            moveSpeedPxS: DoubleRange(min: 220, max: 260),
            hesitationProbability: 0,
            settleMs: IntRange(min: 42, max: 42)
        )

        let plan = HumanTimingCurve.plan(path: path, requestedDurationMs: 840, profile: profile, rng: &rng)
        let interior = Array(plan.delaysMs.dropLast())

        XCTAssertEqual(plan.totalDurationMs, 840)
        XCTAssertEqual(plan.delaysMs.count, path.count)
        XCTAssertTrue(interior.max() != interior.min())
        XCTAssertTrue(interior.first! > interior[interior.count / 2])
        XCTAssertTrue(interior.last! > interior[interior.count / 2])
    }

    func testBehaviorBlendAndMotionProfileSamplingRespectConfiguredModeAndRanges() {
        var rng = SeededRandomNumberGenerator(seed: 7)
        let blend = BehaviorBlend(idle: 0, normal: 0, flow: 1, lowEfficiency: 0)
        let profile = MotionProfile(
            behaviorBlend: blend,
            moveSpeedPxS: DoubleRange(min: 300, max: 360),
            pointCount: IntRange(min: 9, max: 11),
            targetSpreadPx: 6,
            clickHoldMs: IntRange(min: 52, max: 58)
        )

        let sampledMode = profile.sampleBehaviorMode(rng: &rng)
        let sampledPointCount = profile.resolvedPointCount(fallback: 4, rng: &rng)
        let sampledHoldMs = profile.resolvedClickHoldMs(defaultValue: 40, rng: &rng)
        let sampledOffset = profile.resolvedTargetOffset(rng: &rng)

        XCTAssertEqual(sampledMode, HumanBehaviorMode.flow)
        XCTAssertTrue((9...11).contains(sampledPointCount))
        XCTAssertTrue((52...58).contains(sampledHoldMs))
        XCTAssertTrue(hypot(sampledOffset.x, sampledOffset.y) <= 6.01)
    }

    private func average(_ values: [Double]) -> Double {
        guard values.isEmpty == false else {
            return 0
        }
        return values.reduce(0, +) / Double(values.count)
    }
}
