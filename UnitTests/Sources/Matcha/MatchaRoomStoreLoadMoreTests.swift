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
struct MatchaRoomStoreLoadMoreTests {
    private let anchor = "$create"
    
    @Test(arguments: [true, false])
    func onlyADocumentsStoreReadsTheEventsRelatedToTheCreateEvent(readsDocumentAnchor: Bool) async {
        let fixture = MatchaRoomFixture(items: [aCreateItem()])
        fixture.createEventID = anchor
        var anchors = [String]()
        fixture.relationsResult = { eventID, _, _, _ in
            anchors.append(eventID)
            return .success(.init(events: [], nextBatch: nil))
        }
        let store = fixture.store(readsDocumentAnchor: readsDocumentAnchor)
        await store.settle()
        
        #expect(anchors == (readsDocumentAnchor ? [anchor] : []))
        #expect(store.snapshot.events.map(\.type) == ["m.room.create"])
    }
    
    @Test
    func awaitingTheRelationsReturnsOnceTheSnapshotHoldsThoseOfAnAnchorTheRoomStateGainedAfterTheStoreLoaded() async {
        let frame = aMatchaEvent(2, type: MatchaConfig.eventDocsUpdate,
                                 content: #"{"m.relates_to": {"rel_type": "m.reference", "event_id": "\#(anchor)"}}"#,
                                 eventID: "$f1")
        let fixture = MatchaRoomFixture(items: [aCreateItem()])
        fixture.relationsResult = { eventID, _, _, _ in
            .success(.init(events: eventID == anchor ? [frame] : [], nextBatch: nil))
        }
        let store = fixture.store(readsDocumentAnchor: true)
        await store.settle()
        #expect(store.snapshot.isLoaded)
        
        fixture.createEventID = anchor
        // The read ends before the snapshot is built again, so the loaded snapshot from before it is still the latest one for a moment.
        await store.awaitRelations()
        #expect(store.snapshot.events.contains { $0.eventID == "$f1" })
    }
    
    @Test
    func loadMoreReportsWhetherHistoryRemainsAndFailsWhenAPageCantBeRead() async throws {
        let fixture = MatchaRoomFixture(olderPages: Array(repeating: [], count: MatchaConfig.initialHistoryPages + 3))
        let store = fixture.store()
        await store.settle()
        
        #expect(try await store.loadMore().get())
        fixture.paginateResult = { .failure(.sdkError(RoomProxyMockError.generic)) }
        #expect(await store.loadMore().isFailure)
        fixture.hasMoreHistory = false
        #expect(try await !store.loadMore().get())
    }
    
    @Test
    func loadMoreFailsWhenTheTimelineCantBeOpened() async {
        let fixture = MatchaRoomFixture()
        fixture.timelineResult = { .failure(.sdkError(RoomProxyMockError.generic)) }
        let store = fixture.store()
        await store.settle()
        
        #expect(await store.loadMore().isFailure)
    }
    
    @Test
    func aLoadWaitingForTheTimelineToOpenFailsOnceTheStoreStops() async {
        let fixture = MatchaRoomFixture()
        let opening = Gate()
        fixture.room.eventTypesTimelineTypesClosure = { [timeline = fixture.timeline] _ in
            await opening.wait()
            return .success(timeline)
        }
        let store = fixture.store()
        var result: Result<Bool, MatchaRoomStoreError>?
        Task { result = await store.loadMore() }
        try? await Task.sleep(for: .milliseconds(50))
        
        store.stop()
        opening.open()
        await eventually { result != nil }
        guard case .failure(.timelineUnavailable) = result else {
            Issue.record("Expected the timeline to be unavailable, got \(String(describing: result))")
            return
        }
    }
    
    @Test
    func readingHistoryFailsWhenTheStoreStopsBeforeTheSnapshotShowsTheStartOfTheRoom() async {
        let fixture = MatchaRoomFixture(olderPages: Array(repeating: [], count: MatchaConfig.initialHistoryPages + 1))
        let store = fixture.store()
        await store.settle()
        // The last page reaches the start of the room, and the store stops before a snapshot shows it.
        fixture.timeline.paginateBackwardsRequestSizeClosure = { [weak fixture, weak store] _ in
            fixture?.hasMoreHistory = false
            store?.stop()
            return .success(())
        }
        
        var result: Result<Void, MatchaRoomStoreError>?
        Task { result = await store.loadHistoryUntil { _ in false } }
        await eventually { result != nil }
        #expect(result?.isFailure == true)
    }
    
    @Test
    func awaitingTheRelationsEndsOnceTheStoreStops() async {
        let fixture = MatchaRoomFixture()
        fixture.createEventID = anchor
        let reading = Gate()
        fixture.relationsResult = { _, _, _, _ in
            await reading.wait()
            return .success(.init(events: [], nextBatch: nil))
        }
        let store = fixture.store(readsDocumentAnchor: true)
        var hasEnded = false
        Task {
            await store.awaitRelations()
            hasEnded = true
        }
        try? await Task.sleep(for: .milliseconds(50))
        
        store.stop()
        await eventually { hasEnded }
        reading.open()
    }
    
    // MARK: - Helpers
    
    private func aCreateItem() -> TimelineItemProxy {
        aTimelineItem(1, json: aMatchaEvent(1, type: "m.room.create", content: "{}", stateKey: "", sender: "@admin:x", eventID: anchor), eventID: anchor)
    }
}
