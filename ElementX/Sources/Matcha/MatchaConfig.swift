//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import MatchaProtocol

/// How much the app reads and how long it waits, as on Android. The event types, limits and the reminder bot are the
/// protocol's, in `MatchaProtocol.MatchaConfig`.
nonisolated extension MatchaConfig {
    /// The types of the room store's scan timeline: Matcha's events and state, and the encrypted events among which an
    /// undecryptable Matcha event hides.
    static let scanTimelineEventTypes = messageLikeEventTypes.union(stateEventTypes).union([DocsProtocol.eventRoomEncrypted])
    
    /// Events per `fetchRelatedEventsJSON` page, and the pages read per anchor before giving up.
    static let relationsPageSize = 100
    static let maxRelationPages = 50
    /// Anchors (board root, thread roots, the documents' `m.room.create`) whose related events are read at once.
    static let maxConcurrentAnchors = 4
    static let anchorsTimeout: Duration = .seconds(30)
    /// Scan timeline pages read on open, and the events per page.
    static let initialHistoryPages = 10
    static let historyPageSize: UInt16 = 50
    /// How long the store waits after a sync change before reading the stored room state again.
    static let storedStateDebounce: Duration = .milliseconds(200)
    
    /// Chats the Tasks tab checks for a board at once, and how long it waits for one chat's store.
    static let tasksTabMaxConcurrentChecks = 4
    static let tasksTabStoreLoadTimeout: Duration = .seconds(30)
    /// How long the boards the Tasks tab opened stay open after the tab is left.
    static let tasksTabKeepAlive: Duration = .seconds(2 * 60)
    /// How long a homeserver's "this chat has no board" answer is reused.
    static let noBoardAnswerLifetime: Duration = .seconds(10 * 60)
}
