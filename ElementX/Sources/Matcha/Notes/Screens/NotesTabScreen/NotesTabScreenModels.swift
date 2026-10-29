//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum NotesTabScreenViewModelAction: Equatable {
    /// Shows a note of a space, or the space's notes list when `documentID` is nil.
    case openNote(spaceID: String, documentID: String?)
    case showSettings
}

/// A space, as its section header and Choose a space show it.
struct NotesTabSpace: Equatable, Identifiable {
    let id: String
    let name: String
    /// For a subspace, the name of the space it is listed under, shown below its own.
    let parentName: String?
    let avatarURL: URL?
    
    var avatar: RoomAvatar {
        .space(id: id, name: name, avatarURL: avatarURL)
    }
}

enum NotesTabContent: Equatable {
    /// The spaces are still being checked and none is known to have notes yet: skeleton rows.
    case loading
    /// No space to list: the user has none, or none has notes and the user can't turn them on in any.
    case empty(hasSpaces: Bool)
    /// A section per space, in the Spaces list's order, each top-level space followed by its subspaces.
    case spaces([NotesSection])
}

struct NotesSection: Equatable, Identifiable {
    let space: NotesTabSpace
    let content: NotesSectionContent
    
    var id: String {
        space.id
    }
}

enum NotesSectionContent: Equatable {
    /// The space's notes are being read, or wait to come on screen.
    case loading
    /// The space's notes couldn't be read: a row with Retry.
    case loadError
    /// Notes are off and the user can turn them on: one quiet row.
    case turnOn
    /// Space notes first, then the others, most recently edited first.
    case notes([NoteRowItem])
}

/// The New note sheet. Both steps share one identity, so choosing a space turns the sheet into the name form without dismissing it.
enum NotesTabSheet: Equatable, Identifiable {
    /// New note, when several spaces can take one.
    case chooseSpace([NotesTabSpace])
    /// The new note's name.
    case name(NoteNameSheetState)
    
    var id: String {
        "new-note"
    }
}

struct NotesTabScreenViewState: BindableState {
    var content = NotesTabContent.loading
    /// Shows New note: at least one space can take a new note.
    var canCreate = false
    /// The user's avatar at the leading edge, which opens the settings; none where the tab isn't a root tab (previews, tests).
    var userProfile: UserProfile?
    var bindings = NotesTabScreenViewStateBindings()
}

struct NotesTabScreenViewStateBindings {
    var sheet: NotesTabSheet?
}

enum NotesTabScreenViewAction {
    case appeared
    case disappeared
    /// Opens a note, or the space's notes list when `documentID` is nil.
    case openNote(spaceID: String, documentID: String?)
    case retry(spaceID: String)
    /// A row of the space's section came on screen or went: only the spaces on screen have their notes read.
    case rowAppeared(spaceID: String, rowID: String)
    case rowDisappeared(spaceID: String, rowID: String)
    /// The name sheet, after Choose a space when several spaces can take the note.
    case newNote
    case chooseSpace(spaceID: String)
    case updateName(String)
    case submitName
    case dismissSheet
    case showSettings
}
