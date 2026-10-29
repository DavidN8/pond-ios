//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

struct TasksBoardScreenCoordinatorParameters {
    let store: MatchaRoomStore
    /// Opens the editor of this thread's task once the board shows it.
    let initialThreadID: String?
    /// The chat's chip bar, drawn above the board in a chat.
    var chatBar: ChatBarViewModel?
}

enum TasksBoardScreenCoordinatorAction {
    case presentThread(threadRootEventID: String)
    case presentEditor(TaskEditorTarget)
    case presentArchived
    case presentRemindMe(RemindMeTarget, cardID: String)
}

final class TasksBoardScreenCoordinator: CoordinatorProtocol {
    private let viewModel: TasksBoardScreenViewModelProtocol
    let chatBar: ChatBarViewModel?
    private var cancellables = Set<AnyCancellable>()
    
    private let actionsSubject: PassthroughSubject<TasksBoardScreenCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<TasksBoardScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(parameters: TasksBoardScreenCoordinatorParameters) {
        viewModel = TasksBoardScreenViewModel(store: parameters.store, initialThreadID: parameters.initialThreadID)
        chatBar = parameters.chatBar
    }
    
    func start() {
        viewModel.actionsPublisher.sink { [weak self] action in
            guard let self else { return }
            switch action {
            case .presentThread(let threadRootEventID):
                actionsSubject.send(.presentThread(threadRootEventID: threadRootEventID))
            case .presentEditor(let target):
                actionsSubject.send(.presentEditor(target))
            case .presentArchived:
                actionsSubject.send(.presentArchived)
            case .presentRemindMe(let target, let cardID):
                actionsSubject.send(.presentRemindMe(target, cardID: cardID))
            }
        }
        .store(in: &cancellables)
    }
    
    func toPresentable() -> AnyView {
        AnyView(TasksBoardScreen(context: viewModel.context, chatBarContext: chatBar?.context))
    }
    
    /// The board's archived tasks, shown from the same view model; push it above the board.
    func makeArchivedTasksCoordinator() -> CoordinatorProtocol {
        ArchivedTasksScreenCoordinator(context: viewModel.context)
    }
}

private final class ArchivedTasksScreenCoordinator: CoordinatorProtocol {
    private let context: TasksBoardScreenViewModelType.Context
    
    init(context: TasksBoardScreenViewModelType.Context) {
        self.context = context
    }
    
    func toPresentable() -> AnyView {
        AnyView(ArchivedTasksScreen(context: context))
    }
}
