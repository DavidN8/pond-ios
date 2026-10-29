//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import Testing

/// Android's `HomeNavigationBarItemTest` bar order, and the Channels tab's flow.
@MainActor
struct MatchaHomeTabsTests {
    @Test
    func withTheWorkspacesTheTabsAreChatsTasksNotesChannelsThenSearch() throws {
        let (tabs, _) = makeHomeTabs(isMatchaWorkspacesEnabled: true)
        
        #expect(tabs.count == 5)
        #expect(tabs[0] is NavigationSplitCoordinator)
        let tasks = try #require(tabs[1] as? NavigationSplitCoordinator)
        #expect((tasks.sidebarCoordinator as? NavigationStackCoordinator)?.rootCoordinator is TasksTabScreenCoordinator)
        #expect((tabs[2] as? NavigationStackCoordinator)?.rootCoordinator is NotesTabScreenCoordinator)
        let channels = try #require(tabs[3] as? NavigationSplitCoordinator)
        #expect((channels.sidebarCoordinator as? NavigationStackCoordinator)?.rootCoordinator is ChannelsScreenCoordinator)
        #expect((tabs[4] as? NavigationStackCoordinator)?.rootCoordinator is SearchScreenCoordinator)
    }
    
    @Test
    func withoutTheWorkspacesTheTabsStayUpstreams() throws {
        let (tabs, _) = makeHomeTabs(isMatchaWorkspacesEnabled: false)
        
        #expect(tabs.count == 3)
        let spaces = try #require(tabs[1] as? NavigationSplitCoordinator)
        #expect((spaces.sidebarCoordinator as? NavigationStackCoordinator)?.rootCoordinator is SpacesScreenCoordinator)
        #expect((tabs[2] as? NavigationStackCoordinator)?.rootCoordinator is SearchScreenCoordinator)
    }
    
    @Test(arguments: [true, false])
    func theTabBarKeepsEveryTabOnScrollWhileTheWorkspacesAreOn(isMatchaWorkspacesEnabled: Bool) throws {
        // Android's bar always shows Chats · Tasks · Notes · Channels; upstream's shrinks to the current tab and Search on a scroll.
        let rootCoordinator = NavigationRootCoordinator()
        _ = UserSessionFlowCoordinator(isNewLogin: false,
                                       navigationRootCoordinator: rootCoordinator,
                                       appLockService: AppLockServiceMock(),
                                       flowParameters: makeFlowParameters(isMatchaWorkspacesEnabled: isMatchaWorkspacesEnabled))
        let tabCoordinator = try #require(rootCoordinator.rootCoordinator as? NavigationTabCoordinator<UserSessionFlowCoordinator.HomeTab>)
        
        #expect(tabCoordinator.minimizesTabBarOnScroll == !isMatchaWorkspacesEnabled)
    }
    
    @Test
    func theNotesTabHandsItsStackToItsTabSoItsBarHidesOverANote() {
        let notesTab = MatchaHomeTabs(flowParameters: makeFlowParameters()).tabs[1]
        #expect(notesTab.details.tag == .notes)
        #expect(notesTab.details.navigationStackCoordinator === notesTab.coordinator)
    }
    
    @Test
    func aChannelOpensItsChatNextToTheList() async throws {
        let (flow, split) = makeChannelsFlow()
        
        flow.handle(.openRoom(roomID: "1"))
        let stack = try #require(split.detailCoordinator as? NavigationStackCoordinator)
        try await deferFulfillment(stack.observe(\.showsRoomScreen)) { $0 }.fulfill()
    }
    
    @Test
    func aChannelsSettingsOpenNextToTheList() async throws {
        let (flow, split) = makeChannelsFlow()
        
        flow.handle(.openRoomDetails(roomID: "1"))
        let stack = try #require(split.detailCoordinator as? NavigationStackCoordinator)
        try await deferFulfillment(stack.observe(\.showsRoomDetails)) { $0 }.fulfill()
    }
    
