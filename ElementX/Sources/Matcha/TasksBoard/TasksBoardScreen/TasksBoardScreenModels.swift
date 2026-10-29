//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatchaProtocol

enum TasksBoardScreenViewModelAction: Equatable {
    case presentThread(threadRootEventID: String)
    case presentEditor(TaskEditorTarget)
    case presentArchived
    /// The Remind me sheet about a task, which records the request on its card.
    case presentRemindMe(RemindMeTarget, cardID: String)
}

struct TasksBoardScreenViewState: BindableState {
    var roomName: String
    var content: TasksBoardContent = .lookingForBoard
    /// The bottom banner after a write: Undo after archiving, Retry after a failure.
    var banner: TaskBanner?
    var bindings = TasksBoardScreenViewStateBindings()
    
    /// The task whose actions are offered in the action sheet.
    var actionsTask: TaskItem? {
        guard let id = bindings.actionsTaskID, case .board(let board) = content else { return nil }
        return board.allTasks.first { $0.id == id }
    }
}

struct TasksBoardScreenViewStateBindings {
    /// The status shown on a compact board.
    var selectedStatus: TaskStatus = .todo
    var actionsTaskID: String?
}

enum TasksBoardScreenViewAction {
    case createBoard
    case retryLoad
    /// A tap on a task: its thread, or the editor for an older standalone card.
    case openTask(id: String)
    case showActions(id: String)
    case move(id: String, status: TaskStatus)
    case setArchived(id: String, archived: Bool)
    /// The New task button, on the tab of `status` (To do on a wide board).
    case newTask(status: TaskStatus)
    case editTask(id: String)
    case remindMe(id: String)
    case showArchived
    case loadMore
    case bannerAction
    case dismissBanner
}

enum TasksBoardContent: Equatable {
    /// The board isn't proven absent yet, so creating one could replace one made elsewhere; the history is being read.
    case lookingForBoard
    /// The Matcha data of the chat could not be opened, or its history could not be read to look for the board.
    case loadFailed
    /// The chat has no board.
    case setup(canCreate: Bool, isCreating: Bool, createFailed: Bool)
    case board(TasksBoard)
}

struct TasksBoard: Equatable {
    var todo: [TaskItem] = []
    var doing: [TaskItem] = []
    var done: [TaskItem] = []
    var archived: [TaskItem] = []
    /// Tasks hidden from this board (not shared and not involving the user), which still open from their thread.
    var hidden: [TaskItem] = []
    /// The tasks are still being read: placeholder rows stand in for them.
    var isLoading = false
    /// The user may change tasks; otherwise the board is read-only.
    var canEdit = true
    /// The user may rename and archive threads, so also linked tasks.
    var canManageThreads = true
    /// The user may add tasks, which also creates their threads.
    var canAdd = true
    /// Remind me is offered on active tasks: the user can post, and outside a DM or with the reminder bot in it.
    var canRemind = false
    /// Some task updates can't be decrypted, so the board may be out of date.
    var isUnreadable = false
    var hasMore = false
    var isLoadingMore = false
    
    var allTasks: [TaskItem] {
        todo + doing + done + archived + hidden
    }
    
    func tasks(_ status: TaskStatus) -> [TaskItem] {
        switch status {
        case .todo: todo
        case .doing: doing
        case .done: done
        }
    }
    
    func canArchive(_ task: TaskItem) -> Bool {
        MatchaPermissions(canManageThreads: canManageThreads, canWriteCards: canEdit).canArchive(threadID: task.threadID)
    }
}

/// A banner over the bottom of the board, with an optional action.
struct TaskBanner: Equatable, Identifiable {
    let id = UUID()
    let message: String
    let actionTitle: String?
}

/// What the task editor opens on.
enum TaskEditorTarget: Hashable {
    /// A new task, which also creates its thread.
    case new(status: TaskStatus)
    case edit(taskID: String)
}
