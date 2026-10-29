//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import Foundation
import MatchaProtocol
import MatrixRustSDK
import Testing

@MainActor
struct MatchaRoomStoreTests {
    private let thread = "$thread-1"
    
    @Test
    func cardsAndThreadNamesAreReadFromTheEventsRelatingToTheBoardAndEachThreadThenFromLiveEvents() async throws {
        let fixture = MatchaRoomFixture(threads: [threadItem(thread, body: "Original body")])
        fixture.boardPointer = .success(aBoardRoot)
        fixture.references = try [aBoardRoot: [rawEvent(2, type: MatchaConfig.eventKanbanCard,
                                                        content: aCard(id: KanbanProtocol.threadCardID(thread), title: "Card", status: .doing, threadID: thread))],
                                  thread: [rawEvent(1, type: MatchaConfig.eventThreadMetadata, content: ThreadMetadataProtocol.patchContent(rootID: thread, name: "Renamed"))]]
        let store = fixture.store()
        await store.settle()
        
        #expect(store.snapshot.isLoaded)
        #expect(store.snapshot.threads.first?.metadata.name == "Renamed")
        #expect(store.snapshot.board?.cards.first?.status == .doing)
        
        try fixture.sendLiveEvent(rawEvent(3, type: MatchaConfig.eventThreadMetadata, content: ThreadMetadataProtocol.patchContent(rootID: thread, archived: true)))
        await waitForSnapshot(store) { $0.threads.first?.metadata.archived == true }
    }
    
    @Test
    func aThreadsHiddenFirstReplyIsReadFromItsRepliesAndLeftOutOfItsReplyCount() async throws {
        let fixture = MatchaRoomFixture(threads: [threadItem(thread, body: "Plan")])
        fixture.boardPointer = .success(aBoardRoot)
        fixture.references = try [aBoardRoot: [rawEvent(2, type: MatchaConfig.eventKanbanCard,
                                                        content: aCard(id: KanbanProtocol.threadCardID(thread), title: "Plan", threadID: thread))]]
        fixture.threadReplies = try [thread: [reply(5), reply(4),
                                              rawEvent(3, type: MatchaConfig.eventThreadMetadata, content: ThreadMetadataProtocol.bootstrapReplyContent(rootID: thread, name: "Plan"))]]
        let store = fixture.store()
        await store.settle()
        
        let snapshot = store.snapshot
        #expect(snapshot.isLoaded)
        #expect(!snapshot.events.contains { $0.eventID == "$r4" })
        #expect(snapshot.threads.first?.hasHiddenFirstReply == true)
        #expect(snapshot.threads.first?.visibleReplies == 2)
    }
    
    @Test
    func aThreadsReplyCountAndLatestReplyAreThoseOfItsRepliesReadNotTheThreadListsWhichCountsSomeAgain() async {
        let fixture = MatchaRoomFixture(threads: [aThreadListItem(thread, numberOfReplies: 2, latestSender: "@bob:x")])
        fixture.threadReplies = [thread: [reply(13, sender: "@carol:x"), reply(12)]]
        let store = fixture.store()
        await store.settle()
        #expect(store.snapshot.threads.first?.visibleReplies == 2)
        #expect(store.snapshot.threads.first?.lastActivityTimestamp == 13)
        
        // The SDK's thread list counts both replies again when the scan reads them back from history, and takes the older one for
        // the latest reply.
        fixture.threads.send([aThreadListItem(thread, numberOfReplies: 4, latestSender: "@bob:x", latestTimestamp: 12)])
        await store.settle()
        #expect(store.snapshot.threads.first?.visibleReplies == 2)
        #expect(store.snapshot.threads.first?.lastActivityTimestamp == 13)
        
        // A new reply counts once.
        fixture.threadReplies[thread]?.insert(reply(15, sender: "@dan:x"), at: 0)
        fixture.threads.send([aThreadListItem(thread, numberOfReplies: 5, latestSender: "@dan:x", latestTimestamp: 15)])
        await store.settle()
        #expect(store.snapshot.threads.first?.visibleReplies == 3)
        #expect(store.snapshot.threads.first?.lastActivityTimestamp == 15)
        #expect(store.snapshot.threads.first?.participants.contains("@dan:x") == true)
    }
    
    @Test
    func aCardFirstReadUndecryptableThroughTheBoardsRelationsShowsOnceTheScanHoldsItDecrypted() async throws {
        let encrypted = #"{"algorithm": "m.megolm.v1.aes-sha2", "ciphertext": "x", "m.relates_to": {"rel_type": "m.reference", "event_id": "\#(aBoardRoot)"}}"#
        let fixture = MatchaRoomFixture()
        fixture.boardPointer = .success(aBoardRoot)
        fixture.references = [aBoardRoot: [aMatchaEvent(2, type: "m.room.encrypted", content: encrypted)]]
        let store = fixture.store()
        await store.settle()
        #expect(store.snapshot.unreadable)
        
        fixture.items = try [aCardItem(2, id: "c-1", title: "Card")]
        await store.settle()
        #expect(store.snapshot.board?.cards.map(\.title) == ["Card"])
        #expect(!store.snapshot.unreadable)
    }
    