    @Test
    func aChatOpenedFromChannelsIsOnScreenAsOneOpenedFromChats() async throws {
        let notificationService = NotificationServiceMock(.init())
        let flowParameters = makeFlowParameters(notificationService: notificationService)
        let clientProxy = try #require(flowParameters.userSession.clientProxy as? ClientProxyMock)
        let (removedNotifications, continuation) = AsyncStream<String>.makeStream()
        notificationService.removeDeliveredMessageNotificationsForClosure = { continuation.yield($0) }
        let homeTabs = MatchaHomeTabs(flowParameters: flowParameters)
        homeTabs.start()
        
        let removed = deferFulfillment(removedNotifications) { $0 == "1" }
        homeTabs.channelsTabFlowCoordinator.handle(.openRoom(roomID: "1"))
        
        // Its notifications go and it counts as recently visited, as the Chats tab does.
        try await removed.fulfill()
        #expect(clientProxy.trackRecentlyVisitedRoomReceivedInvocations == ["1"])
        // So no in-app notification shows for it while it is open.
        #expect(homeTabs.isDisplayingRoomScreen(withRoomID: "1", on: .channels))
        #expect(!homeTabs.isDisplayingRoomScreen(withRoomID: "2", on: .channels))
        #expect(!homeTabs.isDisplayingRoomScreen(withRoomID: "1", on: .tasks))
        
        homeTabs.channelsTabFlowCoordinator.clearRoute(animated: false)
        #expect(!homeTabs.isDisplayingRoomScreen(withRoomID: "1", on: .channels))
    }
    
    @Test
    func aSpaceShownIsNoChatOnScreen() {
        let (flow, _) = makeChannelsFlow()
        let space = SpaceServiceRoom.mock(id: "1", isSpace: true)
        
        flow.handle(.openSpace(SpaceRoomListProxyMock(.init(spaceServiceRoom: space))))
        #expect(!flow.isDisplayingRoomScreen(withRoomID: "1"))
    }
    
    @Test
    func theChatShownTappedAgainKeepsItsFlowAsOnTheChatsTab() async throws {
        let (flow, split) = makeChannelsFlow()
        
        flow.handle(.openRoom(roomID: "1"))
        let stack = try #require(split.detailCoordinator as? NavigationStackCoordinator)
        try await deferFulfillment(stack.observe(\.showsRoomScreen)) { $0 }.fulfill()
        
        // Next to the list (iPad), the same channel again doesn't open the chat anew.
        flow.handle(.openRoom(roomID: "1"))
        #expect(split.detailCoordinator === stack)
        
        flow.handle(.openRoom(roomID: "2"))
        #expect(split.detailCoordinator !== stack)
    }
    
    @Test
    func anotherSpaceReplacesTheOneShownAndTheFirstGoingAwayLeavesItOpen() throws {
        let (flow, split) = makeChannelsFlow()
        
        flow.handle(.openSpaceBoards(spaceID: "!a:example.com"))
        let first = try #require(split.detailCoordinator as? NavigationStackCoordinator)
        // The space's Boards screen is the stack's root: there is no empty root to go Back to.
        #expect(first.rootCoordinator is TasksTabScreenCoordinator)
        
        // The first stack's root goes when it is replaced, which would end its flow.
        flow.handle(.openSpaceBoards(spaceID: "!b:example.com"))
        let second = try #require(split.detailCoordinator as? NavigationStackCoordinator)
        #expect(second !== first)
        #expect(second.rootCoordinator is TasksTabScreenCoordinator)
        
        // Going back from it shows the list on its own.
        second.setRootCoordinator(nil)
        #expect(split.detailCoordinator == nil)
    }
    
    @Test
    func aTaskOfTheTasksTabOpensItsChatAboveTheTab() async throws {
        let notificationService = NotificationServiceMock(.init())
        let (removedNotifications, continuation) = AsyncStream<String>.makeStream()
        notificationService.removeDeliveredMessageNotificationsForClosure = { continuation.yield($0) }
        let rootCoordinator = NavigationRootCoordinator()
        let userSessionFlowCoordinator = UserSessionFlowCoordinator(isNewLogin: false,
                                                                    navigationRootCoordinator: rootCoordinator,
                                                                    appLockService: AppLockServiceMock(),
                                                                    flowParameters: makeFlowParameters(notificationService: notificationService))
        userSessionFlowCoordinator.start()
        let tabCoordinator = try #require(rootCoordinator.rootCoordinator as? NavigationTabCoordinator<UserSessionFlowCoordinator.HomeTab>)
        let tasks = try #require(tabCoordinator.tabCoordinators[1] as? NavigationSplitCoordinator)
        let tasksTab = try #require((tasks.sidebarCoordinator as? NavigationStackCoordinator)?.rootCoordinator as? TasksTabScreenCoordinator)
        tabCoordinator.selectedTab = .tasks
        
        let removed = deferFulfillment(removedNotifications) { $0 == "1" }
        tasksTab.context.send(viewAction: .openChat(roomID: "1"))
        // Above the tab, as Android pushes it: the tab's detail, which a phone pushes over the tab and its bar.
        let chat = try #require(tasks.detailCoordinator as? NavigationStackCoordinator)
        try await deferFulfillment(chat.observe(\.showsRoomScreen)) { $0 }.fulfill()
        #expect(tabCoordinator.selectedTab == .tasks)
        // On screen, as a chat opened from the Chats tab: its notifications go and none shows in the app.
        try await removed.fulfill()
        #expect(userSessionFlowCoordinator.isDisplayingRoomScreen(withRoomID: "1"))
        #expect(!userSessionFlowCoordinator.isDisplayingRoomScreen(withRoomID: "2"))
        
        // Back shows the tasks again.
        chat.setRootCoordinator(nil)
        #expect(tasks.detailCoordinator == nil)
        #expect(!userSessionFlowCoordinator.isDisplayingRoomScreen(withRoomID: "1"))
    }
    
