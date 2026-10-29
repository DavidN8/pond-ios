//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

struct SpaceNotesListScreenCoordinatorParameters {
    let notesContext: SpaceNotesContext
}

enum SpaceNotesListScreenCoordinatorAction {
    case openNote(documentID: String)
    case openSetup
}

final class SpaceNotesListScreenCoordinator: CoordinatorProtocol {
    private let viewModel: SpaceNotesListScreenViewModelProtocol
    private var cancellables = Set<AnyCancellable>()
    
    private let actionsSubject: PassthroughSubject<SpaceNotesListScreenCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<SpaceNotesListScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(parameters: SpaceNotesListScreenCoordinatorParameters) {
        viewModel = SpaceNotesListScreenViewModel(notesContext: parameters.notesContext)
    }
    
    func start() {
        viewModel.actionsPublisher.sink { [weak self] action in
            guard let self else { return }
            switch action {
            case .openNote(let documentID):
                actionsSubject.send(.openNote(documentID: documentID))
            case .openSetup:
                actionsSubject.send(.openSetup)
            }
        }
        .store(in: &cancellables)
    }
    
    func toPresentable() -> AnyView {
        AnyView(SpaceNotesListScreen(context: viewModel.context))
    }
}

/// The list's skeleton, which `SpaceNotesFlowCoordinator` shows while the space opens.
final class SpaceNotesLoadingScreenCoordinator: CoordinatorProtocol {
    private let viewModel = SpaceNotesListScreenFixedViewModel(state: .init())
    
    func toPresentable() -> AnyView {
        AnyView(SpaceNotesListScreen(context: viewModel.context))
    }
}
