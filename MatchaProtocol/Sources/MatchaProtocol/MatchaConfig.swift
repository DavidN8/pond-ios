//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

/// Matcha workspace features (named threads, task boards, reminders, documents), shared with the Matcha web and Android clients.
/// The event types and limits are a wire protocol: they must stay identical to theirs.
public enum MatchaConfig {
    /// Encrypted timeline patch carrying a thread's shared name and archive state, related to the thread root by m.reference.
    public static let eventThreadMetadata = "com.matchahoneylatte.thread.metadata"
    /// Legacy, read-only state event with a thread's archive flag; the state key is the thread root id.
    public static let stateThreadArchive = "com.matchahoneylatte.thread_archive"
    /// State event, empty state key, pointing at the room's board root event.
    public static let stateKanban = "com.matchahoneylatte.kanban"
    /// Timeline event used as the board root that card revisions relate to.
    public static let eventKanbanBoard = "com.matchahoneylatte.kanban.board"
    /// A complete card revision, related to the board root by m.reference.
    public static let eventKanbanCard = "com.matchahoneylatte.kanban.card"
    /// A Yjs document update frame, related to the room's m.room.create event by m.reference.
    public static let eventDocsUpdate = "com.matchahoneylatte.docs.update"
    
    /// Timeline event types the Matcha features read; they are hidden from the regular timelines.
    public static let messageLikeEventTypes: Set<String> = [eventThreadMetadata, eventKanbanBoard, eventKanbanCard, eventDocsUpdate]
    /// State event types the Matcha features read.
    public static let stateEventTypes: Set<String> = [stateKanban, stateThreadArchive]
    
    /// The localpart of the bot that schedules and delivers `!remind` commands; each homeserver runs its own.
    public static let reminderBotLocalpart = "matcha-reminder"
    
    public static let relationTypeReference = "m.reference"
    public static let relationTypeThread = "m.thread"
    
    public static let threadNameMaxLength = 100
    public static let cardTitleMaxLength = 200
    public static let cardDescriptionMaxLength = 4000
    public static let documentNameMaxLength = 100
    public static let reminderMessageMaxLength = 2000
    public static let reminderMaxDelayDays: Int64 = 365
    
    /// Raw Yjs bytes per document frame; leaves room for base64, JSON and the encryption envelope under 64 KiB.
    public static let docsChunkBytes = 16 * 1024
    public static let docsMaxChunks = 256
    
    /// The reminder bot of the homeserver of `userID`: `@matcha-reminder:<server name>`.
    public static func reminderBotUserID(sessionUserID userID: String) -> String {
        let serverName = userID.split(separator: ":", maxSplits: 1).dropFirst().first ?? Substring(userID)
        return "@\(reminderBotLocalpart):\(serverName)"
    }
}
