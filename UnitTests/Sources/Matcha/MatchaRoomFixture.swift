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
import MatrixRustSDKMocks
import Testing

/// The root of the board in board tests.
let aBoardRoot = "$board"
/// The user of the session in Matcha tests.
let matchaUser = "@me:x"

/// A joined room for the Matcha store over the proxy mocks: its scan timeline, thread list, relations, state and live events.
/// Everything is answered at once, so a store over it loads once it settles. The room's mock holds on to the fixture, so a store
/// over the room keeps working whatever holds the fixture.
final class MatchaRoomFixture {
    let room: JoinedRoomProxyMock
    let roomInfo: RoomInfoProxyMock
    let threads: CurrentValueSubject<[RoomThreadListItem], Never>
    let threadsPagination: CurrentValueSubject<RoomThreadListPaginationState, Never>
    let timeline: TimelineProxyMock
    
    /// The scan timeline's items, oldest first.
    var items: [TimelineItemProxy] {
        get { timelineUpdates.value.0 }
        set { timelineUpdates.send((newValue, timelineUpdates.value.1)) }
    }
    
    /// History older than `items`, one page per backward pagination, newest page first.
    var olderPages: [[TimelineItemProxy]]
    var hasMoreHistory: Bool {
        get { timelineUpdates.value.1.backward != .endReached }
        set { timelineUpdates.send((items, TimelinePaginationState(backward: newValue ? .idle : .endReached, forward: .endReached))) }
    }
    
    var paginateResult: () -> Result<Void, TimelineProxyError> = { .success(()) }
    /// Overrides opening the scan timeline; by default it opens on `items`.
    var timelineResult: (() -> Result<TimelineProxyProtocol, RoomProxyError>)?
    private(set) var timelinesOpened = 0
    
    /// The events related to each anchor by `m.reference`, as raw JSON, newest first.
    var references: [String: [String]] = [:]
    /// The replies of each thread, as raw JSON, newest first.
    var threadReplies: [String: [String]] = [:]
    /// Overrides reading related events, given the anchor, the relation, the token to start from and the limit.
    var relationsResult: ((String, RawRelationType, String?, Int) async -> Result<RawEventsPage, RoomProxyError>)?
    /// The stored board pointer's root, or how reading it fails.
    var boardPointer: Result<String?, RoomProxyError> = .success(nil)
    /// How the homeserver answers a board pointer read.
    var serverPointer: () -> Result<String?, RoomProxyError> = { .success(nil) }
    private(set) var serverPointerReads = 0
    /// The legacy thread archive state, by thread root id.
    var legacyArchive: [String: Bool] = [:]
    /// The id of the room's `m.room.create` event in the stored state.
    var createEventID: String?
    var sendResult: (String, String) -> Result<String, RoomProxyError> = { _, _ in .success("$sent") }
    var sendStateResult: (String, String, String) -> Result<String, RoomProxyError> = { _, _, _ in .success("$state") }
    private(set) var sent: [(type: String, content: String)] = []
    
    private let timelineUpdates: CurrentValueSubject<([TimelineItemProxy], TimelinePaginationState), Never>
    private var liveEvents: [AsyncStream<String>.Continuation] = []
    