    @Test
    func threadsTheirSharedNamesAndTheBoardAreReadFromTheRoom() async throws {
        let fixture = try MatchaRoomFixture(items: [aCardItem(1, id: "c-standalone", title: "Standalone"),
                                                    aCardItem(2, id: KanbanProtocol.threadCardID(thread), title: "Old title", status: .doing, threadID: thread),
                                                    aThreadPatchItem(3, threadID: thread, name: "Renamed")],
                                            threads: [threadItem(thread, body: "Original body")])
        fixture.boardPointer = .success(aBoardRoot)
        let store = fixture.store()
        await store.settle()
        
        let snapshot = store.snapshot
        #expect(snapshot.isLoaded)
        #expect(snapshot.threads.map(\.metadata.name) == ["Renamed"])
        #expect(snapshot.board?.rootID == aBoardRoot)
        #expect(snapshot.board?.cards.map(\.title) == ["Standalone", "Renamed"])
        #expect(snapshot.board?.cards.last?.status == .doing)
        #expect(snapshot.permissions.canCreateBoard)
    }
    
    @Test
    func aThreadWhoseRootCannotBeDecryptedIsFlaggedAndKeepsItsRootTimestamp() async {
        let fixture = MatchaRoomFixture(threads: [aThreadListItem(thread, numberOfReplies: 3, isRootUnreadable: true)])
        let store = fixture.store()
        await store.settle()
        
        let matchaThread = store.snapshot.threads.first
        #expect(matchaThread?.isRootUnreadable == true)
        #expect(matchaThread?.rootTimestamp == 10)
        #expect(matchaThread?.metadata.name == thread)
    }
    
    @Test
    func aSentEventIsShownBeforeItsRemoteEchoAndNotDuplicatedAfter() async throws {
        let fixture = MatchaRoomFixture()
        let store = fixture.store()
        await store.settle()
        let content = try ThreadMetadataProtocol.patchContent(rootID: thread, archived: true)
        
        #expect(try await store.send(type: MatchaConfig.eventThreadMetadata, contentJSON: content).get() == "$sent")
        await store.settle()
        #expect(store.snapshot.events.map(\.eventID) == ["$sent"])
        
        fixture.items = [aTimelineItem(9, json: aMatchaEvent(9, type: MatchaConfig.eventThreadMetadata, content: content, sender: matchaUser, eventID: "$sent"),
                                       eventID: "$sent")]
        await store.settle()
        #expect(store.snapshot.events.map(\.eventID) == ["$sent"])
    }
    
