//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

struct SpaceNotesSetupScreenCoordinatorParameters {
    let room: JoinedRoomProxyProtocol
}

enum SpaceNotesSetupScreenCoordinatorAction {
    case done
    case close
}

final class SpaceNotesSetupScreenCoordinator: CoordinatorProtocol {
    private let viewModel: SpaceNotesSetupScreenViewModelProtocol
    private var cancellables = Set<AnyCancellable>()
    
    private let actionsSubject: PassthroughSubject<SpaceNotesSetupScreenCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<SpaceNotesSetupScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(parameters: SpaceNotesSetupScreenCoordinatorParameters) {
        viewModel = SpaceNotesSetupScreenViewModel(room: parameters.room)
    }
    
    func start() {
        viewModel.actionsPublisher.sink { [weak self] action in
            guard let self else { return }
            switch action {
            case .done:
                actionsSubject.send(.done)
            case .close:
                actionsSubject.send(.close)
            }
        }
        .store(in: &cancellables)
    }
    
    func toPresentable() -> AnyView {
        AnyView(SpaceNotesSetupScreen(context: viewModel.context))
    }
}
