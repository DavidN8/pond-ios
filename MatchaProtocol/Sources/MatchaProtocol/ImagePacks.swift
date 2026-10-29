//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// What an MSC2545 pack image is for.
public enum ImageUsage: String, Sendable {
    case emoticon
    case sticker
}

/// The valid fields of a pack image's `info`, which a sticker event carries.
public struct PackImageInfo: Sendable, Hashable {
    public let width: Int?
    public let height: Int?
    public let mimeType: String?
    public let size: Int?
    
    public init(width: Int? = nil, height: Int? = nil, mimeType: String? = nil, size: Int? = nil) {
        self.width = width
        self.height = height
        self.mimeType = mimeType
        self.size = size
    }
}

/// A validated image of an MSC2545 pack: a custom emoji, or a sticker in sticker packs.
public struct CustomEmoji: Sendable, Hashable {
    /// Without colons.
    public let shortcode: String
    /// The mxc URL of the image.
    public let url: String
    public let body: String?
    /// Nil when the image has no valid `info` field.
    public let info: PackImageInfo?
    
    public init(shortcode: String, url: String, body: String? = nil, info: PackImageInfo? = nil) {
        self.shortcode = shortcode
        self.url = url
        self.body = body
        self.info = info
    }
}

/// Custom emoji, or stickers, from one pack, ready to offer in a room.
public struct EmojiPack: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case user
        case room
    }
    
    /// "user" for the personal pack, otherwise "<room id>|<state key>".
    public let id: String
    public let kind: Kind
    public let roomID: String?
    public let stateKey: String?
    public let name: String
    /// The mxc URL of the pack avatar.
    public let avatarURL: String?
    public let emojis: [CustomEmoji]
    
    public init(id: String, kind: Kind, roomID: String? = nil, stateKey: String? = nil, name: String, avatarURL: String? = nil, emojis: [CustomEmoji]) {
        self.id = id
        self.kind = kind
        self.roomID = roomID
        self.stateKey = stateKey
        self.name = name
        self.avatarURL = avatarURL
        self.emojis = emojis
    }
}

/// A room or space whose packs may apply: its name and the contents of its `im.ponies.room_emotes` state by state key.
public struct EmojiPackRoom: Sendable {
    public let id: String
    public let name: String
    public let packs: [String: JSONValue]
    
    public init(id: String, name: String, packs: [String: JSONValue]) {
        self.id = id
        self.name = name
        self.packs = packs
    }
}

public enum ImagePackEditError: Error, Equatable {
    case missingImage(String)
    case shortcodeTaken(String)
}

/// MSC2545 custom emoji packs, the rules of the web client's `utils/matcha/imagePacks.ts`.
public enum ImagePacks {
    /// Room or space pack; the empty state key is the pack Matcha manages.
    public static let roomEmotesEventType = "im.ponies.room_emotes"
    /// Personal pack, in global account data.
    public static let userEmotesEventType = "im.ponies.user_emotes"
    /// Global account data listing room packs the user enabled everywhere.
    public static let emoteRoomsEventType = "im.ponies.emote_rooms"
    /// Attribute marking an inline custom emoji image in a formatted body.
    public static let emoticonAttribute = "data-mx-emoticon"
    public static let spaceParentEventType = "m.space.parent"
    public static let stickerEventType = "m.sticker"
    
    // MSC4027 caps a reaction's shortcode at 100 bytes, colons included.
    private static let maxShortcodeBytes = 98
    // How far up nested spaces to look for packs.
    private static let maxSpaceDepth = 5
    private static let maxTextLength = 1000
    private static let maxNewShortcodeLength = 32
    
    // MARK: - Parsing
    
    /// Validated emoji of a pack, sorted by shortcode; malformed images are skipped so other clients' data cannot break us.
    public static func parseEmojiImages(_ content: JSONValue?) -> [CustomEmoji] {
        parseImages(content, usage: .emoticon)
    }
    
