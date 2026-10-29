//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Testing

/// The room flow's Matcha parts: its room's store and the chip bar's routes.
@MainActor
struct MatchaRoomFlowTests {
    @Test
    func aThreadCreatedWhileRoomDetailsCoverTheChatDoesntOpen() async throws {
        let fixture = MatchaRoomFixture()
        fixture.sendResult = { type, _ in .success(type == "m.room.message" ? "$root" : "$meta") }
        let gate = Gate()
        let send = try #require(fixture.room.sendRawEventTypeContentJSONClosure)
        fixture.room.sendRawEventTypeContentJSONClosure = { type, content in
            await gate.wait()
            return await send(type, content)
        }
        let flow = Flow(fixture)
        let chatBar = try await flow.openRoom()
        await eventually { chatBar.context.viewState.canCreateThread }
        
        chatBar.context.send(viewAction: .newThread)
        chatBar.context.send(viewAction: .updateThreadName("Launch plan"))
        chatBar.context.send(viewAction: .submitThreadName)
        // The user opens the room's details while the thread is still being created.
        flow.coordinator.handleAppRoute(.roomDetails(roomID: fixture.room.id), animated: false)
        await eventually { flow.stack.stackCoordinators.last is RoomDetailsScreenCoordinator }
        
        gate.open()
        await eventually { fixture.sent.count == 2 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(flow.stack.stackCoordinators.last is RoomDetailsScreenCoordinator)
        #expect(flow.stack.stackCoordinators.count == 1)
        
        // Back on the chat, the bar navigates again.
        flow.stack.pop(animated: false)
        chatBar.context.send(viewAction: .allThreads)
        await eventually { flow.stack.stackCoordinators.last is RoomThreadListScreenCoordinator }
    }
    
    @Test
    func theBoardsChipsStillOpenThreads() async throws {
        let fixture = try MatchaRoomFixture(items: [aThreadPatchItem(1, threadID: "$t1", name: "Plan")], threads: [aThreadListItem("$t1")])
        fixture.boardPointer = .success(aBoardRoot)
        let flow = Flow(fixture)
        let chatBar = try await flow.openRoom()
        
        chatBar.context.send(viewAction: .board)
        await eventually { flow.stack.stackCoordinators.last is TasksBoardScreenCoordinator }
        let boardBar = try #require((flow.stack.stackCoordinators.last as? TasksBoardScreenCoordinator)?.chatBar)
        await eventually { boardBar.context.viewState.threads.map(\.id) == ["$t1"] }
        
        boardBar.context.send(viewAction: .select(.thread(id: "$t1")))
        await eventually { flow.stack.stackCoordinators.last is ThreadTimelineScreenCoordinator }
        #expect(flow.stack.stackCoordinators.count == 1)
    }
    
    @Test
    func theComposersTaskOpensANewTasksEditorOverTheChat() async throws {
        let fixture = MatchaRoomFixture()
        fixture.boardPointer = .success(aBoardRoot)
        let flow = Flow(fixture)
        let chatBar = try await flow.openRoom()
        let store = flow.userSession.matchaService.acquireStore(for: fixture.room)
        flow.userSession.matchaService.releaseStore(store)
        await eventually { store.snapshot.board != nil }
        
        chatBar.context.send(viewAction: .newTask)
        await eventually { (flow.stack.sheetCoordinator as? NavigationStackCoordinator)?.rootCoordinator is TaskEditorScreenCoordinator }
        #expect(flow.stack.stackCoordinators.isEmpty)
    }
    
    @Test
    func aThreadsComposerTaskOpensANewTasksEditorOverTheThread() async throws {
        let fixture = try MatchaRoomFixture(items: [aThreadPatchItem(1, threadID: "$t1", name: "Plan")], threads: [aThreadListItem("$t1")])
        fixture.boardPointer = .success(aBoardRoot)
        let flow = Flow(fixture)
        let chatBar = try await flow.openRoom()
        await eventually { chatBar.context.viewState.threads.map(\.id) == ["$t1"] }
        
        chatBar.context.send(viewAction: .select(.thread(id: "$t1")))
        await eventually { flow.stack.stackCoordinators.last is ThreadTimelineScreenCoordinator }
        let threadBar = try #require((flow.stack.stackCoordinators.last as? ThreadTimelineScreenCoordinator)?.chatBar)
        await eventually { threadBar.context.viewState.chat.store.snapshot.board != nil }
        
        threadBar.context.send(viewAction: .newTask)
        await eventually { (flow.stack.sheetCoordinator as? NavigationStackCoordinator)?.rootCoordinator is TaskEditorScreenCoordinator }
        #expect(flow.stack.stackCoordinators.last is ThreadTimelineScreenCoordinator)
    }
    
    @Test
    func withoutABoardTheComposersTaskOpensTheBoard() async throws {
        let fixture = MatchaRoomFixture()
        let flow = Flow(fixture)
        let chatBar = try await flow.openRoom()
        let store = flow.userSession.matchaService.acquireStore(for: fixture.room)
        flow.userSession.matchaService.releaseStore(store)
        await eventually { store.snapshot.isLoaded }
        
        // The board's setup says how to start one, as on Android.
        chatBar.context.send(viewAction: .newTask)
        await eventually { flow.stack.stackCoordinators.last is TasksBoardScreenCoordinator }
        #expect(flow.stack.sheetCoordinator == nil)
    }
    
    @Test
    func twoRoutesRacingToOpenTheRoomTakeOneHoldOfItsStore() async {
        let fixture = MatchaRoomFixture()
        let flow = Flow(fixture)
        
        // Both pass the flow's "no room yet" check while the room subscribes.
        flow.coordinator.handleAppRoute(.room(roomID: fixture.room.id, via: []), animated: false)
        flow.coordinator.handleAppRoute(.room(roomID: fixture.room.id, via: []), animated: false)
        await eventually { flow.stack.rootCoordinator is RoomScreenCoordinator }
        await eventually { fixture.room.subscribeForUpdatesCallsCount == 2 }
        let store = flow.userSession.matchaService.acquireStore(for: fixture.room)
        flow.userSession.matchaService.releaseStore(store)
        
        flow.coordinator.clearRoute(animated: false)
        await eventually { store.isStopped }
    }
}

/// A room flow on its own stack, showing the fixture's room.
@MainActor
private struct Flow {
    let coordinator: RoomFlowCoordinator
    let stack: NavigationStackCoordinator
    let userSession: UserSessionMock
    private let roomID: String
    
