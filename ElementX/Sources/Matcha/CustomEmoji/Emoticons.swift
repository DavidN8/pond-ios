//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import SwiftSoup

/// MSC2545 custom emoji in a formatted body, `<img data-mx-emoticon src="mxc://…" alt=":code:">`, as the web client reads them.
/// The NSE builds this file too, for its notification text.
nonisolated enum Emoticons {
    private static let attribute = "data-mx-emoticon"
    
    /// The mxc URL of a custom emoji and the text it reads as, when `element` is one the timeline draws inline.
    static func emoticon(_ element: Element) -> (url: URL, text: String)? {
        guard element.tagName().lowercased() == "img", let source = try? element.attr("src"), source.hasPrefix("mxc://"),
              let url = URL(string: source) else {
            return nil
        }
        // Either attribute names the emoji, as on the web client.
        let names = [try? element.attr("alt"), try? element.attr("title")].compactMap(\.self)
        // ponytail: the SDK's timeline sanitizes formatted bodies, and ruma-html keeps only width, height, alt, title and src on
        // an image, so an mxc image named `:code:` is one too. Drop this once the sanitizer keeps `data-mx-emoticon`.
        guard element.hasAttr(attribute) || names.contains(where: isShortcodeName) else { return nil }
        return (url, names.first { !$0.isEmpty } ?? "[img]")
    }
    
    /// The custom emoji images in `element`.
    static func emoticonImages(in element: Element) -> [Element] {
        ((try? element.select("img").array()) ?? []).filter { emoticon($0) != nil }
    }
    
    /// Whether a formatted body is made only of custom emoji, emoji and whitespace, with at least one custom emoji: the web
    /// client's rule for drawing it big. Any other markup, line breaks aside, keeps it normal size.
    static func isEmoticonsOnly(html: String) -> Bool {
        guard html.contains("mxc://"), let body = try? SwiftSoup.parseBodyFragment(html).body() else { return false }
        let images = emoticonImages(in: body)
        images.forEach { try? $0.remove() }
        _ = try? body.select("br").remove()
        guard !images.isEmpty, body.children().isEmpty(), let text = try? body.text() else { return false }
        return text.allSatisfy { $0.isWhitespace || $0 == "\u{200B}" || $0.isEmoji }
    }
}

/// Marks an inline custom emoji's attachment with its alt text, so that a text's custom emoji are found without converting it.
nonisolated enum EmoticonAttribute: AttributedStringKey {
    typealias Value = String
    static let name = "MXEmoticonAttribute"
}

nonisolated extension PlainMentionBuilder {
    /// Plain text keeps a custom emoji's alt text.
    func handleEmoticon(for attributedString: NSMutableAttributedString, in range: NSRange, url: URL, altText: String) { }
}

/// `:code:` as MSC2545 names an emoji: a shortcode between colons, without whitespace or another colon.
private nonisolated func isShortcodeName(_ name: String) -> Bool {
    name.count > 2 && name.first == ":" && name.last == ":" && !name.dropFirst().dropLast().contains { $0 == ":" || $0.isWhitespace }
}

private nonisolated extension Character {
    /// Drawn as an emoji: presented as one by default, or a sequence such as a keycap or an emoji variation.
    var isEmoji: Bool {
        guard let first = unicodeScalars.first else { return false }
        return first.properties.isEmojiPresentation || (first.properties.isEmoji && unicodeScalars.count > 1)
    }
}
