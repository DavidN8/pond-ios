//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum NoteEditorScreenViewModelAction {
    case close
}

/// The navigation bar's subtitle.
enum NoteStatus: Equatable {
    case loading
    case saving
    case saved
    case offline
    case failed
    case viewOnly
    case earlierChat
}

/// The notice under the navigation bar.
enum NoteNotice: Equatable {
    case offline
    case decryptError
    case incomplete
    case invalid
    case permissionError
    case tooLarge
}

struct NoteEditorScreenViewState: BindableState {
    /// The note's name; nil for Space notes before anyone names it.
    var title: String?
    var status = NoteStatus.loading
    var notice: NoteNotice?
    /// The note could not be loaded at all: a full-page error with Retry.
    var isLoadError = false
    /// The Markdown, including edits not saved yet.
    var text = ""
    /// `text` read as Markdown for the preview; it may lag behind `text` while it is read.
    var blocks: [MarkdownBlock] = []
    /// Typed edits are still going into the document, so `text` may lag behind the field.
    var isApplyingEdits = false
    var isEditing = false
    var canEdit = false
    var canRename = false
    /// Edits that have not reached the server: leaving loses them.
    var hasUnsavedChanges = false
    var bindings = NoteEditorScreenViewStateBindings()
    
    var displayTitle: String {
        title ?? UntranslatedL10n.screenMatchaDocsMainName
    }
}

struct NoteEditorScreenViewStateBindings {
    var isShowingLeaveAlert = false
    var isSharingText = false
    var nameSheet: NoteNameSheetState?
}

enum NoteEditorScreenViewAction: CustomStringConvertible {
    /// The text field changed from `before` to `after`.
    case edit(before: String, after: String)
    case startEditing
    case stopEditing
    case retry
    case back
    case confirmLeave
    case shareFromLeaveAlert
    case rename
    case updateName(String)
    case submitName
    case dismissNameSheet
    /// The app went to the background: unsent edits go now.
    case enteredBackground
    
    /// Never the note's text.
    var description: String {
        switch self {
        case .edit: "edit"
        case .startEditing: "startEditing"
        case .stopEditing: "stopEditing"
        case .retry: "retry"
        case .back: "back"
        case .confirmLeave: "confirmLeave"
        case .shareFromLeaveAlert: "shareFromLeaveAlert"
        case .rename: "rename"
        case .updateName: "updateName"
        case .submitName: "submitName"
        case .dismissNameSheet: "dismissNameSheet"
        case .enteredBackground: "enteredBackground"
        }
    }
}
