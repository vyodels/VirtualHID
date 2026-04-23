import Foundation
import XCTest
import ControlServer
import ProfileStore
import Supervisor

@objcMembers
final class ControlServiceTests: XCTestCase {
    func testActionRejectsLandingZonePayload() {
        let service = try! makeService()
        let response = service.handleLine(
            #"{"id":"1","method":"action","params":{"context":{"host":"example.com","element":{"sig":"sig-fixed","role":"button"}},"options":{"dryRun":true},"primitives":[{"type":"click","at":{"x":120,"y":88},"button":"left","profile":{"landingZone":{"center":{"x":120,"y":88},"radius":10}}}]}}"#
        )
        let payload = try! decode(response)
        XCTAssertEqual(payload["ok"] as? Bool, false)
        let error = payload["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? String, "E_FIXED_POINT_ONLY")
    }

    func testActionsExecuteSeriallyAcrossConcurrentClients() {
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
        XCTAssertTrue(elapsedMs >= 380)
    }

    private func makeService() throws -> ControlService {
        let store = try ProfileStore(path: ":memory:")
        return ControlService(
            configuration: ControlServerConfiguration(allowSelfTarget: true),
            supervisor: SupervisorService(),
            profileStore: store
        )
    }

    private func decode(_ text: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
    }
}