    /// Validated images of a pack for `usage`, sorted by shortcode. An image's own non-empty usage replaces the pack's, and no usage
    /// anywhere means every usage.
    public static func parseImages(_ content: JSONValue?, usage wanted: ImageUsage) -> [CustomEmoji] {
        guard let content = content?.objectValue, let images = content.object("images") else { return [] }
        let packUsage = usages(content.object("pack")?["usage"])
        var emojis = [CustomEmoji]()
        for (shortcode, image) in images {
            guard isValidShortcode(shortcode), let image = image.objectValue, let url = image.string("url"), isMXC(url) else { continue }
            let body = image.string("body")
            if let body, body.utf16.count > maxTextLength {
                continue
            }
            let imageUsage = usages(image["usage"])
            let usage = imageUsage.isEmpty ? packUsage : imageUsage
            guard usage.isEmpty || usage.contains(.string(wanted.rawValue)) else { continue }
            emojis.append(CustomEmoji(shortcode: shortcode, url: url, body: body?.isEmpty == false ? body : nil, info: imageInfo(image.object("info"))))
        }
        return emojis.sorted { $0.shortcode.localizedCompare($1.shortcode) == .orderedAscending }
    }
    
    /// A plain mxc URL by the spec's server name and media ID grammar, which also keeps quotes and markup out of HTML attributes.
    public static func isMXC(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        let scheme = Array("mxc://".utf8)
        guard bytes.count <= maxTextLength, bytes.starts(with: scheme) else { return false }
        let rest = bytes.dropFirst(scheme.count)
        guard let slash = rest.firstIndex(of: UInt8(ascii: "/")) else { return false }
        let server = rest[..<slash]
        let mediaID = rest[(slash + 1)...]
        return !server.isEmpty && !mediaID.isEmpty
            && server.allSatisfy { isASCIIAlphanumeric($0) || ".:[]-".utf8.contains($0) }
            && mediaID.allSatisfy { isASCIIAlphanumeric($0) || "_-".utf8.contains($0) }
    }
    
    /// A shortcode other clients may have stored: no spaces or colons, nor control or format characters such as bidi overrides,
    /// which would garble the body.
    public static func isValidShortcode(_ shortcode: String) -> Bool {
        !shortcode.isEmpty && shortcode.utf8.count <= maxShortcodeBytes && shortcode.unicodeScalars.allSatisfy { scalar in
            // JavaScript's Unicode `\s` is White_Space plus U+FEFF, which is a format character anyway.
            scalar != ":" && !scalar.properties.isWhitespace && ![.control, .format].contains(scalar.properties.generalCategory)
        }
    }
    
    /// A shortcode Matcha writes when adding or renaming an emoji: `^[A-Za-z0-9_-]{2,32}$`.
    public static func isValidNewShortcode(_ shortcode: String) -> Bool {
        (2...maxNewShortcodeLength).contains(shortcode.utf8.count) && shortcode.utf8.allSatisfy(isNewShortcodeByte)
    }
    
    // MARK: - Packs of a room
    
    /// The spaces whose packs apply in a room, nearest first: those the room names in its own `m.space.parent` state with a `via`
    /// array, then theirs, up to five levels. A space cannot add its packs to a room just by listing it as a child.
    /// - Parameter parents: a room's `m.space.parent` contents by state key.
    public static func parentSpaceIDs(of roomID: String,
                                      isolation: isolated (any Actor)? = #isolation,
                                      parents: (String) async -> [String: JSONValue]) async -> [String] {
        var found: Set = [roomID]
        var ordered = [String]()
        var level = [roomID]
        for _ in 0..<maxSpaceDepth where !level.isEmpty {
            var next = [String]()
            for id in level {
                // ponytail: a room's parents in state key order, where the web client keeps the store's order.
                for (parentID, content) in await parents(id).sorted(by: { $0.key < $1.key }) {
                    guard !parentID.isEmpty, !found.contains(parentID), case .array = content.objectValue?["via"] else { continue }
                    found.insert(parentID)
                    ordered.append(parentID)
                    next.append(parentID)
                }
            }
            level = next
        }
        return ordered
    }
    
    /// The rooms and state keys of the packs the user enabled everywhere (`im.ponies.emote_rooms`), in a stable order.
    /// ponytail: sorted by room ID and state key, as the order of a JSON object isn't kept; the web client keeps the stored order.
    public static func enabledPacks(_ emoteRooms: JSONValue?) -> [(roomID: String, stateKeys: [String])] {
        guard let rooms = emoteRooms?.objectValue?.object("rooms") else { return [] }
        return rooms.keys.sorted().compactMap { roomID in
            rooms[roomID]?.objectValue.map { (roomID, $0.keys.sorted()) }
        }
    }
    
