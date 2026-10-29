//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import MatchaProtocol
import MatrixRustSDK

/// Reads a room's custom emoji packs again, for the composer's suggestions and the reaction picker as they open.
typealias CustomEmojiPacksLoader = () async -> [EmojiPack]

/// The custom emoji and sticker packs usable in each room (MSC2545), in the web client's order, read when first asked for and kept
/// for the session. Room packs aren't in the sliding sync's required state, so they come from the server, the local store standing
/// in when a request fails.
final class CustomEmojiPacks {
    private struct AccountDataWrite {
        let content: JSONValue
        /// What the local store may hold while sync hasn't echoed `content`: its content before the first write sync hasn't
        /// echoed yet, and each write since.
        let staleStoreContents: [JSONValue?]
    }
    
    /// One read gives both, as emoji and stickers share packs.
    private struct RoomPacks {
        let emojis: [EmojiPack]
        let stickers: [EmojiPack]
    }
    
    private struct RoomRead {
        /// Tells this read from those that replaced it.
        let number: Int
        let task: Task<RoomPacks, Never>
    }
    
    /// ponytail: how many rooms' packs are kept; the least recently used is read again when next needed.
    private static let maxRooms = 20
    
    private let clientProxy: ClientProxyProtocol
    private let userPackName: String
    private let userStickerPackName: String
    /// The read of each room's packs, in flight or done.
    private var reads = [String: RoomRead]()
    private var readCount = 0
    /// The last packs read for each room, for what mustn't wait for the server, such as sending a message.
    private var lastPacks = [String: [EmojiPack]]()
    /// Room IDs, the most recently used last.
    private var recentRoomIDs = [String]()
    private var accountDataWrites = [String: AccountDataWrite]()
    
    init(clientProxy: ClientProxyProtocol,
         userPackName: String = UntranslatedL10n.screenMatchaEmojiPersonalPackName,
         userStickerPackName: String = UntranslatedL10n.screenMatchaStickersPersonalPackName) {
        self.clientProxy = clientProxy
        self.userPackName = userPackName
        self.userStickerPackName = userStickerPackName
    }
    
    /// The packs of a room, read once per session.
    func packs(roomID: String) async -> [EmojiPack] {
        if let read = reads[roomID] {
            markUsed(roomID)
            return await read.task.value.emojis
        }
        return await refresh(roomID: roomID)
    }
    
    /// Reads a room's packs again, as the picker, the composer's suggestions and the pack settings do when they open.
    func refresh(roomID: String) async -> [EmojiPack] {
        await startReading(roomID: roomID).value.emojis
    }
    
    /// Reads a room's sticker packs again, as the sticker picker opens.
    func stickerPacks(roomID: String) async -> [EmojiPack] {
        await startReading(roomID: roomID).value.stickers
    }
    
    /// The packs last read for a room, without waiting: none before the first read, which this starts.
    func cachedPacks(roomID: String) -> [EmojiPack] {
        if reads[roomID] == nil {
            _ = startReading(roomID: roomID)
        } else {
            markUsed(roomID)
        }
        return lastPacks[roomID] ?? []
    }
    
    /// Global account data of `type`, with what this session wrote in place of the local store's copy until sync echoes it; nil
    /// when there is none or the store can't be read.
    func accountData(type: String) async -> JSONValue? {
        try? await latestAccountData(type: type).get()
    }
    
    /// `accountData(type:)`, failing when the local store can't be read, for edits that mustn't replace content they couldn't read.
    func latestAccountData(type: String) async -> Result<JSONValue?, ClientProxyError> {
        let stored: JSONValue?
        switch await storedAccountData(type: type) {
        case .success(let content):
            stored = content
        case .failure(let error):
            return .failure(error)
        }
        guard let write = accountDataWrites[type] else { return .success(stored) }
        if stored != write.content, write.staleStoreContents.contains(stored) {
            return .success(write.content)
        }
        // Sync echoed the last write, or another device wrote since.
        accountDataWrites[type] = nil
        return .success(stored)
    }
    
    /// Writes global account data, such as the personal pack, and reads every room's packs again when next asked.
    func setAccountData(type: String, content: JSONValue) async -> Result<Void, ClientProxyError> {
        let stored = try? await storedAccountData(type: type).get()
        if case .failure(let error) = await clientProxy.setAccountData(type: type, contentJSON: content.jsonString) {
            return .failure(error)
        }
        // Until sync echoes this write, the store may also hold any earlier write it hasn't echoed yet.
        let staleStoreContents: [JSONValue?] = if let pending = accountDataWrites[type], stored != pending.content, pending.staleStoreContents.contains(stored) {
            pending.staleStoreContents + [pending.content]
        } else {
            [stored]
        }
        accountDataWrites[type] = AccountDataWrite(content: content, staleStoreContents: staleStoreContents)
        // Every room offers the personal pack and those enabled everywhere.
        forgetRooms()
        return .success(())
    }
    
    /// Reads every room's packs again when next asked, as after a room or space pack changes: a space's pack applies in its rooms.
    /// Until then, sending uses the packs last read.
    func forgetRooms() {
        reads.removeAll()
    }
    