    @Test
    func aSentMessageOfATypeTheStoreDoesNotReadIsNotEchoed() async throws {
        let fixture = MatchaRoomFixture()
        let store = fixture.store()
        await store.settle()
        
        _ = try await store.send(type: "m.room.message", contentJSON: #"{"msgtype": "m.text", "body": "!remind 7200s Call"}"#).get()
        await store.settle()
        #expect(store.snapshot.events.isEmpty)
    }
    
    @Test
    func aFailedSendLeavesNothingBehind() async {
        let fixture = MatchaRoomFixture()
        fixture.sendResult = { _, _ in .failure(.sdkError(RoomProxyMockError.generic)) }
        let store = fixture.store()
        await store.settle()
        
        #expect(await store.send(type: MatchaConfig.eventKanbanCard, contentJSON: "{}").isFailure)
        await store.settle()
        #expect(store.snapshot.events.isEmpty)
    }
    
    @Test
    func undecryptableBoardAndThreadEventsMakeTheBoardUnreadableWithTheWarningFromTheirCause() async {
        let unrelated = anUndecryptableItem(1, target: "$poll", cause: .unknown)
        let historical = anUndecryptableItem(2, target: aBoardRoot, cause: .historicalMessageAndBackupIsDisabled)
        let fixture = MatchaRoomFixture(items: [unrelated], threads: [threadItem(thread, body: "Body")])
        fixture.boardPointer = .success(aBoardRoot)
        let store = fixture.store()
        await store.settle()
        #expect(!store.snapshot.unreadable)
        #expect(store.snapshot.warning == nil)
        #expect(store.snapshot.events.map(\.type) == ["m.room.encrypted"])
        
        fixture.items = [unrelated, historical]
        await store.settle()
        #expect(store.snapshot.unreadable)
        #expect(store.snapshot.warning == .historyUnavailable)
        
        fixture.items = [unrelated, historical, anUndecryptableItem(3, target: thread, cause: .unknownDevice)]
        await store.settle()
        #expect(store.snapshot.warning == .undecryptable)
    }
    
    @Test
    func aThreadRootFromBeforeJoiningWarnsThatItCantBeRead() async {
        let fixture = MatchaRoomFixture(threads: [aThreadListItem(thread, numberOfReplies: 3, isRootUnreadable: true, rootUTDCause: .sentBeforeWeJoined)])
        let store = fixture.store()
        await store.settle()
        
        #expect(!store.snapshot.unreadable)
        #expect(store.snapshot.warning == .noAccess)
    }
    
    @Test
    func theBoardPointerIsReadAgainOnDemandAndAFailedReadIsNeverTakenForAnEmptyOne() async throws {
        let fixture = MatchaRoomFixture()
        func pointer(_ result: Result<String?, RoomProxyError>) {
            fixture.boardPointer = result
            fixture.serverPointer = { result }
        }
        pointer(.failure(.sdkError(RoomProxyMockError.generic)))
        let store = fixture.store()
        await store.settle()
        #expect(await store.readBoardPointer().isFailure)
        
        pointer(.success(nil))
        #expect(try await store.readBoardPointer().get() == nil)
        
        pointer(.failure(.sdkError(RoomProxyMockError.generic)))
        #expect(await store.readBoardPointer().isFailure)
        
        pointer(.success(aBoardRoot))
        #expect(try await store.readBoardPointer().get() == aBoardRoot)
        await store.settle()
        #expect(store.snapshot.board?.rootID == aBoardRoot)
    }
    
    @Test
    func aMissingBoardIsOnlyResolvedOnceTheHistoryIsReadBackToTheStart() async throws {
        // Ten pages are read up front; the pointer is in the twelfth, and the homeserver can't be asked.
        let fixture = MatchaRoomFixture(olderPages: Array(repeating: [], count: 11) + [[aBoardPointerItem(1, rootID: aBoardRoot)]])
        fixture.serverPointer = { .failure(.sdkError(RoomProxyMockError.generic)) }
        let store = fixture.store()
        await store.settle()
        #expect(store.snapshot.isLoaded)
        #expect(store.snapshot.board == nil)
        #expect(!store.snapshot.isBoardResolved)
        
        try await store.loadHistoryUntil { $0.board != nil }.get()
        await store.settle()
        #expect(store.snapshot.board?.rootID == aBoardRoot)
        #expect(store.snapshot.isBoardResolved)
        
        let empty = MatchaRoomFixture(olderPages: Array(repeating: [], count: 12))
        empty.serverPointer = { .failure(.sdkError(RoomProxyMockError.generic)) }
        let emptyStore = empty.store()
        await emptyStore.settle()
        try await emptyStore.loadHistoryUntil { $0.board != nil }.get()
        #expect(emptyStore.snapshot.board == nil)
        #expect(emptyStore.snapshot.isBoardResolved)
        #expect(!emptyStore.snapshot.hasMoreHistory)
    }
    
    @Test
    func readingTheHistoryStopsAtAPageThatCantBeRead() async {
        let fixture = MatchaRoomFixture(olderPages: Array(repeating: [], count: 12))
        fixture.serverPointer = { .failure(.sdkError(RoomProxyMockError.generic)) }
        let store = fixture.store()
        await store.settle()
        
        fixture.paginateResult = { .failure(.sdkError(RoomProxyMockError.generic)) }
        #expect(await store.loadHistoryUntil { _ in false }.isFailure)
        await store.settle()
        #expect(!store.snapshot.isBoardResolved)
        #expect(store.snapshot.warning == .network)
    }
    
    @Test
    func aBoardRootThatNoPointerRefersToIsNotABoardButTheBoardCardsReferToIs() async throws {
        let strayRoot = aMatchaEventItem(1, type: MatchaConfig.eventKanbanBoard, content: KanbanProtocol.boardRootContent())
        let stray = MatchaRoomFixture(items: [strayRoot]).store()
        await stray.settle()
        #expect(stray.snapshot.board == nil)
        
        let withCards = try MatchaRoomFixture(items: [strayRoot, aCardItem(2, id: "c-1", title: "Card")]).store()
        await withCards.settle()
        #expect(withCards.snapshot.board?.rootID == aBoardRoot)
    }
    
    @Test
    func everyTaskHasItsOwnIDEvenACardNamedLikeAListRowOrUnlinkedFromItsThread() async throws {
        // The newest revision of the thread's card no longer links it.
        let fixture = try MatchaRoomFixture(items: [aCardItem(1, id: "archived", title: "Named like a row"),
                                                    aCardItem(2, id: KanbanProtocol.threadCardID(thread), title: "Unlinked")],
                                            threads: [threadItem(thread, body: "Thread")])
        fixture.boardPointer = .success(aBoardRoot)
        let store = fixture.store()
        await store.settle()
        
        #expect(Set(store.snapshot.board?.cards.map(\.id) ?? []) == [KanbanProtocol.threadCardID(thread), "archived"])
        #expect(store.snapshot.board?.cards.count == 2)
    }
    
    @Test
    func aTimelineThatCouldNotBeOpenedIsReportedAndCanBeRetried() async {
        let fixture = MatchaRoomFixture()
        fixture.timelineResult = { .failure(.sdkError(RoomProxyMockError.generic)) }
        let store = fixture.store()
        await store.settle()
        #expect(store.snapshot.loadFailed)
        
        fixture.timelineResult = nil
        store.retryLoad()
        await store.settle()
        #expect(!store.snapshot.loadFailed)
        #expect(store.snapshot.isLoaded)
    }
    
    @Test
    func aFailedHistoryReadWarnsAboutTheNetwork() async {
        let fixture = MatchaRoomFixture(olderPages: [[]])
        fixture.paginateResult = { .failure(.sdkError(RoomProxyMockError.generic)) }
        let store = fixture.store()
        await store.settle()
        
        #expect(store.snapshot.warning == .network)
    }
    
    @Test
    func aHomeserverWithoutRelationsLeavesTheBoardUnreadAndStopsReadingThreads() async {
        let fixture = MatchaRoomFixture(threads: [threadItem(thread, body: "Plan")])
        fixture.boardPointer = .success(aBoardRoot)
        var reads = 0
        fixture.relationsResult = { _, _, _, _ in
            reads += 1
            return .failure(.sdkError(ClientError.MatrixApi(kind: .unrecognized, code: "M_UNRECOGNIZED", msg: "Unrecognized request", details: nil)))
        }
        let store = fixture.store()
        await store.settle()
        
        #expect(store.relationsUnavailable)
        #expect(store.snapshot.warning == .historyUnavailable)
        let readsBefore = reads
        fixture.threads.send([threadItem(thread, body: "Plan", numberOfReplies: 5)])
        await store.settle()
        #expect(reads == readsBefore, "Every read would fail the same way.")
    }
    
    @Test
    func aStoppedStoreLetsGoOfItsTimelineAndReadsNothingMore() async {
        let fixture = MatchaRoomFixture(threads: [threadItem(thread, body: "Plan")])
        weak var openedTimeline: TimelineProxyMock?
        fixture.timelineResult = {
            let timeline = aScanTimeline()
            openedTimeline = timeline
            return .success(timeline)
        }
        let store = fixture.store()
        await store.settle()
        #expect(openedTimeline != nil)
        
        store.stop()
        #expect(openedTimeline == nil)
        fixture.threads.send([threadItem("$other", body: "Other")])
        await store.settle()
        #expect(store.snapshot.threads.map(\.id) == [thread])
    }
    
    @Test
    func aStoppedStoreReadsNoFurtherPagesOfTheRelationsItWasReading() async {
        let fixture = MatchaRoomFixture()
        fixture.boardPointer = .success(aBoardRoot)
        let page = Gate()
        var pagesRead = 0
        // The homeserver has many pages of the board's events, and the first one is slow.
        fixture.relationsResult = { _, _, _, _ in
            pagesRead += 1
            await page.wait()
            return .success(.init(events: [], nextBatch: "older"))
        }
        let store = fixture.store()
        await eventually { pagesRead == 1 }
        
        store.stop()
        page.open()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(pagesRead == 1)
    }
    
    // MARK: - Helpers
    
    private func threadItem(_ id: String, body: String, numberOfReplies: Int = 3) -> RoomThreadListItem {
        aThreadListItem(id, body: body, numberOfReplies: numberOfReplies)
    }
    
    private func rawEvent(_ index: Int, type: String, content: String) -> String {
        aMatchaEvent(index, type: type, content: content, eventID: "$r\(index)")
    }
    
    /// A text reply in the thread, sent at `index` ms.
    private func reply(_ index: Int, sender: String = "@bob:x") -> String {
        aMatchaEvent(index, type: "m.room.message", content: #"{"msgtype": "m.text", "body": "Hi", "m.relates_to": {"rel_type": "m.thread", "event_id": "\#(thread)"}}"#,
                     sender: sender, eventID: "$r\(index)")
    }
    
    /// An empty scan timeline at the start of the room.
    private func aScanTimeline() -> TimelineProxyMock {
        let provider = TimelineItemProviderMock()
        provider.updatePublisher = Just(([], TimelinePaginationState(backward: .endReached, forward: .endReached))).eraseToAnyPublisher()
        return TimelineProxyMock(.init(timelineItemProvider: provider))
    }
}
