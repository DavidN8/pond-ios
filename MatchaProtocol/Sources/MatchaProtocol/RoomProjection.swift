//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

/// A thread of the SDK's thread list, with what the room projection reads of it.
public struct ListedThread: Sendable, Hashable {
    public var id: String
    /// The root message's text; nil when the root is not a message, or can't be decrypted.
    public var rootBody: String?
    public var rootSenderID: String
    /// Milliseconds since the epoch, like every timestamp here.
    public var rootTimestamp: Int64
    /// The root can't be decrypted on this device, so a name taken from it is missing.
    public var isRootUnreadable: Bool
    public var latestSenderID: String?
    public var latestTimestamp: Int64?
    public var numberOfReplies: Int
    
    public init(id: String,
                rootBody: String?,
                rootSenderID: String,
                rootTimestamp: Int64,
                isRootUnreadable: Bool = false,
                latestSenderID: String? = nil,
                latestTimestamp: Int64? = nil,
                numberOfReplies: Int) {
        self.id = id
        self.rootBody = rootBody
        self.rootSenderID = rootSenderID
        self.rootTimestamp = rootTimestamp
        self.isRootUnreadable = isRootUnreadable
        self.latestSenderID = latestSenderID
        self.latestTimestamp = latestTimestamp
        self.numberOfReplies = numberOfReplies
    }
}

/// A thread of a room with its shared Matcha metadata.
public struct MatchaThread: Sendable, Hashable {
    public var id: String
    public var metadata: ThreadMetadata
    public var rootBody: String?
    public var numberOfReplies: Int
    /// The time of the latest event in the thread, for ordering.
    public var lastActivityTimestamp: Int64
    /// The time of the thread root, 0 when unknown; the chip bar orders threads by it.
    public var rootTimestamp: Int64
    public var isRootUnreadable: Bool
    /// The thread was created with a name, so its first reply is the hidden bootstrap reply that `numberOfReplies` counts.
    public var hasHiddenFirstReply: Bool
    /// The sender of the thread root, or nil while the thread isn't in the thread list read so far.
    public var rootSenderID: String?
    /// Who the thread involves, as far as read, in the order of Android's projection: its root sender, its latest sender, the repliers
    /// the room's store read, then the other repliers among the Matcha events, newest first. The store keeps its repliers as a set,
    /// so they come in id order where Android keeps the order it read them in.
    public var orderedParticipants: [String]
    
    /// `orderedParticipants` as a set.
    public var participants: Set<String> {
        Set(orderedParticipants)
    }
    
    /// The replies people can see.
    public var visibleReplies: Int {
        max(numberOfReplies - (hasHiddenFirstReply ? 1 : 0), 0)
    }
}

/// A room's board.
public struct MatchaBoard: Sendable, Hashable {
    public var rootID: String
    public var cards: [ProjectedCard]
}

