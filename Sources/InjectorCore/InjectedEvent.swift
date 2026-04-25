import CoreGraphics
import Foundation

public struct InjectedEvent: Codable, Equatable {
    public let type: String
    public let location: CodablePoint?
    public let key: String?
    public let virtualKey: CGKeyCode?
    public let timestamp: String

    public init(type: String, location: CodablePoint?, key: String?, virtualKey: CGKeyCode?, timestamp: String) {
        self.type = type
        self.location = location
        self.key = key
        self.virtualKey = virtualKey
        self.timestamp = timestamp
    }
}

public struct CodablePoint: Codable, Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct CodableRect: Codable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