    init(_ fixture: MatchaRoomFixture) {
        roomID = fixture.room.id
        let clientProxy = ClientProxyMock(.init(userID: matchaUser, roomSummaryProvider: RoomSummaryProviderMock(.init(state: .loaded(.mockRooms)))))
        clientProxy.roomForIdentifierClosure = { _ in .joined(fixture.room) }
        let userSettings = UserSettings.mock()
        userSettings.app.threadsEnabled = true
        userSession = UserSessionMock(.init(clientProxy: clientProxy, userSettings: userSettings))
        
        let splitCoordinator = NavigationSplitCoordinator(placeholderCoordinator: PlaceholderScreenCoordinator(hideBrandChrome: false))
        stack = NavigationStackCoordinator()
        splitCoordinator.setDetailCoordinator(stack)
        coordinator = RoomFlowCoordinator(roomID: fixture.room.id,
                                          isChildFlow: false,
                                          navigationStackCoordinator: stack,
                                          flowParameters: CommonFlowParameters(userSession: userSession,
                                                                               availableSessionsPublisher: .init([.init(userSession: userSession)]),
                                                                               bugReportService: BugReportServiceMock(.init()),
                                                                               elementCallService: ElementCallServiceMock(.init()),
                                                                               timelineControllerFactory: TimelineControllerFactoryMock(.init()),
                                                                               emojiProvider: EmojiProvider(userSettings: userSettings),
                                                                               linkMetadataProvider: LinkMetadataProvider(),
                                                                               appMediator: AppMediatorMock(.init()),
                                                                               analytics: AnalyticsServiceMock(.init()),
                                                                               userIndicatorController: UserIndicatorControllerMock(),
                                                                               stateMachineFactory: StateMachineFactory()))
    }
    
    /// Shows the room and returns its chip bar.
    func openRoom() async throws -> ChatBarViewModel {
        coordinator.handleAppRoute(.room(roomID: roomID, via: []), animated: false)
        await eventually { stack.rootCoordinator is RoomScreenCoordinator }
        return try #require((stack.rootCoordinator as? RoomScreenCoordinator)?.chatBar)
    }
}