    /// Custom emoji packs usable in a room, or its sticker packs with `usage: .sticker`, in picker order: the personal pack, packs
    /// the user enabled everywhere (so they keep their place from room to room, as MSC2545 asks), the room's own packs, then packs
    /// of its parent spaces. Only joined parent and enabled rooms count, each pack appears once, and packs without images of that
    /// usage are left out, as are deleted ones, whose content is `{}`.
    /// - Parameter joinedRoom: a room the user has joined, or nil.
    public static func emojiPacks(userContent: JSONValue?,
                                  emoteRooms: JSONValue?,
                                  room: EmojiPackRoom?,
                                  parentSpaceIDs: [String],
                                  userPackName: String,
                                  usage: ImageUsage = .emoticon,
                                  joinedRoom: (String) -> EmojiPackRoom?) -> [EmojiPack] {
        var packs = [EmojiPack]()
        let userEmojis = parseImages(userContent, usage: usage)
        if !userEmojis.isEmpty {
            packs.append(EmojiPack(id: "user", kind: .user, name: userPackName, avatarURL: packDetails(userContent).avatarURL, emojis: userEmojis))
        }
        
        var seen = Set<String>()
        func addPack(_ packRoom: EmojiPackRoom, stateKey: String) {
            guard let content = packRoom.packs[stateKey] else { return }
            let id = "\(packRoom.id)|\(stateKey)"
            guard seen.insert(id).inserted else { return }
            let emojis = parseImages(content, usage: usage)
            guard !emojis.isEmpty else { return }
            let details = packDetails(content)
            packs.append(EmojiPack(id: id, kind: .room, roomID: packRoom.id, stateKey: stateKey,
                                   name: details.name ?? packRoom.name, avatarURL: details.avatarURL, emojis: emojis))
        }
        // The managed pack (empty state key) sorts first; other clients' packs follow in a stable order.
        func addRoomPacks(_ packRoom: EmojiPackRoom?) {
            guard let packRoom else { return }
            for stateKey in packRoom.packs.keys.sorted(by: { $0.localizedCompare($1) == .orderedAscending }) {
                addPack(packRoom, stateKey: stateKey)
            }
        }
        
        for (roomID, stateKeys) in enabledPacks(emoteRooms) {
            guard let packRoom = joinedRoom(roomID) else { continue }
            for stateKey in stateKeys {
                addPack(packRoom, stateKey: stateKey)
            }
        }
        addRoomPacks(room)
        for spaceID in parentSpaceIDs {
            addRoomPacks(joinedRoom(spaceID))
        }
        return packs
    }
    
    // MARK: - Pack edits
    
    /// A new shortcode from an uploaded file's name, unique among `taken`.
    public static func shortcodeFromFileName(_ fileName: String, taken: Set<String>) -> String {
        var scalars = fileName.unicodeScalars[...]
        if let dot = scalars.lastIndex(of: ".") {
            scalars = scalars[..<dot]
        }
        // Each run of other characters becomes one underscore.
        var cleaned = ""
        var isInRun = false
        for scalar in scalars {
            if scalar.isASCII, isNewShortcodeByte(UInt8(scalar.value)) {
                cleaned.unicodeScalars.append(scalar)
                isInRun = false
            } else if !isInRun {
                cleaned += "_"
                isInRun = true
            }
        }
        cleaned = String(cleaned.drop { $0 == "_" }.reversed().drop { $0 == "_" }.reversed())
        var base = String((cleaned.isEmpty ? "emoji" : cleaned).prefix(maxNewShortcodeLength))
        if base.count < 2 {
            base += String(repeating: "_", count: 2 - base.count)
        }
        var shortcode = base
        var number = 2
        while taken.contains(shortcode) {
            let suffix = "_\(number)"
            shortcode = base.prefix(maxNewShortcodeLength - suffix.count) + suffix
            number += 1
        }
        return shortcode
    }
    
    /// Pack content with the image added or replaced, keeping every other field of the content and of its pack.
    public static func withImage(_ content: JSONValue?, shortcode: String, image: JSONValue) -> JSONValue {
        var images = copyImages(content)
        images[shortcode] = image
        return withImages(content, images)
    }
    
    /// Pack content without the image.
    public static func withoutImage(_ content: JSONValue?, shortcode: String) -> JSONValue {
        var images = copyImages(content)
        images[shortcode] = nil
        return withImages(content, images)
    }
    
