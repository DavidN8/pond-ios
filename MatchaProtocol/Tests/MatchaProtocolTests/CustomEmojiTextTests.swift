//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import MatchaProtocol
import Testing

/// The cases of the web client's `customEmoji.test.ts` and of the custom emoji in `EmojiProvider.test.ts`.
struct CustomEmojiTextTests {
    private let packs = [EmojiPack(id: "user", kind: .user, name: "Yours", emojis: [emoji("a")]),
                         EmojiPack(id: "!r:hs.tld|", kind: .room, roomID: "!r:hs.tld", stateKey: "", name: "Room",
                                   emojis: [emoji("a", url: "mxc://hs.tld/other_a"), emoji("b")])]
    
    // MARK: - Typed shortcodes
    
    @Test
    func convertsATypedShortcodeTakingTheFirstPacksEmoji() {
        #expect(ImagePacks.typedEmoji(in: "hi :a: there", packs: packs) == [.text("hi "), .emoji(emoji("a")), .text(" there")])
    }
    
    @Test
    func convertsAdjacentShortcodes() {
        #expect(ImagePacks.typedEmoji(in: "::a::b::", packs: packs) == [.text(":"), .emoji(emoji("a")), .emoji(emoji("b")), .text(":")])
    }
    
    @Test
    func leavesUnknownAndPartialShortcodesButNotAKnownOneSharingTheirColon() {
        #expect(ImagePacks.typedEmoji(in: ":nope: :a :x:b:", packs: packs) == [.text(":nope: :a :x"), .emoji(emoji("b"))])
    }
    
    @Test
    func doesNothingWithoutPacks() {
        #expect(ImagePacks.typedEmoji(in: ":a:", packs: []) == [.text(":a:")])
        #expect(ImagePacks.typedEmoji(in: "", packs: packs) == [.text("")])
    }
    
    @Test
    func neverMatchesAcrossWhitespace() {
        #expect(ImagePacks.typedEmoji(in: ":a\u{00A0}: :\u{FEFF}b: :b:", packs: packs) == [.text(":a\u{00A0}: :\u{FEFF}b: "), .emoji(emoji("b"))])
        #expect(ImagePacks.typedEmoji(in: "a:b:c", packs: packs) == [.text("a"), .emoji(emoji("b")), .text("c")])
    }
    
    @Test
    func keepsTextAroundTheEmojiScalarByScalar() {
        // A combining accent after an emoji stays as typed rather than joining the closing colon.
        #expect(ImagePacks.typedEmoji(in: "é:a:\u{0301}", packs: packs) == [.text("é"), .emoji(emoji("a")), .text("\u{0301}")])
    }
    
    @Test(arguments: [(":a:", true), ("x :pepe.happy: y", true), (":a", false), ("::", false), (": a:", false), ("a: b", false)])
    func spotsTextShapedLikeATypedShortcode(text: String, expected: Bool) {
        #expect(ImagePacks.mayContainTypedEmoji(text) == expected)
    }
    
    // MARK: - Suggestions
    
    @Test
    func suggestsAnExactMatchFirstThenLongerOnesOncePerImage() {
        let packs = [EmojiPack(id: "user", kind: .user, name: "Yours", emojis: [emoji("heart"), emoji("heartcat")]),
                     EmojiPack(id: "!a|", kind: .room, name: "A", emojis: [emoji("heart"), emoji("other"), emoji("Heart_eyes", url: "mxc://hs.tld/he")])]
        
        #expect(ImagePacks.suggestions(for: "heart", in: packs).map(\.shortcode) == ["heart", "heartcat", "Heart_eyes"])
        #expect(ImagePacks.suggestions(for: "HEARTC", in: packs).map(\.shortcode) == ["heartcat"])
        // A closing colon asks for the exact shortcode.
        #expect(ImagePacks.suggestions(for: "heart:", in: packs).map(\.shortcode) == ["heart"])
    }
    
    @Test
    func suggestsAnExactMatchBeforeLongerShortcodesFromEarlierPacks() {
        let packs = [EmojiPack(id: "user", kind: .user, name: "Yours", emojis: (0..<9).map { emoji("blob_\($0)") }),
                     EmojiPack(id: "!a|", kind: .room, name: "A", emojis: [emoji("blob")])]
        
        #expect(ImagePacks.suggestions(for: "blob", in: packs).first?.shortcode == "blob")
    }
    
    @Test
    func suggestsShortcodesWithPunctuationAndAccentsByPrefixOnly() {
        let packs = [EmojiPack(id: "user", kind: .user, name: "Yours", emojis: [emoji("pepe.happy"), emoji("café"), emoji("happy")])]
        
        #expect(ImagePacks.suggestions(for: "pepe.h", in: packs).map(\.shortcode) == ["pepe.happy"])
        #expect(ImagePacks.suggestions(for: "café", in: packs).map(\.shortcode) == ["café"])
        #expect(ImagePacks.suggestions(for: "app", in: packs).isEmpty)
        #expect(ImagePacks.suggestions(for: "", in: packs).isEmpty)
    }
    
    @Test
    func suggestsAtMostEight() {
        let packs = [EmojiPack(id: "user", kind: .user, name: "Yours", emojis: (0..<10).map { emoji("blob\($0)") })]
        
        #expect(ImagePacks.suggestions(for: "blob", in: packs).count == 8)
    }
    
    // MARK: - Reactions
    
    @Test
    func namesACustomEmojiReactionUnderBothShortcodeKeys() {
        #expect(ImagePacks.reactionShortcodeContent(":party:")
            == JSONValue(json: #"{"shortcode": ":party:", "com.beeper.reaction.shortcode": ":party:"}"#))
    }
}

private func emoji(_ shortcode: String, url: String? = nil) -> CustomEmoji {
    CustomEmoji(shortcode: shortcode, url: url ?? "mxc://hs.tld/\(shortcode)")
}
