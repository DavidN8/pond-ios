//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation

/// The Channels tab, in place of the Spaces tab while the Matcha workspaces are on: the channels screen in the sidebar, and next to
/// it (pushed above it on a phone) the space, chat, space notes or space boards it opened, one at a time. Its actions are the
/// Spaces tab's; a task of a space's boards opens its chat or thread above the boards.
final class ChannelsTabFlowCoordinator: FlowCoordinatorProtocol {
    private let navigationSplitCoordinator: NavigationSplitCoordinator
    private let sidebarNavigationStackCoordinator: NavigationStackCoordinator
    private let flowParameters: CommonFlowParameters
    /// What is shown next to the list, and the subscription to its actions, which ends with it.
    private var detail: (flow: AnyObject, actions: AnyCancellable?)?
    /// The chat a task of the space's boards shown opened above them, and the subscription to its actions.
    private var boardsChat: (flow: RoomFlowCoordinator, roomID: String, actions: AnyCancellable)?
    // periphery:ignore - retaining purpose
    private var createSpaceFlowCoordinator: StartChatFlowCoordinator?
    private let selectedIDSubject = CurrentValueSubject<String?, Never>(nil)
    private var cancellables = Set<AnyCancellable>()
    
    private var userSession: UserSessionProtocol {
        flowParameters.userSession
    }
    
    private let actionsSubject: PassthroughSubject<SpacesTabFlowCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<SpacesTabFlowCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(navigationSplitCoordinator: NavigationSplitCoordinator, flowParameters: CommonFlowParameters) {
        self.navigationSplitCoordinator = navigationSplitCoordinator
        self.flowParameters = flowParameters
        sidebarNavigationStackCoordinator = NavigationStackCoordinator(navigationSplitCoordinator: navigationSplitCoordinator)
        navigationSplitCoordinator.setSidebarCoordinator(sidebarNavigationStackCoordinator)
    }
    
    func start(animated: Bool) {
        let coordinator = ChannelsScreenCoordinator(parameters: .init(userSession: userSession,
                                                                      selectedIDPublisher: selectedIDSubject.asCurrentValuePublisher(),
                                                                      userIndicatorController: flowParameters.userIndicatorController))
        coordinator.actionsPublisher
            .sink { [weak self] action in
                self?.handle(action)
            }
            .store(in: &cancellables)
        sidebarNavigationStackCoordinator.setRootCoordinator(coordinator, animated: animated)
    }
    
    /// What the channels screen asked for; internal for the tests.
    func handle(_ action: ChannelsScreenViewModelAction) {
        switch action {
        case .openSpace(let spaceRoomListProxy):
            startSpaceFlow(spaceRoomListProxy)
        case .openRoom(let roomID):
            startRoomFlow(roomID: roomID)
        case .openRoomDetails(let roomID):
            startRoomFlow(roomID: roomID, route: .roomDetails(roomID: roomID))
        case .openSpaceNotes(let spaceID):
            startSpaceNotesFlow(spaceID: spaceID)
        case .openSpaceBoards(let spaceID):
            startSpaceBoardsFlow(spaceID: spaceID)
        case .showSettings:
            actionsSubject.send(.showSettings)
        case .createSpace:
            startCreateSpaceFlow()
        }
    }
    
    /// Whether a chat opened from the list or from a space's boards is shown, as the Chats tab's `isDisplayingRoomScreen`.
    func isDisplayingRoomScreen(withRoomID roomID: String) -> Bool {
        (detail?.flow is RoomFlowCoordinator && selectedIDSubject.value == roomID) || boardsChat?.roomID == roomID
    }
    
    func handleAppRoute(_ appRoute: AppRoute, animated: Bool) {
        // There aren't any routes to this tab, as for the Spaces tab.
        clearRoute(animated: animated)
    }
    
    func clearRoute(animated: Bool) {
        navigationSplitCoordinator.setSheetCoordinator(nil, animated: animated)
        showDetail(nil, actions: nil, stackCoordinator: nil, selectedID: nil)
    }
    
