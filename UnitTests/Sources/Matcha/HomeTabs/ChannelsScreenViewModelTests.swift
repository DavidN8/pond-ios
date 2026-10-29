//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import MatrixRustSDKMocks
import Testing

/// Android's `HomeSpacesPresenterTest` channels tests, plus the iOS tab's own: invites from the room list, listing only on screen.
@MainActor
struct ChannelsScreenViewModelTests {
    private let roomListState = CurrentValueSubject<RoomSummaryProviderState, Never>(.notLoaded)
    private let summaries = CurrentValueSubject<[RoomSummary], Never>([])
    private let spaceService = SpaceServiceProxyMock(.init())
    private let userIndicatorController = UserIndicatorControllerMock()
    private let clientProxy = ClientProxyMock(.init())
    private let viewModel: ChannelsScreenViewModel
    
    init() {
        let roomList = RoomSummaryProviderMock()
        roomList.statePublisher = roomListState.asCurrentValuePublisher()
        roomList.roomListPublisher = summaries.asCurrentValuePublisher()
        clientProxy.staticRoomSummaryProvider = roomList
        clientProxy.spaceService = spaceService
        viewModel = ChannelsScreenViewModel(userSession: UserSessionMock(.init(clientProxy: clientProxy)),
                                            selectedIDPublisher: .init(nil),
                                            userIndicatorController: userIndicatorController)
    }
    
    @Test
    func theChannelsAreGroupedUnderTheirTopLevelSpaceThenTheOnesInNoSpace() async throws {
        // In recency order, as the SDK sorts them
        summaries.send([Self.channel(.subSpaceChannel),
                        Self.channel(.bChannel),
                        Self.summary(.dm, isDirect: true, isDM: true),
                        Self.channel(.other),
                        Self.channel(.aChannel),
                        Self.summary(.subSpace, isSpace: true),
                        Self.summary(.invitedRoom, isJoined: false, isInvite: true),
                        Self.summary(.spaceInvite, isJoined: false, isSpace: true, isInvite: true),
                        Self.channel(.shared),
                        Self.summary(.leftChild, isJoined: false)])
        spaceService.topLevelSpacesPublisher = .init([.mock(id: .spaceA, name: "A", isSpace: true), .mock(id: .spaceB, name: "B", isSpace: true)])
        spaceService.spaceFilterPublisher = .init([Self.filter(.spaceA, level: 0, descendants: [.aChannel, .subSpace, .shared, .leftChild]),
                                                   // The rest of the tree of A
                                                   Self.filter(.subSpace, level: 1, descendants: [.subSpaceChannel]),
                                                   Self.filter(.spaceB, level: 0, descendants: [.bChannel, .shared])])
        viewModel.context.send(viewAction: .appeared)
        
        // Loading until the room list is loaded
        try await deferFulfillment(viewModel.context.observe(\.viewState.content)) { $0 == .loading }.fulfill()
        roomListState.send(.loaded(totalNumberOfRooms: 10))
        let channels = try await awaitChannels()
        
        #expect(channels.spaces.map(\.id) == [.spaceA, .spaceB])
        #expect(channels.spaces[0].channels.map(\.id) == [.subSpaceChannel, .aChannel, .shared])
        #expect(channels.spaces[1].channels.map(\.id) == [.bChannel, .shared])
        // Not the DM, the sub space, the invites, nor the channels of a space
        #expect(channels.otherChannels.map(\.id) == [.other])
        // Only the space invite, unseen
        #expect(channels.invites.map(\.id) == [.spaceInvite])
        #expect(channels.invites.first?.badges.isDotShown == true)
    }
    
    @Test
    func withoutAnySpaceEveryChannelIsAnOtherChannel() async throws {
        summaries.send([Self.channel(.aChannel), Self.channel(.other)])
        roomListState.send(.loaded(totalNumberOfRooms: 2))
        viewModel.context.send(viewAction: .appeared)
        
        let channels = try await awaitChannels()
        #expect(channels.spaces.isEmpty)
        #expect(channels.otherChannels.map(\.id) == [.aChannel, .other])
    }
    
    @Test
    func aDirectChatWithMoreThanTwoMembersIsAChannelLikeOnAndroid() {
        // The SDK's `isDm`, not `isDirect`, as Android's room list.
        let channels = ChannelsScreenViewModel.channels(spaces: [],
                                                        filters: [],
                                                        summaries: [Self.summary(.dm, isDirect: true, isDM: true), Self.summary(.other, isDirect: true)],
                                                        showAllActivity: true,
                                                        seenInvites: [])
        #expect(channels.otherChannels.map(\.id) == [.other])
    }
    
