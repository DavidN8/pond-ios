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
struct StickerPickerScreenViewModelTests {
    private let roomProxy = JoinedRoomProxyMock(.init(id: "!room:x"))
    private let userIndicatorController = UserIndicatorControllerMock()
    
    @Test
    func showsATabPerPackStartingWithTheFirst() async {
        let viewModel = await makeViewModel()
        
        #expect(viewModel.context.viewState.packs?.map(\.id) == ["user", "!room:x|"])
        #expect(viewModel.context.viewState.shownPacks.map(\.id) == ["user"])
        
        viewModel.context.send(viewAction: .selectPack(id: "!room:x|"))
        #expect(viewModel.context.viewState.shownPacks.flatMap(\.emojis).map(\.shortcode) == ["party"])
    }
    
    @Test
    func searchesEveryPackByShortcodeAndBodyIgnoringCase() async {
        let viewModel = await makeViewModel()
        
        viewModel.context.searchQuery = "HAPPY"
        #expect(viewModel.context.viewState.isSearching)
        #expect(viewModel.context.viewState.shownPacks.map(\.id) == ["user", "!room:x|"])
        #expect(viewModel.context.viewState.shownPacks.flatMap(\.emojis).map(\.shortcode) == ["pepe_happy", "party"])
        
        viewModel.context.searchQuery = "nothing"
        #expect(viewModel.context.viewState.shownPacks.isEmpty)
        
        viewModel.context.searchQuery = "  "
        #expect(!viewModel.context.viewState.isSearching)
        #expect(viewModel.context.viewState.shownPacks.map(\.id) == ["user"])
    }
    
    @Test
    func sendsTheTappedStickerAsAStickerEventAndCloses() async throws {
        roomProxy.sendRawEventTypeContentJSONClosure = { _, _ in .success("$sticker") }
        let viewModel = await makeViewModel()
        let dismissed = deferFulfillment(viewModel.actionsPublisher) { action in
            if case .dismiss = action {
                true
            } else {
                false
            }
        }
        
        viewModel.context.send(viewAction: .send(Self.happy))
        try await dismissed.fulfill()
        await viewModel.settle()
        
        let sent = try #require(roomProxy.sendRawEventTypeContentJSONReceivedArguments)
        #expect(sent.type == "m.sticker")
        #expect(JSONValue(json: sent.contentJSON) == ImagePacks.stickerContent(Self.happy, threadRootID: nil))
        #expect(!userIndicatorController.submitIndicatorDelayCalled)
    }
    
    @Test
    func sendsInTheThreadItWasOpenedFrom() async throws {
        roomProxy.sendRawEventTypeContentJSONClosure = { _, _ in .success("$sticker") }
        let viewModel = await makeViewModel(threadRootEventID: "$root")
        
        viewModel.context.send(viewAction: .send(Self.happy))
        await viewModel.settle()
        
        let sent = try #require(roomProxy.sendRawEventTypeContentJSONReceivedArguments)
        #expect(JSONValue(json: sent.contentJSON)?.objectValue?.object("m.relates_to")?.string("event_id") == "$root")
    }
    
    @Test
    func saysWhenTheStickerCouldNotBeSent() async {
        roomProxy.sendRawEventTypeContentJSONClosure = { _, _ in .failure(.sdkError(RoomProxyMockError.generic)) }
        let viewModel = await makeViewModel()
        
        viewModel.context.send(viewAction: .send(Self.happy))
        await viewModel.settle()
        
        #expect(userIndicatorController.submitIndicatorDelayReceivedArguments?.indicator.title == UntranslatedL10n.screenMatchaStickersErrorSend)
    }
    
    @Test
    func closesWithoutSending() async throws {
        let viewModel = await makeViewModel()
        let dismissed = deferFulfillment(viewModel.actionsPublisher) { action in
            if case .dismiss = action {
                true
            } else {
                false
            }
        }
        
        viewModel.context.send(viewAction: .dismiss)
        try await dismissed.fulfill()
        
        #expect(!roomProxy.sendRawEventTypeContentJSONCalled)
    }
    
    // MARK: - Helpers
    
    private static let happy = CustomEmoji(shortcode: "pepe_happy", url: "mxc://example.org/happy", body: "Happy Pepe",
                                           info: .init(width: 512, height: 512, mimeType: "image/webp", size: 31000))
    private static let packs = [
        EmojiPack(id: "user", kind: .user, name: "Your stickers", emojis: [happy, CustomEmoji(shortcode: "pepe_sad", url: "mxc://example.org/sad")]),
        EmojiPack(id: "!room:x|", kind: .room, roomID: "!room:x", stateKey: "", name: "Crew",
                  emojis: [CustomEmoji(shortcode: "party", url: "mxc://example.org/party", body: "Happy party")])
    ]
    
    private func makeViewModel(threadRootEventID: String? = nil) async -> StickerPickerScreenViewModel {
        let viewModel = StickerPickerScreenViewModel(roomProxy: roomProxy,
                                                     threadRootEventID: threadRootEventID,
                                                     loadStickerPacks: { Self.packs },
                                                     mediaProvider: nil,
                                                     userIndicatorController: userIndicatorController)
        await viewModel.settle()
        return viewModel
    }
}
