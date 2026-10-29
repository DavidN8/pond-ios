//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import MatchaProtocol
import MatrixRustSDK
import MatrixRustSDKMocks
import Testing

struct RawRoomEventsTests {
    @Test
    func sendRawEvent() async {
        let room = RoomSDKMock()
        room.sendRawEventTypeContentRequestConfigOverrideReturnValue = "$card"
        
        let result = await room.sendRawEvent(type: MatchaConfig.eventKanbanCard, contentJSON: #"{"title":"Milk"}"#)
        
        #expect(result.success == "$card")
        #expect(room.sendRawEventTypeContentRequestConfigOverrideReceivedArguments?.eventType == MatchaConfig.eventKanbanCard)
        #expect(room.sendRawEventTypeContentRequestConfigOverrideReceivedArguments?.content == #"{"title":"Milk"}"#)
        
        room.sendRawEventTypeContentRequestConfigOverrideThrowableError = TestError.failed
        #expect(await room.sendRawEvent(type: MatchaConfig.eventKanbanCard, contentJSON: "{}").isSDKError)
    }
    
    @Test
    func sendRawStateEvent() async {
        let room = RoomSDKMock()
        room.sendStateEventRawEventTypeStateKeyContentRequestConfigOverrideReturnValue = "$pointer"
        
        let result = await room.sendRawStateEvent(type: MatchaConfig.stateKanban, stateKey: "", contentJSON: #"{"root":"$board"}"#)
        
        #expect(result.success == "$pointer")
        let arguments = room.sendStateEventRawEventTypeStateKeyContentRequestConfigOverrideReceivedArguments
        #expect(arguments?.eventType == MatchaConfig.stateKanban)
        #expect(arguments?.stateKey == "")
        #expect(arguments?.content == #"{"root":"$board"}"#)
        
        room.sendStateEventRawEventTypeStateKeyContentRequestConfigOverrideThrowableError = TestError.failed
        #expect(await room.sendRawStateEvent(type: MatchaConfig.stateKanban, stateKey: "", contentJSON: "{}").isSDKError)
    }
    
    @Test
    func stateEventsJSON() async {
        let room = RoomSDKMock()
        room.stateEventsEventTypeReturnValue = [stateEvent(stateKey: "$a", content: #"{"archived":true}"#),
                                                stateEvent(stateKey: "$b", content: #"{"archived":false}"#)]
        
        let result = await room.stateEventsJSON(type: MatchaConfig.stateThreadArchive)
        
        #expect(result.success == ["$a": #"{"archived":true}"#, "$b": #"{"archived":false}"#])
        #expect(room.stateEventsEventTypeReceivedEventType == stateEventTypeFromString(s: MatchaConfig.stateThreadArchive))
        
        room.stateEventsEventTypeThrowableError = TestError.failed
        #expect(await room.stateEventsJSON(type: MatchaConfig.stateThreadArchive).isSDKError)
    }
    
    @Test
    func storedStateEventID() async {
        let room = RoomSDKMock()
        room.stateEventsEventTypeReturnValue = [stateEvent(stateKey: "", content: "{}", eventID: "$create")]
        
        #expect(await room.storedStateEventID(type: "m.room.create", stateKey: "").success == "$create")
        #expect(room.stateEventsEventTypeReceivedEventType == .roomCreate)
        #expect(await room.storedStateEventID(type: "m.room.create", stateKey: "other").success == .some(nil))
        
        room.stateEventsEventTypeThrowableError = TestError.failed
        #expect(await room.storedStateEventID(type: "m.room.create", stateKey: "").isSDKError)
    }
    
    @Test
    func fetchStateEventContentJSON() async {
        let room = RoomSDKMock()
        room.fetchStateEventContentJsonEventTypeStateKeyReturnValue = #"{"root":"$board"}"#
        
        #expect(await room.fetchStateEventContentJSON(type: MatchaConfig.stateKanban, stateKey: "").success == #"{"root":"$board"}"#)
        #expect(room.fetchStateEventContentJsonEventTypeStateKeyReceivedArguments?.eventType == MatchaConfig.stateKanban)
        #expect(room.fetchStateEventContentJsonEventTypeStateKeyReceivedArguments?.stateKey == "")
        
        // The SDK answers a 404 with nil: the room has no such state.
        room.fetchStateEventContentJsonEventTypeStateKeyReturnValue = nil
        #expect(await room.fetchStateEventContentJSON(type: MatchaConfig.stateKanban, stateKey: "").success == .some(nil))
        
        room.fetchStateEventContentJsonEventTypeStateKeyThrowableError = TestError.failed
        #expect(await room.fetchStateEventContentJSON(type: MatchaConfig.stateKanban, stateKey: "").isSDKError)
    }
    
    @Test(arguments: [(RawRelationType.reference, RelationType.reference), (.thread, .thread)])
    func fetchRelatedEventsJSON(relation: RawRelationType, expected: RelationType) async {
        let room = RoomSDKMock()
        room.fetchRelationsJsonEventIdRelationTypeFromLimitReturnValue = .init(events: [#"{"type":"a"}"#, #"{"type":"b"}"#], nextBatch: "older")
        
        let result = await room.fetchRelatedEventsJSON(eventID: "$root", relation: relation, from: "newer", limit: MatchaConfig.relationsPageSize)
        
        #expect(result.success == RawEventsPage(events: [#"{"type":"a"}"#, #"{"type":"b"}"#], nextBatch: "older"))
        let arguments = room.fetchRelationsJsonEventIdRelationTypeFromLimitReceivedArguments
        #expect(arguments?.eventId == "$root")
        #expect(arguments?.relationType == expected)
        #expect(arguments?.from == "newer")
        #expect(arguments?.limit == 100)
        
        room.fetchRelationsJsonEventIdRelationTypeFromLimitThrowableError = TestError.failed
        #expect(await room.fetchRelatedEventsJSON(eventID: "$root", relation: relation, from: nil, limit: 1).isSDKError)
    }
    
    @Test
    func rawMessageLikeEventsDeliversTimelineShapedJSON() async throws {
        let room = RoomSDKMock()
        room.subscribeToMessageLikeEventsEventTypeListenerReturnValue = TaskHandleSDKMock()
        
        let stream = room.rawMessageLikeEvents(types: MatchaConfig.messageLikeEventTypes)
        let firstEvent = Task {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        
        let invocations = room.subscribeToMessageLikeEventsEventTypeListenerReceivedInvocations
        #expect(Set(invocations.map(\.eventType)) == Set(MatchaConfig.messageLikeEventTypes.map { messageLikeEventTypeFromString(s: $0) }))
        let card = try #require(invocations.first { $0.eventType == messageLikeEventTypeFromString(s: MatchaConfig.eventKanbanCard) })
        card.listener.onEvent(event: RoomMessageLikeEvent(eventType: card.eventType,
                                                          eventId: "$card",
                                                          sender: "@alice:example.org",
                                                          timestamp: 1_700_000_000_000,
                                                          contentJson: #"{"title":"Buy \"oat\" milk","n":1.0}"#,
                                                          encryptionInfo: nil))
        
        let json = try #require(await firstEvent.value)
        #expect(json.contains(#""content":{"title":"Buy \"oat\" milk","n":1.0}"#), "The content is passed on verbatim.")
        #expect(RawEvent(json: json) == RawEvent(type: MatchaConfig.eventKanbanCard,
                                                 content: ["title": .string(#"Buy "oat" milk"#), "n": .number(1)],
                                                 eventID: "$card",
                                                 senderID: "@alice:example.org",
                                                 timestamp: 1_700_000_000_000))
    }
    
    @Test
    func rawMessageLikeEventsEndWithTheIteratingTask() async {
        let room = RoomSDKMock()
        let handle = TaskHandleSDKMock()
        room.subscribeToMessageLikeEventsEventTypeListenerReturnValue = handle
        
        let stream = room.rawMessageLikeEvents(types: [MatchaConfig.eventKanbanCard, MatchaConfig.eventThreadMetadata])
        let iteration = Task {
            for await _ in stream { }
        }
        iteration.cancel()
        await iteration.value
        
        #expect(handle.cancelCallsCount == 2)
    }
    
    @Test
    func rawMessageLikeEventsEndWhenTheStreamIsDropped() {
        let room = RoomSDKMock()
        let handle = TaskHandleSDKMock()
        room.subscribeToMessageLikeEventsEventTypeListenerReturnValue = handle
        
        do {
            _ = room.rawMessageLikeEvents(types: [MatchaConfig.eventKanbanCard, MatchaConfig.eventThreadMetadata])
        }
        
        #expect(handle.cancelCallsCount == 2)
    }
    
    @Test
    func rawMessageLikeEventsAcceptEventsFromSDKThreads() async throws {
        let room = RoomSDKMock()
        room.subscribeToMessageLikeEventsEventTypeListenerReturnValue = TaskHandleSDKMock()
        let stream = room.rawMessageLikeEvents(types: [MatchaConfig.eventKanbanCard])
        let listener = try #require(room.subscribeToMessageLikeEventsEventTypeListenerReceivedInvocations.first?.listener)
        
        // The SDK calls listeners on its own threads, never on the main actor.
        DispatchQueue.global().async {
            listener.onEvent(event: RoomMessageLikeEvent(eventType: messageLikeEventTypeFromString(s: MatchaConfig.eventKanbanCard),
                                                         eventId: "$card",
                                                         sender: "@alice:example.org",
                                                         timestamp: 1,
                                                         contentJson: "{}",
                                                         encryptionInfo: nil))
        }
        
        var iterator = stream.makeAsyncIterator()
        let json = try #require(await iterator.next())
        #expect(RawEvent(json: json)?.eventID == "$card")
    }
    
    @Test
    func eventTypesTimeline() async {
        let room = RoomSDKMock()
        let timeline = TimelineSDKMock()
        timeline.subscribeToBackPaginationStatusListenerReturnValue = TaskHandleSDKMock()
        timeline.addListenerListenerReturnValue = TaskHandleSDKMock()
        room.timelineWithConfigurationConfigurationReturnValue = timeline
        
        let result = await room.eventTypesTimeline(types: MatchaConfig.scanTimelineEventTypes)
        
        #expect(result.success != nil)
        let configuration = room.timelineWithConfigurationConfigurationReceivedConfiguration
        #expect(configuration?.focus == .live(hideThreadedEvents: false), "Thread replies carry Matcha events too.")
        let types = MatchaConfig.scanTimelineEventTypes.sorted()
        #expect(configuration?.filter == .eventFilter(filter: .include(types.map { .eventType(timelineEventTypeFromString(s: $0)) })))
        #expect(types.contains("m.room.encrypted"))
        #expect(configuration?.trackReadReceipts == .disabled)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!timeline.fetchMembersCalled, "The scan shows no senders, so the room's members aren't fetched for it.")
        
        room.timelineWithConfigurationConfigurationThrowableError = TestError.failed
        #expect(await room.eventTypesTimeline(types: MatchaConfig.scanTimelineEventTypes).isSDKError)
    }
    
    @Test
    func scanTimelineItemsKeepTheirJSONVerbatim() throws {
        // The shared fixtures reject a fractional version, and a leading U+FEFF is part of a name.
        let json = #"{"type":"com.matchahoneylatte.thread.metadata","event_id":"$e7","sender":"@alice:example.org","origin_server_ts":1,"#
            + #""content":{"version":1.0,"name":""# + "\u{FEFF}" + #"x","m.relates_to":{"rel_type":"m.reference","event_id":"$root"}}}"#
        let item = EventTimelineItem(configuration: .init(eventID: "$e7"))
        let provider = try #require(item.lazyProvider as? LazyTimelineItemProviderSDKMock)
        provider.debugInfoReturnValue = .init(model: "", originalJson: json, latestEditJson: nil)
        let proxy = EventTimelineItemProxy(item: item, uniqueID: .init("1"))
        
        let event = try #require(RawEvent(json: proxy.originalJSON))
        
        #expect(event.content["version"] == .number(1))
        #expect(event.content["name"] == .string("\u{FEFF}x"))
        #expect(ThreadMetadataProtocol.parsePatch(event, rootID: "$root") == nil)
    }
    
    @Test
    func roomStateRequestEscapesTheRoomIDAndSendsTheSessionsToken() throws {
        let request = try #require(RoomStateRequest.request(homeserverURL: "https://matrix.example.org/", accessToken: "token", roomID: "!room:example.org"))
        
        #expect(request.url?.absoluteString == "https://matrix.example.org/_matrix/client/v3/rooms/%21room%3Aexample.org/state")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        #expect(RoomStateRequest.request(homeserverURL: "file:///etc", accessToken: "token", roomID: "!room:example.org") == nil)
    }
    
    @Test
    func roomStateResponseGivesTheContentsOfOneTypeByStateKey() {
        let state = #"""
        [{"type": "im.ponies.room_emotes", "state_key": "", "content": {"images": {}}},
         {"type": "im.ponies.room_emotes", "state_key": "pepe", "content": {"pack": {"display_name": "Pepe"}}},
         {"type": "m.room.member", "state_key": "@alice:example.org", "content": {"membership": "join"}},
         {"type": "im.ponies.room_emotes", "content": {}}, {"type": "im.ponies.room_emotes", "state_key": "list", "content": []}, 42]
        """#
        
        let contents = RoomStateRequest.contents(ofType: ImagePacks.roomEmotesEventType, in: Data(state.utf8))
        
        #expect(contents?.keys.sorted() == ["", "pepe"])
        #expect(contents?["pepe"].flatMap(JSONValue.init(json:)) == JSONValue(json: #"{"pack": {"display_name": "Pepe"}}"#))
        #expect(RoomStateRequest.contents(ofType: ImagePacks.roomEmotesEventType, in: Data(#"{"errcode": "M_FORBIDDEN"}"#.utf8)) == nil)
    }
    
    // MARK: - Helpers
    
    private enum TestError: Error {
        case failed
    }
    
    private func stateEvent(stateKey: String, content: String, eventID: String = "$event") -> RoomStateEvent {
        RoomStateEvent(eventType: stateEventTypeFromString(s: "test"), stateKey: stateKey, sender: "@alice:example.org", contentJson: content, eventId: eventID, timestamp: 0)
    }
}

private extension Result where Failure == RoomProxyError {
    var success: Success? {
        try? get()
    }
    
    var isSDKError: Bool {
        if case .failure(.sdkError) = self {
            true
        } else {
            false
        }
    }
}