    @Test
    func aTaskOfASpacesBoardsOpensItsChatAboveTheBoards() async throws {
        let homeTabs = MatchaHomeTabs(flowParameters: makeFlowParameters())
        homeTabs.start()
        let channels = try #require(homeTabs.tabs[2].coordinator as? NavigationSplitCoordinator)
        homeTabs.channelsTabFlowCoordinator.handle(.openSpaceBoards(spaceID: "!a:example.com"))
        let stack = try #require(channels.detailCoordinator as? NavigationStackCoordinator)
        let boards = try #require(stack.rootCoordinator as? TasksTabScreenCoordinator)
        #expect(boards.context.viewState.userProfile == nil)
        
        boards.context.send(viewAction: .openChat(roomID: "2"))
        // Pushed above the boards, as Android's, and on screen as a channel's chat.
        try await deferFulfillment(stack.observe(\.showsRoomScreenOnTop)) { $0 }.fulfill()
        #expect(channels.detailCoordinator === stack)
        #expect(homeTabs.isDisplayingRoomScreen(withRoomID: "2", on: .channels))
        
        // Back returns to the boards.
        stack.pop(animated: false)
        #expect(stack.rootCoordinator === boards)
        #expect(stack.stackCoordinators.isEmpty)
        #expect(!homeTabs.isDisplayingRoomScreen(withRoomID: "2", on: .channels))
    }
    
    @Test
    func theTasksTabsAvatarOpensTheSettings() async throws {
        let homeTabs = MatchaHomeTabs(flowParameters: makeFlowParameters())
        homeTabs.start()
        let tasks = try #require(homeTabs.tabs[0].coordinator as? NavigationSplitCoordinator)
        let tasksTab = try #require((tasks.sidebarCoordinator as? NavigationStackCoordinator)?.rootCoordinator as? TasksTabScreenCoordinator)
        #expect(tasksTab.context.viewState.userProfile?.id == "@alice:example.com")
        
        let deferred = deferFulfillment(homeTabs.actionsPublisher.map { action in
            if case .showSettings = action {
                true
            } else {
                false
            }
        }) { $0 }
        tasksTab.context.send(viewAction: .showSettings)
        try await deferred.fulfill()
    }
    
    @Test
    func notesOfASpaceThatIsntJoinedCloseAgain() async throws {
        let (flow, split) = makeChannelsFlow()
        
        flow.handle(.openSpaceNotes(spaceID: "!notJoined:example.com"))
        #expect(split.detailCoordinator is NavigationStackCoordinator)
        try await deferFulfillment(split.observe(\.hasDetail)) { !$0 }.fulfill()
    }
    
    @Test
    func clearingTheRouteShowsTheListAlone() {
        let (flow, split) = makeChannelsFlow()
        
        flow.handle(.openSpaceBoards(spaceID: "!a:example.com"))
        #expect(split.detailCoordinator != nil)
        flow.clearRoute(animated: false)
        #expect(split.detailCoordinator == nil)
    }
    
    @Test
    func settingsAreTheSessionsToShow() async throws {
        let (flow, _) = makeChannelsFlow()
        
        let deferred = deferFulfillment(flow.actionsPublisher.map { action in
            if case .showSettings = action {
                true
            } else {
                false
            }
        }) { $0 }
        flow.handle(.showSettings)
        try await deferred.fulfill()
    }
    
    @Test
    func theNotesTabsAvatarOpensTheSettingsThroughTheTabs() async throws {
        let homeTabs = MatchaHomeTabs(flowParameters: makeFlowParameters())
        homeTabs.start()
        let notesTab = try #require((homeTabs.tabs[1].coordinator as? NavigationStackCoordinator)?.rootCoordinator as? NotesTabScreenCoordinator)
        
        let deferred = deferFulfillment(homeTabs.actionsPublisher.map { action in
            if case .showSettings = action {
                true
            } else {
                false
            }
        }) { $0 }
        notesTab.context.send(viewAction: .showSettings)
        try await deferred.fulfill()
    }
    
