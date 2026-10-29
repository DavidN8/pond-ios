//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// A piece of message text: as typed, or a typed `:shortcode:` naming an available custom emoji.
public enum TypedEmojiPiece: Sendable, Equatable {
    case text(String)
    case emoji(CustomEmoji)
}

/// Sending custom emoji, the rules of the web client's `editor/customEmoji.ts`, `editor/serialize.ts`, the custom emoji of
/// `autocomplete/EmojiProvider.tsx` and `reactionShortcode.ts`.
public extension ImagePacks {
    /// Opens and closes the placeholder standing for the nth custom emoji while markdown becomes HTML (web's `⁅N⁆`).
    static let placeholderOpening = "\u{2045}"
    static let placeholderClosing = "\u{2046}"
    
    /// Whether the text has anything shaped like a typed `:shortcode:`, before reading packs to look it up.
    static func mayContainTypedEmoji(_ text: String) -> Bool {
        !typedShortcodes(in: text.unicodeScalars) { _ in true }.isEmpty
    }
    
    /// The text split around every fully typed `:shortcode:` that names an emoji of `packs`, the first in pack order. As on the
    /// web client, the closing colon of an unknown shortcode may open the next one. Without any, the text is one piece.
    static func typedEmoji(in text: String, packs: [EmojiPack]) -> [TypedEmojiPiece] {
        var emojis = [String: CustomEmoji]()
        for emoji in packs.lazy.flatMap(\.emojis) where emojis[emoji.shortcode] == nil {
            emojis[emoji.shortcode] = emoji
        }
        let scalars = text.unicodeScalars
        var pieces = [TypedEmojiPiece]()
        var textStart = scalars.startIndex
        for (range, shortcode) in typedShortcodes(in: scalars, isKnown: { emojis[$0] != nil }) {
            if textStart < range.lowerBound {
                pieces.append(.text(String(scalars[textStart..<range.lowerBound])))
            }
            if let emoji = emojis[shortcode] {
                pieces.append(.emoji(emoji))
            }
            textStart = range.upperBound
        }
        if textStart < scalars.endIndex || pieces.isEmpty {
            pieces.append(.text(String(scalars[textStart...])))
        }
        return pieces
    }
    
    /// The custom emoji offered for a typed `:query` (the text after the colon, maybe with a closing colon), as the web client's
    /// EmojiProvider: those whose `:shortcode:` contains `:query` ignoring case, so shortcodes starting with it, the exact match
    /// first, then shorter shortcodes, each image once.
    static func suggestions(for query: String, in packs: [EmojiPack], limit: Int = 8) -> [CustomEmoji] {
        let typed = ":" + query.lowercased()
        let trimmed = query.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        guard typed.count > 1 else { return [] }
        let matches = packs.lazy.flatMap(\.emojis).filter { ":\($0.shortcode.lowercased()):".contains(typed) }
        // Sorting the offsets too keeps pack order among equals, as lodash's stable `sortBy` does.
        let sorted = matches.enumerated().sorted { first, second in
            let firstKey = (first.element.shortcode.lowercased() == trimmed ? 0 : 1, first.element.shortcode.utf16.count, first.offset)
            let secondKey = (second.element.shortcode.lowercased() == trimmed ? 0 : 1, second.element.shortcode.utf16.count, second.offset)
            return firstKey < secondKey
        }
        var urls = Set<String>()
        return Array(sorted.map(\.element).filter { urls.insert($0.url).inserted }.prefix(limit))
    }
    
    /// The content a custom emoji reaction adds to its `m.relates_to` (MSC4027), under both keys as some clients read only one.
    /// - Parameter shortcode: with its colons, `:code:`.
    static func reactionShortcodeContent(_ shortcode: String) -> JSONValue {
        .object(["shortcode": .string(shortcode), "com.beeper.reaction.shortcode": .string(shortcode)])
    }
    
    // MARK: - Private
    
    /// The ranges and names of the typed `:shortcode:` (web's `/:([^\s:]+):/g`) that `isKnown` accepts.
    private static func typedShortcodes(in scalars: String.UnicodeScalarView,
                                        isKnown: (String) -> Bool) -> [(range: Range<String.Index>, shortcode: String)] {
        var found = [(range: Range<String.Index>, shortcode: String)]()
        var searchStart = scalars.startIndex
        while let opening = scalars[searchStart...].firstIndex(of: ":") {
            let nameStart = scalars.index(after: opening)
            let nameEnd = scalars[nameStart...].firstIndex { $0 == ":" || $0.isJavaScriptWhitespace } ?? scalars.endIndex
            guard nameEnd > nameStart, nameEnd < scalars.endIndex, scalars[nameEnd] == ":" else {
                // No shortcode opens here; the next colon may open one.
                searchStart = nameStart
                continue
            }
            let shortcode = String(scalars[nameStart..<nameEnd])
            if isKnown(shortcode) {
                let end = scalars.index(after: nameEnd)
                found.append((opening..<end, shortcode))
                searchStart = end
            } else {
                // The closing colon of an unknown shortcode may open the next one.
                searchStart = nameEnd
            }
        }
        return found
    }
}

private extension Unicode.Scalar {
    /// JavaScript's Unicode `\s`: White_Space plus U+FEFF.
    var isJavaScriptWhitespace: Bool {
        properties.isWhitespace || self == "\u{FEFF}"
    }
}
