//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import MatchaProtocol
import Testing

struct TaskParticipantsTests {
    private static let root = "$board"
    
    @Test
    func repliersAreTheSendersOfTheThreadRepliesNotOfRedactedOnesOrOtherRelations() throws {
        let repliers = try TaskParticipants.repliers([
            reply("@bob:x", thread: "$t1"),
            reply("@carol:x", thread: "$t1"),
            reply("@bob:x", thread: "$t1"),
            reply("@dan:x", thread: "$t2"),
            reply("@redacted:x", thread: "$t1", redacted: true),
            reply("@reactor:x", thread: "$t1", relation: "m.annotation"),
            reply("not a user id", thread: "$t1"),
            reply(nil, thread: "$t1")
        ])
        #expect(repliers == ["$t1": ["@bob:x", "@carol:x"], "$t2": ["@dan:x"]])
    }
    
    @Test
    func anOlderCardsParticipantsAreTheAuthorsOfItsRevisionsWithoutAThread() throws {
        let authors = try TaskParticipants.standaloneAuthors([
            revision("@bob:x", cardID: "legacy", threadID: nil),
            revision("@carol:x", cardID: "legacy", threadID: nil),
            revision("@dan:x", cardID: "legacy", threadID: "$t1"),
            revision("@erin:x", cardID: "other", threadID: nil)
        ], rootID: Self.root)
        #expect(authors == ["legacy": ["@bob:x", "@carol:x"], "other": ["@erin:x"]])
    }
    
    @Test
    func aTaskInvolvesItsThreadsPeopleOrItsAuthorsAndInADirectChatItsMembers() {
        let threads: [CodePointKey: [String]] = [CodePointKey("$t1"): ["@bob:x", "@carol:x"]]
        let authors: [String: [String]] = ["legacy": ["@dan:x"], "thread-card": ["@writer:x"]]
        func participants(_ card: ProjectedCard, direct: Set<String> = []) -> [String] {
            TaskParticipants.participants(of: card, threadParticipants: threads, standaloneAuthors: authors, directMembers: direct)
        }
        #expect(participants(aCard("thread-card", threadID: "$t1")) == ["@bob:x", "@carol:x"])
        #expect(participants(aCard("legacy", threadID: nil)) == ["@dan:x"])
        #expect(participants(aCard("unknown", threadID: "$t9")).isEmpty)
        #expect(participants(aCard("unknown", threadID: "$t9"), direct: ["@me:x", "@bob:x"]) == ["@bob:x", "@me:x"])
    }
    
    @Test
    func aTaskIsOnTheBoardOfEveryoneWhenSharedWithTheChatOtherwiseOfThePeopleItInvolves() {
        #expect(aCard("c", threadID: nil, showToRoom: true).isShownOnBoard(userID: "@me:x"))
        #expect(aCard("c", threadID: nil, participants: ["@me:x"]).isShownOnBoard(userID: "@me:x"))
        #expect(!aCard("c", threadID: nil, participants: ["@bob:x"]).isShownOnBoard(userID: "@me:x"))
    }
    
    @Test
    func participantsAreListedLikeAndroidRootSenderLatestSenderTheStoresRepliersThenTheEventsRepliers() throws {
        let thread = ListedThread(id: "$t1", rootBody: "Plan", rootSenderID: "@zed:x", rootTimestamp: 1, latestSenderID: "@amy:x",
                                  latestTimestamp: 2, numberOfReplies: 4)
        let events = try [reply("@mia:x", thread: "$t1"),
                          reply("@zed:x", thread: "$t1"),
                          reply("@bob:x", thread: "$t1"),
                          revision("@dan:x", cardID: "legacy", threadID: nil),
                          revision("@cat:x", cardID: "legacy", threadID: nil),
                          revision("@dan:x", cardID: "legacy", threadID: nil)]
        func project(directMembers: Set<String>) -> (threads: [MatchaThread], board: MatchaBoard?) {
            // Android's buildSet order: the store's per-thread repliers (a set here, so in id order), then the events' repliers newest first.
            RoomProjection.threadsAndBoard(events: events, boardRootID: Self.root, threadList: [thread],
                                           threadRepliers: ["$t1": ["@kim:x", "@bob:x", "@eve:x"]], legacyArchive: [:], directMembers: directMembers)
        }
        let inOrder = ["@zed:x", "@amy:x", "@bob:x", "@eve:x", "@kim:x", "@mia:x"]
        
        let (threads, board) = project(directMembers: [])
        #expect(threads.first?.orderedParticipants == inOrder)
        #expect(threads.first?.participants == Set(inOrder))
        let cards = Dictionary(uniqueKeysWithValues: (board?.cards ?? []).map { ($0.id, $0.orderedParticipants) })
        #expect(cards == [KanbanProtocol.threadCardID("$t1"): inOrder, "legacy": ["@dan:x", "@cat:x"]])
        
        // In a direct chat its members who aren't involved yet follow, in id order.
        let directCards = project(directMembers: ["@me:x", "@zed:x", "@ann:x"]).board?.cards.map(\.orderedParticipants)
        #expect(directCards == [["@dan:x", "@cat:x", "@ann:x", "@me:x", "@zed:x"], inOrder + ["@ann:x", "@me:x"]])
    }
    
    // MARK: - Helpers
    
    private func event(_ type: String, sender: String?, content: String, redacted: Bool = false) throws -> RawEvent {
        let senderField = sender.map { #""sender": "\#($0)", "# } ?? ""
        let unsigned = redacted ? #", "unsigned": {"redacted_because": {}}"# : ""
        return try #require(RawEvent(json: #"{"type": "\#(type)", "event_id": "$e", \#(senderField)"content": \#(content)\#(unsigned)}"#))
    }
    
    private func reply(_ sender: String?, thread: String, relation: String = MatchaConfig.relationTypeThread, redacted: Bool = false) throws -> RawEvent {
        try event("m.room.message", sender: sender, content: #"{"m.relates_to": {"rel_type": "\#(relation)", "event_id": "\#(thread)"}}"#, redacted: redacted)
    }
    
    private func revision(_ sender: String, cardID: String, threadID: String?) throws -> RawEvent {
        let card = CardRevision(cardID: cardID, title: "Title", description: "", status: .todo, archived: false, threadID: threadID,
                                dueAt: nil, reminderRequested: nil, showToRoom: false)
        return try event(MatchaConfig.eventKanbanCard, sender: sender, content: KanbanProtocol.cardContent(card, rootID: Self.root))
    }
    
    private func aCard(_ id: String, threadID: String?, showToRoom: Bool = false, participants: [String] = []) -> ProjectedCard {
        ProjectedCard(id: id, title: "Title", description: "", status: .todo, archived: false, threadID: threadID, dueAt: nil,
                      reminderRequested: nil, showToRoom: showToRoom, earlierCards: [], hasRevision: true, orderedParticipants: participants)
    }
}
