//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import Testing

@MainActor
struct MatchaServiceTests {
    @Test
    func screensShowingTheSameRoomShareOneStoreWhichTheLastOneStops() {
        let room = MatchaRoomFixture()
        let service = MatchaService(clientProxy: ClientProxyMock(.init()))
        
        let first = service.acquireStore(for: room.room)
        let second = service.acquireStore(for: room.room)
        #expect(first === second)
        
        service.releaseStore(first)
        #expect(!first.isStopped)
        service.releaseStore(second)
        #expect(first.isStopped)
        #expect(service.acquireStore(for: room.room) !== first)
    }
    
    @Test
    func stoppingTheServiceStopsTheNotesTabsReader() {
        let client = ClientProxyMock(.init())
        let space = { (id: String) in SpaceServiceFilter(room: .mock(id: id, isSpace: true, state: .joined), level: 0, descendants: []) }
        let filters = CurrentValueSubject<[SpaceServiceFilter], Never>([space("!a:x")])
        let spaceService = SpaceServiceProxyMock(.init())
        spaceService.spaceFilterPublisher = filters.asCurrentValuePublisher()
        client.spaceService = spaceService
        client.roomInfoRoomIDClosure = { _ in .failure(.roomNotInLocalStore) }
        let service = MatchaService(clientProxy: client)
        service.notesTabReader.start()
        #expect(service.notesTabReader.spacesPublisher.value?.map(\.id) == ["!a:x"])
        
        // Logout and clear cache stop the service; the reader follows the spaces no more.
        service.stop()
        filters.send([space("!a:x"), space("!b:x")])
        #expect(service.notesTabReader.spacesPublisher.value?.map(\.id) == ["!a:x"])
    }
    
    @Test
    func aRoomTheTasksTabHasOpenIsReadThroughTheTabsStoreWhichOutlivesTheScreen() async throws {
        let room = MatchaRoomFixture(roomID: "!board:x")
        room.serverPointer = { .success("$board-root") }
        let client = ClientProxyMock(.init())
        let roomList = StaticRoomSummaryProviderMock()
        roomList.statePublisher = CurrentValueSubject(.loaded(totalNumberOfRooms: 1)).asCurrentValuePublisher()
        roomList.roomListPublisher = CurrentValueSubject([RoomSummary.mock(id: "!board:x", name: "Board")]).asCurrentValuePublisher()
        client.staticRoomSummaryProvider = roomList
        client.stateEventsJSONRoomIDTypeClosure = { _, _ in .success([:]) }
        client.fetchStateEventContentJSONRoomIDTypeStateKeyClosure = { _, _, _ in .success(#"{"version": 1, "event_id": "$board-root"}"#) }
        client.roomForIdentifierClosure = { _ in .joined(room.room) }
        let service = MatchaService(clientProxy: client)
        let shown = Task { await service.tasksTabRooms.run() }
        let chats = await firstValue(of: service.tasksTabRooms.chatsPublisher, timeout: .seconds(10)) { !$0.boards.isEmpty }
        let tabStore = try #require(chats?.boards.first?.room.store)
        
        let store = service.acquireStore(for: room.room)
        #expect(store === tabStore)
        service.releaseStore(store)
        #expect(!store.isStopped)
        
        service.stop()
        #expect(store.isStopped)
        shown.cancel()
    }
    
    @Test
    func stoppingTheServiceLetsGoOfATabsRoomThatWaitedForAChatScreen() async {
        let room = MatchaRoomFixture(roomID: "!board:x")
        let summaries = CurrentValueSubject<[RoomSummary], Never>([RoomSummary.mock(id: "!board:x", name: "Board")])
        let client = ClientProxyMock(.init())
        let roomList = StaticRoomSummaryProviderMock()
        roomList.statePublisher = CurrentValueSubject(.loaded(totalNumberOfRooms: 1)).asCurrentValuePublisher()
        roomList.roomListPublisher = summaries.asCurrentValuePublisher()
        client.staticRoomSummaryProvider = roomList
        client.stateEventsJSONRoomIDTypeClosure = { _, _ in .success([:]) }
        client.fetchStateEventContentJSONRoomIDTypeStateKeyClosure = { _, _, _ in .success(#"{"version": 1, "event_id": "$board-root"}"#) }
        client.roomForIdentifierClosure = { _ in .joined(room.room) }
        let service = MatchaService(clientProxy: client)
        let shown = Task { await service.tasksTabRooms.run() }
        weak var tabRoom: TabRoom?
        do {
            let chats = await firstValue(of: service.tasksTabRooms.chatsPublisher, timeout: .seconds(10)) { !$0.boards.isEmpty }
            tabRoom = chats?.boards.first?.room
        }
        #expect(tabRoom != nil)
        let store = service.acquireStore(for: room.room)
        
        // The chat leaves the list while its screen still reads through the tab's store, so the tab waits for the screen to let go.
        summaries.send([])
        service.stop()
        #expect(store.isStopped)
        await eventually { tabRoom == nil }
        shown.cancel()
    }
    
    @Test
    func aRoomScreenReplacedByAnotherRoomsLetsGoOfItsStore() async throws {
        let client = ClientProxyMock(.init(userID: matchaUser, roomSummaryProvider: RoomSummaryProviderMock(.init(state: .loaded(.mockRooms)))))
        var rooms = [String: JoinedRoomProxyMock]()
        let openRoom = client.roomForIdentifierClosure
        client.roomForIdentifierClosure = { roomID in
            let room = await openRoom?(roomID)
            if case .joined(let joined as JoinedRoomProxyMock) = room {
                rooms[roomID] = joined
            }
            return room
        }
        let userSession = UserSessionMock(.init(clientProxy: client))
        let chats = ChatsTabFlowCoordinator(navigationSplitCoordinator: NavigationSplitCoordinator(placeholderCoordinator: PlaceholderScreenCoordinator(hideBrandChrome: false)),
                                            flowParameters: CommonFlowParameters(userSession: userSession,
                                                                                 availableSessionsPublisher: .init([.init(userSession: userSession)]),
                                                                                 bugReportService: BugReportServiceMock(.init()),
                                                                                 elementCallService: ElementCallServiceMock(.init()),
                                                                                 timelineControllerFactory: TimelineControllerFactoryMock(.init()),
                                                                                 emojiProvider: EmojiProvider(userSettings: userSession.userSettings),
                                                                                 linkMetadataProvider: LinkMetadataProvider(),
                                                                                 appMediator: AppMediatorMock(.init()),
                                                                                 analytics: AnalyticsServiceMock(.init()),
                                                                                 userIndicatorController: UserIndicatorControllerMock(),
                                                                                 stateMachineFactory: PublishedStateMachineFactory()))
        chats.start()
        
        chats.handleAppRoute(.room(roomID: "1", via: []), animated: false)
        // The room's screen has opened its store once the store opens its scan timeline.
        await eventually { rooms["1"]?.eventTypesTimelineTypesCallsCount == 1 }
        let roomOne = try #require(rooms["1"])
        let store = userSession.matchaService.acquireStore(for: roomOne)
        userSession.matchaService.releaseStore(store)
        #expect(!store.isStopped)
        
        // On iPad, or from a notification, another room replaces the one shown without going back to the list first.
        chats.handleAppRoute(.room(roomID: "2", via: []), animated: false)
        await eventually { rooms["2"]?.eventTypesTimelineTypesCallsCount == 1 }
        await eventually { store.isStopped }
    }
}
