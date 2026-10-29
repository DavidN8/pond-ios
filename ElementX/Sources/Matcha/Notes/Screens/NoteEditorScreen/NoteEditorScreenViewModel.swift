//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import MatchaProtocol
import SwiftUI

typealias NoteEditorScreenViewModelType = StateStoreViewModelV2<NoteEditorScreenViewState, NoteEditorScreenViewAction>

/// One note: a preview of its Markdown, edit mode with a text field whose changes go into the shared document, and honest save
/// states. The document session lives as long as the screen; edits not acknowledged when leaving are lost, after a warning.
class NoteEditorScreenViewModel: NoteEditorScreenViewModelType, NoteEditorScreenViewModelProtocol {
    private let notesContext: SpaceNotesContext
    private let documentID: String
    private let session: RoomDocumentSession
    
    private var documentState: DocumentSessionState
    private var catalogState: CatalogState?
    private var isOffline = false
    private var roomName: String?
    private var applyingEdits = 0
    private var isLeaving = false
    private var parsedText: String?
    private var parseTask: Task<Void, Never>?
    /// The sheet whose name is being saved, shown or not.
    private var savingSheet: NoteNameSheetState?
    
    private let actionsSubject: PassthroughSubject<NoteEditorScreenViewModelAction, Never> = .init()
    var actionsPublisher: AnyPublisher<NoteEditorScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(notesContext: SpaceNotesContext, documentID: String) {
        self.notesContext = notesContext
        self.documentID = documentID
        session = notesContext.openDocument(documentID)
        documentState = session.state
        catalogState = notesContext.catalog?.state
        super.init(initialViewState: NoteEditorScreenViewState())
        
        session.statePublisher
            .sink { [weak self] state in
                self?.documentState = state
                self?.updateState()
            }
            .store(in: &cancellables)
        notesContext.catalog?.statePublisher
            .sink { [weak self] state in
                self?.catalogState = state
                self?.updateState()
            }
            .store(in: &cancellables)
        notesContext.reachability
            .removeDuplicates()
            .sink { [weak self] reachability in
                self?.isOffline = reachability == .unreachable
                self?.updateState()
            }
            .store(in: &cancellables)
        notesContext.room.infoPublisher
            .map(\.displayName)
            .removeDuplicates()
            .sink { [weak self] name in
                self?.roomName = name
                self?.updateState()
            }
            .store(in: &cancellables)
    }
    
    func stop() {
        parseTask?.cancel()
        session.close()
    }
    
    // MARK: - Public
    
    override func process(viewAction: NoteEditorScreenViewAction) {
        switch viewAction {
        case .edit(let before, let after):
            guard state.canEdit else { return }
            applyingEdits += 1
            updateState()
            Task {
                await session.edit(from: before, to: after)
                applyingEdits -= 1
                updateState()
            }
        case .startEditing:
            if state.canEdit {
                state.isEditing = true
            }
        case .stopEditing:
            state.isEditing = false
            Task { await session.flush() }
        case .retry:
            Task {
                // A failed save only needs sending again; anything else reads the note again.
                if session.state.error != .sendError {
                    await notesContext.catalog?.retry()
                    await session.retry().value
                }
                await session.flush()
            }
        case .back:
            back()
        case .confirmLeave:
            state.bindings.isShowingLeaveAlert = false
            actionsSubject.send(.close)
        case .shareFromLeaveAlert:
            state.bindings.isShowingLeaveAlert = false
            state.bindings.isSharingText = true
        case .rename:
            guard state.canRename, savingSheet == nil else {
                state.bindings.nameSheet = savingSheet
                return
            }
            state.bindings.nameSheet = .rename(documentID: documentID, name: state.title ?? "")
        case .updateName(let name):
            guard let sheet = state.bindings.nameSheet, !sheet.isSaving else { return }
            state.bindings.nameSheet = sheet.updating(name: name)
        case .submitName:
            submitName()
        case .dismissNameSheet:
            // A name being saved keeps saving; its sheet comes back if the save fails.
            state.bindings.nameSheet = nil
        case .enteredBackground:
            Task { await session.flush() }
        }
    }
    
    // MARK: - Private
    