    // MARK: - Private
    
    private func startSpaceFlow(_ spaceRoomListProxy: SpaceRoomListProxyProtocol) {
        let stackCoordinator = NavigationStackCoordinator(navigationSplitCoordinator: navigationSplitCoordinator)
        let flow = SpaceFlowCoordinator(entryPoint: .space(spaceRoomListProxy),
                                        spaceServiceProxy: userSession.clientProxy.spaceService,
                                        isChildFlow: false,
                                        navigationStackCoordinator: stackCoordinator,
                                        flowParameters: flowParameters)
        let actions = flow.actionsPublisher
            .sink { [weak self, weak flow] action in
                switch action {
                case .presentCallScreen(let roomProxy, let isVoiceCall):
                    self?.actionsSubject.send(.presentCallScreen(roomProxy: roomProxy, isVoiceCall: isVoiceCall))
                case .verifyUser(let userID):
                    self?.actionsSubject.send(.verifyUser(userID: userID))
                case .finished:
                    self?.finishDetail(flow)
                }
            }
        showDetail(flow, actions: actions, stackCoordinator: stackCoordinator, selectedID: spaceRoomListProxy.id)
        flow.start()
    }
    
    /// A chat next to the list, or its settings (`AppRoute.roomDetails`) from its long-press menu.
    private func startRoomFlow(roomID: String, route: AppRoute? = nil) {
        let route = route ?? .room(roomID: roomID, via: [])
        // The chat shown, tapped again next to the list, keeps its flow, as on the Chats tab.
        if let flow = detail?.flow as? RoomFlowCoordinator, selectedIDSubject.value == roomID {
            flow.handleAppRoute(route, animated: true)
            return
        }
        let stackCoordinator = NavigationStackCoordinator(navigationSplitCoordinator: navigationSplitCoordinator)
        let flow = RoomFlowCoordinator(roomID: roomID,
                                       isChildFlow: false,
                                       navigationStackCoordinator: stackCoordinator,
                                       flowParameters: flowParameters)
        let actions = flow.actions
            .sink { [weak self, weak flow] action in
                switch action {
                case .presentCallScreen(let roomProxy, let isVoiceCall):
                    self?.actionsSubject.send(.presentCallScreen(roomProxy: roomProxy, isVoiceCall: isVoiceCall))
                case .verifyUser(let userID):
                    self?.actionsSubject.send(.verifyUser(userID: userID))
                case .continueWithSpaceFlow(let spaceRoomListProxy):
                    // A space invite, once joined.
                    self?.startSpaceFlow(spaceRoomListProxy)
                case .finished:
                    self?.finishDetail(flow)
                }
            }
        showDetail(flow, actions: actions, stackCoordinator: stackCoordinator, selectedID: roomID)
        flow.handleAppRoute(route, animated: true)
        
        if case .room = route {
            userSession.matchaTrackOpenedChat(roomID: roomID)
        }
    }
    
    /// Android's All notes: the space's notes list, whose skeleton the flow pushes at once.
    private func startSpaceNotesFlow(spaceID: String) {
        let stackCoordinator = NavigationStackCoordinator(navigationSplitCoordinator: navigationSplitCoordinator)
        let flow = SpaceNotesFlowCoordinator(entry: .space(spaceID: spaceID, documentID: nil),
                                             navigationStackCoordinator: stackCoordinator,
                                             contextFactory: userSession.matchaService.notesContextFactory)
        let actions = flow.actionsPublisher
            .sink { [weak self, weak flow] action in
                switch action {
                case .finished:
                    self?.finishDetail(flow)
                }
            }
        showDetail(flow, actions: actions, stackCoordinator: stackCoordinator, selectedID: nil)
        flow.start(animated: true)
    }
    
