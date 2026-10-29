//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

struct NotesTabScreenCoordinatorParameters {
    /// The session's reader, which keeps what it read for the session.
    let reader: NotesTabReader
    let contextFactory: SpaceNotesContextFactory
    let mediaProvider: MediaProviderProtocol
    /// The user's avatar, which opens the settings, as on every root tab.
    var userProfilePublisher: CurrentValuePublisher<UserProfile, Never>?
}

enum NotesTabScreenCoordinatorAction {
    /// Shows a note of a space, or the space's notes list when `documentID` is nil.
    case openNote(spaceID: String, documentID: String?)
    case showSettings
}

final class NotesTabScreenCoordinator: CoordinatorProtocol {
    private let viewModel: NotesTabScreenViewModelProtocol
    private var cancellables = Set<AnyCancellable>()
    
    private let actionsSubject: PassthroughSubject<NotesTabScreenCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<NotesTabScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    /// The screen's context, so the tabs' tests can act on the screen.
    var context: NotesTabScreenViewModelType.Context {
        viewModel.context
    }
    
    init(parameters: NotesTabScreenCoordinatorParameters) {
        viewModel = NotesTabScreenViewModel(reader: parameters.reader,
                                            contextFactory: parameters.contextFactory,
                                            mediaProvider: parameters.mediaProvider,
                                            userProfilePublisher: parameters.userProfilePublisher)
    }
    
    func start() {
        viewModel.actionsPublisher.sink { [weak self] action in
            switch action {
            case .openNote(let spaceID, let documentID):
                self?.actionsSubject.send(.openNote(spaceID: spaceID, documentID: documentID))
            case .showSettings:
                self?.actionsSubject.send(.showSettings)
            }
        }
        .store(in: &cancellables)
    }
    
    func stop() {
        viewModel.stop()
    }
    
    func toPresentable() -> AnyView {
        AnyView(NotesTabScreen(context: viewModel.context))
    }
}
