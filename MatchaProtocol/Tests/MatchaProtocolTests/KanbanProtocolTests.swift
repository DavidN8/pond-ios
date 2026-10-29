//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import MatchaProtocol
import Testing

struct KanbanProtocolTests {
    private static let root = "$board:example.org"
    private static let valid = #""card_id": "c-1", "title": "Write spec", "description": "", "column": "doing", "archived": false"#
    
    @Test
    func aValidCardIsReadWithDefaultsForOptionalFields() throws {
        let card = try KanbanProtocol.parseCard(cardEvent(Self.valid), rootID: Self.root)
        #expect(card == CardRevision(cardID: "c-1", title: "Write spec", description: "", status: .doing, archived: false,
                                     threadID: nil, dueAt: nil, reminderRequested: nil, showToRoom: true))
    }
    
    @Test
    func optionalFieldsAreReadWhenValidAndDroppedWhenNot() throws {
        let fields = #"\#(Self.valid), "thread_id": "$t", "due_at": 1767225600000, "reminder_requested": {"event_id": "$cmd", "at": 1767225600000}, "show_to_room": false"#
        let card = try #require(try KanbanProtocol.parseCard(cardEvent(fields), rootID: Self.root))
        #expect(card.threadID == "$t")
        #expect(card.dueAt == 1_767_225_600_000)
        #expect(card.reminderRequested == ReminderRequestRef(eventID: "$cmd", at: 1_767_225_600_000))
        #expect(!card.showToRoom)
        
        let lenientFields = #"\#(Self.valid), "thread_id": "not-an-id", "due_at": -5, "reminder_requested": {"event_id": "x"}"#
        let lenient = try #require(try KanbanProtocol.parseCard(cardEvent(lenientFields), rootID: Self.root))
        #expect(lenient.threadID == nil)
        #expect(lenient.dueAt == nil)
        #expect(lenient.reminderRequested == nil)
    }
    
    @Test(arguments: [
        #""card_id": "bad id", "title": "t", "description": "", "column": "todo", "archived": false"#,
        #""card_id": "c", "title": "  ", "description": "", "column": "todo", "archived": false"#,
        #""card_id": "c", "title": "\#(String(repeating: "t", count: 201))", "description": "", "column": "todo", "archived": false"#,
        #""card_id": "c", "title": "t", "description": "\#(String(repeating: "d", count: 4001))", "column": "todo", "archived": false"#,
        #""card_id": "c", "title": "t", "description": "", "column": "blocked", "archived": false"#,
        #""card_id": "c", "title": "t", "description": "", "column": "todo", "archived": "no""#,
        #""card_id": "c", "title": "t", "description": "", "column": "todo", "archived": false, "show_to_room": "yes""#
    ])
    func invalidRevisionsAreRejected(fields: String) throws {
        #expect(try KanbanProtocol.parseCard(cardEvent(fields), rootID: Self.root) == nil)
    }
    
    @Test
    func redactedRevisionsAndOtherBoardsAreRejected() throws {
        #expect(try KanbanProtocol.parseCard(cardEvent(Self.valid, redacted: true), rootID: Self.root) == nil)
        #expect(try KanbanProtocol.parseCard(cardEvent(Self.valid), rootID: "$another-board") == nil)
    }
    
    @Test
    func writtenCardsRoundTrip() throws {
        let card = CardRevision(cardID: "c-1", title: "Title", description: "Notes", status: .done, archived: true, threadID: "$t", dueAt: 42,
                                reminderRequested: ReminderRequestRef(eventID: "$cmd", at: 43), showToRoom: false)
        let content = try KanbanProtocol.cardContent(card, rootID: Self.root)
        let event = try #require(RawEvent(json: #"{"type": "\#(MatchaConfig.eventKanbanCard)", "content": \#(content)}"#))
        #expect(KanbanProtocol.parseCard(event, rootID: Self.root) == card)
    }
    
    @Test
    func showToRoomIsReadWhenABooleanAndAbsentMeansShownToEveryone() throws {
        #expect(try KanbanProtocol.parseCard(cardEvent(Self.valid), rootID: Self.root)?.showToRoom == true)
        #expect(try KanbanProtocol.parseCard(cardEvent(#"\#(Self.valid), "show_to_room": true"#), rootID: Self.root)?.showToRoom == true)
        #expect(try KanbanProtocol.parseCard(cardEvent(#"\#(Self.valid), "show_to_room": false"#), rootID: Self.root)?.showToRoom == false)
    }
    
    @Test(arguments: [#""true""#, "1", "null", "{}"])
    func anyOtherShowToRoomMakesTheCardInvalid(value: String) throws {
        #expect(try KanbanProtocol.parseCard(cardEvent(#"\#(Self.valid), "show_to_room": \#(value)"#), rootID: Self.root) == nil)
    }
    
    @Test
    func everyWrittenCardSaysWhetherItIsShownToEveryone() throws {
        let shown = aRevision(cardID: "c-1", threadID: nil, showToRoom: true)
        #expect(try KanbanProtocol.cardContent(shown, rootID: Self.root).contains(#""show_to_room":true"#))
        var hidden = shown
        hidden.showToRoom = false
        #expect(try KanbanProtocol.cardContent(hidden, rootID: Self.root).contains(#""show_to_room":false"#))
    }
    
    @Test
    func aThreadsCardWithoutARevisionIsShownToEveryoneAndOneWithARevisionKeepsItsValue() {
        let hidden = aRevision(cardID: "thread-x", threadID: "$t1", showToRoom: false)
        let cards = KanbanProtocol.project(latestCards: [hidden],
                                           threads: [("$t1", ThreadMetadata(name: "One", archived: false, archiveExplicit: false)),
                                                     ("$t2", ThreadMetadata(name: "Two", archived: false, archiveExplicit: false))])
        #expect(cards.map(\.showToRoom) == [false, true])
    }
    
    @Test
    func theBoardPointerMustBeVersion1WithAnEventID() {
        #expect(KanbanProtocol.parseBoardPointer(json: #"{"version": 1, "event_id": "$root"}"#) == "$root")
        #expect(KanbanProtocol.parseBoardPointer(json: #"{"version": 2, "event_id": "$root"}"#) == nil)
        #expect(KanbanProtocol.parseBoardPointer(json: #"{"version": 1, "event_id": "root"}"#) == nil)
        #expect(KanbanProtocol.parseBoardPointer(nil) == nil)
    }
    
    @Test
    func threadCardIDsMatchTheWebClient() {
        // SHA-256 of the UTF-8 string "$abc", as the web client computes it with crypto.subtle.digest.
        #expect(KanbanProtocol.threadCardID("$abc") == "thread-896f8c657f9fa111b8dbef8fd2b536b3b2dad5977bb9131dd920378e53a7ad7c")
    }
    
    @Test
    func theNewestRevisionOfEachCardWins() {
        let newest = aRevision(cardID: "c", threadID: nil, title: "New", status: .done)
        let older = aRevision(cardID: "c", threadID: nil, title: "Old", status: .todo)
        #expect(KanbanProtocol.latestRevisions([newest, older]) == [newest])
    }
    
    @Test
    func everyThreadProjectsToExactlyOneCardNamedAfterTheThread() {
        let linked = CardRevision(cardID: "thread-x", title: "Stale title", description: "Notes", status: .doing, archived: false, threadID: "$t1",
                                  dueAt: 5, reminderRequested: nil, showToRoom: true)
        let earlier = aRevision(cardID: "c-old", threadID: "$t1", title: "Earlier")
        let standalone = aRevision(cardID: "c-2", threadID: nil, title: "Standalone")
        let cards = KanbanProtocol.project(latestCards: [linked, standalone, earlier],
                                           threads: [("$t1", ThreadMetadata(name: "Thread name", archived: false, archiveExplicit: false)),
                                                     ("$t2", ThreadMetadata(name: "New thread", archived: false, archiveExplicit: false))])
        #expect(cards.map(\.title) == ["Standalone", "Thread name", "New thread"])
        let first = cards[1]
        #expect(first.id == "thread-x")
        #expect(first.status == .doing)
        #expect(first.description == "Notes")
        #expect(first.earlierCards == [earlier])
        #expect(first.hasRevision)
        let fresh = cards[2]
        #expect(fresh.id == KanbanProtocol.threadCardID("$t2"))
        #expect(fresh.status == .todo)
        // Nothing read so far describes the new thread's card: it only shows the defaults.
        #expect(!fresh.hasRevision)
    }
    
    @Test
    func aCardUnlinkedFromItsThreadGivesWayToTheThreadsCardSoIDsStayUnique() {
        let unlinked = aRevision(cardID: KanbanProtocol.threadCardID("$t"), threadID: nil, title: "Unlinked", status: .done)
        let other = aRevision(cardID: "c-2", threadID: nil, title: "Other")
        let cards = KanbanProtocol.project(latestCards: [unlinked, other],
                                           threads: [("$t", ThreadMetadata(name: "Thread", archived: false, archiveExplicit: false))])
        #expect(cards.map(\.id) == [KanbanProtocol.threadCardID("$t"), "c-2"])
        #expect(cards.first?.title == "Thread")
        #expect(cards.first?.threadID == "$t")
    }
    
    @Test
    func anExplicitThreadArchiveWinsOverTheCardOtherwiseTheCardDecides() {
        let card = aRevision(cardID: "c", threadID: "$t", archived: true)
        let explicit = KanbanProtocol.project(latestCards: [card], threads: [("$t", ThreadMetadata(name: "n", archived: false, archiveExplicit: true))])
        #expect(explicit.map(\.archived) == [false])
        let implicit = KanbanProtocol.project(latestCards: [card], threads: [("$t", ThreadMetadata(name: "n", archived: false, archiveExplicit: false))])
        #expect(implicit.map(\.archived) == [true])
    }
    
    @Test
    func aThreadWithUnreadableMetadataKeepsItsCardAsWritten() {
        let card = aRevision(cardID: "c", threadID: "$t", title: "As written", status: .done)
        let projected = KanbanProtocol.project(latestCards: [card], threads: [("$t", nil), ("$t-unknown", nil)])
        #expect(projected.map(\.title) == ["As written"])
    }
    
    // MARK: - Helpers
    
    private func cardEvent(_ fields: String, redacted: Bool = false) throws -> RawEvent {
        let unsigned = redacted ? #", "unsigned": {"redacted_because": {}}"# : ""
        let json = #"""
        {"type": "\#(MatchaConfig.eventKanbanCard)", "event_id": "$e", "sender": "@a:b", "origin_server_ts": 1,
         "content": {"version": 1, \#(fields), "m.relates_to": {"rel_type": "m.reference", "event_id": "\#(Self.root)"}}\#(unsigned)}
        """#
        return try #require(RawEvent(json: json))
    }
    
    private func aRevision(cardID: String,
                           threadID: String?,
                           title: String = "t",
                           status: TaskStatus = .todo,
                           archived: Bool = false,
                           showToRoom: Bool = true) -> CardRevision {
        CardRevision(cardID: cardID, title: title, description: "", status: status, archived: archived, threadID: threadID,
                     dueAt: nil, reminderRequested: nil, showToRoom: showToRoom)
    }
}
