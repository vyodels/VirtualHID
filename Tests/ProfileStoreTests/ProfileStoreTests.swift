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
        XCTAssertLessThanOrEqual(moveLearned.motion.controlSpread ?? 1, 0.34)

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

    func testRebuildCanonicalizesKeyAndTypeIntoSingleInputTemplate() throws {
        let store = try ProfileStore(path: ":memory:")

        for index in 0..<3 {
            _ = try store.insertTrace(
                TraceInput(
                    ts: Int64(1_800_000_010_000 + index),
                    source: "user",
                    host: "__global__",
                    elementSig: "",
                    taskId: nil,
                    stage: nil,
                    actionType: "key",
                    payload: TracePayload(
                        eventId: "key-\(index)",
                        type: "flagsChanged",
                        keyCode: 56,
                        dwellMs: [48 + Double(index)],
                        modifierFlags: [1],
                        flagsChangedKeyCodes: [56],
                        eventTimeline: ["flagsChanged"]
                    )
                )
            )
        }

        for index in 0..<3 {
            _ = try store.insertTrace(
                TraceInput(
                    ts: Int64(1_800_000_011_000 + index),
                    source: "user",
                    host: "__global__",
                    elementSig: "",
                    taskId: nil,
                    stage: nil,
                    actionType: "type",
                    payload: TracePayload(
                        eventId: "type-\(index)",
                        type: "keyUp",
                        keyCode: 12,
                        dwellMs: [70 + Double(index)],
                        interKeyMs: [120 + Double(index)],
                        eventTimeline: ["keyDown", "keyUp"]
                    )
                )
            )
        }

        let report = try store.rebuild(host: "__global__")
        let templates = try store.listTemplates(host: "__global__")
        let template = try store.lookupTemplate(host: "__global__", sig: "", taskId: nil, actionType: "key")
        let learned = try JSONDecoder().decode(LearnedMotionTemplate.self, from: Data(template.paramsJSON.utf8))

        XCTAssertEqual(report.scannedTraces, 6)
        XCTAssertEqual(report.generatedTemplates, 1)
        XCTAssertEqual(templates.map(\.actionType), ["type"])
        XCTAssertEqual(template.actionType, "type")
        XCTAssertEqual(template.sampleSize, 6)
        XCTAssertEqual(learned.actionType, "type")
        XCTAssertEqual(learned.sampleSize, 6)
    }

    func testRebuildIgnoresVirtualHIDGeneratedReplaySources() throws {
        let store = try ProfileStore(path: ":memory:")

        for index in 0..<5 {
            _ = try store.insertTrace(
                TraceInput(
                    ts: Int64(1_800_000_020_000 + index),
                    source: index.isMultiple(of: 2) ? "hid-dry-run" : "hid",
                    host: "example.com",
                    elementSig: "sig-click",
                    taskId: "task-click",
                    stage: "stage",
                    actionType: "click",
                    payload: TracePayload(
                        eventId: "hid-\(index)",
                        type: "leftMouseUp",
                        point: TracePoint(x: 120, y: 88),
                        clickHoldMs: [20]
                    )
                )
            )
        }

        for index in 0..<5 {
            _ = try store.insertTrace(
                TraceInput(
                    ts: Int64(1_800_000_021_000 + index),
                    source: "user-passive",
                    host: "example.com",
                    elementSig: "sig-click",
                    taskId: "task-click",
                    stage: "stage",
                    actionType: "click",
                    payload: TracePayload(
                        eventId: "user-\(index)",
                        type: "leftMouseUp",
                        point: TracePoint(x: 120, y: 88),
                        clickHoldMs: [80 + Double(index)]
                    )
                )
            )
        }

        let report = try store.rebuild(host: "example.com")
        let template = try store.lookupTemplate(host: "example.com", sig: "sig-click", taskId: "task-click", actionType: "click")
        let learned = try JSONDecoder().decode(LearnedMotionTemplate.self, from: Data(template.paramsJSON.utf8))

        XCTAssertEqual(try store.traceCount(host: "example.com"), 10)
        XCTAssertEqual(report.scannedTraces, 5)
        XCTAssertEqual(report.generatedTemplates, 1)
        XCTAssertEqual(template.sampleSize, 5)
        XCTAssertGreaterThanOrEqual(learned.motion.clickHoldMs?.min ?? 0, 70)
    }

    func testRebuildExposesRawHIDDistributionsForScrollKeyboardAndDoubleClick() throws {
        let store = try ProfileStore(path: ":memory:")

        for index in 0..<5 {
            _ = try store.insertTrace(
                TraceInput(
                    ts: Int64(1_800_000_010_000 + index),
                    source: "user",
                    host: "example.com",
                    elementSig: "sig-scroll",
                    taskId: "task-scroll",
                    stage: "stage",
                    actionType: "scroll",
                    payload: TracePayload(
                        eventId: "scroll-\(index)",
                        type: "scrollWheel",
                        point: TracePoint(x: 100, y: 120),
                        durationMs: 180 + Double(index * 20),
                        scrollDeltas: [
                            TraceScrollDelta(dx: 0, dy: -120 - Double(index * 4)),
                            TraceScrollDelta(dx: 0, dy: -76 - Double(index * 3))
                        ],
                        scrollIntervalsMs: [42 + Double(index * 5)],
                        eventTimeline: ["scrollWheel", "scrollWheel"]
                    )
                )
            )
            _ = try store.insertTrace(
                TraceInput(
                    ts: Int64(1_800_000_011_000 + index),
                    source: "user",
                    host: "example.com",
                    elementSig: "sig-click",
                    taskId: "task-click",
                    stage: "stage",
                    actionType: "click",
                    payload: TracePayload(
                        eventId: "double-\(index)",
                        type: "leftMouseUp",
                        point: TracePoint(x: 140, y: 160),
                        clickHoldMs: [54 + Double(index * 3)],
                        doubleClickIntervalMs: [180 + Double(index * 12)],
                        eventTimeline: ["leftMouseDown", "leftMouseUp", "leftMouseDown", "leftMouseUp"]
                    )
                )
            )
            _ = try store.insertTrace(
                TraceInput(
                    ts: Int64(1_800_000_012_000 + index),
                    source: "user",
                    host: "example.com",
                    elementSig: "sig-type",
                    taskId: "task-type",
                    stage: "stage",
                    actionType: "type",
                    payload: TracePayload(
                        eventId: "key-\(index)",
                        type: "keyUp",
                        keyCode: 12,
                        dwellMs: [70 + Double(index * 4)],
                        interKeyMs: [96 + Double(index * 8)],
                        modifierFlags: [1],
                        flagsChangedKeyCodes: [56],
                        comboKeyCodes: [56, 12],
                        repeatCount: index.isMultiple(of: 2) ? 1 : 0,
                        eventTimeline: ["flagsChanged", "keyDown", "keyUp"]
                    )
                )
            )
        }

        _ = try store.rebuild(host: "example.com")
        let scroll = try store.lookupTemplate(host: "example.com", sig: "sig-scroll", taskId: "task-scroll", actionType: "scroll")
        let click = try store.lookupTemplate(host: "example.com", sig: "sig-click", taskId: "task-click", actionType: "click")
        let type = try store.lookupTemplate(host: "example.com", sig: "sig-type", taskId: "task-type", actionType: "type")

        let scrollLearned = try JSONDecoder().decode(LearnedMotionTemplate.self, from: Data(scroll.paramsJSON.utf8))
        XCTAssertNotNil(scrollLearned.motion.scrollDeltaY)
        XCTAssertNotNil(scrollLearned.motion.scrollStepCount)
        XCTAssertNotNil(scrollLearned.motion.scrollStepDelayMs)

        let scrollJSON = try JSONSerialization.jsonObject(with: Data(scroll.paramsJSON.utf8)) as? [String: Any]
        let scrollRaw = scrollJSON?["rawHID"] as? [String: Any]
        XCTAssertNotNil(scrollRaw?["scrollDeltaY"])
        XCTAssertNotNil(scrollRaw?["scrollIntervalsMs"])
        XCTAssertNotNil(scrollRaw?["scrollEventCount"])

        let clickLearned = try JSONDecoder().decode(LearnedMotionTemplate.self, from: Data(click.paramsJSON.utf8))
        XCTAssertNotNil(clickLearned.motion.doubleClickInterClickMs)

        let clickJSON = try JSONSerialization.jsonObject(with: Data(click.paramsJSON.utf8)) as? [String: Any]
        let clickRaw = clickJSON?["rawHID"] as? [String: Any]
        XCTAssertNotNil(clickRaw?["doubleClickIntervalMs"])
        XCTAssertTrue((clickRaw?["eventTimeline"] as? [String] ?? []).contains("leftMouseDown"))

        let typeLearned = try JSONDecoder().decode(LearnedMotionTemplate.self, from: Data(type.paramsJSON.utf8))
        XCTAssertNotNil(typeLearned.motion.dwellMs)
        XCTAssertNotNil(typeLearned.motion.interKeyMs)

        let typeJSON = try JSONSerialization.jsonObject(with: Data(type.paramsJSON.utf8)) as? [String: Any]
        let typeRaw = typeJSON?["rawHID"] as? [String: Any]
        XCTAssertNotNil(typeRaw?["dwellMs"])
        XCTAssertNotNil(typeRaw?["interKeyMs"])
        XCTAssertEqual(typeRaw?["modifierFlags"] as? [Int], [1])
        XCTAssertEqual(typeRaw?["flagsChangedKeyCodes"] as? [Int], [56])
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

    func testApplyTemplateWritesValidatedProfilePatch() throws {
        let store = try ProfileStore(path: ":memory:")
        let params = """
        {"version":2,"strategy":"analysis-patch","actionType":"click","sampleSize":12,"motion":{"moveSpeedPxS":{"min":180,"max":320},"pointCount":{"min":8,"max":16},"behaviorBlend":{"idle":0,"normal":1,"flow":0,"lowEfficiency":0}}}
        """

        let template = try store.applyTemplate(
            host: "example.com",
            elementSig: "sig-apply",
            taskId: "task",
            actionType: "click",
            sampleSize: 12,
            confidence: 0.72,
            paramsJSON: params
        )
        let fetched = try store.lookupTemplate(host: "example.com", sig: "sig-apply", taskId: "task", actionType: "click")

        XCTAssertEqual(template.confidence, 0.72)
        XCTAssertEqual(fetched.sampleSize, 12)
        XCTAssertEqual(fetched.actionType, "click")
    }
}
