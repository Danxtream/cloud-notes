// Licensed under GPL-3.0-only with an additional term under section 7(b); see LICENSE and NOTICE.md.

import Foundation

/// The folder colours Samsung Notes offers, in its colour picker's order. A folder's `color` in the cloud tree holds the
/// value the picker stores (`stored`); Samsung Notes 4.4.48 draws each with a lighter shade (`shown`). The values are
/// the ones Samsung Notes 4.4.48 uses in its picker and the shades it draws.
enum FolderColor: String, CaseIterable, Identifiable {
    case grey, red, orange, yellow, lightGreen = "light-green", green, lightBlue = "light-blue", blue, violet
    case lightPurple = "light-purple", pink, lightBrown = "light-brown"

    var id: String { rawValue }

    /// The colour's name as Samsung Notes shows it.
    var name: String {
        switch self {
        case .grey: return "Grey"
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .lightGreen: return "Light green"
        case .green: return "Green"
        case .lightBlue: return "Light blue"
        case .blue: return "Blue"
        case .violet: return "Violet"
        case .lightPurple: return "Light purple"
        case .pink: return "Pink"
        case .lightBrown: return "Light brown"
        }
    }

    /// The RGB value Samsung Notes stores, as opaque ARGB in a folder's `color` (a signed 32-bit number).
    private var rgb: UInt32 {
        switch self {
        case .grey: return 0xD1D1D1
        case .red: return 0xFF4133
        case .orange: return 0xFF7043
        case .yellow: return 0xFFC107
        case .lightGreen: return 0x8BC34A
        case .green: return 0x009E7C
        case .lightBlue: return 0x47D6DC
        case .blue: return 0x5485EE
        case .violet: return 0xBB5FCB
        case .lightPurple: return 0xA4BDFD
        case .pink: return 0xF6B7B4
        case .lightBrown: return 0x7E6967
        }
    }

    /// The value Samsung Notes' colour picker writes for this colour.
    var stored: Int { Int(Int32(bitPattern: 0xFF00_0000 | rgb)) }

    /// The RGB shade Samsung Notes draws the folder icon in; nil for grey, which it draws as its default folder.
    var shown: UInt32? {
        switch self {
        case .grey: return nil
        case .red: return 0xFB5C66
        case .orange: return 0xFF893A
        case .yellow: return 0xFFD956
        case .lightGreen: return 0xC6DF7B
        case .green: return 0x1CC494
        case .lightBlue: return 0x6BDBF1
        case .blue: return 0x5298F9
        case .violet: return 0x8F6CF6
        case .lightPurple: return 0xCCBCF2
        case .pink: return 0xFBC6D4
        case .lightBrown: return 0xBEABA4
        }
    }

    /// The colour a folder's stored `color` stands for, as Samsung Notes reads it: an opaque or 70% alpha picker value.
    /// Anything else, such as the -1 of a folder that was never coloured, is drawn as the default (grey).
    init(stored value: Int) {
        let bits = UInt32(bitPattern: Int32(truncatingIfNeeded: value))
        self = Self.allCases.first { bits == 0xFF00_0000 | $0.rgb || bits == 0xB300_0000 | $0.rgb } ?? .grey
    }

    /// The colour for a name such as "light blue", "Light-Blue" or "lightblue"; "default" and "none" mean grey.
    init?(name: String) {
        let key = name.lowercased().filter { $0.isLetter }
        if key == "default" || key == "none" || key == "gray" { self = .grey; return }
        guard let match = Self.allCases.first(where: { $0.rawValue.filter { $0.isLetter } == key }) else { return nil }
        self = match
    }
}