    @Test
    func nothingToListIsTheEmptyState() async throws {
        spaceService.topLevelSpacesPublisher = .init([])
        roomListState.send(.loaded(totalNumberOfRooms: 1))
        summaries.send([Self.summary(.dm, isDirect: true, isDM: true)])
        viewModel.context.send(viewAction: .appeared)
        
        try await deferFulfillment(viewModel.context.observe(\.viewState.content)) { $0 == .empty }.fulfill()
    }
    
    @Test
    func aRoomListLoadedBeforeItsRoomsArePublishedIsStillLoading() async throws {
        // The SDK says loaded before the provider has built its summaries, which the Chats list waits for too.
        roomListState.send(.loaded(totalNumberOfRooms: 2))
        viewModel.context.send(viewAction: .appeared)
        try await deferFailure(viewModel.context.observe(\.viewState.content), timeout: .milliseconds(200)) { $0 != .loading }.fulfill()
        
        summaries.send([Self.channel(.aChannel), Self.channel(.other)])
        #expect(try await awaitChannels().otherChannels.map(\.id) == [.aChannel, .other])
    }
    
    @Test
    func aSpaceIsListedEvenWhenTheRoomListHasNoRoomOfItsOwn() async throws {
        // A joined space is counted by the SDK's room list but never listed in it.
        spaceService.topLevelSpacesPublisher = .init([.mock(id: .spaceA, name: "A", isSpace: true)])
        roomListState.send(.loaded(totalNumberOfRooms: 1))
        viewModel.context.send(viewAction: .appeared)
        
        #expect(try await awaitChannels().spaces.map(\.id) == [.spaceA])
    }
    
    @Test
    func theListIsOnlyBuiltWhileTheTabIsOnScreen() async throws {
        summaries.send([Self.channel(.aChannel)])
        roomListState.send(.loaded(totalNumberOfRooms: 1))
        #expect(viewModel.context.viewState.content == .loading)
        
        viewModel.context.send(viewAction: .appeared)
        #expect(try await awaitChannels().otherChannels.map(\.id) == [.aChannel])
        
        viewModel.context.send(viewAction: .disappeared)
        summaries.send([Self.channel(.aChannel), Self.channel(.other)])
        try await deferFailure(viewModel.context.observe(\.viewState.content), timeout: .milliseconds(200)) { content in
            guard case .channels(let channels) = content else { return false }
            return channels.otherChannels.count == 2
        }.fulfill()
        
        // Back on screen, the list is read again.
        viewModel.context.send(viewAction: .appeared)
        #expect(try await awaitChannels { $0.otherChannels.count == 2 }.otherChannels.map(\.id) == [.aChannel, .other])
    }
    
    @Test
    func aSpaceOpensWithItsRoomList() async throws {
        let space = SpaceServiceRoom.mock(id: .spaceA, isSpace: true)
        spaceService.spaceRoomListSpaceIDClosure = { _ in .success(SpaceRoomListProxyMock(.init(spaceServiceRoom: space))) }
        
        let deferred = deferFulfillment(viewModel.actionsPublisher) { _ in true }
        viewModel.context.send(viewAction: .openSpace(spaceID: .spaceA))
        guard case .openSpace(let spaceRoomListProxy) = try await deferred.fulfill() else {
            Issue.record("The space should open")
            return
        }
        #expect(spaceRoomListProxy.id == .spaceA)
    }
    
    @Test
    func aSpaceThatCantBeReadSaysSo() async throws {
        spaceService.spaceRoomListSpaceIDClosure = { _ in .failure(.missingSpace) }
        
        let deferred = deferFailure(viewModel.actionsPublisher, timeout: .milliseconds(500)) { _ in true }
        viewModel.context.send(viewAction: .openSpace(spaceID: .spaceA))
        try await deferred.fulfill()
        #expect(userIndicatorController.submitIndicatorDelayCallsCount == 1)
    }
    
