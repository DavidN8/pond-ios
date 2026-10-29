//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

typealias NotesTabScreenViewModelType = StateStoreViewModelV2<NotesTabScreenViewState, NotesTabScreenViewAction>

/// The Notes tab: a section per joined space with its notes, read by `NotesTabReader` while the tab is on screen, and New note. A
/// new note is named in its space's own catalog, which is opened with the name sheet and closed with it. A sheet dismissed while it
/// saves is only hidden: the save finishes, even once the tab is left, and the note then opens if the tab is still on screen.
class NotesTabScreenViewModel: NotesTabScreenViewModelType, NotesTabScreenViewModelProtocol {
    private let reader: NotesTabReader
    private let contextFactory: SpaceNotesContextFactory
    private let loadTimeout: Duration
    private var spaces: [NotesSpace]?
    /// The rows on screen, by space: an appearance reported twice still counts once.
    private var visibleRows = Set<VisibleRow>()
    private var isOnScreen = false
    private var isChoosingSpace = false
    private var nameSheet: NameSheet?
    
    private struct VisibleRow: Hashable {
        let spaceID: String
        let rowID: String
    }
    
    /// The name sheet of a new note, with the catalog it saves in.
    private final class NameSheet {
        let spaceID: String
        var state = NoteNameSheetState.new()
        /// Dismissed while saving: hidden until the save fails or New note is tapped again.
        var isHidden = false
        private let context: Task<SpaceNotesContext?, Never>
        private var isClosed = false
        
        init(spaceID: String, contextFactory: SpaceNotesContextFactory) {
            self.spaceID = spaceID
            // The catalog reads the space while the name is typed.
            context = Task { await contextFactory.makeContext(roomID: spaceID) }
        }
        
        var catalog: DocumentCatalog? {
            get async {
                await context.value?.catalog
            }
        }
        
        func close() {
            guard !isClosed else { return }
            isClosed = true
            Task { [context] in await context.value?.close() }
        }
    }
    
    private let actionsSubject: PassthroughSubject<NotesTabScreenViewModelAction, Never> = .init()
    var actionsPublisher: AnyPublisher<NotesTabScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(reader: NotesTabReader,
         contextFactory: SpaceNotesContextFactory,
         mediaProvider: MediaProviderProtocol?,
         userProfilePublisher: CurrentValuePublisher<UserProfile, Never>? = nil,
         loadTimeout: Duration = NotesTabReader.loadTimeout) {
        self.reader = reader
        self.contextFactory = contextFactory
        self.loadTimeout = loadTimeout
        super.init(initialViewState: NotesTabScreenViewState(userProfile: userProfilePublisher?.value), mediaProvider: mediaProvider)
        
        userProfilePublisher?
            .map(Optional.some)
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.state.userProfile, on: self)
            .store(in: &cancellables)
        
