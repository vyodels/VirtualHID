import CoreGraphics
import Foundation

public enum PostMode: String, Codable {
    case global
    case pid
    case auto
}

public enum PostRoute: String, Codable, Equatable {
    case global
    case pid
}

public enum PosterError: Error, Equatable, LocalizedError {
    case notFrontmost
    case postModeUnsupported(CGEventType)

    public var errorDescription: String? {
        switch self {
        case .notFrontmost:
            return "E_NOT_FRONTMOST"
        case .postModeUnsupported(let type):
            return "E_POST_MODE_UNSUPPORTED(\(type.rawValue))"
        }
    }
}

protocol EventPostingBackend {
    func postGlobal(_ event: CGEvent)
    func postToPid(_ event: CGEvent, pid: pid_t)
}

struct CoreGraphicsEventPostingBackend: EventPostingBackend {
    func postGlobal(_ event: CGEvent) {
        event.post(tap: .cgSessionEventTap)
    }

    func postToPid(_ event: CGEvent, pid: pid_t) {
        event.postToPid(pid)
    }
}

public final class EventPoster {
    public static let defaultMarkValue: Int64 = 0x56484944

    public let mode: PostMode
    public let targetPid: pid_t
    private let backend: EventPostingBackend
    private let markValue: Int64

    public init(mode: PostMode, targetPid: pid_t) {
        self.mode = mode
        self.targetPid = targetPid
        self.backend = CoreGraphicsEventPostingBackend()
        self.markValue = Self.defaultMarkValue
    }

    init(mode: PostMode, targetPid: pid_t, backend: EventPostingBackend, markValue: Int64 = EventPoster.defaultMarkValue) {
        self.mode = mode
        self.targetPid = targetPid
        self.backend = backend
        self.markValue = markValue
    }

    public func preflight(frontmost: Bool) throws {
        guard mode == .global else {
            return
        }
        guard frontmost else {
            throw PosterError.notFrontmost
        }
    }

    public func post(_ event: CGEvent, type: CGEventType, frontmost: Bool) throws -> PostRoute {
        event.setIntegerValueField(.eventSourceUserData, value: markValue)

        switch mode {
        case .global:
            try preflight(frontmost: frontmost)
            backend.postGlobal(event)
            return .global

        case .pid:
            guard Self.isPidSafe(type) else {
                throw PosterError.postModeUnsupported(type)
            }
            backend.postToPid(event, pid: targetPid)
            return .pid

        case .auto:
            if Self.isPidSafe(type) {
                backend.postToPid(event, pid: targetPid)
                return .pid
            }
            guard frontmost else {
                throw PosterError.notFrontmost
            }
            backend.postGlobal(event)
            return .global
        }
    }

    public static func isPidSafe(_ type: CGEventType) -> Bool {
        switch type {
        case .mouseMoved, .scrollWheel:
            return true
        default:
            return false
        }
    }
}
