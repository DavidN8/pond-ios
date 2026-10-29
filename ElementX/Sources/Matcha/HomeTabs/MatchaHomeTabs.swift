//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation

/// The tabs Matcha puts after Chats while the workspaces are on, Android's `HomeNavigationBarItem.barOrder`: Chats · Tasks · Notes ·
/// Channels, Channels in place of Spaces. Their actions are the Spaces tab's, which the session flow already handles. A chat a task
/// opens is shown above its tab, as Android pushes it, so Back returns to the tasks.
final class MatchaHomeTabs {
    typealias HomeTab = UserSessionFlowCoordinator.HomeTab
    
    let tabs: [NavigationTabCoordinator<HomeTab>.Tab]
    
    private let flowParameters: CommonFlowParameters
    private let tasksTabSplitCoordinator: NavigationSplitCoordinator
    private let tasksTabFlowCoordinator: TasksTabFlowCoordinator
    /// The chat a task of the Tasks tab opened, and the subscription to its actions, which ends with it.
    private var tasksTabChat: (flow: RoomFlowCoordinator, roomID: String, actions: AnyCancellable)?
    private let notesTabFlowCoordinator: NotesTabFlowCoordinator
    /// Internal for the tests.
    let channelsTabFlowCoordinator: ChannelsTabFlowCoordinator
    private var cancellables = Set<AnyCancellable>()
    
    private let actionsSubject: PassthroughSubject<SpacesTabFlowCoordinatorAction, Never> = .init()
    let actionsPublisher: AnyPublisher<SpacesTabFlowCoordinatorAction, Never>
    
