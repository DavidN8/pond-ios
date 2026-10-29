//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation

enum TasksBoardFlowCoordinatorAction: Equatable {
    /// Show the thread above the board; the board stays below it.
    case presentThread(threadRootEventID: String)
    /// The board was popped.
    case finished
}

/// A chat's task board pushed on a navigation stack, with its archived tasks pushed above it and the task editor as a sheet. The
/// room flow starts it for the chat's Tasks button; the Tasks tab can start it on its own stack with the chat's store.
///
/// ponytail: two screens and a sheet, so no state machine, like `PinnedEventsTimelineFlowCoordinator`.
final class TasksBoardFlowCoordinator: FlowCoordinatorProtocol {
    private let store: MatchaRoomStore
    private let initialThreadID: String?
    private let navigationStackCoordinator: NavigationStackCoordinator
    private let userIndicatorController: UserIndicatorControllerProtocol
    private let chatBar: ChatBarViewModel?
    private var cancellables = Set<AnyCancellable>()
    /// The editor's and Remind me's subscriptions: each new sheet's replaces the last one's, so they don't pile up while the board
    /// shows. One of each is enough, as at most one of each is presented at a time.
    private var editorCancellable: AnyCancellable?
    private var remindMeCancellable: AnyCancellable?
    
    private let actionsSubject: PassthroughSubject<TasksBoardFlowCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<TasksBoardFlowCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    /// - Parameters:
    ///   - initialThreadID: opens the editor of this thread's task once the board shows it (a thread chip's "View task").
    ///   - chatBar: the chat's chip bar, drawn above the board in a chat; nil in the Tasks tab.
    init(store: MatchaRoomStore,
         initialThreadID: String? = nil,
         navigationStackCoordinator: NavigationStackCoordinator,
         userIndicatorController: UserIndicatorControllerProtocol,
         chatBar: ChatBarViewModel? = nil) {
        self.store = store
        self.initialThreadID = initialThreadID
        self.navigationStackCoordinator = navigationStackCoordinator
        self.userIndicatorController = userIndicatorController
        self.chatBar = chatBar
    }
    
    func start(animated: Bool) {
        let coordinator = TasksBoardScreenCoordinator(parameters: .init(store: store, initialThreadID: initialThreadID, chatBar: chatBar))
        coordinator.actionsPublisher
            .sink { [weak self, weak coordinator] action in
                guard let self else { return }
                switch action {
                case .presentThread(let threadRootEventID):
                    actionsSubject.send(.presentThread(threadRootEventID: threadRootEventID))
                case .presentEditor(let target):
                    presentEditor(target)
                case .presentArchived:
                    if let coordinator {
                        navigationStackCoordinator.push(coordinator.makeArchivedTasksCoordinator())
                    }
                case .presentRemindMe(let target, let cardID):
                    presentRemindMe(target, cardID: cardID, on: navigationStackCoordinator)
                }
            }
            .store(in: &cancellables)
        navigationStackCoordinator.push(coordinator, animated: animated) { [weak self] in
            self?.actionsSubject.send(.finished)
        }
    }
    
    func handleAppRoute(_ appRoute: AppRoute, animated: Bool) { }
    
    func clearRoute(animated: Bool) { }
    
    // MARK: - Private
    
    private func presentEditor(_ target: TaskEditorTarget) {
        let stackCoordinator = NavigationStackCoordinator()
        let coordinator = TaskEditorScreenCoordinator(parameters: .init(store: store, target: target))
        editorCancellable = coordinator.actionsPublisher
            .sink { [weak self, weak stackCoordinator] action in
                guard let self else { return }
                switch action {
                case .close:
                    navigationStackCoordinator.setSheetCoordinator(nil)
                case .openThread(let threadRootEventID):
                    navigationStackCoordinator.setSheetCoordinator(nil)
                    actionsSubject.send(.presentThread(threadRootEventID: threadRootEventID))
                case .remindMe(let target, let cardID):
                    if let stackCoordinator {
                        presentRemindMe(target, cardID: cardID, on: stackCoordinator)
                    }
                }
            }
        stackCoordinator.setRootCoordinator(coordinator)
        navigationStackCoordinator.setSheetCoordinator(stackCoordinator)
    }
    
    private func presentRemindMe(_ target: RemindMeTarget, cardID: String, on stack: NavigationStackCoordinator) {
        remindMeCancellable = RemindMeScreenCoordinator.present(on: stack, parameters: .task(target, cardID: cardID, store: store,
                                                                                             userIndicatorController: userIndicatorController))
    }
}