    init(roomID: String = "!room:x",
         items: [TimelineItemProxy] = [],
         olderPages: [[TimelineItemProxy]] = [],
         threads: [RoomThreadListItem] = [],
         threadsPagination: RoomThreadListPaginationState = .idle(endReached: true),
         isDirect: Bool = false,
         heroes: [String] = [],
         canSendState: Bool = true) {
        self.olderPages = olderPages
        self.threads = .init(threads)
        self.threadsPagination = .init(threadsPagination)
        timelineUpdates = .init((items, TimelinePaginationState(backward: olderPages.isEmpty ? .endReached : .idle, forward: .endReached)))
        
        room = JoinedRoomProxyMock(.init(id: roomID, isDirect: isDirect, ownUserID: matchaUser))
        roomInfo = RoomInfoProxyMock(.init(id: roomID, isDirect: isDirect))
        roomInfo.heroes = heroes.map { RoomHero(userId: $0, displayName: nil, avatarUrl: nil, status: nil, call: nil) }
        let powerLevels = RoomPowerLevelsProxyMock(.init(canUserSendState: canSendState))
        roomInfo.powerLevels = powerLevels
        room.infoPublisher = CurrentValueSubject<RoomInfoProxyProtocol, Never>(roomInfo).asCurrentValuePublisher()
        
        let provider = TimelineItemProviderMock()
        provider.updatePublisher = timelineUpdates.eraseToAnyPublisher()
        provider.paginationState = timelineUpdates.value.1
        provider.kind = .live
        provider.membershipChangePublisher = PassthroughSubject().eraseToAnyPublisher()
        timeline = TimelineProxyMock(.init(timelineItemProvider: provider))
        timeline.paginateBackwardsRequestSizeClosure = { [self] _ in
            let result = paginateResult()
            if case .success = result {
                // The parameters of this init shadow the properties.
                let page = self.olderPages.isEmpty ? [] : self.olderPages.removeFirst()
                timelineUpdates.send((page + self.items, TimelinePaginationState(backward: self.olderPages.isEmpty ? .endReached : .idle, forward: .endReached)))
            }
            return result
        }
        
        let threadList = RoomThreadListServiceProxyMock(.init(items: []))
        threadList.itemsPublisher = self.threads.asCurrentValuePublisher()
        threadList.paginationStatePublisher = self.threadsPagination.asCurrentValuePublisher()
        room.threadListServiceReturnValue = threadList
        
        room.eventTypesTimelineTypesClosure = { [self] _ in
            timelinesOpened += 1
            return timelineResult?() ?? .success(timeline)
        }
        room.rawMessageLikeEventsTypesClosure = { [self] _ in
            let (stream, continuation) = AsyncStream<String>.makeStream()
            liveEvents.append(continuation)
            return stream
        }
        room.fetchRelatedEventsJSONEventIDRelationFromLimitClosure = { [self] eventID, relation, from, limit in
            if let relationsResult {
                return await relationsResult(eventID, relation, from, limit)
            }
            let related = relation == .reference ? references : threadReplies
            return .success(.init(events: related[eventID] ?? [], nextBatch: nil))
        }
        room.stateEventsJSONTypeClosure = { [self] type in
            switch type {
            case MatchaConfig.stateKanban:
                return boardPointer.map { root in root.map { ["": KanbanProtocol.boardPointerContent(rootID: $0)] } ?? [:] }
            case MatchaConfig.stateThreadArchive:
                return .success(legacyArchive.mapValues { #"{"archived": \#($0)}"# })
            default:
                return .success([:])
            }
        }
        room.fetchStateEventContentJSONTypeStateKeyClosure = { [self] type, stateKey in
            guard type == MatchaConfig.stateKanban, stateKey.isEmpty else { return .success(nil) }
            serverPointerReads += 1
            return serverPointer().map { $0.map { KanbanProtocol.boardPointerContent(rootID: $0) } }
        }
        room.storedStateEventIDTypeStateKeyClosure = { [self] type, stateKey in
            .success(type == "m.room.create" && stateKey.isEmpty ? createEventID : nil)
        }
        room.sendRawEventTypeContentJSONClosure = { [self] type, content in
            let result = sendResult(type, content)
            if case .success = result {
                sent.append((type, content))
            }
            return result
        }
        room.sendRawStateEventTypeStateKeyContentJSONClosure = { [self] type, stateKey, content in
            sendStateResult(type, stateKey, content)
        }
    }
    
    /// Delivers a new event from sync to every store reading the room.
    func sendLiveEvent(_ json: String) {
        liveEvents.forEach { $0.yield(json) }
    }
    
    func store(noBoardAnswers: NoBoardAnswers = NoBoardAnswers(), readsDocumentAnchor: Bool = false, knownServerPointer: String? = nil) -> MatchaRoomStore {
        MatchaRoomStore(room: room, noBoardAnswers: noBoardAnswers, readsDocumentAnchor: readsDocumentAnchor, knownServerPointer: knownServerPointer)
    }
}

// MARK: - Events

/// A Matcha event's raw JSON, sent at `index` ms.
func aMatchaEvent(_ index: Int, type: String, content: String, stateKey: String? = nil, sender: String = "@bob:x", eventID: String? = nil, unsigned: String = "") -> String {
    let stateKeyField = stateKey.map { #""state_key": "\#($0)", "# } ?? ""
    return #"{"type": "\#(type)", \#(stateKeyField)"event_id": "\#(eventID ?? "$e\(index)")", "sender": "\#(sender)", "origin_server_ts": \#(index)\#(unsigned), "content": \#(content)}"#
}

/// A scan timeline item carrying `json`, with the SDK content `content` (a redacted message unless given).
func aTimelineItem(_ index: Int, json: String, eventID: String? = nil, content: TimelineItemContent? = nil) -> TimelineItemProxy {
    var configuration = EventTimelineItemSDKMockConfiguration(eventID: eventID ?? "$e\(index)")
    if let content {
        configuration.content = content
    }
    let item = EventTimelineItem(configuration: configuration)
    (item.lazyProvider as? LazyTimelineItemProviderSDKMock)?.debugInfoReturnValue = .init(model: "", originalJson: json, latestEditJson: nil)
    return .event(EventTimelineItemProxy(item: item, uniqueID: .init("item-\(index)")))
}

/// A scan timeline item carrying a Matcha event.
func aMatchaEventItem(_ index: Int, type: String, content: String, stateKey: String? = nil, sender: String = "@bob:x") -> TimelineItemProxy {
    aTimelineItem(index, json: aMatchaEvent(index, type: type, content: content, stateKey: stateKey, sender: sender))
}

/// A card revision of the board at `boardRoot`.
func aCard(id: String,
           title: String,
           status: TaskStatus = .todo,
           threadID: String? = nil,
           archived: Bool = false,
           showToRoom: Bool = true,
           boardRoot: String = aBoardRoot) throws -> String {
    try KanbanProtocol.cardContent(CardRevision(cardID: id, title: title, description: "", status: status, archived: archived, threadID: threadID,
                                                dueAt: nil, reminderRequested: nil, showToRoom: showToRoom),
                                   rootID: boardRoot)
}

/// A scan timeline item carrying one revision of a card of the board.
func aCardItem(_ index: Int,
               id: String,
               title: String,
               status: TaskStatus = .todo,
               threadID: String? = nil,
               showToRoom: Bool = true,
               sender: String = "@bob:x") throws -> TimelineItemProxy {
    try aMatchaEventItem(index, type: MatchaConfig.eventKanbanCard, content: aCard(id: id, title: title, status: status, threadID: threadID, showToRoom: showToRoom),
                         sender: sender)
}

/// A scan timeline item carrying a patch of the shared name or archived flag of the thread `threadID`.
func aThreadPatchItem(_ index: Int, threadID: String, name: String? = nil, archived: Bool? = nil) throws -> TimelineItemProxy {
    try aMatchaEventItem(index, type: MatchaConfig.eventThreadMetadata, content: ThreadMetadataProtocol.patchContent(rootID: threadID, name: name, archived: archived))
}

/// A scan timeline item carrying the board pointer state event, pointing at `rootID`.
func aBoardPointerItem(_ index: Int, rootID: String) -> TimelineItemProxy {
    aMatchaEventItem(index, type: MatchaConfig.stateKanban, content: KanbanProtocol.boardPointerContent(rootID: rootID), stateKey: "")
}

/// An undecryptable scan timeline item whose clear relation refers to `target`.
func anUndecryptableItem(_ index: Int, target: String, cause: UtdCause) -> TimelineItemProxy {
    let content = #"{"algorithm": "m.megolm.v1.aes-sha2", "ciphertext": "x", "m.relates_to": {"rel_type": "m.reference", "event_id": "\#(target)"}}"#
    return aTimelineItem(index,
                         json: aMatchaEvent(index, type: "m.room.encrypted", content: content, eventID: "$u\(index)"),
                         eventID: "$u\(index)",
                         content: .msgLike(content: .init(kind: .unableToDecrypt(msg: .megolmV1AesSha2(sessionId: "session", cause: cause)),
                                                          inReplyTo: nil, threadRoot: nil, threadSummary: nil)))
}

/// A thread of the thread list.
func aThreadListItem(_ id: String,
                     body: String? = nil,
                     timestamp: Int64 = 10,
                     sender: String = "@bob:x",
                     numberOfReplies: Int = 1,
                     isRootUnreadable: Bool = false,
                     rootUTDCause: UtdCause? = nil,
                     latestSender: String? = nil,
                     latestTimestamp: Int64? = nil) -> RoomThreadListItem {
    let thread = ListedThread(id: id,
                              rootBody: isRootUnreadable ? nil : body ?? "Root of \(id)",
                              rootSenderID: sender,
                              rootTimestamp: timestamp,
                              isRootUnreadable: isRootUnreadable,
                              latestSenderID: latestSender,
                              latestTimestamp: latestSender.map { _ in latestTimestamp ?? timestamp },
                              numberOfReplies: numberOfReplies)
    return RoomThreadListItem(id: id,
                              rootMessageDetails: .init(sender: .init(id: sender), timestamp: .now, message: nil),
                              latestMessageDetails: nil,
                              numberOfReplies: UInt(numberOfReplies),
                              matcha: MatchaListedThread(thread: thread, rootUTDCause: rootUTDCause))
}

/// Waits for a snapshot of `store` that satisfies `condition`, recording an issue when none comes.
@discardableResult
func waitForSnapshot(_ store: MatchaRoomStore,
                     sourceLocation: SourceLocation = #_sourceLocation,
                     where condition: @escaping @Sendable (MatchaRoomSnapshot) -> Bool) async -> MatchaRoomSnapshot? {
    let snapshot = await firstValue(of: store.snapshotPublisher, timeout: .seconds(10), where: condition)
    if snapshot == nil {
        Issue.record("No snapshot came that satisfies the condition", sourceLocation: sourceLocation)
    }
    return snapshot
}

/// Holds whoever waits on it until it is opened.
final class Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    
    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

/// Waits until `condition` holds, checking every few milliseconds, recording an issue when it doesn't within a few seconds.
func eventually(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async {
    for _ in 0..<500 {
        if condition() {
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("The condition never held", sourceLocation: sourceLocation)
}
