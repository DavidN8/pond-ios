//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// What the chat screen under the chip bar shows.
enum ChatBarSelection: Hashable {
    case general
    case thread(id: String)
    /// The task board, which always draws the bar.
    case board
}

/// Where the chip bar or the chat's top bar asks the room flow to go.
enum ChatBarRoute: Equatable {
    /// The room timeline.
    case general
    case thread(id: String)
    case allThreads
    /// The chat's task board; with a thread, that thread's task.
    case board(threadID: String?)
    /// The Remind me sheet about the chat, or about a thread.
    case remindMe(threadID: String?)
    /// The notes of one of the chat's joined parent spaces.
    case spaceNotes(spaceID: String)
    /// A new task in the chat, from the composer's attach menu.
    case newTask
    /// The composer's sticker sheet, sending to the thread when there is one.
    case stickers(threadID: String?)
}

/// A screen that draws a chat's chip bar. The room flow follows the bar's routes only while that screen is on top.
protocol ChatBarScreen: AnyObject {
    var chatBar: ChatBarViewModel? { get }
}

extension RoomScreenCoordinator: ChatBarScreen { }
extension ThreadTimelineScreenCoordinator: ChatBarScreen { }
extension TasksBoardScreenCoordinator: ChatBarScreen { }

struct ChatBarThread: Identifiable, Equatable {
    let id: String
    /// The shared name or the root message text, or nil when only the event id is known; drawn as "Untitled thread".
    let name: String?
    let isArchived: Bool
}

struct ChatBarViewState: BindableState {
    let selection: ChatBarSelection
    /// The chat's writes and their banner, observed by the views.
    let chat: MatchaChat
    /// Draw the bar: the chat has an active named thread, or the board is shown.
    var showsBar = false
    /// Up to four active threads, newest activity first, then the open thread when it is not one of them. Empty until loaded.
    var threads: [ChatBarThread] = []
    var canCreateThread = false
    var canManageThreads = false
    /// Remind me is offered: the user can post, outside a DM or with the reminder bot in it.
    var canRemind = false
    /// Why some thread names may be missing or out of date, shown as a strip under the bar.
    var warning: MatchaWarning?
    /// To do and In progress tasks on the chat's board, counted on the top bar's board button.
    var openTaskCount = 0
    /// The open thread's name, or nil while it isn't known.
    var threadName: String?
    /// What line 2 of the chat's top bar says about the room.
    var subtitle = MatchaChatSubtitle()
    
    var bindings = ChatBarViewStateBindings()
}

/// Line 2 of a chat's top bar (WHATSAPP_DESIGN §3.3, Android's `TopBarSubtitle`).
struct MatchaChatSubtitle: Equatable {
    var isDM = false
    var isTombstoned = false
    var joinedMemberCount = 0
    
    /// Who is typing, else a group's member count; nothing in a DM without typing, or in a tombstoned room.
    func room(typingMembers: [String]) -> (text: String, isTyping: Bool)? {
        guard !isTombstoned else { return nil }
        if let typing = typing(typingMembers) {
            return (typing, true)
        }
        guard !isDM, joinedMemberCount > 0 else { return nil }
        return (UntranslatedL10n.commonMatchaMemberCount(joinedMemberCount), false)
    }
    
    /// Who is typing, else the thread's name, else "Untitled thread".
    func thread(name: String?, typingMembers: [String]) -> (text: String, isTyping: Bool) {
        typing(typingMembers).map { ($0, true) } ?? (name ?? UntranslatedL10n.commonMatchaThreadUntitled, false)
    }
    
    /// The timeline's typing notice as plain text; "typing…" in a DM.
    private func typing(_ members: [String]) -> String? {
        guard let first = members.first else { return nil }
        if isDM {
            return UntranslatedL10n.screenMatchaRoomTypingDm
        }
        return switch members.count {
        case 1: first + L10n.screenRoomTypingNotificationSingularIos
        case 2: L10n.screenRoomTypingTwoMembers(first, members[1]) + L10n.screenRoomTypingNotificationPluralIos
        default: L10n.screenRoomTypingManyMembersFirstComponentIos(first, members[1]) + L10n.commonManyMembers(members.count - 2)
            + L10n.screenRoomTypingNotificationPluralIos
        }
    }
}

struct ChatBarViewStateBindings {
    /// The New thread sheet, or the Rename thread sheet when it has a thread.
    var threadNameSheet: ThreadNameSheet?
}

struct ThreadNameSheet: Identifiable, Equatable {
    var threadID: String?
    var name: String
    var error: ThreadNameError?
    var isSending = false
    
    var id: String {
        threadID ?? "new"
    }
}

enum ThreadNameError {
    case empty
    case tooLong
    case createFailed
    case renameFailed
}

enum ChatBarViewAction {
    /// A chip was tapped; tapping the selected one does nothing.
    case select(ChatBarSelection)
    case allThreads
    case board
    case newThread
    case renameThread(id: String)
    case updateThreadName(String)
    case submitThreadName
    case setArchived(threadID: String, archived: Bool)
    case viewTask(threadID: String)
    /// About `threadID`, or else the open thread, or else the chat.
    case remindMe(threadID: String?)
    case openSpaceNotes(spaceID: String)
    case newTask
    /// The composer's sticker button.
    case stickers
}
