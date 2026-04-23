import CoreGraphics
import Foundation
import XCTest
@testable import InjectorCore

@objcMembers
final class EventPosterTests: XCTestCase {
    func testGlobalPostsWhenFrontmost() {
        let backend = RecordingBackend()
        let poster = EventPoster(mode: .global, targetPid: 42, backend: backend)
        let event = try! XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))

        let route = try! poster.post(event, type: .keyDown, frontmost: true)

        XCTAssertEqual(route, .global)
        XCTAssertEqual(backend.calls, [.global])
        XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), EventPoster.defaultMarkValue)
    }

    func testGlobalRejectsWhenNotFrontmost() {
        let backend = RecordingBackend()
        let poster = EventPoster(mode: .global, targetPid: 42, backend: backend)
        let event = try! XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))

        XCTAssertThrowsError(try poster.post(event, type: .keyDown, frontmost: false)) { error in
            XCTAssertEqual(error as? PosterError, .notFrontmost)
        }
        XCTAssertTrue(backend.calls.isEmpty)
    }

    func testPidPostsMouseMove() {
        let backend = RecordingBackend()
        let poster = EventPoster(mode: .pid, targetPid: 77, backend: backend)
        let event = try! XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: .zero, mouseButton: .left))

        let route = try! poster.post(event, type: .mouseMoved, frontmost: false)

        XCTAssertEqual(route, .pid)
        XCTAssertEqual(backend.calls, [.pid(77)])
    }

    func testPidRejectsClick() {
        let backend = RecordingBackend()
        let poster = EventPoster(mode: .pid, targetPid: 77, backend: backend)
        let event = try! XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left))

        XCTAssertThrowsError(try poster.post(event, type: .leftMouseDown, frontmost: false)) { error in
            XCTAssertEqual(error as? PosterError, .postModeUnsupported(.leftMouseDown))
        }
        XCTAssertTrue(backend.calls.isEmpty)
    }
}

private final class RecordingBackend: EventPostingBackend {
    enum Call: Equatable {
        case global
        case pid(pid_t)
    }

    private(set) var calls: [Call] = []

    func postGlobal(_ event: CGEvent) {
        calls.append(.global)
    }

    func postToPid(_ event: CGEvent, pid: pid_t) {
        calls.append(.pid(pid))
    }
}