    @Test
    func theRowsAndToolbarAskTheFlow() async throws {
        let deferred = deferFulfillment(viewModel.actionsPublisher.collect(6).first()) { _ in true }
        viewModel.context.send(viewAction: .openRoom(roomID: .aChannel))
        viewModel.context.send(viewAction: .openSpaceNotes(spaceID: .spaceA))
        viewModel.context.send(viewAction: .openSpaceBoards(spaceID: .spaceB))
        viewModel.context.send(viewAction: .showSettings)
        viewModel.context.send(viewAction: .createSpace)
        // A channel's Settings, from its long-press menu.
        viewModel.context.send(viewAction: .showRoomDetails(roomID: .other))
        let actions = try await deferred.fulfill().map { action -> String in
            switch action {
            case .openRoom(let roomID): "room \(roomID)"
            case .openRoomDetails(let roomID): "details \(roomID)"
            case .openSpaceNotes(let spaceID): "notes \(spaceID)"
            case .openSpaceBoards(let spaceID): "boards \(spaceID)"
            case .showSettings: "settings"
            case .createSpace: "create"
            case .openSpace: "space"
            }
        }
        #expect(actions == ["room \(String.aChannel)", "notes \(String.spaceA)", "boards \(String.spaceB)", "settings", "create", "details \(String.other)"])
    }
    
    @Test
    func aChannelsLongPressMenuFlagsItAsTheChatsListDoes() async {
        let room = JoinedRoomProxyMock(.init(id: .aChannel))
        clientProxy.roomForIdentifierClosure = { _ in .joined(room) }
        
        viewModel.context.send(viewAction: .markAsUnread(roomID: .aChannel))
        await eventually { room.flagAsUnreadReceivedInvocations == [true] }
        #expect(room.markAsReadReceiptTypeCallsCount == 0)
        
        // Read also sends a receipt, public while the user shares their presence (the default).
        viewModel.context.send(viewAction: .markAsRead(roomID: .aChannel))
        await eventually { room.markAsReadReceiptTypeReceivedInvocations == [.read] }
        #expect(room.flagAsUnreadReceivedInvocations == [true, false])
        
        viewModel.context.send(viewAction: .setFavourite(roomID: .aChannel, isFavourite: true))
        await eventually { room.flagAsFavouriteReceivedInvocations == [true] }
    }
    
    // MARK: - Helpers
    
    private func awaitChannels(sourceLocation: SourceLocation = #_sourceLocation,
                               until condition: @escaping (Channels) -> Bool = { _ in true }) async throws -> Channels {
        var result: Channels?
        try await deferFulfillment(viewModel.context.observe(\.viewState.content), sourceLocation: sourceLocation) { content in
            guard case .channels(let channels) = content, condition(channels) else { return false }
            result = channels
            return true
        }.fulfill()
        return try #require(result, sourceLocation: sourceLocation)
    }
    
    private static func channel(_ id: String) -> RoomSummary {
        summary(id)
    }
    
    private static func summary(_ id: String,
                                isJoined: Bool = true,
                                isDirect: Bool = false,
                                isDM: Bool = false,
                                isSpace: Bool = false,
                                isInvite: Bool = false) -> RoomSummary {
        RoomSummary(room: RoomSDKMock(), id: id, joinRequestType: isInvite ? .invite(inviter: nil) : nil, isJoined: isJoined, name: id,
                    isDirect: isDirect, isSpace: isSpace, avatarURL: nil, heroes: [], activeMembersCount: 5, lastMessage: nil,
                    lastMessageDate: nil, lastMessageState: nil, unreadMessagesCount: 0, unreadMentionsCount: 0, unreadNotificationsCount: 0,
                    notificationMode: nil, canonicalAlias: nil, alternativeAliases: [], hasOngoingCall: false, activeCallIntent: nil,
                    isMarkedUnread: false, isFavourite: false, isTombstoned: false, isDM: isDM)
    }
    
    private static func filter(_ spaceID: String, level: UInt, descendants: Set<String>) -> SpaceServiceFilter {
        SpaceServiceFilter(room: .mock(id: spaceID, isSpace: true), level: level, descendants: descendants)
    }
}

private extension String {
    static let spaceA = "!spaceA:example.com"
    static let spaceB = "!spaceB:example.com"
    static let spaceInvite = "!spaceInvite:example.com"
    static let subSpace = "!subSpace:example.com"
    static let aChannel = "!aChannel:example.com"
    static let subSpaceChannel = "!subSpaceChannel:example.com"
    static let bChannel = "!bChannel:example.com"
    static let shared = "!shared:example.com"
    static let leftChild = "!leftChild:example.com"
    static let dm = "!dm:example.com"
    static let invitedRoom = "!invited:example.com"
    static let other = "!other:example.com"
}
