//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import CryptoKit
import Foundation

/// The three board columns; the wire values are shared with the other clients.
public enum TaskStatus: String, Sendable, CaseIterable {
    case todo
    case doing
    case done
}

/// A reminder command sent for a card; only the bot's reply confirms that it is scheduled.
public struct ReminderRequestRef: Sendable, Hashable {
    public var eventID: String
    public var at: Int64
    
    public init(eventID: String, at: Int64) {
        self.eventID = eventID
        self.at = at
    }
}

/// One complete card revision. The newest revision of a card id wins.
public struct CardRevision: Sendable, Hashable {
    public var cardID: String
    public var title: String
    public var description: String
    public var status: TaskStatus
    public var archived: Bool
    public var threadID: String?
    public var dueAt: Int64?
    public var reminderRequested: ReminderRequestRef?
    public var showToRoom: Bool
    
    public init(cardID: String,
                title: String,
                description: String,
                status: TaskStatus,
                archived: Bool,
                threadID: String?,
                dueAt: Int64?,
                reminderRequested: ReminderRequestRef?,
                showToRoom: Bool) {
        self.cardID = cardID
        self.title = title
        self.description = description
        self.status = status
        self.archived = archived
        self.threadID = threadID
        self.dueAt = dueAt
        self.reminderRequested = reminderRequested
        self.showToRoom = showToRoom
    }
}

/// A card as shown on a board: a thread's card (one per thread) or an older standalone card.
public struct ProjectedCard: Sendable, Hashable {
    public var id: String
    public var title: String
    public var description: String
    public var status: TaskStatus
    public var archived: Bool
    public var threadID: String?
    public var dueAt: Int64?
    public var reminderRequested: ReminderRequestRef?
    public var showToRoom: Bool
    /// Older cards that were linked to the same thread under a different card id; kept, never merged.
    public var earlierCards: [CardRevision]
    /// False for a thread's card that no revision read so far describes, so it shows the defaults; its revision may lie further
    /// back in the history. Never write a card that has none over one not read yet.
    public var hasRevision: Bool
    /// Who the task involves (see `TaskParticipants`), the current user included when they are: in the order of
    /// `MatchaThread.orderedParticipants` (an older standalone card's authors newest first), then a direct chat's members not among
    /// them in id order. Filled in by the room's projection.
    public var orderedParticipants: [String]
    
    /// `orderedParticipants` as a set.
    public var participants: Set<String> {
        Set(orderedParticipants)
    }
    
    public init(id: String,
                title: String,
                description: String,
                status: TaskStatus,
                archived: Bool,
                threadID: String?,
                dueAt: Int64?,
                reminderRequested: ReminderRequestRef?,
                showToRoom: Bool,
                earlierCards: [CardRevision],
                hasRevision: Bool,
                orderedParticipants: [String] = []) {
        self.id = id
        self.title = title
        self.description = description
        self.status = status
        self.archived = archived
        self.threadID = threadID
        self.dueAt = dueAt
        self.reminderRequested = reminderRequested
        self.showToRoom = showToRoom
        self.earlierCards = earlierCards
        self.hasRevision = hasRevision
        self.orderedParticipants = orderedParticipants
    }
}

/// Per-room boards shared with the other clients: a state pointer, a root timeline event, and card revisions related to the root.
/// Card content only ever travels in timeline events, which are encrypted in encrypted rooms.
public enum KanbanProtocol {
    private static let maxTimestamp: Int64 = 253_402_300_799_999
    
    public static func isValidTimestamp(_ value: Int64?) -> Bool {
        guard let value else { return false }
        return (1...maxTimestamp).contains(value)
    }
    
    public static func isValidTitle(_ title: String) -> Bool {
        !title.isKotlinBlank && title.utf16Length <= MatchaConfig.cardTitleMaxLength
    }
    
    public static func isValidDescription(_ description: String) -> Bool {
        description.utf16Length <= MatchaConfig.cardDescriptionMaxLength
    }
    
    /// The board root event id from the `com.matchahoneylatte.kanban` state content, or nil.
    public static func parseBoardPointer(_ content: JSONObject?) -> String? {
        guard let content, content.integer("version") == 1, let eventID = content.string("event_id"), eventID.unicodeScalars.first == "$" else { return nil }
        return eventID
    }
    
