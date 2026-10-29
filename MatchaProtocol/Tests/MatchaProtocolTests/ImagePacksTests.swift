//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import MatchaProtocol
import Testing

/// The cases of the web client's `imagePacks.test.ts`.
struct ImagePacksTests {
    // MARK: - parseEmojiImages
    
    @Test
    func parsesValidEmojiSortedByShortcode() {
        #expect(ImagePacks.parseEmojiImages(json(#"""
        {"images": {
            "zebra": {"url": "mxc://example.org/z"},
            "apple": {"url": "mxc://example.org/a", "body": "An apple", "info": {"w": 32}},
            "party-parrot": {"url": "mxc://[::1]:8448/abc_DEF-1"}
        }}
        """#)) == [
            CustomEmoji(shortcode: "apple", url: mxc("a"), body: "An apple", info: .init(width: 32)),
            CustomEmoji(shortcode: "party-parrot", url: "mxc://[::1]:8448/abc_DEF-1"),
            CustomEmoji(shortcode: "zebra", url: mxc("z"))
        ])
    }
    
    @Test(arguments: [nil, "null", "1", #""images""#, "[]", #"{"images": []}"#, #"{"images": "x"}"#, #"{"images": null}"#])
    func parsesNothingFromContentThatIsNotAPack(content: String?) {
        #expect(ImagePacks.parseEmojiImages(content.map(json)) == [])
    }
    
    @Test
    func dropsImagesWhoseURLIsNotAPlainMXCURL() {
        let urls: [JSONValue] = ["https://example.org/a.png", "javascript:alert(1)", "data:image/png;base64,AAAA", "MXC://example.org/a",
                                 "mxc://example.org", "mxc://example.org/", "mxc://example.org/a/b", #"mxc://example.org/a" onerror="alert(1)"#,
                                 "mxc://exa mple.org/a", " \(mxc("a"))", mxc(String(repeating: "a", count: 1000))].map(JSONValue.string)
            + [.integer(42), .null, .object(["url": .string(mxc("a"))])]
        var images = JSONObject()
        for (index, url) in urls.enumerated() {
            images["code\(index)"] = .object(["url": url])
        }
        images["ok"] = .object(["url": .string(mxc("ok"))])
        
        #expect(ImagePacks.parseEmojiImages(.object(["images": .object(images)])) == [CustomEmoji(shortcode: "ok", url: mxc("ok"))])
    }
    
    @Test
    func dropsInvalidShortcodesAndImageEntries() {
        let image = JSONValue.object(["url": .string(mxc("a"))])
        let images: JSONObject = [
            "has space": image,
            "co:lon": image,
            "": image,
            // Too long once colons are added, measured in UTF-8 bytes as MSC4027 does.
            String(repeating: "x", count: 99): image,
            String(repeating: "猫", count: 33): image,
            "bidi\u{202E}override": image,
            "bell\u{07}": image,
            "null": .null,
            "array": .array([.string(mxc("a"))]),
            "string": .string(mxc("a")),
            String(repeating: "x", count: 98): .object(["url": .string(mxc("long"))]),
            String(repeating: "猫", count: 32): .object(["url": .string(mxc("cat"))]),
            "ünïcode": .object(["url": .string(mxc("u"))])
        ]
        
        #expect(ImagePacks.parseEmojiImages(.object(["images": .object(images)])) == [
            CustomEmoji(shortcode: "ünïcode", url: mxc("u")),
            CustomEmoji(shortcode: String(repeating: "x", count: 98), url: mxc("long")),
            CustomEmoji(shortcode: String(repeating: "猫", count: 32), url: mxc("cat"))
        ])
    }
    
    @Test
    func dropsOverlongBodiesAndIgnoresBodiesThatAreNotStrings() {
        let images: JSONObject = [
            "long": .object(["url": .string(mxc("a")), "body": .string(String(repeating: "b", count: 1001))]),
            "max": .object(["url": .string(mxc("b")), "body": .string(String(repeating: "b", count: 1000))]),
            "number": .object(["url": .string(mxc("c")), "body": .integer(5)]),
            "empty": .object(["url": .string(mxc("d")), "body": .string("")])
        ]
        
        #expect(ImagePacks.parseEmojiImages(.object(["images": .object(images)])) == [
            CustomEmoji(shortcode: "empty", url: mxc("d")),
            CustomEmoji(shortcode: "max", url: mxc("b"), body: String(repeating: "b", count: 1000)),
            CustomEmoji(shortcode: "number", url: mxc("c"))
        ])
    }
    
    @Test
    func keepsOnlyEmoticonsWithImageUsageOverridingThePacks() {
        let images = #"""
        {"none": {"url": "mxc://example.org/a"}, "empty": {"url": "mxc://example.org/b", "usage": []},
         "emoticon": {"url": "mxc://example.org/c", "usage": ["emoticon"]}, "sticker": {"url": "mxc://example.org/d", "usage": ["sticker"]},
         "both": {"url": "mxc://example.org/e", "usage": ["sticker", "emoticon"]}, "hostile": {"url": "mxc://example.org/f", "usage": "emoticon"}}
        """#
        func codes(_ pack: String) -> [String] {
            ImagePacks.parseEmojiImages(json(#"{"images": \#(images)\#(pack)}"#)).map(\.shortcode)
        }
        
        #expect(codes("") == ["both", "emoticon", "empty", "hostile", "none"])
        #expect(codes(#", "pack": {"usage": ["sticker"]}"#) == ["both", "emoticon"])
        #expect(codes(#", "pack": {"usage": ["emoticon"]}"#) == ["both", "emoticon", "empty", "hostile", "none"])
        #expect(codes(#", "pack": {"usage": "sticker"}"#) == ["both", "emoticon", "empty", "hostile", "none"])
    }
    
    @Test
    func keepsOnlyStickersWithImageUsageOverridingThePacks() {
        let images = #"""
        {"none": {"url": "mxc://example.org/a"}, "empty": {"url": "mxc://example.org/b", "usage": []},
         "emoticon": {"url": "mxc://example.org/c", "usage": ["emoticon"]}, "sticker": {"url": "mxc://example.org/d", "usage": ["sticker"]},
         "both": {"url": "mxc://example.org/e", "usage": ["sticker", "emoticon"]}, "unknown": {"url": "mxc://example.org/f", "usage": ["gif"]}}
        """#
        func codes(_ pack: String) -> [String] {
            ImagePacks.parseImages(json(#"{"images": \#(images)\#(pack)}"#), usage: .sticker).map(\.shortcode)
        }
        
        #expect(codes("") == ["both", "empty", "none", "sticker"])
        #expect(codes(#", "pack": {"usage": ["emoticon"]}"#) == ["both", "sticker"])
        #expect(codes(#", "pack": {"usage": ["sticker"]}"#) == ["both", "empty", "none", "sticker"])
        #expect(codes(#", "pack": {"usage": []}"#) == ["both", "empty", "none", "sticker"])
    }
    
    @Test
    func keepsOnlyTheValidFieldsOfAnImagesInfo() {
        func info(_ info: String) -> PackImageInfo? {
            ImagePacks.parseImages(json(#"{"images": {"s": {"url": "mxc://example.org/s", "info": \#(info)}}}"#), usage: .sticker).first?.info
        }
        
        #expect(info(#"{"w": 512, "h": 256, "mimetype": "image/webp", "size": 31000, "thumbnail_url": "mxc://example.org/t"}"#)
            == PackImageInfo(width: 512, height: 256, mimeType: "image/webp", size: 31000))
        #expect(info(#"{"w": 1.5, "h": -1, "mimetype": "text/html", "size": "12"}"#) == nil)
        #expect(info(#"{"w": 0, "h": 9999999999, "mimetype": "image/png"}"#) == PackImageInfo(mimeType: "image/png"))
        #expect(info(#""big""#) == nil)
        #expect(info("{}") == nil)
    }
    
    // MARK: - emojiPacks
    
    @Test
    func ordersPersonalEnabledRoomAndParentSpacePacksEachOnce() {
        let rooms = [
            room("!room:x", "General", [
                "zz-cinny": pack("b", name: "Cinny pack"),
                "": pack("a"),
                "empty": json(#"{"images": {}}"#),
                "stickers": json(#"{"images": {"s": {"url": "mxc://example.org/s"}}, "pack": {"usage": ["sticker"]}}"#)
            ]),
            room("!space:x", "Space", ["": json(#"{"images": {"c": {"url": "mxc://example.org/c"}}, "pack": {"avatar_url": "mxc://example.org/space", "display_name": "  "}}"#)]),
            room("!other:x", "Other", ["fav": pack("e", name: "Favourites"), "": pack("f")])
        ]
        // !left:x and !invited:x are not joined.
        let joined = Dictionary(uniqueKeysWithValues: rooms.map { ($0.id, $0) })
        
        let packs = ImagePacks.emojiPacks(userContent: json(#"{"images": {"wave": {"url": "mxc://example.org/wave"}}, "pack": {"display_name": "Ignored", "avatar_url": "mxc://example.org/me"}}"#),
                                          emoteRooms: json(#"""
                                          {"rooms": {
                                              "!other:x": {"fav": {}, "missing": {}},
                                              "!invited:x": {"": {}},
                                              "!room:x": {"zz-cinny": {}}
                                          }}
                                          """#),
                                          room: joined["!room:x"],
                                          parentSpaceIDs: ["!left:x", "!space:x", "!room:x", "!unknown:x"],
                                          userPackName: "Your emoji") { joined[$0] }
        
        #expect(packs.map(\.id) == ["user", "!other:x|fav", "!room:x|zz-cinny", "!room:x|", "!space:x|"])
        #expect(packs[0] == EmojiPack(id: "user", kind: .user, name: "Your emoji", avatarURL: mxc("me"), emojis: [CustomEmoji(shortcode: "wave", url: mxc("wave"))]))
        #expect(packs[3] == EmojiPack(id: "!room:x|", kind: .room, roomID: "!room:x", stateKey: "", name: "General", emojis: [CustomEmoji(shortcode: "a", url: mxc("a"))]))
        #expect(packs.map(\.name) == ["Your emoji", "Favourites", "Cinny pack", "General", "Space"])
        #expect(packs[4].avatarURL == mxc("space"))
    }
    
    @Test
    func offersOnlyEnabledPacksWithoutARoom() {
        let other = room("!other:x", "Other", ["fav": pack("e")])
        
        let packs = ImagePacks.emojiPacks(userContent: nil, emoteRooms: json(#"{"rooms": {"!other:x": {"fav": {}}}}"#),
                                          room: nil, parentSpaceIDs: [], userPackName: "Your emoji") { $0 == other.id ? other : nil }
        
        #expect(packs.map(\.id) == ["!other:x|fav"])
    }
    
    @Test(arguments: [#"{"rooms": "x"}"#, #"{"rooms": {"!other:x": "x"}}"#, #"{"rooms": ["!other:x"]}"#, #"{"images": 1}"#])
    func ignoresMalformedAccountData(content: String) {
        let other = room("!other:x", "Other", ["": pack("e")])
        
        let packs = ImagePacks.emojiPacks(userContent: json(content), emoteRooms: json(content),
                                          room: nil, parentSpaceIDs: [], userPackName: "Your emoji") { $0 == other.id ? other : nil }
        
        #expect(packs.isEmpty)
    }
    
    @Test
    func ordersStickerPacksLikeEmojiPacksSkippingDeletedPacksAndEmojiOnlyOnes() {
        let stickers = #"{"images": {"pepe": {"url": "mxc://example.org/pepe", "usage": ["sticker"]}}}"#
        let rooms = [
            room("!room:x", "General", [
                "": pack("a"),
                "emoji-only": json(#"{"images": {"e": {"url": "mxc://example.org/e"}}, "pack": {"usage": ["emoticon"]}}"#),
                "pepe": json(#"{"images": {"pepe": {"url": "mxc://example.org/pepe"}}, "pack": {"usage": ["sticker"], "display_name": "Pepe"}}"#),
                "deleted": json("{}")
            ]),
            room("!space:x", "Space", ["": json(stickers)]),
            room("!other:x", "Other", ["fav": json(stickers), "deleted": json("{}")])
        ]
        let joined = Dictionary(uniqueKeysWithValues: rooms.map { ($0.id, $0) })
        
        let packs = ImagePacks.emojiPacks(userContent: json(stickers),
                                          emoteRooms: json(#"{"rooms": {"!other:x": {"fav": {}, "deleted": {}}}}"#),
                                          room: joined["!room:x"],
                                          parentSpaceIDs: ["!space:x"],
                                          userPackName: "Your stickers",
                                          usage: .sticker) { joined[$0] }
        
        #expect(packs.map(\.id) == ["user", "!other:x|fav", "!room:x|", "!room:x|pepe", "!space:x|"])
        #expect(packs.map(\.name) == ["Your stickers", "Other", "General", "Pepe", "Space"])
        #expect(packs[2].emojis == [CustomEmoji(shortcode: "a", url: mxc("a"))])
    }
    
    // MARK: - stickerContent
    
    @Test
    func buildsAStickerWithItsBodyURLAndInfo() {
        let sticker = CustomEmoji(shortcode: "pepe_happy", url: mxc("pepe"), body: "Happy Pepe", info: .init(width: 512, height: 512, mimeType: "image/webp", size: 31000))
        
        #expect(ImagePacks.stickerContent(sticker, threadRootID: nil) == json(#"""
        {"body": "Happy Pepe", "url": "mxc://example.org/pepe", "info": {"w": 512, "h": 512, "mimetype": "image/webp", "size": 31000}}
        """#))
    }
    
    @Test
    func namesAStickerWithoutBodyByItsShortcodeAndKeepsAnEmptyInfo() {
        #expect(ImagePacks.stickerContent(CustomEmoji(shortcode: "pepe_sad", url: mxc("sad")), threadRootID: nil) == json(#"""
        {"body": "pepe_sad", "url": "mxc://example.org/sad", "info": {}}
        """#))
        #expect(ImagePacks.stickerContent(CustomEmoji(shortcode: "s", url: mxc("s"), info: .init(width: 64)), threadRootID: nil)
            .objectValue?["info"] == json(#"{"w": 64}"#))
    }
    
    @Test
    func sendsAStickerInAThreadFallingBackToAReplyToItsRoot() {
        let content = ImagePacks.stickerContent(CustomEmoji(shortcode: "s", url: mxc("s")), threadRootID: "$root")
        
        #expect(content.objectValue?["m.relates_to"] == json(#"""
        {"rel_type": "m.thread", "event_id": "$root", "is_falling_back": true, "m.in_reply_to": {"event_id": "$root"}}
        """#))
    }
    
    // MARK: - parentSpaceIDs
    
    @Test
    func followsTheRoomsOwnParentsUpThroughNestedSpacesNearestFirst() async {
        let via = #"{"via": ["x"]}"#
        let parents = [
            "!room:x": ["!a:x": json(via), "!b:x": json(#"{"via": ["x"], "canonical": true}"#), "!removed:x": json("{}")],
            "!a:x": ["!top:x": json(via), "!room:x": json(via)],
            "!b:x": ["!top:x": json(via)],
            "!top:x": ["!a:x": json(via)]
        ]
        
        #expect(await ImagePacks.parentSpaceIDs(of: "!room:x") { parents[$0] ?? [:] } == ["!a:x", "!b:x", "!top:x"])
    }
    
    @Test
    func ignoresSpacesThatOnlyListTheRoomAsAChild() async {
        // A space's m.space.child events are never read: only the room's own parents count.
        #expect(await ImagePacks.parentSpaceIDs(of: "!room:x") { _ in [:] } == [])
    }
    
    @Test
    func stopsAfterFiveLevels() async {
        let ids = await ImagePacks.parentSpaceIDs(of: "!0:x") { id in
            let level = Int(id.dropFirst().prefix { $0 != ":" }) ?? 0
            return ["!\(level + 1):x": json(#"{"via": ["x"]}"#)]
        }
        
        #expect(ids == ["!1:x", "!2:x", "!3:x", "!4:x", "!5:x"])
    }
    
    // MARK: - Lookup
    
    @Test
    func findsTheFirstMatchInPackOrder() {
        let packs = [
            EmojiPack(id: "user", kind: .user, name: "Mine", emojis: [CustomEmoji(shortcode: "cat", url: mxc("mine"))]),
            EmojiPack(id: "!r|", kind: .room, name: "Room", emojis: [CustomEmoji(shortcode: "cat", url: mxc("room")), CustomEmoji(shortcode: "dog", url: mxc("dog"))])
        ]
        
        #expect(packs.emoji(shortcode: "cat")?.url == mxc("mine"))
        #expect(packs.emoji(shortcode: "dog")?.url == mxc("dog"))
        #expect(packs.emoji(shortcode: ":dog:") == nil)
        #expect([EmojiPack]().emoji(shortcode: "cat") == nil)
        #expect(packs.emoji(url: mxc("room"))?.shortcode == "cat")
        #expect(packs.emoji(url: mxc("dog"))?.shortcode == "dog")
        #expect(packs.emoji(url: mxc("unknown")) == nil)
    }
    
    // MARK: - Shortcodes
    
    @Test(arguments: [("party parrot.gif", "party_parrot"),
                      ("Cat-Face_2.PNG", "Cat-Face_2"),
                      ("file.name.webp", "file_name"),
                      ("😀.png", "emoji"),
                      (".gif", "emoji"),
                      ("a.png", "a_"),
                      ("_x_.png", "x_"),
                      ("a_😀b.png", "a__b"),
                      ("\(String(repeating: "a", count: 40)).png", String(repeating: "a", count: 32))])
    func turnsAFileNameIntoAShortcode(fileName: String, shortcode: String) {
        #expect(ImagePacks.shortcodeFromFileName(fileName, taken: []) == shortcode)
        #expect(ImagePacks.isValidNewShortcode(shortcode))
    }
    
    @Test
    func addsANumberUntilTheShortcodeIsFree() {
        #expect(ImagePacks.shortcodeFromFileName("cat.png", taken: ["cat"]) == "cat_2")
        #expect(ImagePacks.shortcodeFromFileName("cat.png", taken: ["cat", "cat_2", "cat_3"]) == "cat_4")
        let long = String(repeating: "b", count: 32)
        let result = ImagePacks.shortcodeFromFileName("\(long).gif", taken: [long])
        #expect(result == "\(String(repeating: "b", count: 30))_2")
        #expect(ImagePacks.isValidNewShortcode(result))
    }
    
    @Test(arguments: [("ab", true), ("A-z_09", true), (String(repeating: "x", count: 32), true),
                      ("a", false), (String(repeating: "x", count: 33), false), ("a b", false), ("a:b", false), ("café", false), ("", false)])
    func checksNewShortcodes(shortcode: String, isValid: Bool) {
        #expect(ImagePacks.isValidNewShortcode(shortcode) == isValid)
    }
    
    // MARK: - Pack editing
    
    @Test
    func withImageAddsAnImageAndKeepsUnknownFields() {
        let result = ImagePacks.withImage(packToEdit, shortcode: "new", image: newImage)
        
        #expect(result == json(#"""
        {"images": {"old": {"url": "mxc://example.org/old", "usage": ["emoticon"]}, "other": {"url": "mxc://example.org/other"},
                    "new": {"url": "mxc://example.org/new", "info": {"w": 32, "h": 32, "mimetype": "image/png", "size": 100}}},
         "pack": {"display_name": "Pack", "org.example.extra": true}, "org.example.unknown": {"nested": 1}}
        """#))
    }
    
    @Test
    func withImageReplacesAnImageAndStartsMissingOrMalformedContent() {
        #expect(ImagePacks.withImage(packToEdit, shortcode: "old", image: newImage).objectValue?.object("images")?["old"] == newImage)
        #expect(ImagePacks.withImage(nil, shortcode: "new", image: newImage) == .object(["images": .object(["new": newImage])]))
        #expect(ImagePacks.withImage(json(#"{"images": "x"}"#), shortcode: "new", image: newImage) == .object(["images": .object(["new": newImage])]))
        #expect(ImagePacks.withImage(nil, shortcode: "__proto__", image: newImage) == .object(["images": .object(["__proto__": newImage])]))
    }
    
    @Test
    func withoutImageRemovesOnlyThatImage() {
        #expect(ImagePacks.withoutImage(packToEdit, shortcode: "old") == json(#"""
        {"images": {"other": {"url": "mxc://example.org/other"}},
         "pack": {"display_name": "Pack", "org.example.extra": true}, "org.example.unknown": {"nested": 1}}
        """#))
        #expect(ImagePacks.withoutImage(packToEdit, shortcode: "missing") == packToEdit)
        #expect(ImagePacks.withoutImage(nil, shortcode: "missing") == json(#"{"images": {}}"#))
    }
    
    @Test
    func withRenamedImageMovesTheSameImageToTheNewShortcode() throws {
        let result = try ImagePacks.withRenamedImage(packToEdit, from: "old", to: "renamed")
        
        #expect(result == json(#"""
        {"images": {"renamed": {"url": "mxc://example.org/old", "usage": ["emoticon"]}, "other": {"url": "mxc://example.org/other"}},
         "pack": {"display_name": "Pack", "org.example.extra": true}, "org.example.unknown": {"nested": 1}}
        """#))
        #expect(try ImagePacks.withRenamedImage(packToEdit, from: "old", to: "constructor").objectValue?.object("images")?["constructor"] != nil)
    }
    
    @Test
    func withRenamedImageRefusesTakenOrMissingShortcodes() {
        #expect(throws: ImagePackEditError.shortcodeTaken("other")) { try ImagePacks.withRenamedImage(packToEdit, from: "old", to: "other") }
        #expect(throws: ImagePackEditError.missingImage("missing")) { try ImagePacks.withRenamedImage(packToEdit, from: "missing", to: "new") }
        #expect(throws: ImagePackEditError.missingImage("missing")) { try ImagePacks.withRenamedImage(nil, from: "missing", to: "new") }
        #expect(throws: ImagePackEditError.missingImage("toString")) { try ImagePacks.withRenamedImage(packToEdit, from: "toString", to: "x") }
    }
    
    @Test
    func withRenamedImageReturnsTheContentWhenTheNameIsTheSame() throws {
        #expect(try ImagePacks.withRenamedImage(packToEdit, from: "old", to: "old") == packToEdit)
    }
    
    // MARK: - emoticonHTML
    
    @Test
    func buildsAnInlineEmoticonImage() {
        #expect(ImagePacks.emoticonHTML(url: mxc("a"), shortcode: "wave") == #"<img data-mx-emoticon src="mxc://example.org/a" alt=":wave:" title=":wave:" height="32" />"#)
    }
    
    @Test
    func escapesAttributeValues() {
        #expect(ImagePacks.emoticonHTML(url: #"mxc://x/a" onerror="alert(1)"#, shortcode: #"a"<b>'&"#)
            == #"<img data-mx-emoticon src="mxc://x/a&quot; onerror=&quot;alert(1)" alt=":a&quot;&lt;b&gt;&#39;&amp;:" title=":a&quot;&lt;b&gt;&#39;&amp;:" height="32" />"#)
    }
    
    // MARK: - Helpers
    
    private let packToEdit = json(#"""
    {"images": {"old": {"url": "mxc://example.org/old", "usage": ["emoticon"]}, "other": {"url": "mxc://example.org/other"}},
     "pack": {"display_name": "Pack", "org.example.extra": true}, "org.example.unknown": {"nested": 1}}
    """#)
    private let newImage = json(#"{"url": "mxc://example.org/new", "info": {"w": 32, "h": 32, "mimetype": "image/png", "size": 100}}"#)
    
    private func pack(_ code: String, name: String? = nil) -> JSONValue {
        var content: JSONObject = ["images": .object([code: .object(["url": .string(mxc(code))])])]
        if let name {
            content["pack"] = .object(["display_name": .string(name)])
        }
        return .object(content)
    }
    
    private func room(_ id: String, _ name: String, _ packs: [String: JSONValue]) -> EmojiPackRoom {
        EmojiPackRoom(id: id, name: name, packs: packs)
    }
}

private func mxc(_ id: String) -> String {
    "mxc://example.org/\(id)"
}

private func json(_ text: String) -> JSONValue {
    guard let value = JSONValue(json: text) else {
        Issue.record("Invalid JSON in a test: \(text)")
        return .null
    }
    return value
}