    init(flowParameters: CommonFlowParameters) {
        self.flowParameters = flowParameters
        let userSession = flowParameters.userSession
        
        // A split view like Channels, so a task's chat hides the tab bar on a phone, as the chats of the Chats tab.
        tasksTabSplitCoordinator = NavigationSplitCoordinator(placeholderCoordinator: PlaceholderScreenCoordinator(hideBrandChrome: userSession.userSettings.app.hideBrandChrome))
        let tasksTabNavigationStackCoordinator = NavigationStackCoordinator(navigationSplitCoordinator: tasksTabSplitCoordinator)
        tasksTabSplitCoordinator.setSidebarCoordinator(tasksTabNavigationStackCoordinator)
        tasksTabFlowCoordinator = TasksTabFlowCoordinator(navigationStackCoordinator: tasksTabNavigationStackCoordinator,
                                                          rooms: userSession.matchaService.tasksTabRooms,
                                                          clientProxy: userSession.clientProxy,
                                                          mediaProvider: userSession.mediaProvider,
                                                          userIndicatorController: flowParameters.userIndicatorController,
                                                          userProfilePublisher: userSession.clientProxy.userProfilePublisher)
        let tasksTabDetails = NavigationTabCoordinator<HomeTab>.TabDetails(tag: .tasks,
                                                                           title: UntranslatedL10n.commonMatchaTasks,
                                                                           icon: \.matchaBoard,
                                                                           selectedIcon: \.matchaBoardSolid,
                                                                           accessibilityIdentifier: A11yIdentifiers.homeTabs.tasks)
        tasksTabDetails.navigationSplitCoordinator = tasksTabSplitCoordinator
        
        // A plain stack, like the Search tab's: the tab's screens get the full width.
        let notesTabNavigationStackCoordinator = NavigationStackCoordinator()
        notesTabFlowCoordinator = NotesTabFlowCoordinator(navigationStackCoordinator: notesTabNavigationStackCoordinator,
                                                          reader: userSession.matchaService.notesTabReader,
                                                          contextFactory: userSession.matchaService.notesContextFactory,
                                                          mediaProvider: userSession.mediaProvider,
                                                          userProfilePublisher: userSession.clientProxy.userProfilePublisher)
        let notesTabDetails = NavigationTabCoordinator<HomeTab>.TabDetails(tag: .notes,
                                                                           title: UntranslatedL10n.commonMatchaDocs,
                                                                           icon: \.matchaNotes,
                                                                           selectedIcon: \.matchaNotesSolid,
                                                                           accessibilityIdentifier: A11yIdentifiers.homeTabs.notes)
        // A note or a space's notes pushed above the tab hides the tab bar, as a chat does in Chats and Channels.
        notesTabDetails.navigationStackCoordinator = notesTabNavigationStackCoordinator
        
        let channelsSplitCoordinator = NavigationSplitCoordinator(placeholderCoordinator: PlaceholderScreenCoordinator(hideBrandChrome: userSession.userSettings.app.hideBrandChrome))
        channelsTabFlowCoordinator = ChannelsTabFlowCoordinator(navigationSplitCoordinator: channelsSplitCoordinator, flowParameters: flowParameters)
        // The room icon is a hash, the usual channel sign; Compound has no solid variant of it.
        let channelsTabDetails = NavigationTabCoordinator<HomeTab>.TabDetails(tag: .channels,
                                                                              title: UntranslatedL10n.screenHomeTabChannels,
                                                                              icon: \.room,
                                                                              selectedIcon: \.room,
                                                                              accessibilityIdentifier: A11yIdentifiers.homeTabs.channels)
        channelsTabDetails.navigationSplitCoordinator = channelsSplitCoordinator
        
        tabs = [.init(coordinator: tasksTabSplitCoordinator, details: tasksTabDetails),
                .init(coordinator: notesTabNavigationStackCoordinator, details: notesTabDetails),
                .init(coordinator: channelsSplitCoordinator, details: channelsTabDetails)]
        
        actionsPublisher = channelsTabFlowCoordinator.actionsPublisher
            .merge(with: notesTabFlowCoordinator.actionsPublisher.map { action in
                switch action {
                case .showSettings: .showSettings
                }
            }, actionsSubject)
            .eraseToAnyPublisher()
        
        tasksTabFlowCoordinator.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .presentRoom(let roomID):
                    startTasksTabChat(roomID: roomID, route: .room(roomID: roomID, via: []))
                case .presentThread(let roomID, let threadRootEventID):
                    startTasksTabChat(roomID: roomID, route: .thread(roomID: roomID, threadRootEventID: threadRootEventID, focusEventID: nil))
                case .showSettings:
                    actionsSubject.send(.showSettings)
                case .finished:
                    break // Only a space's boards finish.
                }
            }
            .store(in: &cancellables)
    }
    
    func start() {
        tasksTabFlowCoordinator.start()
        notesTabFlowCoordinator.start()
        channelsTabFlowCoordinator.start()
    }
    
    /// Whether the tab shows this chat, so no in-app notification shows for it, as for the Chats tab's.
    func isDisplayingRoomScreen(withRoomID roomID: String, on tab: HomeTab) -> Bool {
        switch tab {
        case .tasks: tasksTabChat?.roomID == roomID
        case .channels: channelsTabFlowCoordinator.isDisplayingRoomScreen(withRoomID: roomID)
        case .chats, .spaces, .search, .notes: false
        }
    }
    
    // MARK: - Private
    
    /// The chat as the Tasks tab's detail, which a phone pushes above the tab, in place of any chat shown before.
    private func startTasksTabChat(roomID: String, route: AppRoute) {
        let stackCoordinator = NavigationStackCoordinator(navigationSplitCoordinator: tasksTabSplitCoordinator)
        let flow = RoomFlowCoordinator(roomID: roomID,
                                       isChildFlow: false,
                                       navigationStackCoordinator: stackCoordinator,
                                       flowParameters: flowParameters)
        let actions = flow.actions
            .sink { [weak self, weak flow] action in
                guard let self else { return }
                switch action {
                case .presentCallScreen(let roomProxy, let isVoiceCall):
                    actionsSubject.send(.presentCallScreen(roomProxy: roomProxy, isVoiceCall: isVoiceCall))
                case .verifyUser(let userID):
                    actionsSubject.send(.verifyUser(userID: userID))
                case .continueWithSpaceFlow, .finished:
                    // A task's chat is never a space. A flow replaced meanwhile can't close the chat that replaced it.
                    guard let flow, flow === tasksTabChat?.flow else { return }
                    tasksTabChat = nil
                    tasksTabSplitCoordinator.setDetailCoordinator(nil)
                }
            }
        // Replaced first, as the Chats tab does: the stack going away finishes the flow it showed, which is no longer heard.
        tasksTabChat = (flow, roomID, actions)
        tasksTabSplitCoordinator.setDetailCoordinator(stackCoordinator)
        flow.handleAppRoute(route, animated: true)
        flowParameters.userSession.matchaTrackOpenedChat(roomID: roomID)
    }
}

extension UserSessionProtocol {
    /// What the Chats tab does for a chat it opens: the chat is recently visited and its notifications go.
    func matchaTrackOpenedChat(roomID: String) {
        Task { [self] in
            _ = await clientProxy.trackRecentlyVisitedRoom(roomID)
            notificationService.removeDeliveredMessageNotifications(for: roomID)
        }
    }
}
