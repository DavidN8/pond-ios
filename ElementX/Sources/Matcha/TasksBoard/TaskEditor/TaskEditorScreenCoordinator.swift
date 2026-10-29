//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

struct TaskEditorScreenCoordinatorParameters {
    let store: MatchaRoomStore
    let target: TaskEditorTarget
}

enum TaskEditorScreenCoordinatorAction {
    case close
    case openThread(threadRootEventID: String)
    case remindMe(RemindMeTarget, cardID: String)
}

/// The task editor; present it as a sheet inside its own `NavigationStackCoordinator`, for its toolbar.
final class TaskEditorScreenCoordinator: CoordinatorProtocol {
    private let viewModel: TaskEditorScreenViewModelProtocol
    private var cancellables = Set<AnyCancellable>()
    
    private let actionsSubject: PassthroughSubject<TaskEditorScreenCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<TaskEditorScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(parameters: TaskEditorScreenCoordinatorParameters) {
        viewModel = TaskEditorScreenViewModel(store: parameters.store, target: parameters.target)
    }
    
    func start() {
        viewModel.actionsPublisher.sink { [weak self] action in
            guard let self else { return }
            switch action {
            case .close:
                actionsSubject.send(.close)
            case .openThread(let threadRootEventID):
                actionsSubject.send(.openThread(threadRootEventID: threadRootEventID))
            case .remindMe(let target, let cardID):
                actionsSubject.send(.remindMe(target, cardID: cardID))
            }
        }
        .store(in: &cancellables)
    }
    
    func toPresentable() -> AnyView {
        AnyView(TaskEditorScreen(context: viewModel.context))
    }
}
