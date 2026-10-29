//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation

enum NotesTabFlowCoordinatorAction {
    case showSettings
}

/// The Notes tab: its screen at the root of the tab's stack, and a space's notes (its list or one note) pushed above it.
final class NotesTabFlowCoordinator: FlowCoordinatorProtocol {
    private let navigationStackCoordinator: NavigationStackCoordinator
    private let reader: NotesTabReader
    private let contextFactory: SpaceNotesContextFactory
    private let mediaProvider: MediaProviderProtocol
    private let userProfilePublisher: CurrentValuePublisher<UserProfile, Never>
    private var spaceNotesFlow: SpaceNotesFlowCoordinator?
    private var cancellables = Set<AnyCancellable>()
    
    private let actionsSubject: PassthroughSubject<NotesTabFlowCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<NotesTabFlowCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(navigationStackCoordinator: NavigationStackCoordinator,
         reader: NotesTabReader,
         contextFactory: SpaceNotesContextFactory,
         mediaProvider: MediaProviderProtocol,
         userProfilePublisher: CurrentValuePublisher<UserProfile, Never>) {
        self.navigationStackCoordinator = navigationStackCoordinator
        self.reader = reader
        self.contextFactory = contextFactory
        self.mediaProvider = mediaProvider
        self.userProfilePublisher = userProfilePublisher
    }
    
    func start(animated: Bool) {
        let coordinator = NotesTabScreenCoordinator(parameters: .init(reader: reader,
                                                                      contextFactory: contextFactory,
                                                                      mediaProvider: mediaProvider,
                                                                      userProfilePublisher: userProfilePublisher))
        coordinator.actionsPublisher
            .sink { [weak self] action in
                switch action {
                case .openNote(let spaceID, let documentID):
                    self?.openNotes(spaceID: spaceID, documentID: documentID)
                case .showSettings:
                    self?.actionsSubject.send(.showSettings)
                }
            }
            .store(in: &cancellables)
        navigationStackCoordinator.setRootCoordinator(coordinator, animated: animated)
    }
    
    func handleAppRoute(_ appRoute: AppRoute, animated: Bool) { }
    
    func clearRoute(animated: Bool) {
        navigationStackCoordinator.popToRoot(animated: animated)
    }
    
    // MARK: - Private
    
    private func openNotes(spaceID: String, documentID: String?) {
        // One at a time: a second tap while the first flow's skeleton is pushed would replace that flow and leave its screens without
        // one. A note created from the tab opens only while the tab is on screen, so nothing is above it.
        guard spaceNotesFlow == nil else { return }
        let flow = SpaceNotesFlowCoordinator(entry: .space(spaceID: spaceID, documentID: documentID),
                                             navigationStackCoordinator: navigationStackCoordinator,
                                             contextFactory: contextFactory)
        flow.actionsPublisher
            .sink { [weak self, weak flow] action in
                switch action {
                case .finished:
                    if let self, spaceNotesFlow === flow {
                        spaceNotesFlow = nil
                    }
                }
            }
            .store(in: &cancellables)
        spaceNotesFlow = flow
        flow.start(animated: true)
    }
}