    /// `parseBoardPointer` of a pointer's raw content JSON.
    public static func parseBoardPointer(json: String?) -> String? {
        parseBoardPointer(json.flatMap(JSONValue.init(json:))?.objectValue)
    }
    
    public static func boardPointerContent(rootID: String) -> String {
        JSONValue.object(["version": .integer(1), "event_id": .string(rootID)]).jsonString
    }
    
    public static func boardRootContent() -> String {
        JSONValue.object(["version": .integer(1)]).jsonString
    }
    
    /// Reads a card revision related to `rootID`; invalid revisions are dropped, exactly like the other clients.
    public static func parseCard(_ event: RawEvent, rootID: String) -> CardRevision? {
        guard !event.isRedacted, event.type == MatchaConfig.eventKanbanCard else { return nil }
        let content = event.content
        guard content.integer("version") == 1, rootID.isSameID(content.referenceTarget),
              let cardID = content.string("card_id"), isValidCardID(cardID),
              let title = content.string("title"), isValidTitle(title),
              let description = content.string("description"), isValidDescription(description),
              let status = content.string("column").flatMap(TaskStatus.init(rawValue:)),
              let archived = content.bool("archived") else {
            return nil
        }
        // Absent on older cards, which stay visible to everyone; any other value makes the revision invalid.
        let showToRoom: Bool
        if content["show_to_room"] == nil {
            showToRoom = true
        } else if let value = content.bool("show_to_room") {
            showToRoom = value
        } else {
            return nil
        }
        return CardRevision(cardID: cardID,
                            title: title,
                            description: description,
                            status: status,
                            archived: archived,
                            threadID: content.string("thread_id").flatMap { isValidEventID($0) ? $0 : nil },
                            dueAt: content.integer("due_at").flatMap { isValidTimestamp($0) ? $0 : nil },
                            reminderRequested: content.object("reminder_requested").flatMap(reminderRequest),
                            showToRoom: showToRoom)
    }
    
    /// Content of a complete card revision.
    public static func cardContent(_ card: CardRevision, rootID: String) throws(MatchaProtocolError) -> String {
        guard isValidTitle(card.title), isValidDescription(card.description), isValidCardID(card.cardID) else { throw .invalidArgument }
        var content: JSONObject = [
            "version": .integer(1),
            "card_id": .string(card.cardID),
            "title": .string(card.title.kotlinTrimmed),
            "description": .string(card.description),
            "column": .string(card.status.rawValue),
            "archived": .bool(card.archived),
            "show_to_room": .bool(card.showToRoom),
            "m.relates_to": ThreadMetadataProtocol.reference(rootID)
        ]
        if let threadID = card.threadID {
            content["thread_id"] = .string(threadID)
        }
        if let dueAt = card.dueAt, isValidTimestamp(dueAt) {
            content["due_at"] = .integer(dueAt)
        }
        if let request = card.reminderRequested {
            content["reminder_requested"] = .object(["event_id": .string(request.eventID), "at": .integer(request.at)])
        }
        return JSONValue.object(content).jsonString
    }
    
