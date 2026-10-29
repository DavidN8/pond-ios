//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatchaProtocol

enum TasksTabScreenViewModelAction: Equatable {
    /// Shows a chat, for Open chat and for an older standalone card.
    case presentRoom(roomID: String)
    /// Shows a thread of a chat, for a task.
    case presentThread(roomID: String, threadRootEventID: String)
    /// The task editor of a chat, over the store the tab holds for it.
    case presentEditor(roomID: String, target: TaskEditorTarget)
    case showSettings
}

struct TasksTabScreenViewState: BindableState {
    var filter: TasksTabFilter = .all
    /// The chat the list is narrowed to with Chat ▾, or nil for every chat.
    var chatFilter: TasksTabChat?
    /// The person the list is narrowed to with People ▾, or nil for everyone the user works with.
    var personFilter: TasksTabPerson?
    /// Everyone but the user that the tasks involve, for People ▾, by name.
    var people: [TasksTabPerson] = []
    /// The tasks are shown as a table rather than grouped by deadline.
    var isTable = false
    var content: TasksTabContent = .loading
    /// Chats still being checked or read, for "Checking N more chats…".
    var checkingCount = 0
    /// Chats that could not be checked or opened, for "Couldn't check N chats".
    var failedCount = 0
    /// Some tasks can't be decrypted, so the list may be out of date.
    var isUnreadable = false
    /// Some chats have older history that may hold more tasks.
    var hasMore = false
    var isLoadingMore = false
    /// All boards of a space: the space's name, empty until known; nil on the Tasks tab.
    var spaceName: String?
    /// The chats the open Choose a chat sheet lists: those with a board for Chat ▾, those where the user can add a task for New task.
    var chatChoices: [TasksTabChat] = []
    /// The bottom banner after a write: Undo after archiving, Retry after a failure.
    var banner: TaskBanner?
    /// The user's avatar at the leading edge, which opens the settings; only on the Tasks tab, a root tab.
    var userProfile: UserProfile?
    var bindings = TasksTabScreenViewStateBindings()
    
    /// The task whose actions the action sheet offers.
    var actionsTask: TabTask? {
        guard let id = bindings.actionsTaskID else { return nil }
        return content.allTasks.first { $0.id == id }
    }
    
    /// The chat choices that match the search query, by name.
    var visibleChatChoices: [TasksTabChat] {
        let query = bindings.chatSearchQuery.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? chatChoices : chatChoices.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}

struct TasksTabScreenViewStateBindings {
    var sheet: TasksTabSheet?
    var chatSearchQuery = ""
    var actionsTaskID: TabTaskID?
}

enum TasksTabScreenViewAction {
    /// The tab is on screen: its chats are read until it goes.
    case appeared
    case disappeared
    case setFilter(TasksTabFilter)
    /// Chat ▾: lists the chats to choose from, or shows every chat again when one is chosen.
    case toggleChatFilter
    /// A chat picked in the Choose a chat sheet, for its purpose.
    case chooseChat(roomID: String)
    case toggleDone
    /// People ▾: lists the people to choose from, or shows everyone's tasks again when one is chosen.
    case togglePersonFilter
    /// A person picked in the Filter by person sheet, or nil for everyone the user works with.
    case choosePerson(userID: String?)
    /// Switches between the list grouped by deadline and the table.
    case toggleTable
    /// A tapped table header: sorts by its column, or the other way round when it already does.
    case sortTable(TaskTableColumn)
    /// Tap on a task: its thread, or its chat for an older standalone card.
    case openTask(TabTaskID)
    case showActions(TabTaskID)
    case move(TabTaskID, status: TaskStatus)
    case setArchived(TabTaskID, archived: Bool)
    case editTask(TabTaskID)
    case openChat(roomID: String)
    /// New task: Choose a chat, then the editor.
    case newTask
    case dismissSheet
    case retry
    case loadMore
    case bannerAction
    case dismissBanner
    case showSettings
}

/// The filter chips, in their order.
enum TasksTabFilter: CaseIterable {
    case all, todo, doing, done, archived
}

/// The sheets the tab presents itself; the editor is the flow's.
enum TasksTabSheet: Hashable, Identifiable {
    case chooseChat(ChooseChatPurpose)
    /// People ▾: everyone the user works with, or one of them.
    case choosePerson
    
