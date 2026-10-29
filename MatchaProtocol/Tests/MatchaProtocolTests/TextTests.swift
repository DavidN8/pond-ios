//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

// Not @testable: the app reads these helpers as public API.
import MatchaProtocol
import Testing

struct TextTests {
    @Test
    func theKotlinTrimRemovesKotlinsWhitespaceOnly() {
        // U+001C is whitespace to Kotlin, not to Foundation; U+0085 the other way round; U+00A0 to both.
        let text = "\u{1C}\u{A0} a \u{85}\t\u{2029}"
        #expect(text.kotlinTrimmed == "a \u{85}")
        #expect(text.kotlinTrimmedStart == "a \u{85}\t\u{2029}")
        #expect(text.kotlinTrimmedEnd == "\u{1C}\u{A0} a \u{85}")
        #expect(" \u{1C}\u{2028}".isKotlinBlank && "".isKotlinBlank && !"\u{85}".isKotlinBlank)
        #expect(" \u{2028}\u{1F}".kotlinTrimmed.isEmpty && " ".kotlinTrimmedStart.isEmpty && " ".kotlinTrimmedEnd.isEmpty)
        #expect(("\u{1F}" as Unicode.Scalar).isKotlinWhitespace && !("\u{85}" as Unicode.Scalar).isKotlinWhitespace)
    }
}