    /// Stable card id for a thread, identical to the other clients': `thread-` + SHA-256 hex of the thread root id.
    public static func threadCardID(_ threadID: String) -> String {
        "thread-" + SHA256.hash(data: Data(threadID.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    
    /// Keeps the newest revision of each card id, from revisions in server order, newest first.
    public static func latestRevisions(_ revisionsNewestFirst: [CardRevision]) -> [CardRevision] {
        var seen = Set<String>()
        return revisionsNewestFirst.filter { seen.insert($0.cardID).inserted }
    }
    
    /// Projects every thread onto exactly one card, keeping standalone cards. Card ids are unique: like the web client's map of
    /// cards, a thread's card replaces a standalone card with the same id (one unlinked from the thread) in its place.
    ///
    /// - Parameters:
    ///   - latestCards: the newest revision of each card, newest card first (see `latestRevisions`).
    ///   - threads: every thread known for the room (thread list, threads referenced by cards, the thread the user came from), in
    ///     order and each once, with its resolved metadata, or nil when the metadata could not be read.
    public static func project(latestCards: [CardRevision], threads: [(id: String, metadata: ThreadMetadata?)]) -> [ProjectedCard] {
        let linked = Dictionary(grouping: latestCards.filter { $0.threadID != nil }) { CodePointKey($0.threadID ?? "") }
        var seen = Set<CodePointKey>()
        let threadIDs = (threads.map(\.id) + latestCards.compactMap(\.threadID)).filter { seen.insert(CodePointKey($0)).inserted }
        let metadata = Dictionary(threads.map { (CodePointKey($0.id), $0.metadata) }) { first, _ in first }
        
        var projected = OrderedCards()
        for card in latestCards where card.threadID == nil {
            projected[card.cardID] = card.projected(earlierCards: [])
        }
        for threadID in threadIDs {
            let revisions = linked[CodePointKey(threadID)] ?? []
            let existing = revisions.first
            guard let thread = metadata[CodePointKey(threadID)] ?? nil else {
                // Unreadable metadata: keep what the card itself says rather than hiding it.
                if let existing {
                    projected[existing.cardID] = existing.projected(earlierCards: Array(revisions.dropFirst()))
                }
                continue
            }
            let id = existing?.cardID ?? threadCardID(threadID)
            projected[id] = ProjectedCard(id: id,
                                          title: thread.name,
                                          description: existing?.description ?? "",
                                          status: existing?.status ?? .todo,
                                          archived: thread.archiveExplicit ? thread.archived : existing?.archived ?? thread.archived,
                                          threadID: threadID,
                                          dueAt: existing?.dueAt,
                                          reminderRequested: existing?.reminderRequested,
                                          showToRoom: existing?.showToRoom ?? true,
                                          earlierCards: Array(revisions.dropFirst()),
                                          hasRevision: existing != nil)
        }
        return projected.values
    }
    
    // MARK: - Private
    
    private static func isValidCardID(_ value: String) -> Bool {
        value.consists(of: { $0.isASCIIAlphanumeric || $0 == "-" }, lengths: 1...80)
    }
    
    /// `$` and 1 to 511 code points without ASCII whitespace, like the other clients' `^\$\S{1,511}$`.
    private static func isValidEventID(_ value: String) -> Bool {
        let rest = value.unicodeScalars.dropFirst()
        return value.unicodeScalars.first == "$" && (1...511).contains(rest.count) && !rest.contains(where: \.isASCIIWhitespace)
    }
    
    private static func reminderRequest(_ request: JSONObject) -> ReminderRequestRef? {
        guard let eventID = request.string("event_id"), isValidEventID(eventID),
              let at = request.integer("at"), isValidTimestamp(at) else { return nil }
        return ReminderRequestRef(eventID: eventID, at: at)
    }
}

/// Cards by id in insertion order; replacing a card keeps its place, like Kotlin's `LinkedHashMap`.
private struct OrderedCards {
    private(set) var values: [ProjectedCard] = []
    private var indices: [String: Int] = [:]
    
    subscript(id: String) -> ProjectedCard? {
        get { indices[id].map { values[$0] } }
        set {
            guard let newValue else { return }
            if let index = indices[id] {
                values[index] = newValue
            } else {
                indices[id] = values.count
                values.append(newValue)
            }
        }
    }
}

private extension CardRevision {
    func projected(earlierCards: [CardRevision]) -> ProjectedCard {
        ProjectedCard(id: cardID,
                      title: title,
                      description: description,
                      status: status,
                      archived: archived,
                      threadID: threadID,
                      dueAt: dueAt,
                      reminderRequested: reminderRequested,
                      showToRoom: showToRoom,
                      earlierCards: earlierCards,
                      hasRevision: true)
    }
}

/// The outcome of turning a picked local date and time into a deadline.
public enum LocalDeadline: Sendable, Hashable {
    case valid(epochMillis: Int64)
    /// The time doesn't exist in the time zone, because the clocks skip it.
    case skipped
    /// The time is outside what the protocol accepts (before 1970, or after the year 9999).
    case outOfRange
}

public extension KanbanProtocol {
    /// A deadline must round-trip: a local time (year, month, day, hour, minute) skipped by a clock change is refused rather than
    /// silently moved. A time repeated by a change takes the earlier offset.
    static func deadline(_ components: DateComponents, in timeZone: TimeZone) -> LocalDeadline {
        guard let millis = LocalTime.instant(components, in: timeZone) else { return .skipped }
        return isValidTimestamp(millis) ? .valid(epochMillis: millis) : .outOfRange
    }
}
