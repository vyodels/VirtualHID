import CoreGraphics
import Foundation

public enum KeyMap {
    public struct CharacterEvent: Equatable {
        public let keyCode: CGKeyCode
        public let modifiers: CGEventFlags

        public init(keyCode: CGKeyCode, modifiers: CGEventFlags = []) {
            self.keyCode = keyCode
            self.modifiers = modifiers
        }
    }

    private static let mapping: [UnicodeScalar: CharacterEvent] = [
        "a": CharacterEvent(keyCode: 0), "b": CharacterEvent(keyCode: 11),
        "c": CharacterEvent(keyCode: 8), "d": CharacterEvent(keyCode: 2),
        "e": CharacterEvent(keyCode: 14), "f": CharacterEvent(keyCode: 3),
        "g": CharacterEvent(keyCode: 5), "h": CharacterEvent(keyCode: 4),
        "i": CharacterEvent(keyCode: 34), "j": CharacterEvent(keyCode: 38),
        "k": CharacterEvent(keyCode: 40), "l": CharacterEvent(keyCode: 37),
        "m": CharacterEvent(keyCode: 46), "n": CharacterEvent(keyCode: 45),
        "o": CharacterEvent(keyCode: 31), "p": CharacterEvent(keyCode: 35),
        "q": CharacterEvent(keyCode: 12), "r": CharacterEvent(keyCode: 15),
        "s": CharacterEvent(keyCode: 1), "t": CharacterEvent(keyCode: 17),
        "u": CharacterEvent(keyCode: 32), "v": CharacterEvent(keyCode: 9),
        "w": CharacterEvent(keyCode: 13), "x": CharacterEvent(keyCode: 7),
        "y": CharacterEvent(keyCode: 16), "z": CharacterEvent(keyCode: 6),
        "1": CharacterEvent(keyCode: 18), "2": CharacterEvent(keyCode: 19),
        "3": CharacterEvent(keyCode: 20), "4": CharacterEvent(keyCode: 21),
        "5": CharacterEvent(keyCode: 23), "6": CharacterEvent(keyCode: 22),
        "7": CharacterEvent(keyCode: 26), "8": CharacterEvent(keyCode: 28),
        "9": CharacterEvent(keyCode: 25), "0": CharacterEvent(keyCode: 29),
        " ": CharacterEvent(keyCode: 49),
        "\t": CharacterEvent(keyCode: 48),
        "\n": CharacterEvent(keyCode: 36)
    ]

    public static func characterEvent(for scalar: UnicodeScalar) -> CharacterEvent? {
        if let direct = mapping[scalar] {
            return direct
        }

        let lowercase = scalar.properties.lowercaseMapping.unicodeScalars
        if lowercase.count == 1, let lowered = lowercase.first, let base = mapping[lowered], scalar.properties.isUppercase {
            return CharacterEvent(keyCode: base.keyCode, modifiers: [.maskShift])
        }

        return nil
    }
}
