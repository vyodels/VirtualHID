import Foundation
import HumanizationKit
import ProfileStore
import XCTest

@objcMembers
final class ProfileStoreTests: XCTestCase {
    func testRebuildAggregatesRichMotionProfiles() throws {
        let store = try ProfileStore(path: ":memory:")

        for index in 0..<5 {
            _ = try store.insertTrace(
                TraceInput(
                    ts: Int64(1_800_000_000_000 + index),
                    source: "user",
                    host: "example.com",
                    elementSig: "sig-move",
                    taskId: "task-move",
                    stage: "stage",
                    actionType: "move",
                    payload: TracePayload(
                        eventId: "move-\(index)",
                        type: "mouseMoved",
                        point: TracePoint(x: 122 + Double(index), y: 84 + Double(index)),
                        points: [
                            TracePoint(x: 10, y: 10),
                            TracePoint(x: 40 + Double(index), y: 24 + Double(index % 2)),
                            TracePoint(x: 88 + Double(index), y: 58 + Double(index % 3)),
                            TracePoint(x: 122 + Double(index), y: 84 + Double(index))
                        ],
                        origin: TracePoint(x: 10, y: 10),
                        targetPoint: TracePoint(x: 120, y: 82),
                        targetRadiusPx: 7 + Double(index % 2),
                        landingErrorPx: 3 + Double(index % 3),
                        durationMs: 360 + Double(index * 22),
                        segmentMs: [84, 120, 156 + Double(index * 4)],
                        hesitationMs: index.isMultiple(of: 2) ? [48 + Double(index * 5)] : [],
                        straightness: 0.84 + Double(index) * 0.02,
                        turnJitter: 0.10 + Double(index) * 0.015
                    )
                )
            )
        }

        for index in 0..<5 {
            _ = try store.insertTrace(
                TraceInput(
                    ts: Int64(1_800_000_001_000 + index),
                    source: "user",
                    host: "example.com",
                    elementSig: "sig-click",
                    taskId: "task-click",
                    stage: "stage",
                    actionType: "click",
                    payload: TracePayload(
                        eventId: "click-\(index)",
                        type: "leftMouseDown",
                        point: TracePoint(x: 220, y: 180),
                        points: [TracePoint(x: 218, y: 176), TracePoint(x: 220, y: 180)],
                        targetPoint: TracePoint(x: 220, y: 180),
                        targetRadiusPx: 5,
                        durationMs: 120 + Double(index * 6),
                        clickHoldMs: [62 + Double(index * 4)],
                        interClickMs: [142 + Double(index * 10)]
                    )
                )
            )
        }

        for index in 0..<5 {
            _ = try store.insertTrace(
                TraceInput(
                    ts: Int64(1_800_000_002_000 + index),
                    source: "user",
                    host: "example.com",
                    elementSig: "sig-type",
                    taskId: "task-type",
                    stage: "stage",
                    actionType: "type",
                    payload: TracePayload(
                        eventId: "type-\(index)",
                        type: "keyDown",
                        keyCode: 12,
                        dwellMs: [76 + Double(index * 5)],
                        interKeyMs: [112 + Double(index * 11)]
                    )
                )
            )
        }

        let report = try store.rebuild(host: "example.com")
        let moveTemplate = try store.lookupTemplate(host: "example.com", sig: "sig-move", taskId: "task-move", actionType: "move")
        let clickTemplate = try store.lookupTemplate(host: "example.com", sig: "sig-click", taskId: "task-click", actionType: "click")
        let typeTemplate = try store.lookupTemplate(host: "example.com", sig: "sig-type", taskId: "task-type", actionType: "type")

        XCTAssertEqual(report.scannedTraces, 15)
        XCTAssertEqual(report.generatedTemplates, 3)

        let moveLearned = try JSONDecoder().decode(LearnedMotionTemplate.self, from: Data(moveTemplate.paramsJSON.utf8))
        XCTAssertEqual(moveLearned.version, 2)
        XCTAssertEqual(moveLearned.actionType, "move")
        XCTAssertEqual(moveLearned.sampleSize, 5)
        XCTAssertTrue(moveLearned.motion.moveSpeedPxS != nil)
        XCTAssertTrue(moveLearned.motion.pointCount != nil)
        XCTAssertTrue(moveLearned.motion.targetSpreadPx != nil)
        XCTAssertTrue(moveLearned.motion.hesitationProbability != nil)
        XCTAssertTrue(moveLearned.motion.straightnessMean != nil)
        XCTAssertTrue(moveLearned.motion.turnJitterMean != nil)
        XCTAssertTrue(moveLearned.motion.behaviorBlend != nil)
        XCTAssertTrue((moveLearned.motion.moveSpeedPxS?.max ?? 0) > (moveLearned.motion.moveSpeedPxS?.min ?? 0))
        XCTAssertTrue((moveLearned.motion.pointCount?.max ?? 0) > (moveLearned.motion.pointCount?.min ?? 0))

        let clickLearned = try JSONDecoder().decode(LearnedMotionTemplate.self, from: Data(clickTemplate.paramsJSON.utf8))
        XCTAssertEqual(clickLearned.actionType, "click")
        XCTAssertTrue(clickLearned.motion.clickHoldMs != nil)
        XCTAssertTrue(clickLearned.motion.interClickMs != nil)
        XCTAssertTrue((clickLearned.motion.clickHoldMs?.max ?? 0) > (clickLearned.motion.clickHoldMs?.min ?? 0))

        let typeLearned = try JSONDecoder().decode(LearnedMotionTemplate.self, from: Data(typeTemplate.paramsJSON.utf8))
        XCTAssertEqual(typeLearned.actionType, "type")
        XCTAssertTrue(abs((typeLearned.motion.dwellMsMean ?? 0) - 86) < 0.01)
        XCTAssertTrue(abs((typeLearned.motion.interKeyMsMean ?? 0) - 134) < 0.01)
    }

