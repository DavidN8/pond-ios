//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatchaProtocol

/// A task as shown in a row or a card of a board, and in the Tasks tab.
struct TaskItem: Identifiable, Equatable {
    let id: String
    /// The task name, or nil when only the thread's event id is known; drawn as "Untitled thread".
    let title: String?
    /// The first line of the description, or empty.
    let summary: String
    let status: TaskStatus
    let isArchived: Bool
    /// The task's thread, or nil for an older standalone card.
    let threadID: String?
    let dueAt: Int64?
    /// The formatted deadline, or nil without a deadline.
    let deadline: String?
    /// The deadline has passed and the task isn't done.
    let isOverdue: Bool
    /// Replies in the task's thread, without the hidden reply that set it up; nil for a standalone card.
    let replyCount: Int?
    /// A reminder was requested; only the bot's reply confirms it, so this never says "scheduled".
    let hasReminder: Bool
    /// Shown to everyone in the chat (`show_to_room`). Never set in a direct chat, whose members are involved in every task anyway.
    let isSharedWithChat: Bool
    /// Who the task involves, the current user included when they are, in Android's order: the thread's starter first.
    let participants: [String]
}

extension MatchaRoomSnapshot {
    /// The board's tasks that `isShown` keeps, active and archived, ordered by deadline (soonest first, none last), then newest
    /// thread first, keeping the board's order otherwise.
    func taskItems(formatDeadline: (Int64) -> String, now: Date, isShown: (ProjectedCard) -> Bool) -> [TaskItem] {
        guard let cards = board?.cards.filter(isShown) else { return [] }
        let threadsByID = Dictionary(threads.map { ($0.id, $0) }) { first, _ in first }
        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
        func rootTimestamp(_ card: ProjectedCard) -> Int64 {
            card.threadID.flatMap { threadsByID[$0]?.rootTimestamp } ?? 0
        }
        return cards.enumerated()
            .sorted { lhs, rhs in
                let (lhsDue, rhsDue) = (lhs.element.dueAt ?? .max, rhs.element.dueAt ?? .max)
                if lhsDue != rhsDue {
                    return lhsDue < rhsDue
                }
                let (lhsRoot, rhsRoot) = (rootTimestamp(lhs.element), rootTimestamp(rhs.element))
                return lhsRoot != rhsRoot ? lhsRoot > rhsRoot : lhs.offset < rhs.offset
            }
            .map { _, card in
                TaskItem(id: card.id,
                         // Without a shared name or a readable root, the name falls back to the thread id.
                         title: card.title == card.threadID ? nil : card.title,
                         summary: card.description.split(whereSeparator: \.isNewline)
                             .lazy.map { $0.trimmingCharacters(in: .whitespaces) }
                             .first { !$0.isEmpty } ?? "",
                         status: card.status,
                         isArchived: card.archived,
                         threadID: card.threadID,
                         dueAt: card.dueAt,
                         deadline: card.dueAt.map(formatDeadline),
                         isOverdue: card.dueAt.map { $0 < nowMillis } == true && card.status != .done,
                         replyCount: card.threadID.map { threadsByID[$0]?.visibleReplies ?? 0 },
                         hasReminder: card.reminderRequested != nil,
                         isSharedWithChat: card.showToRoom && !isDirect,
                         participants: card.orderedParticipants)
            }
    }
}
