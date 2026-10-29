//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatchaProtocol
import SwiftSoup
import WysiwygComposer

/// Typed `:code:` of the room's custom emoji sent as inline images (MSC2545), as the web client's `editor/serialize.ts` does:
/// the formatted body gets the `<img>`, the body keeps `:code:`, and code keeps the text.
enum CustomEmojiMessages {
    private static let emote = "/me "
    private static let placeholder = /\u{2045}(\d+)\u{2046}/
    /// The placeholder once markdown percent-encoded it into a link target.
    private static let encodedPlaceholder = /%E2%81%85(\d+)%E2%81%86/.ignoresCase()
    /// What JavaScript's `encodeURI` leaves as it is.
    private static let uriCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789;,/?:@&=+$-_.!~*'()#")
    
    /// The formatted body for a message whose typed `:code:` name custom emoji of `packs`, or nil to send the message unchanged.
    /// - Parameters:
    ///   - markdown: the composer's text, which stays the body.
    ///   - html: the rich text editor's formatted body; nil from the plain composer, whose markdown becomes HTML here.
    static func formattedBody(markdown: String, html: String?, packs: [EmojiPack]) -> String? {
        if let html {
            return replacingTypedEmoji(inHTML: html, packs: packs)
        }
        // The timeline drops "/me " from the start of both bodies, so it stays out of the markdown.
        if markdown.hasPrefix(emote) {
            return formattedBody(markdown: String(markdown.dropFirst(emote.count)), html: nil, packs: packs).map { emote + $0 }
        }
        
        let pieces = ImagePacks.typedEmoji(in: markdown, packs: packs)
        var emojis = [CustomEmoji]()
        // Placeholders rather than markup, as on web: raw <img> can turn the whole message into an HTML block.
        let placeholderMarkdown = pieces.map { piece in
            switch piece {
            case .text(let text):
                return text
            case .emoji(let emoji):
                emojis.append(emoji)
                return "\(ImagePacks.placeholderOpening)\(emojis.count - 1)\(ImagePacks.placeholderClosing)"
            }
        }.joined()
        guard !emojis.isEmpty else { return nil }
        
        // The rich text editor's markdown parser, as the SDK's content from markdown can't be read back.
        let model = newComposerModel()
        guard (try? model.setContentFromMarkdown(markdown: placeholderMarkdown)) != nil else { return nil }
        return restoringEmoji(in: model.getContentAsMessageHtml(), emojis: emojis)
    }
    
    /// A formatted body for the rich text editor, which drops images: each custom emoji becomes its `:code:` again.
    static func editableHTML(_ html: String) -> String {
        guard let found = emoticonImages(html) else { return html }
        for image in found.images {
            if let text = editedEmoji(image).map({ ":\($0.shortcode):" }) ?? Emoticons.emoticon(image)?.text {
                try? image.replaceWith(TextNode(text, nil))
            }
        }
        return serialize(found.document) ?? html
    }
    
    /// The custom emoji a message being edited shows, as a pack to look its `:code:` up in before the room's: saving the edit
    /// keeps each image even when the room's packs no longer have it, as the web client's editor keeps them.
    static func editedPack(of item: EventBasedMessageTimelineItemProtocol) -> EmojiPack? {
        let html: String? = switch item.contentType {
        case .text(let content): content.formattedBodyHTMLString
        case .emote(let content): content.formattedBodyHTMLString
        case .audio(let content), .voice(let content): content.formattedCaptionHTMLString
        case .file(let content): content.formattedCaptionHTMLString
        case .image(let content): content.formattedCaptionHTMLString
        case .video(let content): content.formattedCaptionHTMLString
        case .gallery(let content): content.formattedCaptionHTMLString
        case .notice, .location: nil
        }
        guard let found = html.flatMap(emoticonImages) else { return nil }
        let emojis = found.images.compactMap(editedEmoji)
        return emojis.isEmpty ? nil : EmojiPack(id: "edited", kind: .room, name: "", emojis: emojis)
    }
    
    // MARK: - Private
    
    /// The custom emoji images of a formatted body, with the document that holds them.
    private static func emoticonImages(_ html: String) -> (document: Document, images: [Element])? {
        guard html.contains("mxc://"), let document = parse(html), let body = document.body() else { return nil }
        return (document, Emoticons.emoticonImages(in: body))
    }
    
