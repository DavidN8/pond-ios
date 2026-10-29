//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

struct NoteEditorScreenCoordinatorParameters {
    let notesContext: SpaceNotesContext
    let documentID: String
}

enum NoteEditorScreenCoordinatorAction {
    case close
}

final class NoteEditorScreenCoordinator: CoordinatorProtocol {
    private let viewModel: NoteEditorScreenViewModelProtocol
    private var cancellables = Set<AnyCancellable>()
    
    private let actionsSubject: PassthroughSubject<NoteEditorScreenCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<NoteEditorScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(parameters: NoteEditorScreenCoordinatorParameters) {
        viewModel = NoteEditorScreenViewModel(notesContext: parameters.notesContext, documentID: parameters.documentID)
    }
    
    func start() {
        viewModel.actionsPublisher.sink { [weak self] action in
            switch action {
            case .close:
                self?.actionsSubject.send(.close)
            }
        }
        .store(in: &cancellables)
    }
    
    func stop() {
        viewModel.stop()
    }
    
    func toPresentable() -> AnyView {
        AnyView(NoteEditorScreen(context: viewModel.context))
    }
}
