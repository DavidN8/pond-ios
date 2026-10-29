//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

typealias SpaceNotesListScreenViewModelType = StateStoreViewModelV2<SpaceNotesListScreenViewState, SpaceNotesListScreenViewAction>

/// The notes of a space: Space notes first, then the others by last edit, with New note and Rename. A name being saved keeps
/// saving when its sheet is dismissed; a failure shows the sheet again, and a new note opens once saved.
class SpaceNotesListScreenViewModel: SpaceNotesListScreenViewModelType, SpaceNotesListScreenViewModelProtocol {
    private let notesContext: SpaceNotesContext
    private let setup: SpaceNotesSetup
    private var setupStatus: SpaceNotesStatus?
    private var catalogState = CatalogState.loading
    private var lastEdits: [String: Int64] = [:]
    /// The sheet whose name is being saved, shown or not.
    private var savingSheet: NoteNameSheetState?
    private var setupStatusRead: Task<Void, Never>?
    
    private let actionsSubject: PassthroughSubject<SpaceNotesListScreenViewModelAction, Never> = .init()
    var actionsPublisher: AnyPublisher<SpaceNotesListScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(notesContext: SpaceNotesContext) {
        self.notesContext = notesContext
        setup = SpaceNotesSetup(room: notesContext.room)
        super.init(initialViewState: SpaceNotesListScreenViewState(spaceName: notesContext.room.infoPublisher.value.displayName))
        
        notesContext.catalog?.statePublisher
            .sink { [weak self] state in
                self?.catalogState = state
                self?.updateContent()
            }
            .store(in: &cancellables)
        notesContext.store.snapshotPublisher
            .map { NoteRowItem.lastEdits($0.events) }
            .removeDuplicates()
            .sink { [weak self] edits in
                self?.lastEdits = edits
                self?.updateContent()
            }
            .store(in: &cancellables)
        // Turning notes on changes encryption and power levels, which arrive with the room info.
        notesContext.room.infoPublisher
            .sink { [weak self] info in
                self?.state.spaceName = info.displayName
                self?.refreshSetupStatus()
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Public
    
    override func process(viewAction: SpaceNotesListScreenViewAction) {
        switch viewAction {
        case .appeared:
            refreshSetupStatus()
        case .openNote(let documentID):
            actionsSubject.send(.openNote(documentID: documentID))
        case .openSetup:
            actionsSubject.send(.openSetup)
        case .newNote:
            state.bindings.nameSheet = savingSheet ?? .new()
        case .rename(let documentID):
            guard state.canCreate, savingSheet == nil else { return }
            let title = catalogState.documents.first { $0.id == documentID }?.title ?? ""
            state.bindings.nameSheet = .rename(documentID: documentID, name: title)
        case .updateName(let name):
            guard let sheet = state.bindings.nameSheet, !sheet.isSaving else { return }
            state.bindings.nameSheet = sheet.updating(name: name)
        case .submitName:
            submitName()
        case .dismissNameSheet:
            // A name being saved keeps saving; its sheet comes back if the save fails.
            state.bindings.nameSheet = nil
        case .retry:
            Task { await notesContext.catalog?.retry() }
        }
    }
    
    // MARK: - Private
    
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
            case .success(let documentID):
                if state.bindings.nameSheet?.id == saving.id {
                    state.bindings.nameSheet = nil
                }
                if saving.isNew {
                    actionsSubject.send(.openNote(documentID: documentID))
                }
            case .failure(let error):
                MXLog.warning("Could not save a note name: \(error.error)")
                state.bindings.nameSheet = saving.saveFailed(error)
            }
        }
    }
    
    /// The latest read wins: an older one can answer last, with the state from before notes were turned on.
    private func refreshSetupStatus() {
        setupStatusRead?.cancel()
        setupStatusRead = Task {
            let status = await setup.status()
            guard !Task.isCancelled else { return }
            setupStatus = status
            updateContent()
        }
    }
    
    private func updateContent() {
        let content: SpaceNotesListContent = if let setupStatus, !setupStatus.isConfigured {
            .notSetUp(canSetUp: setupStatus.canSetUp)
        } else if setupStatus == nil {
            .loading
        } else if notesContext.catalog == nil || catalogState.isLoadFailed {
            .loadError
        } else if catalogState.sync == .loading, catalogState.documents.count <= 1 {
            // Partial content is shown as soon as it exists, so a skeleton only stands for an empty catalog.
            .loading
        } else {
            .notes(NoteRowItem.rows(catalogState.documents, lastEdits: lastEdits))
        }
        let isShowingNotes = if case .notes = content {
            true
        } else {
            false
        }
        state.content = content
        state.canCreate = isShowingNotes && catalogState.canEdit
        state.hasUnreadableNames = isShowingNotes && (catalogState.error == .decryptError || catalogState.error == .incompleteUpdate)
    }
}
