//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

// The text rules of the Android client, which the fixtures pin: lengths in UTF-16 code units (as in Kotlin and JavaScript),
// Kotlin's `trim()` and `isBlank()`, and the ASCII-only `\s` / `\S` of Java regular expressions.
// Prefixes and containment are tested by code point or code unit, never with String's grapheme-based `hasPrefix` or `contains`.
// Event ids are compared and keyed by code point too (`isSameID`, `CodePointKey`): String's `==` and hashing equate canonically
// equivalent text (U+212A KELVIN SIGN and K, say) where Kotlin compares code units.

// The Kotlin helpers are public for the app, under Kotlin names: upstream's own `String.isBlank` (Foundation's whitespace)
// would silently shadow a package member of the same name in the app.
public extension String {
    /// Kotlin's `trim()`.
    var kotlinTrimmed: String {
        let scalars = unicodeScalars
        guard let start = scalars.firstIndex(where: { !$0.isKotlinWhitespace }) else { return "" }
        let end = scalars.lastIndex { !$0.isKotlinWhitespace } ?? start
        return String(scalars[start...end])
    }
    
    /// Kotlin's `trimStart()`.
    var kotlinTrimmedStart: String {
        String(unicodeScalars.drop(while: \.isKotlinWhitespace))
    }
    
    /// Kotlin's `trimEnd()`.
    var kotlinTrimmedEnd: String {
        let scalars = unicodeScalars
        return scalars.lastIndex { !$0.isKotlinWhitespace }.map { String(scalars[...$0]) } ?? ""
    }
    
    /// Kotlin's `isBlank()`.
    var isKotlinBlank: Bool {
        unicodeScalars.allSatisfy(\.isKotlinWhitespace)
    }
}

extension String {
    var utf16Length: Int {
        utf16.count
    }
    
    /// The same id code point by code point, as Kotlin's `==` compares them.
    func isSameID(_ other: String?) -> Bool {
        other.map { unicodeScalars.elementsEqual($0.unicodeScalars) } ?? false
    }
    
    var containsASCIIWhitespace: Bool {
        unicodeScalars.contains(where: \.isASCIIWhitespace)
    }
    
    /// Every run of ASCII whitespace replaced by one space, like Kotlin's `replace(Regex("\\s+"), " ")`.
    var collapsingASCIIWhitespace: String {
        var result = String.UnicodeScalarView()
        var isInRun = false
        for scalar in unicodeScalars {
            if scalar.isASCIIWhitespace {
                if !isInRun {
                    result.append(" ")
                }
                isInRun = true
            } else {
                result.append(scalar)
                isInRun = false
            }
        }
        return String(result)
    }
    
    /// The first `count` UTF-16 code units, like Kotlin's `take(count)`.
    /// ponytail: a cut through a surrogate pair gives U+FFFD where Kotlin keeps a lone surrogate; no fixture covers it.
    func utf16Prefix(_ count: Int) -> String {
        String(decoding: utf16.prefix(count), as: UTF16.self)
    }
    
    /// Only the characters of `allowed`, between `lengths` UTF-16 code units long.
    func consists(of allowed: (Unicode.Scalar) -> Bool, lengths: ClosedRange<Int>) -> Bool {
        lengths.contains(utf16Length) && unicodeScalars.allSatisfy(allowed)
    }
}

/// An id as a dictionary or set key, equal and hashed code point by code point (see `isSameID`).
struct CodePointKey: Hashable {
    let id: String
    
    init(_ id: String) {
        self.id = id
    }
    
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id.isSameID(rhs.id)
    }
    
    func hash(into hasher: inout Hasher) {
        for scalar in id.unicodeScalars {
            hasher.combine(scalar)
        }
    }
}

extension Unicode.Scalar {
    /// Java's ASCII `\s`: space, tab, line feed, vertical tab, form feed, carriage return.
    var isASCIIWhitespace: Bool {
        switch value {
        case 0x20, 0x09...0x0D: true
        default: false
        }
    }
    
    /// Kotlin's `Char.isWhitespace()`: Unicode space, line and paragraph separators, U+0009–U+000D and U+001C–U+001F.
    public var isKotlinWhitespace: Bool {
        switch value {
        case 0x09...0x0D, 0x1C...0x1F: return true
        default:
            switch properties.generalCategory {
            case .spaceSeparator, .lineSeparator, .paragraphSeparator: return true
            default: return false
            }
        }
    }
    
    var isASCIIAlphanumeric: Bool {
        switch value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: true
        default: false
        }
    }
    
    var isLowercaseHexDigit: Bool {
        switch value {
        case 0x30...0x39, 0x61...0x66: true
        default: false
        }
    }
}
