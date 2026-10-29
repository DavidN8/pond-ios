//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import MatchaProtocol
import Testing

@MainActor
struct CustomEmojiPacksTests {
    private let homeserver = EmojiHomeserver()
    
    @Test
    func listsPersonalEnabledRoomAndParentSpacePacksInTheWebClientsOrder() async {
        homeserver.accountData = [ImagePacks.userEmotesEventType: pack("wave"),
                                  ImagePacks.emoteRoomsEventType: #"{"rooms": {"!other:x": {"fav": {}}, "!left:x": {"": {}}}}"#]
        homeserver.rooms = ["!room:x": "General", "!space:x": "Space", "!top:x": "Top", "!other:x": "Other", "!left:x": nil]
        homeserver.stored["!room:x"] = [ImagePacks.spaceParentEventType: ["!space:x": #"{"via": ["x"]}"#,
                                                                          "!child-only:x": "{}"]]
        homeserver.stored["!space:x"] = [ImagePacks.spaceParentEventType: ["!top:x": #"{"via": []}"#]]
        homeserver.server = ["!room:x": ["": pack("room")], "!space:x": ["": pack("space")], "!top:x": ["": pack("top")], "!left:x": ["": pack("left")],
                             "!other:x": ["fav": pack("star", name: "Favourites")]]
        
        let packs = await CustomEmojiPacks(clientProxy: homeserver.client, userPackName: "Your emoji").packs(roomID: "!room:x")
        
        #expect(packs.map(\.id) == ["user", "!other:x|fav", "!room:x|", "!space:x|", "!top:x|"])
        #expect(packs.map(\.name) == ["Your emoji", "Favourites", "General", "Space", "Top"])
        #expect(packs.emoji(url: "mxc://example.org/space")?.shortcode == "space")
        // Nothing of a room the user left was read.
        #expect(homeserver.fetches == ["!room:x|", "!other:x|fav", "!space:x|", "!top:x|"])
    }
    
    @Test
    func listsEveryPackTheServerHoldsNamedOnesIncludedWhenTheRoomsStateCanBeRead() async {
        homeserver.listsState = true
        homeserver.rooms = ["!room:x": "General", "!space:x": "Space"]
        homeserver.stored["!room:x"] = [ImagePacks.spaceParentEventType: ["!space:x": #"{"via": ["x"]}"#],
                                        ImagePacks.roomEmotesEventType: ["deleted-since": pack("stale")]]
        homeserver.server = ["!room:x": ["": pack("room"), "pepe": pack("pepe", name: "Pepe"), "gone": "{}"],
                             "!space:x": ["crew": pack("crew", name: "Crew")]]
        
        let packs = await CustomEmojiPacks(clientProxy: homeserver.client).packs(roomID: "!room:x")
        
        #expect(packs.map(\.id) == ["!room:x|", "!room:x|pepe", "!space:x|crew"])
        #expect(homeserver.stateReads == ["!room:x", "!space:x"])
        #expect(homeserver.fetches.isEmpty)
    }
    
    @Test
    func listsStickerPacksFromTheSameReadAndKeepsStickersOutOfTheEmojiPacks() async {
        let stickers = #"{"images": {"pepe": {"url": "mxc://example.org/pepe", "usage": ["sticker"]}}}"#
        homeserver.accountData = [ImagePacks.userEmotesEventType: stickers]
        homeserver.rooms = ["!room:x": "General"]
        // A named pack the store has, a deleted one, and the managed pack, whose image is both.
        homeserver.stored["!room:x"] = [ImagePacks.roomEmotesEventType: ["pepe": stickers, "gone": "{}"]]
        homeserver.server = ["!room:x": ["": pack("wave")]]
        let packSource = CustomEmojiPacks(clientProxy: homeserver.client, userPackName: "Your emoji", userStickerPackName: "Your stickers")
        
        let stickerPacks = await packSource.stickerPacks(roomID: "!room:x")
        
        #expect(stickerPacks.map(\.id) == ["user", "!room:x|", "!room:x|pepe"])
        #expect(stickerPacks.first?.name == "Your stickers")
        #expect(stickerPacks.first?.emojis == [CustomEmoji(shortcode: "pepe", url: "mxc://example.org/pepe")])
        #expect(packSource.cachedPacks(roomID: "!room:x").map(\.id) == ["!room:x|"])
        #expect(homeserver.fetches == ["!room:x|"])
    }
    
    @Test
    func prefersTheServersCopyOfAPackToTheLocalStores() async {
        homeserver.rooms = ["!room:x": "General"]
        homeserver.stored["!room:x"] = [ImagePacks.roomEmotesEventType: ["": pack("stored"), "other": pack("other")]]
        homeserver.server = ["!room:x": ["": pack("server")]]
        let packSource = CustomEmojiPacks(clientProxy: homeserver.client)
        
        // The store may keep a pack's old content after a change made elsewhere.
        let packs = await packSource.packs(roomID: "!room:x")
        #expect(packs.map(\.id) == ["!room:x|", "!room:x|other"])
        #expect(packs.first?.emojis.map(\.shortcode) == ["server"])
        
        // The store's copy stands in when the request fails.
        homeserver.failsFetches = true
        #expect(await packSource.refresh(roomID: "!room:x").first?.emojis.map(\.shortcode) == ["stored"])
    }
    
    @Test
    func sendingUsesThePacksLastReadWithoutWaitingForTheServer() async {
        homeserver.rooms = ["!room:x": "General"]
        homeserver.server = ["!room:x": ["": pack("first")]]
        let packSource = CustomEmojiPacks(clientProxy: homeserver.client)
        
        // None before the first read, which this starts.
        #expect(packSource.cachedPacks(roomID: "!room:x").isEmpty)
        #expect(await packSource.packs(roomID: "!room:x").emoji(shortcode: "first") != nil)
        #expect(packSource.cachedPacks(roomID: "!room:x").emoji(shortcode: "first") != nil)
        #expect(homeserver.fetches == ["!room:x|"])
        
        // A read that fails keeps the packs last read, and the next is read again.
        homeserver.failsFetches = true
        _ = await packSource.refresh(roomID: "!room:x")
        #expect(packSource.cachedPacks(roomID: "!room:x").emoji(shortcode: "first") != nil)
        _ = await packSource.packs(roomID: "!room:x")
        #expect(homeserver.fetches == ["!room:x|", "!room:x|", "!room:x|"])
    }
    
    @Test
    func keepsARoomsPacksForTheSessionUntilRefreshed() async {
        homeserver.rooms = ["!room:x": "General"]
        homeserver.server = ["!room:x": ["": pack("first")]]
        let packSource = CustomEmojiPacks(clientProxy: homeserver.client)
        
        #expect(await packSource.packs(roomID: "!room:x").emoji(shortcode: "first") != nil)
        homeserver.server = ["!room:x": ["": pack("second")]]
        #expect(await packSource.packs(roomID: "!room:x").emoji(shortcode: "first") != nil)
        #expect(homeserver.fetches == ["!room:x|"])
        
        #expect(await packSource.refresh(roomID: "!room:x").emoji(shortcode: "second") != nil)
        #expect(homeserver.fetches == ["!room:x|", "!room:x|"])
    }
    
    @Test
    func readsARoomAgainAfterAFailedRequest() async {
        homeserver.rooms = ["!room:x": "General"]
        homeserver.server = ["!room:x": ["": pack("wave")]]
        homeserver.failsFetches = true
        let packSource = CustomEmojiPacks(clientProxy: homeserver.client)
        
        #expect(await packSource.packs(roomID: "!room:x").isEmpty)
        homeserver.failsFetches = false
        #expect(await packSource.packs(roomID: "!room:x").map(\.id) == ["!room:x|"])
    }
    
    @Test
    func prefersItsOwnAccountDataWriteUntilSyncEchoesIt() async throws {
        homeserver.rooms = ["!room:x": "General"]
        homeserver.accountData = [ImagePacks.userEmotesEventType: pack("old")]
        let packSource = CustomEmojiPacks(clientProxy: homeserver.client)
        #expect(await packSource.packs(roomID: "!room:x").emoji(shortcode: "old") != nil)
        
        let written = try #require(JSONValue(json: pack("new")))
        #expect(await packSource.setAccountData(type: ImagePacks.userEmotesEventType, content: written).isSuccess)
        
        // The local store still has the old pack until the sync echo.
        #expect(homeserver.sent == [ImagePacks.userEmotesEventType: written.jsonString])
        #expect(await packSource.packs(roomID: "!room:x").emoji(shortcode: "new") != nil)
        
        homeserver.accountData[ImagePacks.userEmotesEventType] = written.jsonString
        #expect(await packSource.accountData(type: ImagePacks.userEmotesEventType) == written)
        // Once echoed, a later change from another device wins.
        homeserver.accountData[ImagePacks.userEmotesEventType] = pack("elsewhere")
        #expect(await packSource.accountData(type: ImagePacks.userEmotesEventType) == JSONValue(json: pack("elsewhere")))
    }
    
    @Test
    func prefersItsLastWriteUntilSyncEchoesEachWriteBeforeIt() async throws {
        homeserver.accountData = [ImagePacks.userEmotesEventType: pack("a")]
        let packSource = CustomEmojiPacks(clientProxy: homeserver.client)
        let writes = try ["b", "c", "d"].map { try #require(JSONValue(json: pack($0))) }
        
        // Two writes before sync echoes the first, then a third between the echoes.
        #expect(await packSource.setAccountData(type: ImagePacks.userEmotesEventType, content: writes[0]).isSuccess)
        #expect(await packSource.setAccountData(type: ImagePacks.userEmotesEventType, content: writes[1]).isSuccess)
        homeserver.accountData[ImagePacks.userEmotesEventType] = writes[0].jsonString
        #expect(await packSource.accountData(type: ImagePacks.userEmotesEventType) == writes[1])
        #expect(await packSource.setAccountData(type: ImagePacks.userEmotesEventType, content: writes[2]).isSuccess)
        homeserver.accountData[ImagePacks.userEmotesEventType] = writes[1].jsonString
        #expect(await packSource.accountData(type: ImagePacks.userEmotesEventType) == writes[2])
        
        homeserver.accountData[ImagePacks.userEmotesEventType] = writes[2].jsonString
        #expect(await packSource.accountData(type: ImagePacks.userEmotesEventType) == writes[2])
        // Once echoed, a later change from another device wins.
        homeserver.accountData[ImagePacks.userEmotesEventType] = writes[0].jsonString
        #expect(await packSource.accountData(type: ImagePacks.userEmotesEventType) == writes[0])
    }
    
    @Test
    func keepsTheStoresAccountDataWhenAWriteFails() async throws {
        homeserver.accountData = [ImagePacks.userEmotesEventType: pack("old")]
        homeserver.client.setAccountDataTypeContentJSONClosure = { _, _ in .failure(.sdkError(ClientProxyMockError.generic)) }
        let packSource = CustomEmojiPacks(clientProxy: homeserver.client)
        
        let result = try await packSource.setAccountData(type: ImagePacks.userEmotesEventType, content: #require(JSONValue(json: pack("new"))))
        
        #expect(!result.isSuccess)
        #expect(await packSource.accountData(type: ImagePacks.userEmotesEventType) == JSONValue(json: pack("old")))
    }
    
    // MARK: - Helpers
    
    private func pack(_ code: String, name: String? = nil) -> String {
        let images = #"{"images": {"\#(code)": {"url": "mxc://example.org/\#(code)"}}"#
        return name.map { images + #", "pack": {"display_name": "\#($0)"}}"# } ?? images + "}"
    }
}

/// The client of a session whose rooms, local store and homeserver the tests set.
@MainActor
private final class EmojiHomeserver {
    let client = ClientProxyMock(.init())
    var accountData = [String: String]()
    /// Rooms in the local store, by ID: joined with this name, or left when nil.
    var rooms = [String: String?]()
    /// The local store's state: room ID → event type → state key → content.
    var stored = [String: [String: [String: String]]]()
    /// The homeserver's packs: room ID → state key → content.
    var server = [String: [String: String]]()
    var failsFetches = false
    /// Whether the homeserver's whole state of a room can be read; when it can't, as when a token refresh is due, packs come from
    /// the store and one state key at a time.
    var listsState = false
    private(set) var fetches = [String]()
    private(set) var stateReads = [String]()
    private(set) var sent = [String: String]()
    
    init() {
        client.accountDataJSONTypeClosure = { [unowned self] type in .success(accountData[type]) }
        client.setAccountDataTypeContentJSONClosure = { [unowned self] type, content in
            sent[type] = content
            return .success(())
        }
        client.roomInfoRoomIDClosure = { [unowned self] roomID in
            guard let name = rooms[roomID] else { return .failure(.roomNotInLocalStore) }
            return .success(RoomInfoProxyMock(.init(id: roomID, name: name, membership: name == nil ? .left : .joined)))
        }
        client.stateEventsJSONRoomIDTypeClosure = { [unowned self] roomID, type in
            guard rooms[roomID] != nil else { return .failure(.roomNotInLocalStore) }
            return .success(stored[roomID]?[type] ?? [:])
        }
        client.fetchStateEventContentJSONRoomIDTypeStateKeyClosure = { [unowned self] roomID, type, stateKey in
            #expect(type == ImagePacks.roomEmotesEventType)
            fetches.append("\(roomID)|\(stateKey)")
            return failsFetches ? .failure(.sdkError(ClientProxyMockError.generic)) : .success(server[roomID]?[stateKey])
        }
        client.fetchStateEventsJSONRoomIDTypeClosure = { [unowned self] roomID, type in
            #expect(type == ImagePacks.roomEmotesEventType)
            guard listsState else { return .failure(.sdkError(ClientProxyMockError.generic)) }
            stateReads.append(roomID)
            return .success(server[roomID] ?? [:])
        }
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self {
            true
        } else {
            false
        }
    }
}
