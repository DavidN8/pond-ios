//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation

enum TasksTabFlowCoordinatorAction: Equatable {
    /// Show the chat; the host shows it above the tab or the boards, as Android does.
    case presentRoom(roomID: String)
    /// Show the thread of a task, in its chat, above the tab or the boards.
    case presentThread(roomID: String, threadRootEventID: String)
    /// A space's boards were popped.
    case finished
    /// The Tasks tab's avatar.
    case showSettings
}

/// The Tasks tab at the root of its stack, or a space's boards (the Channels tab's All boards) pushed on a stack, with the task
/// editor and its Remind me as sheets. The editor writes through the store the tab holds for the chat, held until the sheet goes.
/// Opening a chat or a thread is the host's: the tab only says which.
///
/// ponytail: one screen and a sheet, so no state machine, like `TasksBoardFlowCoordinator`.
final class TasksTabFlowCoordinator: FlowCoordinatorProtocol {
    private let navigationStackCoordinator: NavigationStackCoordinator
    private let rooms: TasksTabRooms
    private let clientProxy: ClientProxyProtocol
    private let mediaProvider: MediaProviderProtocol
    private let userIndicatorController: UserIndicatorControllerProtocol
    private let spaceID: String?
    private let userProfilePublisher: CurrentValuePublisher<UserProfile, Never>?
    private var cancellables = Set<AnyCancellable>()
    /// Each editor sheet's subscriptions, which hold its chat; dropped with their sheet, as the flow lasts the whole session.
    private var editorCancellables = [UUID: Set<AnyCancellable>]()
    
    private let actionsSubject: PassthroughSubject<TasksTabFlowCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<TasksTabFlowCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    /// - Parameters:
    ///   - rooms: the session's `MatchaService.tasksTabRooms`.
    ///   - spaceID: the space whose boards to show; nil sets the Tasks tab as the stack's root.
    ///   - userProfilePublisher: the Tasks tab's avatar, which opens the settings.
    init(navigationStackCoordinator: NavigationStackCoordinator,
         rooms: TasksTabRooms,
         clientProxy: ClientProxyProtocol,
         mediaProvider: MediaProviderProtocol,
         userIndicatorController: UserIndicatorControllerProtocol,
         spaceID: String? = nil,
         userProfilePublisher: CurrentValuePublisher<UserProfile, Never>? = nil) {
        self.navigationStackCoordinator = navigationStackCoordinator
        self.rooms = rooms
        self.clientProxy = clientProxy
        self.mediaProvider = mediaProvider
        self.userIndicatorController = userIndicatorController
        self.spaceID = spaceID
        self.userProfilePublisher = userProfilePublisher
    }
    
    func start(animated: Bool) {
        let coordinator = TasksTabScreenCoordinator(parameters: .init(rooms: rooms,
                                                                      clientProxy: clientProxy,
                                                                      mediaProvider: mediaProvider,
                                                                      spaceID: spaceID,
                                                                      userProfilePublisher: userProfilePublisher))
        coordinator.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .presentRoom(let roomID):
                    actionsSubject.send(.presentRoom(roomID: roomID))
                case .presentThread(let roomID, let threadRootEventID):
                    actionsSubject.send(.presentThread(roomID: roomID, threadRootEventID: threadRootEventID))
                case .presentEditor(let roomID, let target):
                    presentEditor(roomID: roomID, target: target)
                case .showSettings:
                    actionsSubject.send(.showSettings)
                }
            }
            .store(in: &cancellables)
        if spaceID == nil {
            navigationStackCoordinator.setRootCoordinator(coordinator, animated: animated)
        } else if navigationStackCoordinator.rootCoordinator == nil {
            // A stack of their own, as the Channels tab's detail: no empty root to go Back to.
            navigationStackCoordinator.setRootCoordinator(coordinator, animated: animated) { [weak self] in
                self?.actionsSubject.send(.finished)
            }
        } else {
            navigationStackCoordinator.push(coordinator, animated: animated) { [weak self] in
                self?.actionsSubject.send(.finished)
            }
        }
    }
    
    func handleAppRoute(_ appRoute: AppRoute, animated: Bool) { }
    
    func clearRoute(animated: Bool) {
        navigationStackCoordinator.setSheetCoordinator(nil, animated: animated)
    }
    
    // MARK: - Private
    
    private func presentEditor(roomID: String, target: TaskEditorTarget) {
        // Held while the sheet shows, so the room isn't let go under a save, even once the tab has been gone a while.
        guard let room = rooms.acquire(roomID: roomID) else { return }
        let sheetID = UUID()
        let stackCoordinator = NavigationStackCoordinator()
        let coordinator = TaskEditorScreenCoordinator(parameters: .init(store: room.store, target: target))
        coordinator.actionsPublisher
            .sink { [weak self, weak stackCoordinator] action in
                guard let self else { return }
                switch action {
                case .close:
                    navigationStackCoordinator.setSheetCoordinator(nil)
                case .openThread(let threadRootEventID):
                    navigationStackCoordinator.setSheetCoordinator(nil)
                    actionsSubject.send(.presentThread(roomID: roomID, threadRootEventID: threadRootEventID))
                case .remindMe(let target, let cardID):
                    // Kept on purpose: Android passes no onRemind here only because its tab can't show the sheet.
                    if let stackCoordinator {
                        RemindMeScreenCoordinator.present(on: stackCoordinator,
                                                          parameters: .task(target, cardID: cardID, store: room.store, userIndicatorController: userIndicatorController))
                            .store(in: &editorCancellables[sheetID, default: []])
                    }
                }
            }
            .store(in: &editorCancellables[sheetID, default: []])
        stackCoordinator.setRootCoordinator(coordinator)
        navigationStackCoordinator.setSheetCoordinator(stackCoordinator) { [weak self, rooms] in
            self?.editorCancellables[sheetID] = nil
            rooms.release(room)
        }
    }
}