    func testRetentionDropsExpiredAndOverflowTraces() throws {
        let retention = TraceRetentionPolicy(
            maxAgeMs: 1_000,
            maxTracesPerGroup: 3,
            cleanupIntervalMs: 0
        )
        let store = try ProfileStore(path: ":memory:", retentionPolicy: retention)

        for index in 0..<2 {
            _ = try store.insertTrace(
                TraceInput(
                    ts: Int64(index * 10),
                    source: "user",
                    host: "example.com",
                    elementSig: "sig-retain",
                    taskId: "task-retain",
                    stage: "old",
                    actionType: "move",
                    payload: TracePayload(
                        eventId: "old-\(index)",
                        type: "mouseMoved",
                        point: TracePoint(x: Double(index), y: Double(index)),
                        points: [TracePoint(x: 0, y: 0), TracePoint(x: 10, y: 10)],
                        durationMs: 120
                    )
                )
            )
        }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for index in 0..<5 {
            _ = try store.insertTrace(
                TraceInput(
                    ts: now + Int64(index),
                    source: "user",
                    host: "example.com",
                    elementSig: "sig-retain",
                    taskId: "task-retain",
                    stage: "new",
                    actionType: "move",
                    payload: TracePayload(
                        eventId: "new-\(index)",
                        type: "mouseMoved",
                        point: TracePoint(x: 100 + Double(index), y: 100 + Double(index)),
                        points: [TracePoint(x: 10, y: 10), TracePoint(x: 100 + Double(index), y: 100 + Double(index))],
                        durationMs: 150 + Double(index * 10)
                    )
                )
            )
        }

        let report = try store.rebuild(host: "example.com")

        XCTAssertEqual(report.scannedTraces, 3)
        XCTAssertEqual(try store.traceCount(host: "example.com"), 3)
        XCTAssertEqual(try store.totalTemplates(), 0)
    }

    func testSensitiveRoleTraceIsDropped() throws {
        let store = try ProfileStore(path: ":memory:")

        let result = try store.commitObservedEvent(
            eventId: "event-sensitive",
            eventType: "keyDown",
            ts: 1_800_000_000_000,
            point: nil,
            keyCode: 0,
            elementSig: "sig-sensitive",
            role: "password",
            host: "example.com",
            taskId: nil,
            stage: nil
        )

        XCTAssertEqual(result.dropped, true)
        XCTAssertEqual(try store.traceCount(host: "example.com"), 0)
    }
}
