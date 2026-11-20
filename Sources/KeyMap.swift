import Foundation

/// Maps a typed character to riti's virtual key code (see riti/include/riti.h).
enum KeyMap {
    private static let table: [Character: UInt16] = {
        var t: [Character: UInt16] = [
            "`": 41, "~": 1, "!": 59, "@": 60, "#": 61, "$": 62, "%": 63, "^": 64,
            "&": 65, "*": 66, "(": 67, ")": 68, "_": 87, "+": 88, "-": 12, "=": 13,
            "[": 26, "]": 27, "\\": 43, "{": 91, "}": 92, "|": 93, ";": 39, "'": 40,
            ",": 51, ".": 52, "/": 53, ":": 99, "\"": 100, "<": 101, ">": 102, "?": 103,
            "1": 2, "2": 3, "3": 4, "4": 5, "5": 6, "6": 7, "7": 8, "8": 9, "9": 10, "0": 11,
        ]
        for (i, c) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            t[c] = UInt16(41110 + i)
            t[Character(c.uppercased())] = UInt16(41140 + i)
        }
        return t
    }()

    static func code(for character: Character) -> UInt16? { table[character] }

    /// Physical key (macOS virtual key code, ANSI layout) → (unshifted, shifted) character.
    ///
    /// Avro Phonetic and Probhat are defined by key position on a US QWERTY keyboard,
    /// so the character is derived from the key itself rather than from
    /// NSEvent.characters/charactersIgnoringModifiers. Those depend on the keyboard
    /// layout macOS applies, and while an input method is active that translation
    /// can drop Shift (Shift+t arrived as "t"), which broke every Shift letter.
    private static let positions: [UInt16: (Character, Character)] = [
        0: ("a", "A"), 1: ("s", "S"), 2: ("d", "D"), 3: ("f", "F"), 4: ("h", "H"),
        5: ("g", "G"), 6: ("z", "Z"), 7: ("x", "X"), 8: ("c", "C"), 9: ("v", "V"),
        11: ("b", "B"), 12: ("q", "Q"), 13: ("w", "W"), 14: ("e", "E"), 15: ("r", "R"),
        16: ("y", "Y"), 17: ("t", "T"), 31: ("o", "O"), 32: ("u", "U"), 34: ("i", "I"),
        35: ("p", "P"), 37: ("l", "L"), 38: ("j", "J"), 40: ("k", "K"), 45: ("n", "N"),
        46: ("m", "M"),
        18: ("1", "!"), 19: ("2", "@"), 20: ("3", "#"), 21: ("4", "$"), 23: ("5", "%"),
        22: ("6", "^"), 26: ("7", "&"), 28: ("8", "*"), 25: ("9", "("), 29: ("0", ")"),
        27: ("-", "_"), 24: ("=", "+"), 33: ("[", "{"), 30: ("]", "}"), 42: ("\\", "|"),
        41: (";", ":"), 39: ("'", "\""), 43: (",", "<"), 47: (".", ">"), 44: ("/", "?"),
        50: ("`", "~"),
        // Keypad: same character with or without Shift.
        82: ("0", "0"), 83: ("1", "1"), 84: ("2", "2"), 85: ("3", "3"), 86: ("4", "4"),
        87: ("5", "5"), 88: ("6", "6"), 89: ("7", "7"), 91: ("8", "8"), 92: ("9", "9"),
        65: (".", "."), 67: ("*", "*"), 69: ("+", "+"), 75: ("/", "/"), 78: ("-", "-"), 81: ("=", "="),
    ]

    /// The character for a physical key, honouring Shift. Nil for keys not in the
    /// table (for example the extra ISO key); callers then fall back to the event's text.
    static func character(forKeyCode keyCode: UInt16, shift: Bool) -> Character? {
        guard let pair = positions[keyCode] else { return nil }
        return shift ? pair.1 : pair.0
    }
}