    /// A custom emoji image as the web client's editor reads it: named by its title (MSC2545's shortcode), else its alt text,
    /// without colons, when a pack could hold it.
    private static func editedEmoji(_ image: Element) -> CustomEmoji? {
        let name = [try? image.attr("title"), try? image.attr("alt")].lazy.compactMap(\.self).first { !$0.isEmpty } ?? ""
        var shortcode = name.unicodeScalars[...]
        if shortcode.first == ":" {
            shortcode.removeFirst()
        }
        if shortcode.last == ":" {
            shortcode.removeLast()
        }
        guard let url = try? image.attr("src"), ImagePacks.isMXC(url), ImagePacks.isValidShortcode(String(shortcode)) else { return nil }
        return CustomEmoji(shortcode: String(shortcode), url: url)
    }
    
    /// The editor's HTML with typed `:code:` outside code as images.
    private static func replacingTypedEmoji(inHTML html: String, packs: [EmojiPack]) -> String? {
        guard let document = parse(html) else { return nil }
        var isChanged = false
        for node in textNodes(in: document) where !isInCode(node) {
            let pieces = ImagePacks.typedEmoji(in: node.getWholeText(), packs: packs)
            guard pieces.contains(where: {
                if case .emoji = $0 {
                    true
                } else {
                    false
                }
            }) else { continue }
            for piece in pieces {
                switch piece {
                case .text(let text):
                    _ = try? node.before(TextNode(text, nil))
                case .emoji(let emoji):
                    _ = try? node.before(ImagePacks.emoticonHTML(url: emoji.url, shortcode: emoji.shortcode))
                }
            }
            try? node.remove()
            isChanged = true
        }
        return isChanged ? serialize(document) : nil
    }
    
    /// Web's `restoreEmoticons`: placeholders become images, or their `:code:` inside code and attributes (link targets, image
    /// alt text). A placeholder without its emoji is removed so none is sent.
    private static func restoringEmoji(in html: String, emojis: [CustomEmoji]) -> String? {
        guard let document = parse(html) else { return nil }
        let text = { (number: Substring) in Int(number).flatMap { emojis.indices.contains($0) ? ":\(emojis[$0].shortcode):" : nil } ?? "" }
        
        for element in (try? document.body()?.getAllElements()) ?? Elements() {
            for attribute in element.getAttributes()?.asList() ?? [] {
                let value = attribute.getValue()
                let restored = value
                    .replacing(placeholder) { text($0.output.1) }
                    .replacing(encodedPlaceholder) { text($0.output.1).addingPercentEncoding(withAllowedCharacters: uriCharacters) ?? "" }
                if restored != value {
                    _ = try? element.attr(attribute.getKey(), restored)
                }
            }
        }
        
        for node in textNodes(in: document) {
            let whole = node.getWholeText()
            let matches = whole.matches(of: placeholder)
            guard !matches.isEmpty else { continue }
            let inCode = isInCode(node)
            var textStart = whole.startIndex
            for match in matches {
                _ = try? node.before(TextNode(String(whole[textStart..<match.range.lowerBound]), nil))
                if let number = Int(match.output.1), emojis.indices.contains(number) {
                    let emoji = emojis[number]
                    if inCode {
                        _ = try? node.before(TextNode(":\(emoji.shortcode):", nil))
                    } else {
                        _ = try? node.before(ImagePacks.emoticonHTML(url: emoji.url, shortcode: emoji.shortcode))
                    }
                }
                textStart = match.range.upperBound
            }
            _ = try? node.before(TextNode(String(whole[textStart...]), nil))
            try? node.remove()
        }
        return serialize(document)
    }
    
    /// Callers keep the document while using its nodes: SwiftSoup's links to parents are weak.
    private static func parse(_ html: String) -> Document? {
        guard let document = try? SwiftSoup.parseBodyFragment(html) else { return nil }
        document.outputSettings().prettyPrint(pretty: false)
        return document
    }
    
    private static func serialize(_ document: Document) -> String? {
        try? document.body()?.html()
    }
    
    private static func textNodes(in document: Document) -> [TextNode] {
        document.body().map(textNodes(under:)) ?? []
    }
    
    private static func textNodes(under node: Node) -> [TextNode] {
        node.getChildNodes().flatMap { child in (child as? TextNode).map { [$0] } ?? textNodes(under: child) }
    }
    
    private static func isInCode(_ node: Node) -> Bool {
        sequence(first: node) { $0.parent() }.contains { ["code", "pre"].contains($0.nodeName()) }
    }
}
