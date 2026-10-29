//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatchaProtocol

enum TaskEditorScreenViewModelAction: Equatable {
    /// The editor is done: saved, discarded, or the task is gone.
    case close
    /// Shows the task's thread in place of the editor.
    case openThread(threadRootEventID: String)
    /// The Remind me sheet about the task, over the editor, which stays open.
    case remindMe(RemindMeTarget, cardID: String)
}

struct TaskEditorScreenViewState: BindableState {
    var isNew: Bool
    /// The task has a thread, whose name follows the task's.
    var isLinked: Bool
    /// False when the task's thread can't be renamed by this user, so the name is read-only.
    var canRename: Bool
    /// Show to everyone in channel is offered; never in a direct chat, whose members are involved in every task anyway.
    var canShare: Bool
    var titleMaxLength: Int
    /// Names of older cards linked to the same thread.
    var earlierCards: [String] = []
    /// Remind me is offered: an active task that exists, and the user can post, outside a DM or with the reminder bot in it.
    var canRemind = false
    /// When the reminder requested for the task is due, like a deadline; nil without one.
    var reminderRequestedAt: String?
    var dueAt: Int64?
    /// Why the last deadline picked was refused.
    var deadlineError: TaskDeadlineError?
    var isDeadlinePast = false
    /// An empty name is only an error once the user has tried to save.
    var showsEmptyTitleError = false
    /// Why the last save failed; the editor stays open.
    var saveError: TaskWriteError?
    var isSaving = false
    var initial: TaskEditorFields
    var bindings: TaskEditorScreenViewStateBindings
    
    var titleError: TaskFieldError? {
        guard canRename else { return nil }
        let isValid = isLinked ? ThreadMetadataProtocol.isValidName(bindings.title) : KanbanProtocol.isValidTitle(bindings.title)
        if isValid {
            return nil
        }
        return bindings.title.isKotlinBlank ? (showsEmptyTitleError ? .empty : nil) : .tooLong(titleMaxLength)
    }
    
    var descriptionError: TaskFieldError? {
        KanbanProtocol.isValidDescription(bindings.description) ? nil : .tooLong(MatchaConfig.cardDescriptionMaxLength)
    }
    
    /// A warning only: a deadline in the past can still be saved.
    var deadlineWarning: TaskDeadlineError? {
        deadlineError ?? (isDeadlinePast ? .past : nil)
    }
    
    var fields: TaskEditorFields {
        TaskEditorFields(title: bindings.title, description: bindings.description, status: bindings.status, dueAt: dueAt, showToRoom: bindings.showToRoom)
    }
    
    /// Closing would drop changes, so it asks first. A new task's column alone isn't worth asking about, as on Android.
    var hasChanges: Bool {
        var fields = fields
        if isNew {
            fields.status = initial.status
        }
        return fields != initial
    }
}

struct TaskEditorScreenViewStateBindings {
    var title: String
    var description: String
    var status: TaskStatus
    var showToRoom: Bool
    var isDiscardConfirmationPresented = false
}

/// What the editor changes of a task.
struct TaskEditorFields: Equatable {
    var title = ""
    var description = ""
    var status = TaskStatus.todo
    var dueAt: Int64?
    var showToRoom = false
}

enum TaskEditorScreenViewAction {
    /// A deadline picked as a date and time in the device's time zone.
    case setDeadline(Date)
    case addDeadline
    case clearDeadline
    case save
    case openThread
    case remindMe
    /// Cancel or a swipe down: asks before dropping changes.
    case cancel
    case discard
}

enum TaskFieldError: Equatable {
    case empty
    case tooLong(Int)
    
    var message: String {
        switch self {
        case .empty: UntranslatedL10n.commonMatchaErrorNameEmpty
        case .tooLong(let maxLength): UntranslatedL10n.commonMatchaErrorMaxChars(maxLength.formatted())
        }
    }
}

enum TaskDeadlineError: Equatable {
    /// A warning only: saving is still allowed.
    case past
    /// The local time doesn't exist, because the clocks change then.
    case skipped
    case outOfRange
    
    var message: String {
        switch self {
        case .past: UntranslatedL10n.screenMatchaTasksDeadlinePast
        case .skipped: UntranslatedL10n.screenMatchaTasksDeadlineSkipped
        case .outOfRange: UntranslatedL10n.screenMatchaTasksDeadlineRange
        }
    }
}
