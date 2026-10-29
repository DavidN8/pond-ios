//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

struct TasksTabScreenCoordinatorParameters {
    /// The session's chats with a board, `MatchaService.tasksTabRooms`.
    let rooms: TasksTabRooms
    let clientProxy: ClientProxyProtocol
    let mediaProvider: MediaProviderProtocol
    /// The space whose boards are shown, or nil for the Tasks tab.
    var spaceID: String?
    /// The user's avatar, which opens the settings, as on every root tab.
    var userProfilePublisher: CurrentValuePublisher<UserProfile, Never>?
}

enum TasksTabScreenCoordinatorAction {
    case presentRoom(roomID: String)
    case presentThread(roomID: String, threadRootEventID: String)
    case presentEditor(roomID: String, target: TaskEditorTarget)
    case showSettings
}

final class TasksTabScreenCoordinator: CoordinatorProtocol {
    private let viewModel: TasksTabScreenViewModelProtocol
    private var cancellables = Set<AnyCancellable>()
    
    private let actionsSubject: PassthroughSubject<TasksTabScreenCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<TasksTabScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    /// The screen's context, so the flow's tests can act on the screen.
    var context: TasksTabScreenViewModelType.Context {
        viewModel.context
    }
    
    init(parameters: TasksTabScreenCoordinatorParameters) {
        viewModel = TasksTabScreenViewModel(rooms: parameters.rooms,
                                            clientProxy: parameters.clientProxy,
                                            spaceID: parameters.spaceID,
                                            mediaProvider: parameters.mediaProvider,
                                            userProfilePublisher: parameters.userProfilePublisher)
    }
    
    func start() {
        viewModel.actionsPublisher.sink { [weak self] action in
            guard let self else { return }
            switch action {
            case .presentRoom(let roomID):
                actionsSubject.send(.presentRoom(roomID: roomID))
            case .presentThread(let roomID, let threadRootEventID):
                actionsSubject.send(.presentThread(roomID: roomID, threadRootEventID: threadRootEventID))
            case .presentEditor(let roomID, let target):
                actionsSubject.send(.presentEditor(roomID: roomID, target: target))
            case .showSettings:
                actionsSubject.send(.showSettings)
            }
        }
        .store(in: &cancellables)
    }
    
    func toPresentable() -> AnyView {
        AnyView(TasksTabScreen(context: viewModel.context))
    }
}