    // MARK: - Private
    
    private func startReading(roomID: String) -> Task<RoomPacks, Never> {
        markUsed(roomID)
        readCount += 1
        let number = readCount
        let task = Task {
            let (packs, isComplete) = await read(roomID: roomID)
            // Unless a newer read replaced this one meanwhile, or the room was dropped from the cache.
            if reads[roomID]?.number == number {
                if isComplete || lastPacks[roomID] == nil {
                    lastPacks[roomID] = packs.emojis
                }
                if !isComplete {
                    // Read again next time rather than keeping packs a failed request left out for the session.
                    reads[roomID] = nil
                }
            }
            return packs
        }
        reads[roomID] = RoomRead(number: number, task: task)
        return task
    }
    
    private func markUsed(_ roomID: String) {
        recentRoomIDs.removeAll { $0 == roomID }
        recentRoomIDs.append(roomID)
        while recentRoomIDs.count > Self.maxRooms {
            let evicted = recentRoomIDs.removeFirst()
            reads[evicted] = nil
            lastPacks[evicted] = nil
        }
    }
    
    /// The packs of a room, and false when a request failed, leaving out packs it would have read.
    private func read(roomID: String) async -> (packs: RoomPacks, isComplete: Bool) {
        let userContent = await accountData(type: ImagePacks.userEmotesEventType)
        let emoteRooms = await accountData(type: ImagePacks.emoteRoomsEventType)
        let enabled = ImagePacks.enabledPacks(emoteRooms)
        let enabledKeys = Dictionary(enabled.map { ($0.roomID, $0.stateKeys) }) { first, _ in first }
        let parentIDs = await ImagePacks.parentSpaceIDs(of: roomID) { await stateContents(roomID: $0, type: ImagePacks.spaceParentEventType) }
        
        // ponytail: rooms are read one after the other; a few at a time if many enabled packs make it slow.
        var packRooms = [String: EmojiPackRoom]()
        var isComplete = true
        var visited = Set<String>()
        for id in [roomID] + enabled.map(\.roomID) + parentIDs where visited.insert(id).inserted {
            // The managed pack of the room and of its spaces, plus those enabled everywhere.
            let stateKeys = Set(enabledKeys[id] ?? []).union(id == roomID || parentIDs.contains(id) ? [""] : [])
            guard let room = await packRoom(id, stateKeys: stateKeys, mustBeJoined: id != roomID) else { continue }
            packRooms[id] = room.room
            isComplete = isComplete && room.isComplete
        }
        
        func packs(_ usage: ImageUsage, userPackName: String) -> [EmojiPack] {
            ImagePacks.emojiPacks(userContent: userContent,
                                  emoteRooms: emoteRooms,
                                  room: packRooms[roomID],
                                  parentSpaceIDs: parentIDs,
                                  userPackName: userPackName,
                                  usage: usage) { packRooms[$0] }
        }
        return (RoomPacks(emojis: packs(.emoticon, userPackName: userPackName), stickers: packs(.sticker, userPackName: userStickerPackName)), isComplete)
    }
    
    /// A room's packs, nil unless joined: every pack the server holds, named ones included, which the sync never stores. When the
    /// room's state can't be listed, the server's copy of each of `stateKeys` and the local store's of the others and of any whose
    /// request failed. The store would otherwise keep a pack's old content after a change made elsewhere.
    private func packRoom(_ roomID: String, stateKeys: Set<String>, mustBeJoined: Bool) async -> (room: EmojiPackRoom, isComplete: Bool)? {
        let info = try? await clientProxy.roomInfo(roomID: roomID).get()
        if mustBeJoined, info?.membership != .joined {
            return nil
        }
        let name = info?.displayName ?? roomID
        if case .success(let contents) = await clientProxy.fetchStateEventsJSON(roomID: roomID, type: ImagePacks.roomEmotesEventType) {
            return (EmojiPackRoom(id: roomID, name: name, packs: contents.compactMapValues(JSONValue.init(json:))), true)
        }
        var packs = await stateContents(roomID: roomID, type: ImagePacks.roomEmotesEventType)
        var isComplete = true
        for stateKey in stateKeys.sorted() {
            switch await clientProxy.fetchStateEventContentJSON(roomID: roomID, type: ImagePacks.roomEmotesEventType, stateKey: stateKey) {
            case .success(let json):
                packs[stateKey] = json.flatMap(JSONValue.init(json:))
            case .failure:
                isComplete = false
            }
        }
        return (EmojiPackRoom(id: roomID, name: name, packs: packs), isComplete)
    }
    
    /// A room's state contents of `type` in the local store, by state key.
    private func stateContents(roomID: String, type: String) async -> [String: JSONValue] {
        guard case .success(let events) = await clientProxy.stateEventsJSON(roomID: roomID, type: type) else { return [:] }
        return events.compactMapValues(JSONValue.init(json:))
    }
    
    private func storedAccountData(type: String) async -> Result<JSONValue?, ClientProxyError> {
        await clientProxy.accountDataJSON(type: type).map { $0.flatMap(JSONValue.init(json:)) }
    }
}
