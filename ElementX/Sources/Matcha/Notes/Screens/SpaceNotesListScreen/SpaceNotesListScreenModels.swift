//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum SpaceNotesListScreenViewModelAction: Equatable {
    case openNote(documentID: String)
    case openSetup
}

enum SpaceNotesListContent: Equatable {
    case loading
    case loadError
    /// Notes are not turned on for the space; an admin can turn them on.
    case notSetUp(canSetUp: Bool)
    /// Space notes first, then the other notes, most recently edited first.
    case notes([NoteRowItem])
}

struct SpaceNotesListScreenViewState: BindableState {
    var spaceName: String?
    var content = SpaceNotesListContent.loading
    /// Shows New note: the user may write notes and the space is encrypted.
    var canCreate = false
    /// Some names can't be read yet: the rows show what is known.
    var hasUnreadableNames = false
    var bindings = SpaceNotesListScreenViewStateBindings()
}

struct SpaceNotesListScreenViewStateBindings {
    var nameSheet: NoteNameSheetState?
}

enum SpaceNotesListScreenViewAction {
    case appeared
    case openNote(documentID: String)
    case openSetup
    case newNote
    case rename(documentID: String)
    case updateName(String)
    case submitName
    case dismissNameSheet
    case retry
}