    private func back() {
        if state.isEditing {
            state.isEditing = false
        } else if !state.hasUnsavedChanges {
            actionsSubject.send(.close)
        } else if !isLeaving {
            // Edits still waiting for the debounce go now; only what the server refused is at risk.
            isLeaving = true
            Task {
                await session.flush()
                isLeaving = false
                if session.state.pendingUpdates > 0 {
                    state.bindings.isShowingLeaveAlert = true
                } else {
                    actionsSubject.send(.close)
                }
            }
        }
    }
    
    private func submitName() {
        guard let sheet = state.bindings.nameSheet, !sheet.isSaving, let catalog = notesContext.catalog else { return }
        if let invalid = sheet.withNameError() {
            state.bindings.nameSheet = invalid
            return
        }
        var saving = sheet
        saving.isSaving = true
        saving.error = nil
        savingSheet = saving
        state.bindings.nameSheet = saving
        Task { [weak self] in
            let result = await saving.save(in: catalog)
            guard let self else { return }
            savingSheet = nil
            switch result {
            case .success:
                if state.bindings.nameSheet?.id == saving.id {
                    state.bindings.nameSheet = nil
                }
            case .failure(let error):
                MXLog.warning("Could not rename a note: \(error.error)")
                state.bindings.nameSheet = saving.saveFailed(error)
            }
        }
    }
    
    private func updateState() {
        let isEarlier = notesContext.isEarlierChatDocument
        let document = catalogState?.documents.first { $0.id == documentID }
        let canWriteCatalog = !isEarlier && catalogState?.canEdit == true && document != nil
        let canEdit = documentState.canEdit && canWriteCatalog
        let hasUnsaved = documentState.pendingUpdates > 0
        
        state.title = if isEarlier {
            roomName ?? ""
        } else if let document {
            document.title
        } else {
            documentID == DocsProtocol.mainDocumentID ? nil : ""
        }
        state.status = status(isEarlier: isEarlier, canEdit: canEdit)
        state.notice = notice(isOffline: isOffline && !isEarlier && (canEdit || hasUnsaved))
        state.isLoadError = documentState.error.map(Self.loadErrors.contains) == true || catalogState?.isReady == true && document == nil
        state.text = documentState.text
        state.isApplyingEdits = applyingEdits > 0
        state.canEdit = canEdit
        // Losing the right to edit, or an error, ends edit mode; the notice says why.
        state.isEditing = state.isEditing && canEdit
        state.canRename = canWriteCatalog
        state.hasUnsavedChanges = hasUnsaved
        parseIfNeeded(documentState.text)
    }
    
    /// Any member writes the text, and a long note takes a while to read, so it is read off the main actor.
    private func parseIfNeeded(_ text: String) {
        guard text != parsedText else { return }
        parsedText = text
        parseTask?.cancel()
        parseTask = Task { [weak self] in
            let blocks = await MarkdownParser.parseInBackground(text)
            guard !Task.isCancelled else { return }
            self?.state.blocks = blocks
        }
    }
    
    private func status(isEarlier: Bool, canEdit: Bool) -> NoteStatus {
        let hasUnsaved = documentState.pendingUpdates > 0
        if documentState.sync == .loading || catalogState?.sync == .loading {
            return .loading
        } else if isEarlier {
            return .earlierChat
        } else if documentState.error == .sendError {
            return isOffline ? .offline : .failed
        } else if hasUnsaved, documentState.error != nil {
            return .failed
        } else if !canEdit {
            return .viewOnly
        } else {
            return hasUnsaved ? .saving : .saved
        }
    }
    
    private func notice(isOffline: Bool) -> NoteNotice? {
        switch documentState.error {
        case .decryptError: .decryptError
        case .incompleteUpdate: .incomplete
        case .invalidUpdate: .invalid
        case .permissionError: .permissionError
        case .tooLargeError: .tooLarge
        default: isOffline ? .offline : nil
        }
    }
    
    private static let loadErrors: Set<DocumentError> = [.loadError, .anchorError]
}

nonisolated extension MarkdownParser {
    @concurrent
    static func parseInBackground(_ markdown: String) async -> [MarkdownBlock] {
        parse(markdown)
    }
}
