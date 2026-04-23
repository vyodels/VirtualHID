import Foundation
import ProfileStore
import XCTest

final class ProfileStoreTests: XCTestCase {
    func testRebuildCreatesTemplateFromFiveTraces() throws {
        let store = try ProfileStore(path: ":memory:")

        for index in 0..<5 {
            _ = try store.insertTrace(
                TraceInput(
                    ts: Int64(1_800_000_000_000 + index),
                    source: "user",
                    host: "example.com",
                    elementSig: "sig-1",
                    taskId: "task-1",
                    stage: "stage",
                    actionType: "click",
                    payload: TracePayload(
                        eventId: "event-\(index)",
                        type: "leftMouseDown",
                        point: TracePoint(x: Double(index), y: Double(index + 10)),
                        points: [TracePoint(x: Double(index), y: Double(index + 10))]
                    )
                )
            )
        }

        let report = try store.rebuild(host: "example.com")
        let template = try store.getTemplate(host: "example.com", sig: "sig-1")

        XCTAssertEqual(report.scannedTraces, 5)
        XCTAssertEqual(report.generatedTemplates, 1)
        XCTAssertEqual(template.sampleSize, 5)
        XCTAssertEqual(template.actionType, "click")
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
