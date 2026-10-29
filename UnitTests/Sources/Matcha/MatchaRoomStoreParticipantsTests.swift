//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import MatchaProtocol
import Testing

@MainActor
struct MatchaRoomStoreParticipantsTests {
    private let thread = "$thread"
    
    @Test
    func aThreadInvolvesItsRootSenderAndItsRepliersAndAnOlderCardTheAuthorsOfItsRevisions() async throws {
        let fixture = try MatchaRoomFixture(items: [card(1, id: KanbanProtocol.threadCardID(thread), threadID: thread, sender: "@writer:x"),
                                                    card(2, id: "legacy", threadID: nil, sender: "@carol:x"),
                                                    card(3, id: "legacy", threadID: nil, sender: "@dan:x")],
                                            threads: [aThreadListItem(thread, sender: "@bob:x")])
        fixture.boardPointer = .success(aBoardRoot)
        fixture.threadReplies = [thread: [reply(1, sender: "@erin:x"),
                                          // An encrypted reply's relation and sender stay readable.
                                          reply(2, sender: "@frank:x", type: "m.room.encrypted"),
                                          reply(3, sender: "@redacted:x", unsigned: #", "unsigned": {"redacted_because": {}}"#),
                                          reply(4, sender: "@reactor:x", relation: "m.annotation")]]
        let store = fixture.store()
        await store.settle()
        
        let snapshot = store.snapshot
        #expect(snapshot.isLoaded)
        #expect(snapshot.threads.first?.rootSenderID == "@bob:x")
        #expect(snapshot.threads.first?.participants == ["@bob:x", "@erin:x", "@frank:x"])
        let cards = Dictionary(uniqueKeysWithValues: (snapshot.board?.cards ?? []).map { ($0.id, $0) })
        // A thread's task is the thread's people, not whoever wrote its card.
        #expect(cards[KanbanProtocol.threadCardID(thread)]?.participants == ["@bob:x", "@erin:x", "@frank:x"])
        #expect(cards["legacy"]?.participants == ["@carol:x", "@dan:x"])
        #expect(!snapshot.isDirect)
    }
    
    @Test
    func inADirectChatTheUserAndTheOtherMembersAreInEveryTask() async throws {
        let fixture = try MatchaRoomFixture(items: [card(1, id: "legacy", threadID: nil, sender: "@carol:x")], isDirect: true, heroes: ["@bob:x"])
        fixture.boardPointer = .success(aBoardRoot)
        let store = fixture.store()
        await store.settle()
        
        #expect(store.snapshot.isDirect)
        #expect(store.snapshot.board?.cards.first?.participants == ["@carol:x", matchaUser, "@bob:x"])
    }
    
    @Test
    func aThreadsRepliesAreReadAgainWhenItGetsMoreOnlyTheNewOnesWithoutHoldingUpTheBoard() async {
        var replies = [reply(1, sender: "@erin:x")]
        var limits = [Int]()
        let fixture = MatchaRoomFixture(threads: [aThreadListItem(thread)])
        fixture.relationsResult = { _, relation, _, limit in
            guard relation == .thread else { return .success(.init(events: [], nextBatch: nil)) }
            limits.append(limit)
            return .success(.init(events: replies, nextBatch: nil))
        }
        let store = fixture.store()
        await store.settle()
        #expect(store.snapshot.threads.first?.participants == ["@bob:x", "@erin:x"])
        #expect(limits.count == 1)
        
        replies.append(reply(2, sender: matchaUser))
        // The latest reply is known from the thread list straight away; the others once the replies are read again.
        fixture.threads.send([aThreadListItem(thread, numberOfReplies: 3, latestSender: "@gina:x")])
        await store.settle()
        #expect(store.snapshot.isLoaded)
        #expect(store.snapshot.threads.first?.participants == ["@bob:x", "@gina:x", "@erin:x", matchaUser])
        // The first read takes a full page; the next only the two replies counted since and the newest one read.
        #expect(limits == [100, 3])
        
        // The same count isn't read again.
        fixture.threads.send([aThreadListItem(thread, timestamp: 11, numberOfReplies: 3, latestSender: "@gina:x")])
        await store.settle()
        #expect(limits == [100, 3])
        
        // A redaction lowers the count; the newest reply is still read.
        fixture.threads.send([aThreadListItem(thread, timestamp: 12, numberOfReplies: 2, latestSender: "@gina:x")])
        await store.settle()
        #expect(limits == [100, 3, 2])
        #expect(store.snapshot.threads.first?.participants == ["@bob:x", "@gina:x", "@erin:x", matchaUser])
    }
    
    @Test
    func theHiddenReplyThisClientSentMakesTheUserOneOfANewThreadsParticipants() async throws {
        let fixture = MatchaRoomFixture()
        fixture.boardPointer = .success(aBoardRoot)
        let store = fixture.store()
        await store.settle()
        
        #expect(await store.createNamedThread(name: "Plan") == .created(threadID: "$sent"))
        await store.settle()
        #expect(store.snapshot.events.map(\.senderID) == [matchaUser])
        
        _ = try await store.send(type: MatchaConfig.eventKanbanCard,
                                 contentJSON: aCard(id: KanbanProtocol.threadCardID("$sent"), title: "Plan", threadID: "$sent", showToRoom: false)).get()
        await store.settle()
        #expect(store.snapshot.board?.cards.first?.participants == [matchaUser])
    }
    
    @Test
    func aThreadsFirstReadPagesBackThroughAllItsRepliesToItsEarliestReplierAndItsHiddenFirstReply() async {
        // Newest first: the hidden bootstrap reply is the thread's first, and one person replied only on the oldest page.
        let replies = (1...250).reversed().map { index in
            switch index {
            case 1: reply(1, sender: "@bob:x", type: MatchaConfig.eventThreadMetadata)
            case 2: reply(2, sender: "@early:x")
            default: reply(index, sender: "@erin:x")
            }
        }
        let pages = Pages { replies }
        let (_, store) = aPagedStore(threads: [aThreadListItem(thread, numberOfReplies: 250)], page: pages.page)
        await store.settle()
        
        let snapshot = store.snapshot
        #expect(snapshot.isLoaded)
        #expect(pages.requests == [Request(nil, 100), Request("100", 100), Request("200", 100)])
        #expect(snapshot.threads.first?.participants == ["@bob:x", "@erin:x", "@early:x"])
        #expect(snapshot.threads.first?.hasHiddenFirstReply == true)
        #expect(snapshot.threads.first?.visibleReplies == 249)
    }
    
    @Test
    func aLaterReadPagesThroughTheRepliesCountedSinceUntilItReachesAReplyReadBefore() async {
        var replies = (1...250).reversed().map { reply($0, sender: "@erin:x") }
        let pages = Pages { replies }
        let (fixture, store) = aPagedStore(threads: [aThreadListItem(thread, numberOfReplies: 250)], page: pages.page)
        await store.settle()
        pages.requests = []
        
        // 150 new replies, one person among them only on the second page back.
        replies = (251...400).reversed().map { reply($0, sender: $0 == 260 ? "@late:x" : "@gina:x") } + replies
        fixture.threads.send([aThreadListItem(thread, numberOfReplies: 400)])
        await store.settle()
        // The 150 counted and the newest reply read before.
        #expect(pages.requests == [Request(nil, 100), Request("100", 51)])
        #expect(store.snapshot.threads.first?.participants == ["@bob:x", "@erin:x", "@gina:x", "@late:x"])
        
        // A count ahead of the replies served stops at the first page holding a reply read before.
        pages.requests = []
        replies = (401...410).reversed().map { reply($0, sender: "@hal:x") } + replies
        fixture.threads.send([aThreadListItem(thread, numberOfReplies: 600)])
        await store.settle()
        #expect(pages.requests == [Request(nil, 100)])
        #expect(store.snapshot.threads.first?.participants.contains("@hal:x") == true)
    }
    
    @Test
    func aLaterReadReachesTheRepliesCountedSinceWhenNewerOnesWereSentBeforeItRan() async {
        var replies = (1...250).reversed().map { reply($0, sender: "@erin:x") }
        let pages = Pages { replies }
        let (fixture, store) = aPagedStore(threads: [aThreadListItem(thread, numberOfReplies: 250)], page: pages.page)
        await store.settle()
        
        // The thread list counts one new reply, but another one was sent before the read ran, so the counted one is second.
        replies = [reply(252, sender: "@gina:x"), reply(251, sender: "@late:x")] + replies
        fixture.threads.send([aThreadListItem(thread, numberOfReplies: 251)])
        await store.settle()
        fixture.threads.send([aThreadListItem(thread, numberOfReplies: 252)])
        await store.settle()
        #expect(store.snapshot.threads.first?.participants == ["@bob:x", "@erin:x", "@gina:x", "@late:x"])
    }
    
    @Test
    func aLaterReadAfterTheNewestReplyReadWasRedactedStopsAtTheNextOneReadBefore() async {
        var replies = (1...250).reversed().map { reply($0, sender: "@erin:x") }
        let pages = Pages { replies }
        let (fixture, store) = aPagedStore(threads: [aThreadListItem(thread, numberOfReplies: 250)], page: pages.page)
        await store.settle()
        pages.requests = []
        
        replies.removeFirst()
        fixture.threads.send([aThreadListItem(thread, numberOfReplies: 249)])
        await store.settle()
        #expect(pages.requests == [Request(nil, 2)])
    }
    
    @Test
    func aReadStopsAtThePageCapWhenTheHomeserverKeepsPaging() async {
        var requests = 0
        let (_, store) = aPagedStore(threads: [aThreadListItem(thread)]) { _, _ in
            requests += 1
            return .success(.init(events: [aMatchaEvent(1, type: "m.room.message", content: Self.threadRelation(thread), sender: "@erin:x", eventID: "$r1")],
                                  nextBatch: "again"))
        }
        await store.settle()
        
        #expect(requests == 50)
        #expect(store.snapshot.isLoaded)
        #expect(store.snapshot.threads.first?.participants == ["@bob:x", "@erin:x"])
    }
    
    @Test
    func aFailingPageKeepsTheRepliersReadBeforeAndWarnsAndTheNextReadAsksAgainForWhatItMissed() async {
        var replies = (1...250).reversed().map { reply($0, sender: $0 == 1 ? "@early:x" : "@erin:x") }
        var isOffline = false
        let pages = Pages { replies }
        let (fixture, store) = aPagedStore(threads: [aThreadListItem(thread, numberOfReplies: 250)]) { from, limit in
            guard isOffline, let from else { return pages.page(from: from, limit: limit) }
            pages.requests.append(Request(from, limit))
            return .failure(.sdkError(RoomProxyMockError.generic))
        }
        await store.settle()
        pages.requests = []
        
        isOffline = true
        replies = (251...400).reversed().map { reply($0, sender: "@gina:x") } + replies
        fixture.threads.send([aThreadListItem(thread, numberOfReplies: 400)])
        await store.settle()
        #expect(pages.requests == [Request(nil, 100), Request("100", 51)])
        #expect(store.snapshot.warning == .network)
        #expect(store.snapshot.threads.first?.participants == ["@bob:x", "@erin:x", "@early:x"])
        
        // The failed read doesn't count: the next one asks for every reply since the last successful read.
        isOffline = false
        pages.requests = []
        replies = [reply(401, sender: "@hal:x")] + replies
        fixture.threads.send([aThreadListItem(thread, numberOfReplies: 401)])
        await store.settle()
        #expect(pages.requests == [Request(nil, 100), Request("100", 52)])
        #expect(store.snapshot.threads.first?.participants == ["@bob:x", "@erin:x", "@early:x", "@hal:x", "@gina:x"])
    }
    
    @Test
    func aThreadWhoseRepliesAreBeingReadIsReadAgainWhenThatReadEndsForTheRepliesCountedSince() async {
        var replies = (1...250).reversed().map { reply($0, sender: "@erin:x") }
        let pages = Pages { replies }
        let gate = Gate()
        let (fixture, store) = aPagedStore(threads: [aThreadListItem(thread, numberOfReplies: 250)]) { from, limit in
            await gate.wait()
            return pages.page(from: from, limit: limit)
        }
        await waitForSnapshot(store) { $0.threads.first?.numberOfReplies == 250 }
        
        replies = (251...260).reversed().map { reply($0, sender: "@gina:x") } + replies
        fixture.threads.send([aThreadListItem(thread, numberOfReplies: 260)])
        await waitForSnapshot(store) { $0.threads.first?.numberOfReplies == 260 }
        #expect(pages.requests.isEmpty)
        
        gate.open()
        await store.settle()
        // The first read finds all 260; the next asks only for the 10 counted since and one more, and stops at the newest reply it had.
        #expect(pages.requests == [Request(nil, 100), Request("100", 100), Request("200", 100), Request(nil, 11)])
        #expect(store.snapshot.isLoaded)
        #expect(store.snapshot.threads.first?.participants == ["@bob:x", "@gina:x", "@erin:x"])
    }
    
    // MARK: - Helpers
    
    private struct Request: Equatable {
        let from: String?
        let limit: Int
        
        init(_ from: String?, _ limit: Int) {
            self.from = from
            self.limit = limit
        }
    }
    
    /// Pages the replies, newest first, as the homeserver does, each next token the offset of the next page, recording each
    /// page asked for.
    private final class Pages {
        var requests = [Request]()
        private let replies: () -> [String]
        
        init(_ replies: @escaping () -> [String]) {
            self.replies = replies
        }
        
        func page(from: String?, limit: Int) -> Result<RawEventsPage, RoomProxyError> {
            requests.append(Request(from, limit))
            let all = replies()
            let offset = from.flatMap { Int($0) } ?? 0
            let end = min(offset + limit, all.count)
            return .success(.init(events: Array(all[offset..<end]), nextBatch: end < all.count ? String(end) : nil))
        }
    }
    
    private static func threadRelation(_ thread: String, relation: String = "m.thread") -> String {
        #"{"m.relates_to": {"rel_type": "\#(relation)", "event_id": "\#(thread)"}}"#
    }
    
    private func reply(_ index: Int, sender: String, type: String = "m.room.message", relation: String = "m.thread", unsigned: String = "") -> String {
        aMatchaEvent(index, type: type, content: Self.threadRelation(thread, relation: relation), sender: sender, eventID: "$r\(index)", unsigned: unsigned)
    }
    
    private func card(_ index: Int, id: String, threadID: String?, sender: String) throws -> TimelineItemProxy {
        try aCardItem(index, id: id, title: "Card \(index)", threadID: threadID, showToRoom: false, sender: sender)
    }
    
    /// A store over `threads` whose thread replies are read through `page`, given the token to start from and the limit.
    private func aPagedStore(threads: [RoomThreadListItem],
                             page: @escaping (String?, Int) async -> Result<RawEventsPage, RoomProxyError>) -> (MatchaRoomFixture, MatchaRoomStore) {
        let fixture = MatchaRoomFixture(threads: threads)
        fixture.relationsResult = { _, relation, from, limit in
            guard relation == .thread else { return .success(.init(events: [], nextBatch: nil)) }
            return await page(from, limit)
        }
        return (fixture, fixture.store())
    }
}