    /// Pack content with an image moved to a new shortcode, keeping the image as stored. Renaming an image to its current
    /// shortcode returns the content unchanged.
    public static func withRenamedImage(_ content: JSONValue?, from: String, to: String) throws(ImagePackEditError) -> JSONValue {
        var images = copyImages(content)
        guard let image = images[from] else { throw .missingImage(from) }
        guard from != to else { return withImages(content, images) }
        guard images[to] == nil else { throw .shortcodeTaken(to) }
        images[from] = nil
        images[to] = image
        return withImages(content, images)
    }
    
    // MARK: - Messages
    
    /// The formatted-body markup for an inline custom emoji.
    public static func emoticonHTML(url: String, shortcode: String) -> String {
        let text = escapeHTML(":\(shortcode):")
        return "<img \(emoticonAttribute) src=\"\(escapeHTML(url))\" alt=\"\(text)\" title=\"\(text)\" height=\"32\" />"
    }
    
    /// An `m.sticker` event's content for a pack's sticker: its body, else its shortcode, its URL and its info. In a thread it
    /// carries the thread relation, falling back to a reply to the root for clients without threads.
    /// ponytail: the fallback replies to the root, not the thread's latest event as the JS SDK does when it knows it.
    public static func stickerContent(_ sticker: CustomEmoji, threadRootID: String?) -> JSONValue {
        var info = JSONObject()
        info["w"] = sticker.info?.width.map { .integer(Int64($0)) }
        info["h"] = sticker.info?.height.map { .integer(Int64($0)) }
        info["mimetype"] = sticker.info?.mimeType.map(JSONValue.string)
        info["size"] = sticker.info?.size.map { .integer(Int64($0)) }
        var content: JSONObject = ["body": .string(sticker.body ?? sticker.shortcode), "url": .string(sticker.url), "info": .object(info)]
        if let threadRootID {
            content["m.relates_to"] = .object(["rel_type": .string("m.thread"),
                                               "event_id": .string(threadRootID),
                                               "is_falling_back": .bool(true),
                                               "m.in_reply_to": .object(["event_id": .string(threadRootID)])])
        }
        return .object(content)
    }
    
    // MARK: - Private
    
    /// The fields of an image's `info` that are valid, or nil when none is.
    private static func imageInfo(_ info: JSONObject?) -> PackImageInfo? {
        guard let info else { return nil }
        func positive(_ key: String) -> Int? {
            info.integer(key).flatMap { $0 > 0 && $0 <= Int64(Int32.max) ? Int($0) : nil }
        }
        let mimeType = info.string("mimetype").flatMap { $0.hasPrefix("image/") && $0.utf16.count <= 100 ? $0 : nil }
        let result = PackImageInfo(width: positive("w"), height: positive("h"), mimeType: mimeType, size: positive("size"))
        return result == PackImageInfo() ? nil : result
    }
    
    private static func usages(_ value: JSONValue?) -> [JSONValue] {
        if case .array(let values) = value {
            values
        } else {
            []
        }
    }
    
    /// The pack's own display name and avatar, when valid.
    private static func packDetails(_ content: JSONValue?) -> (name: String?, avatarURL: String?) {
        let pack = content?.objectValue?.object("pack")
        let name = pack?.string("display_name")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let avatarURL = pack?.string("avatar_url")
        return (!name.isEmpty && name.utf16.count <= maxTextLength ? name : nil, avatarURL.flatMap { isMXC($0) ? $0 : nil })
    }
    
    /// The stored images, or none when other data is stored there. Other clients' images are kept exactly as stored, even ones
    /// we would not display.
    private static func copyImages(_ content: JSONValue?) -> JSONObject {
        content?.objectValue?.object("images") ?? [:]
    }
    
    private static func withImages(_ content: JSONValue?, _ images: JSONObject) -> JSONValue {
        var base = content?.objectValue ?? [:]
        base["images"] = .object(images)
        return .object(base)
    }
    
    /// lodash's `escape`.
    private static func escapeHTML(_ text: String) -> String {
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&#39;"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }
    
    private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte | 0x20) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }
    
    private static func isNewShortcodeByte(_ byte: UInt8) -> Bool {
        isASCIIAlphanumeric(byte) || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
    }
}

public extension [EmojiPack] {
    /// The first emoji with this shortcode (without colons), searching packs in order.
    func emoji(shortcode: String) -> CustomEmoji? {
        lazy.flatMap(\.emojis).first { $0.shortcode.isSameID(shortcode) }
    }
    
    /// The first emoji with this mxc URL, searching packs in order.
    func emoji(url: String) -> CustomEmoji? {
        lazy.flatMap(\.emojis).first { $0.url.isSameID(url) }
    }
}