    @Test
    func theNotesTabsAvatarFollowsTheProfileAndOpensTheSettings() async throws {
        let userSession = UserSessionMock(.init())
        let profile = CurrentValueSubject<UserProfile, Never>(UserProfile(userID: "@alice:example.com"))
        let viewModel = NotesTabScreenViewModel(reader: userSession.matchaService.notesTabReader,
                                                contextFactory: userSession.matchaService.notesContextFactory,
                                                mediaProvider: nil,
                                                userProfilePublisher: profile.asCurrentValuePublisher())
        #expect(viewModel.context.viewState.userProfile?.id == "@alice:example.com")
        
        profile.send(UserProfile(userID: "@alice:example.com", displayName: "Alice"))
        try await deferFulfillment(viewModel.context.observe(\.viewState.userProfile)) { $0?.displayName == "Alice" }.fulfill()
        
        let deferred = deferFulfillment(viewModel.actionsPublisher) { $0 == .showSettings }
        viewModel.context.send(viewAction: .showSettings)
        try await deferred.fulfill()
    }
    
    // MARK: - Helpers
    
    private func makeFlowParameters(isMatchaWorkspacesEnabled: Bool = true,
                                    notificationService: NotificationServiceMock = NotificationServiceMock(.init())) -> CommonFlowParameters {
        let clientProxy = ClientProxyMock(.init(userID: "@alice:example.com", roomSummaryProvider: RoomSummaryProviderMock(.init(state: .loaded(.mockRooms)))))
        let userSettings = UserSettings.mock()
        userSettings.app.matchaWorkspacesEnabled = isMatchaWorkspacesEnabled
        let userSession = UserSessionMock(.init(clientProxy: clientProxy, userSettings: userSettings, notificationService: notificationService))
        return CommonFlowParameters(userSession: userSession,
                                    availableSessionsPublisher: .init([.init(userSession: userSession)]),
                                    bugReportService: BugReportServiceMock(.init()),
                                    elementCallService: ElementCallServiceMock(.init()),
                                    timelineControllerFactory: TimelineControllerFactoryMock(.init()),
                                    emojiProvider: EmojiProvider(userSettings: userSession.userSettings),
                                    linkMetadataProvider: LinkMetadataProvider(),
                                    appMediator: AppMediatorMock(.init()),
                                    analytics: AnalyticsServiceMock(.init()),
                                    userIndicatorController: UserIndicatorControllerMock(),
                                    stateMachineFactory: PublishedStateMachineFactory())
    }
    
    /// The started session flow's tabs, with the flow that keeps them.
    private func makeHomeTabs(isMatchaWorkspacesEnabled: Bool) -> ([any CoordinatorProtocol], UserSessionFlowCoordinator) {
        let rootCoordinator = NavigationRootCoordinator()
        let userSessionFlowCoordinator = UserSessionFlowCoordinator(isNewLogin: false,
                                                                    navigationRootCoordinator: rootCoordinator,
                                                                    appLockService: AppLockServiceMock(),
                                                                    flowParameters: makeFlowParameters(isMatchaWorkspacesEnabled: isMatchaWorkspacesEnabled))
        userSessionFlowCoordinator.start()
        let tabCoordinator = rootCoordinator.rootCoordinator as? NavigationTabCoordinator<UserSessionFlowCoordinator.HomeTab>
        return (tabCoordinator?.tabCoordinators ?? [], userSessionFlowCoordinator)
    }
    
    private func makeChannelsFlow() -> (ChannelsTabFlowCoordinator, NavigationSplitCoordinator) {
        let split = NavigationSplitCoordinator(placeholderCoordinator: PlaceholderScreenCoordinator(hideBrandChrome: false))
        let flow = ChannelsTabFlowCoordinator(navigationSplitCoordinator: split, flowParameters: makeFlowParameters())
        flow.start()
        return (flow, split)
    }
}

private extension NavigationStackCoordinator {
    var showsRoomScreen: Bool {
        rootCoordinator is RoomScreenCoordinator
    }
    
    var showsRoomScreenOnTop: Bool {
        stackCoordinators.last is RoomScreenCoordinator
    }
    
    var showsRoomDetails: Bool {
        rootCoordinator is RoomDetailsScreenCoordinator
    }
}

private extension NavigationSplitCoordinator {
    var hasDetail: Bool {
        detailCoordinator != nil
    }
}
