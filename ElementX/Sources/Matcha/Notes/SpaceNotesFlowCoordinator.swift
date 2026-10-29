//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import MatchaProtocol

enum SpaceNotesFlowCoordinatorAction {
    /// The flow's first screen has gone; the space's notes are closed.
    case finished
}

/// The notes of a space, or a chat's earlier document, pushed onto a navigation stack: the list, the editor and the one-time setup.
/// Like Android's loading node, it pushes the list's skeleton at once and puts the first screen in its place once the space is open;
/// the context is closed when that screen goes away, or as soon as it opens when the skeleton went first.
final class SpaceNotesFlowCoordinator: FlowCoordinatorProtocol {
    enum Entry {
        /// The space's list, or straight to one of its notes.
        case space(spaceID: String, documentID: String?)
        /// A chat's own earlier document, read-only.
        case earlierChatDocument(roomID: String)
    }
    
    private let entry: Entry
    private let navigationStackCoordinator: NavigationStackCoordinator
    private let contextFactory: SpaceNotesContextFactory
    private var notesContext: SpaceNotesContext?
    /// The skeleton shown while the space opens, until a screen takes its place or it is dismissed.
    private var loadingScreen: SpaceNotesLoadingScreenCoordinator?
    private var cancellables = Set<AnyCancellable>()
    
    private let actionsSubject: PassthroughSubject<SpaceNotesFlowCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<SpaceNotesFlowCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(entry: Entry, navigationStackCoordinator: NavigationStackCoordinator, contextFactory: SpaceNotesContextFactory) {
        self.entry = entry
        self.navigationStackCoordinator = navigationStackCoordinator
        self.contextFactory = contextFactory
    }
    
    func start(animated: Bool) {
        let loadingScreen = SpaceNotesLoadingScreenCoordinator()
        self.loadingScreen = loadingScreen
        // Dismissed, or its stack replaced, before the space is open: the flow ends here.
        navigationStackCoordinator.push(loadingScreen, animated: animated) { [weak self] in
            guard let self, self.loadingScreen === loadingScreen else { return }
            self.loadingScreen = nil
            actionsSubject.send(.finished)
        }
        Task { await open() }
    }
    
    func handleAppRoute(_ appRoute: AppRoute, animated: Bool) { }
    
    func clearRoute(animated: Bool) { }
    
    // MARK: - Private
    
    private func open() async {
        let notesContext: SpaceNotesContext?
        let documentID: String?
        switch entry {
        case .space(let spaceID, let requestedID):
            notesContext = await contextFactory.makeContext(roomID: spaceID)
            documentID = requestedID.flatMap { DocsProtocol.isDocumentID($0) ? $0 : nil }
        case .earlierChatDocument(let roomID):
            notesContext = await contextFactory.makeContext(roomID: roomID, isEarlierChatDocument: true)
            documentID = DocsProtocol.mainDocumentID
        }
        // The loading screen went while the space opened: nothing shows the context.
        guard loadingScreen != nil else {
            notesContext?.close()
            return
        }
        loadingScreen = nil
        // ponytail: popping takes the loading screen off, as nothing pushes above it; whatever pops below it ended the flow above.
        guard let notesContext else {
            MXLog.warning("Notes opened for a room that is not joined, or for a chat as a space")
            navigationStackCoordinator.pop()
            actionsSubject.send(.finished)
            return
        }
        navigationStackCoordinator.pop(animated: false)
        self.notesContext = notesContext
        // The first screen's dismissal ends the flow.
        let finish: () -> Void = { [weak self] in
            notesContext.close()
            self?.notesContext = nil
            self?.actionsSubject.send(.finished)
        }
        if let documentID {
            pushEditor(documentID: documentID, in: notesContext, animated: false, dismissalCallback: finish)
        } else {
            pushList(notesContext, animated: false, dismissalCallback: finish)
        }
    }
    
    private func pushList(_ notesContext: SpaceNotesContext, animated: Bool, dismissalCallback: @escaping () -> Void) {
        let coordinator = SpaceNotesListScreenCoordinator(parameters: .init(notesContext: notesContext))
        coordinator.actionsPublisher
            .sink { [weak self] action in
                switch action {
                case .openNote(let documentID):
                    self?.pushEditor(documentID: documentID, in: notesContext, animated: true, dismissalCallback: nil)
                case .openSetup:
                    self?.pushSetup(notesContext)
                }
            }
            .store(in: &cancellables)
        navigationStackCoordinator.push(coordinator, animated: animated, dismissalCallback: dismissalCallback)
    }
    
    private func pushEditor(documentID: String, in notesContext: SpaceNotesContext, animated: Bool, dismissalCallback: (() -> Void)?) {
        let coordinator = NoteEditorScreenCoordinator(parameters: .init(notesContext: notesContext, documentID: documentID))
        coordinator.actionsPublisher
            .sink { [weak self] action in
                switch action {
                case .close:
                    self?.navigationStackCoordinator.pop()
                }
            }
            .store(in: &cancellables)
        navigationStackCoordinator.push(coordinator, animated: animated, dismissalCallback: dismissalCallback)
    }
    
    private func pushSetup(_ notesContext: SpaceNotesContext) {
        let coordinator = SpaceNotesSetupScreenCoordinator(parameters: .init(room: notesContext.room))
        coordinator.actionsPublisher
            .sink { [weak self] _ in
                // Done or closed, the list below shows what changed.
                self?.navigationStackCoordinator.pop()
            }
            .store(in: &cancellables)
        navigationStackCoordinator.push(coordinator)
    }
}