        reader.spacesPublisher
            .sink { [weak self] spaces in
                self?.spaces = spaces
                self?.updateState()
            }
            .store(in: &cancellables)
    }
    
    func stop() {
        reader.stop()
        closeNameSheet()
    }
    
    // MARK: - Public
    
    override func process(viewAction: NotesTabScreenViewAction) {
        switch viewAction {
        case .appeared:
            isOnScreen = true
            reader.start()
            // Rows still counted as on screen may not appear again when a pushed screen is popped.
            reader.setShown(shownSpaces)
        case .disappeared:
            isOnScreen = false
            // Leaving the tab, or pushing a note above it, closes every catalog the tab opened.
            reader.stop()
        case .openNote(let spaceID, let documentID):
            actionsSubject.send(.openNote(spaceID: spaceID, documentID: documentID))
        case .retry(let spaceID):
            reader.retry(spaceID: spaceID)
        case .rowAppeared(let spaceID, let rowID):
            visibleRows.insert(VisibleRow(spaceID: spaceID, rowID: rowID))
            reader.setShown(shownSpaces)
        case .rowDisappeared(let spaceID, let rowID):
            visibleRows.remove(VisibleRow(spaceID: spaceID, rowID: rowID))
            reader.setShown(shownSpaces)
        case .newNote:
            newNote()
        case .chooseSpace(let spaceID):
            guard isChoosingSpace, newNoteSpaces.contains(where: { $0.id == spaceID }) else { return }
            isChoosingSpace = false
            nameSheet = NameSheet(spaceID: spaceID, contextFactory: contextFactory)
        case .updateName(let name):
            guard let nameSheet, !nameSheet.state.isSaving else { return }
            nameSheet.state = nameSheet.state.updating(name: name)
        case .submitName:
            submitName()
        case .dismissSheet:
            if let nameSheet {
                if nameSheet.state.isSaving {
                    nameSheet.isHidden = true
                } else {
                    closeNameSheet()
                }
            }
            isChoosingSpace = false
        case .showSettings:
            actionsSubject.send(.showSettings)
        }
        updateSheet()
    }
    
    // MARK: - Private
    
    private var shownSpaces: Set<String> {
        Set(visibleRows.map(\.spaceID))
    }
    
    /// The spaces whose catalog can take a note; a catalog not read yet is assumed writable, and creating checks it.
    private var newNoteSpaces: [NotesSpace] {
        (spaces ?? []).filter { space in
            guard case .on(let read) = space.notes, !read.isFailed else { return false }
            return read.catalog.map { $0.sync == .loading || $0.canEdit } ?? true
        }
    }
    
    private func newNote() {
        // A note still saving after its sheet was dismissed shows that sheet again, rather than a second note being started.
        if let nameSheet {
            nameSheet.isHidden = false
            return
        }
        let targets = newNoteSpaces
        if targets.count == 1, let target = targets.first {
            nameSheet = NameSheet(spaceID: target.id, contextFactory: contextFactory)
        } else if !targets.isEmpty {
            isChoosingSpace = true
        }
    }
    
    private func submitName() {
        guard let sheet = nameSheet, !sheet.state.isSaving else { return }
        if let invalid = sheet.state.withNameError() {
            sheet.state = invalid
            return
        }
        let current = sheet.state
        // Saving from here on, so a dismissal from now only hides the sheet.
        sheet.state.isSaving = true
        sheet.state.error = nil
        Task { [weak self, loadTimeout] in
            let result: Result<String, CatalogError>
            if let catalog = await sheet.catalog {
                // The name can be typed before the catalog has read the space.
                _ = await firstValue(of: catalog.statePublisher, timeout: loadTimeout) { $0.sync != .loading }
                result = await current.save(in: catalog)
            } else {
                result = .failure(.init(error: .loadError))
            }
            guard let self, nameSheet === sheet else {
                sheet.close()
                return
            }
            switch result {
            case .success(let documentID):
                // Like the space's list, a new note opens once saved, even when its sheet was dismissed while it saved; but not over
                // a note opened above the tab meanwhile, which would go with its unsent edits.
                closeNameSheet()
                if isOnScreen {
                    actionsSubject.send(.openNote(spaceID: sheet.spaceID, documentID: documentID))
                }
            case .failure(let error):
                MXLog.warning("Could not create a note in \(sheet.spaceID): \(error.error)")
                sheet.state = current.saveFailed(error)
                sheet.isHidden = false
            }
            updateSheet()
        }
    }
    
    private func closeNameSheet() {
        nameSheet?.close()
        nameSheet = nil
    }
    
    private func updateState() {
        let all = spaces ?? []
        let sections = all.compactMap(Self.section)
        state.content = if !sections.isEmpty {
            .spaces(sections)
        } else if spaces == nil || all.contains(where: { $0.notes == .unknown }) {
            .loading
        } else {
            .empty(hasSpaces: !all.isEmpty)
        }
        state.canCreate = !newNoteSpaces.isEmpty
        updateSheet()
    }
    
    private func updateSheet() {
        state.bindings.sheet = if let nameSheet {
            nameSheet.isHidden ? nil : .name(nameSheet.state)
        } else if isChoosingSpace {
            .chooseSpace(newNoteSpaces.map(Self.tabSpace))
        } else {
            nil
        }
    }
    
    private static func section(_ space: NotesSpace) -> NotesSection? {
        let content: NotesSectionContent
        switch space.notes {
        case .unknown, .off:
            return nil
        case .canTurnOn:
            content = .turnOn
        case .on(let read):
            if read.isFailed {
                content = .loadError
            } else if let catalog = read.catalog, catalog.sync != .loading || catalog.documents.count > 1 {
                // Partial content is shown as soon as it exists, so a skeleton only stands for an empty catalog.
                content = .notes(NoteRowItem.rows(catalog.documents, lastEdits: read.lastEdits))
            } else {
                content = .loading
            }
        }
        return NotesSection(space: tabSpace(space), content: content)
    }
    
    private static func tabSpace(_ space: NotesSpace) -> NotesTabSpace {
        NotesTabSpace(id: space.id, name: space.name, parentName: space.parentName, avatarURL: space.avatarURL)
    }
}