    var id: Self {
        self
    }
}

enum ChooseChatPurpose: Hashable {
    /// Chat ▾: narrow the list to one chat.
    case filter
    /// New task: the chat the task goes in.
    case newTask
}

/// A chat with a board, as listed by Chat ▾ and Choose a chat.
struct TasksTabChat: Identifiable, Equatable {
    let roomID: String
    let name: String
    let avatarURL: URL?
    
    var id: String {
        roomID
    }
    
    var avatar: RoomAvatar {
        .room(id: roomID, name: name, avatarURL: avatarURL)
    }
}

/// Someone the user's tasks involve, as listed by People ▾.
struct TasksTabPerson: Identifiable, Equatable {
    let userID: String
    let name: String
    
    var id: String {
        userID
    }
}

/// A task across chats: card ids are only unique within their chat.
struct TabTaskID: Hashable {
    let roomID: String
    let taskID: String
}

/// A task of one of the user's chats.
struct TabTask: Identifiable, Equatable {
    let chat: TasksTabChat
    let task: TaskItem
    /// When the task's thread started, for "newest first"; 0 for an older standalone card.
    let createdAt: Int64
    /// The names of the other people the task involves, for "With Bob, Carol"; empty for "Just you".
    let people: [String]
    /// The user may change the task.
    let canEdit: Bool
    /// The user may archive and restore the task, and its thread with it.
    let canArchive: Bool
    
    var id: TabTaskID {
        TabTaskID(roomID: chat.roomID, taskID: task.id)
    }
    
    /// "With Bob, Carol", or "Just you".
    var peopleLine: String {
        people.isEmpty ? UntranslatedL10n.screenMatchaTasksJustYou : UntranslatedL10n.screenMatchaTasksWithPeople(peopleCell)
    }
    
    /// The other people in a table cell: "Bob, Carol", or "Just you".
    var peopleCell: String {
        people.isEmpty ? UntranslatedL10n.screenMatchaTasksJustYou : people.joined(separator: ", ")
    }
}

/// The columns of the table of tasks, in their order.
enum TaskTableColumn: CaseIterable {
    case task, chat, status, due, people
}

/// How the table of tasks is sorted: by deadline, soonest first, until a header is tapped.
struct TaskTableSort: Equatable {
    var column = TaskTableColumn.due
    var isAscending = true
}

/// The headers that group the tasks by deadline, in their order.
enum TaskSection: CaseIterable {
    case overdue, today, tomorrow, upcoming, noDeadline
}

struct TaskGroup: Equatable, Identifiable {
    /// The header, or nil for a list without headers (Done, Archived).
    let section: TaskSection?
    let tasks: [TabTask]
    
    var id: TaskSection? {
        section
    }
}

enum TasksTabContent: Equatable {
    /// No task is known yet and chats are still being checked: placeholder rows.
    case loading
    /// None of the chats has a task.
    case empty
    /// The tasks the chips select, grouped (empty when none matches), and with All the done tasks in a collapsed "Done · N" row.
    case tasks(groups: [TaskGroup], done: [TabTask], isDoneExpanded: Bool)
    /// The tasks the chips select, one row each, sorted by `sort`; tasks without a value in the sorted column come last.
    case table(rows: [TabTask], sort: TaskTableSort)
    
    var allTasks: [TabTask] {
        switch self {
        case .loading, .empty: []
        case .tasks(let groups, let done, _): groups.flatMap(\.tasks) + done
        case .table(let rows, _): rows
        }
    }
}