/// The threads and board of a room, as every client builds them. The protocol conformance fixtures
/// (`Fixtures/kanban/board.json`) run this function, like the Android store's `projectThreadsAndBoard`.
public enum RoomProjection {
    /// - Parameters:
    ///   - events: the room's Matcha events, newest first.
    ///   - boardRootID: the board the room points at, if it has one.
    ///   - threadList: the SDK's thread list, in its order.
    ///   - threadRepliers: the senders of the replies read from each thread, by thread root id.
    ///   - legacyArchive: the legacy `com.matchahoneylatte.thread_archive` flags, by thread root id.
    ///   - directMembers: the current user and the other members of a direct chat, or empty in any other chat.
    /// - Returns: every thread (listed, linked by a card, or archived by the legacy state), most recently active first, and the
    ///   board with each card's participants.
    public static func threadsAndBoard(events: [RawEvent],
                                       boardRootID: String?,
                                       threadList: [ListedThread],
                                       threadRepliers: [String: Set<String>],
                                       legacyArchive: [String: Bool],
                                       directMembers: Set<String>) -> (threads: [MatchaThread], board: MatchaBoard?) {
        let latestCards = KanbanProtocol.latestRevisions(boardRootID.map { root in events.compactMap { KanbanProtocol.parseCard($0, rootID: root) } } ?? [])
        
        // Ids are keyed by code point (see `CodePointKey`), the caller's dictionaries too, so that no id finds an equivalent other's.
        var patchesByRoot = [CodePointKey: [ThreadMetadataPatch]]()
        for event in events where event.type == MatchaConfig.eventThreadMetadata {
            guard let root = event.content.referenceTarget, let patch = ThreadMetadataProtocol.parsePatch(event, rootID: root) else { continue }
            patchesByRoot[CodePointKey(root), default: []].append(patch)
        }
        let listed = Dictionary(threadList.map { (CodePointKey($0.id), $0) }) { first, _ in first }
        let bootstrapped = Set(events.compactMap(ThreadMetadataProtocol.bootstrapRootID).map(CodePointKey.init))
        // The hidden replies this client sent are among the Matcha events before the thread's replies are read again.
        let eventRepliers = TaskParticipants.repliers(events, by: CodePointKey.init)
        let threadRepliers = Dictionary(threadRepliers.map { (CodePointKey($0.key), $0.value) }) { first, _ in first }
        let legacyArchive = Dictionary(legacyArchive.map { (CodePointKey($0.key), $0.value) }) { first, _ in first }
        var seen = Set<CodePointKey>()
        // A dictionary has no order, so the legacy archive's threads come in id order.
        let threadIDs = (threadList.map(\.id) + latestCards.compactMap(\.threadID) + legacyArchive.filter(\.value).keys.map(\.id).sorted())
            .filter { seen.insert(CodePointKey($0)).inserted }
        
        let threads = threadIDs.map { id in
            let key = CodePointKey(id)
            let item = listed[key]
            let rootBody = item?.rootBody ?? latestCards.first { id.isSameID($0.threadID) }?.title
            let participants = [item?.rootSenderID, item?.latestSenderID].compactMap(\.self)
                .appendingNew((threadRepliers[key] ?? []).sorted())
                .appendingNew(eventRepliers[key] ?? [])
            return MatchaThread(id: id,
                                metadata: ThreadMetadataProtocol.resolve(rootID: id, rootBody: rootBody, patchesNewestFirst: patchesByRoot[key] ?? [],
                                                                         legacyArchived: legacyArchive[key]),
                                rootBody: rootBody,
                                numberOfReplies: item?.numberOfReplies ?? 0,
                                lastActivityTimestamp: item.map { $0.latestTimestamp ?? $0.rootTimestamp } ?? 0,
                                rootTimestamp: item?.rootTimestamp ?? 0,
                                isRootUnreadable: item?.isRootUnreadable ?? false,
                                hasHiddenFirstReply: bootstrapped.contains(key),
                                rootSenderID: item?.rootSenderID,
                                orderedParticipants: participants)
        }
        // Newest activity first, keeping the order of equal ones like Kotlin's stable sortedByDescending.
        .enumerated()
        .sorted { $0.element.lastActivityTimestamp == $1.element.lastActivityTimestamp ? $0.offset < $1.offset : $0.element.lastActivityTimestamp > $1.element.lastActivityTimestamp }
        .map(\.element)
        
        let board = boardRootID.map { root in
            let threadParticipants = Dictionary(threads.map { (CodePointKey($0.id), $0.orderedParticipants) }) { first, _ in first }
            let standaloneAuthors = TaskParticipants.standaloneAuthors(events, rootID: root)
            let cards = KanbanProtocol.project(latestCards: latestCards, threads: threads.map { ($0.id, $0.metadata) }).map { card in
                var card = card
                card.orderedParticipants = TaskParticipants.participants(of: card, threadParticipants: threadParticipants,
                                                                         standaloneAuthors: standaloneAuthors, directMembers: directMembers)
                return card
            }
            return MatchaBoard(rootID: root, cards: cards)
        }
        return (threads, board)
    }
}