    /// Android's All boards: the space's Boards screen (`SpaceBoardsView`), the Tasks tab's screen for the space, as this stack's root.
    private func startSpaceBoardsFlow(spaceID: String) {
        let stackCoordinator = NavigationStackCoordinator(navigationSplitCoordinator: navigationSplitCoordinator)
        let flow = TasksTabFlowCoordinator(navigationStackCoordinator: stackCoordinator,
                                           rooms: userSession.matchaService.tasksTabRooms,
                                           clientProxy: userSession.clientProxy,
                                           mediaProvider: userSession.mediaProvider,
                                           userIndicatorController: flowParameters.userIndicatorController,
                                           spaceID: spaceID)
        let actions = flow.actionsPublisher
            .sink { [weak self, weak flow, weak stackCoordinator] action in
                guard let self, let stackCoordinator else { return }
                switch action {
                case .presentRoom(let roomID):
                    startBoardsChat(roomID: roomID, route: .room(roomID: roomID, via: []), stackCoordinator: stackCoordinator)
                case .presentThread(let roomID, let threadRootEventID):
                    startBoardsChat(roomID: roomID,
                                    route: .thread(roomID: roomID, threadRootEventID: threadRootEventID, focusEventID: nil),
                                    stackCoordinator: stackCoordinator)
                case .finished:
                    finishDetail(flow)
                case .showSettings:
                    break // The boards have no avatar.
                }
            }
        showDetail(flow, actions: actions, stackCoordinator: stackCoordinator, selectedID: nil)
        flow.start(animated: true)
    }
    
    /// A task's chat pushed above the boards, as Android's, so Back returns to them: a child flow, as `SpaceFlowCoordinator`'s chats.
    private func startBoardsChat(roomID: String, route: AppRoute, stackCoordinator: NavigationStackCoordinator) {
        let flow = RoomFlowCoordinator(roomID: roomID,
                                       isChildFlow: true,
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
                    // A task's chat is never a space.
                    if let flow, flow === boardsChat?.flow {
                        boardsChat = nil
                    }
                }
            }
        boardsChat = (flow, roomID, actions)
        flow.handleAppRoute(route, animated: true)
        userSession.matchaTrackOpenedChat(roomID: roomID)
    }
    
    private func startCreateSpaceFlow() {
        let stackCoordinator = NavigationStackCoordinator()
        let flow = StartChatFlowCoordinator(entryPoint: .createSpace,
                                            userDiscoveryService: UserDiscoveryService(clientProxy: userSession.clientProxy),
                                            navigationStackCoordinator: stackCoordinator,
                                            flowParameters: flowParameters)
        var createdSpace: SpaceRoomListProxyProtocol?
        flow.actionsPublisher
            .sink { [weak self] action in
                switch action {
                case .finished(let result):
                    if case .space(let spaceRoomListProxy) = result {
                        createdSpace = spaceRoomListProxy
                    }
                    self?.navigationSplitCoordinator.setSheetCoordinator(nil)
                case .showRoomDirectory:
                    MXLog.error("The room directory isn't offered when creating a space")
                }
            }
            .store(in: &cancellables)
        navigationSplitCoordinator.setSheetCoordinator(stackCoordinator) { [weak self] in
            self?.createSpaceFlowCoordinator = nil
            if let createdSpace {
                self?.startSpaceFlow(createdSpace)
            }
        }
        flow.start(animated: true)
        createSpaceFlowCoordinator = flow
    }
    
    /// Shows a flow's stack next to the list in place of the one there, or nothing.
    private func showDetail(_ flow: AnyObject?, actions: AnyCancellable?, stackCoordinator: NavigationStackCoordinator?, selectedID: String?) {
        // Replaced first, as the Chats tab does: the stack going away finishes the flow it showed, which is no longer heard. A chat
        // above a space's boards goes with them.
        detail = flow.map { ($0, actions) }
        boardsChat = nil
        navigationSplitCoordinator.setDetailCoordinator(stackCoordinator)
        selectedIDSubject.send(selectedID)
    }
    
    /// A flow has tidied up its stack: the list is shown on its own again, unless another flow replaced it meanwhile.
    private func finishDetail(_ flow: AnyObject?) {
        guard let flow, flow === detail?.flow else { return }
        showDetail(nil, actions: nil, stackCoordinator: nil, selectedID: nil)
    }
}
