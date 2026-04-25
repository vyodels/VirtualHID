import Foundation
import HumanizationKit
import ProfileStore
import XCTest

@objcMembers
final class ReplayTraceStoreTests: XCTestCase {
    func testFingerprintStoresPathSkeletonAndRhythmSegments() {
        let input = TraceInput(
            ts: 1_800_000_000_000,
            source: "user",
            host: "example.com",
            elementSig: "sig-submit",
            taskId: "task",
            stage: "stage",
            actionType: "click",
            payload: TracePayload(
                eventId: "trace-1",
                type: "leftMouseUp",
                points: (0..<24).map { TracePoint(x: Double($0 * 4), y: Double($0 * 2)) },
                targetPoint: TracePoint(x: 92, y: 46),
                landingErrorPx: 1.5,
                durationMs: 420,
                segmentMs: [40, 52, 60, 72, 88],
                hesitationMs: [64],
                clickHoldMs: [58],
                interClickMs: [132],
                behaviorMode: .normal,
                flavor: .smooth
            )
        )

        let fingerprint = ReplayTraceStore.fingerprint(input: input, instructionKey: "open-detail", maxSkeletonPoints: 8)

        XCTAssertEqual(fingerprint.key.host, "example.com")
        XCTAssertEqual(fingerprint.key.instructionKey, "open-detail")
        XCTAssertEqual(fingerprint.pathSkeleton.count, 8)
        XCTAssertEqual(fingerprint.segmentMs, [40, 52, 60, 72, 88])
        XCTAssertEqual(fingerprint.clickHoldMs, [58])
        XCTAssertTrue(fingerprint.quality > 0.85)
    }

    func testRetentionAndSummaryPreferHigherQualityRecentSamples() {
        let key = ReplayTraceKey(host: "example.com", instructionKey: "open-detail", actionType: "click")
        let store = ReplayTraceStore(retention: ReplayTraceRetentionPolicy(maxFingerprintsPerKey: 2, maxAgeMs: 10_000))

        for index in 0..<3 {
            store.commit(
                ReplayTraceFingerprint(
                    key: key,
                    ts: 1_000 + Int64(index),
                    source: "user",
                    pathSkeleton: [TracePoint(x: Double(index), y: 0), TracePoint(x: 10, y: 10)],
                    segmentMs: [Double(40 + index)],
                    hesitationMs: [],
                    clickHoldMs: [Double(50 + index)],
                    interClickMs: [],
                    dwellMs: [],
                    interKeyMs: [],
                    behaviorMode: index == 2 ? .flow : .normal,
                    flavor: .smooth,
                    landingErrorPx: Double(index),
                    durationMs: Double(300 + index),
                    quality: Double(index) / 2.0
                )
            )
        }

        let items = store.list(key: key)
        let summary = store.summarize(key: key)

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(summary?.sampleSize, 2)
        XCTAssertEqual(summary?.preferredFingerprint?.quality, 1.0)
        XCTAssertTrue((summary?.behaviorBlend.flow ?? 0) > 0)
    }
}
