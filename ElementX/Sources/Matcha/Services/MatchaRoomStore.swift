//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Algorithms
import Combine
import Foundation
import MatchaProtocol
import MatrixRustSDK

/// What the room-level Matcha features may do, from the room's power levels.
nonisolated struct MatchaPermissions: Sendable, Equatable {
    var canSendMessages = false
    var canManageThreads = false
    var canWriteCards = false
    var canCreateBoard = false
    var canInvite = false
    
    /// A new thread is a message and its name.
    var canCreateThreads: Bool {
        canManageThreads && canSendMessages
    }
    
    /// Adding a task also creates its thread.
    var canAddTasks: Bool {
        canWriteCards && canCreateThreads
    }
    
    /// Archiving and restoring a thread's task also changes the thread.
    func canArchive(threadID: String?) -> Bool {
        canWriteCards && (threadID == nil || canManageThreads)
    }
}

/// Why some of a room's Matcha data may be missing or out of date: one line for the user. The first case wins when several apply.
nonisolated enum MatchaWarning: Int, Sendable, Comparable {
    /// Some Matcha events or thread roots can't be decrypted on this device yet.
    case undecryptable
    /// Older Matcha events can't be decrypted on this device: the keys of that history aren't available.
    case historyUnavailable
    /// Matcha events from before the user joined can't be read.
    case noAccess
    /// Reading history or the thread list failed; the data may be out of date.
    case network
    
    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Everything the Matcha features know about one room, rebuilt from its timeline, thread list, relations and state.
nonisolated struct MatchaRoomSnapshot: Sendable, Equatable {
    /// False until the thread list, the first history pages, the stored room state and the first relations have been read.
    var isLoaded = false
    /// All threads, active and archived, most recently active first.
    var threads: [MatchaThread] = []
    var board: MatchaBoard?
    var permissions = MatchaPermissions()
    var hasMoreHistory = true
    var hasMoreThreads = true
    var isLoadingMore = false
    /// Matcha events in server order, newest first, for features that read them directly (documents). Events that can't be
    /// decrypted are included with the type `m.room.encrypted`; only their relation is readable.
    var events: [RawEvent] = []
    /// The room holds a board card or thread patch that can't be decrypted, so the board or names may be out of date.
    var unreadable = false
    var warning: MatchaWarning?
    /// True once a missing `board` is really missing: the board is known, the homeserver said the room has no pointer, or the
    /// Matcha history was read back to the start of the room. The stored room state alone proves nothing, since the sync only
    /// stores the custom state it asked for.
    var isBoardResolved = false
    /// The Matcha timeline could not be opened; `MatchaRoomStore.retryLoad()` tries again.
    var loadFailed = false
    /// The room is a direct chat, whose members are involved in every task.
    var isDirect = false
}

enum MatchaRoomStoreError: Error {
    /// The Matcha timeline could not be opened, or the store has stopped.
    case timelineUnavailable
    case timeline(TimelineProxyError)
    /// The task waiting for the read was cancelled.
    case cancelled
}

/// Reads the Matcha workspace data of one joined room and publishes it as one snapshot: cards, thread names and document frames
/// from the events related to each anchor (the board root, every thread root, the document anchor), new ones from the live
/// message-like events, Matcha state and undecryptable events from a scan timeline of only those types, thread roots from the
/// SDK's thread list, and the board pointer from the stored room state and the homeserver. Writes go through
/// `JoinedRoomProxyProtocol.sendRawEvent` and show before their remote echo. Events are parsed and snapshots built off the main
/// actor, one at a time. Owned by `MatchaService`, which calls `stop()` once nothing shows the room.
final class MatchaRoomStore {
    let room: JoinedRoomProxyProtocol
    private let readsDocumentAnchor: Bool
    private let noBoardAnswers: NoBoardAnswers
    
    private let snapshotSubject = CurrentValueSubject<MatchaRoomSnapshot, Never>(.init())
    var snapshotPublisher: CurrentValuePublisher<MatchaRoomSnapshot, Never> {
        snapshotSubject.asCurrentValuePublisher()
    }
    
    var snapshot: MatchaRoomSnapshot {
        snapshotSubject.value
    }
    
    /// The homeserver doesn't serve related events, so cards, thread names and document frames can't be read.
    var relationsUnavailable: Bool {
        inputs.relationsUnavailable
    }
    
    /// The homeserver has answered whether the room has a board pointer, so `readBoardPointer()`'s nil proves there is none.
    var isServerPointerRead: Bool {
        inputs.storedState.isServerRead
    }
    
    private let inputsSubject: CurrentValueSubject<Inputs, Never>
    /// Everything snapshots are built from; every change builds a new one.
    private var inputs: Inputs {
        get { inputsSubject.value }
        set {
            inputsSubject.send(newValue)
            setNeedsSnapshot()
        }
    }
    
    private var scanTimeline: TimelineProxyProtocol?
    private var threadListService: RoomThreadListServiceProxyProtocol?
    private var cancellables = Set<AnyCancellable>()
    private var liveEventsTask: Task<Void, Never>?
    private var storedStateReadTask: Task<Void, Never>?
    
    private var scanCache = ScanCache()
    private var isBuildingSnapshot = false
    private var needsSnapshot = false
    
    private var requestedAnchors = Set<String>()
    /// The reply count each thread had when its replies were last requested, by thread root id.
    private var repliesRequestedAt = [String: Int]()
    /// The highest reply count each thread had when a read of its replies succeeded, by thread root id.
    private var repliesReadAt = [String: Int]()
    /// The newest replies read of each thread, at most a page of them, newest first, by thread root id.
    private var newestRepliesRead = [String: [String]]()
    /// The threads whose replies are being read, one read per thread at a time.
    private var repliesReading = Set<String>()
    
    private let anchorReads = TaskLimiter(limit: MatchaConfig.maxConcurrentAnchors)
    private let historyLock = TaskLimiter(limit: 1)
    private let writeLock = TaskLimiter(limit: 1)
    
    private var tasks = [UUID: Task<Void, Never>]()
    private let pendingWorkSubject = CurrentValueSubject<Int, Never>(0)
    private(set) var isStopped = false
    
    /// A board root this client sent whose pointer couldn't be set; the next create points at it instead of sending another.
    var unpointedBoardRoot: String?
    
    /// - Parameters:
    ///   - readsDocumentAnchor: also read the events related to the room's `m.room.create` event, which document frames relate to.
    ///   - knownServerPointer: the board pointer the homeserver already returned to the caller, so the store starts from it
    ///     instead of asking again.
    init(room: JoinedRoomProxyProtocol, noBoardAnswers: NoBoardAnswers, readsDocumentAnchor: Bool = false, knownServerPointer: String? = nil) {
        self.room = room
        self.noBoardAnswers = noBoardAnswers
        self.readsDocumentAnchor = readsDocumentAnchor
        inputsSubject = .init(Inputs(storedState: StoredState(serverPointer: knownServerPointer, isServerRead: knownServerPointer != nil)))
        start()
    }
    
    /// Ends every read and subscription and lets go of the scan timeline.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        // Ends every wait: no snapshot is built and no timeline update arrives after this.
        inputs.isStopped = true
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        liveEventsTask?.cancel()
        cancellables = []
        scanTimeline = nil
        threadListService = nil
        pendingWorkSubject.send(0)
    }
    
    /// Opens the Matcha timeline again after it `loadFailed`, and asks the homeserver for the board pointer again if it hasn't
    /// answered.
    func retryLoad() {
        if inputs.loadFailed, scanTimeline == nil {
            openTimeline()
        }
        if !inputs.storedState.isServerRead {
            track { await $0.readServerPointer() }
        }
    }
    
    /// Loads one more page of history and of the thread list. Calls are serialized, and a call made before the timeline has
    /// opened waits for it.
    ///
    /// - Returns: whether older history remains, or the failure to read the history page; a failure to read more threads is only
    ///   logged.
    func loadMore() async -> Result<Bool, MatchaRoomStoreError> {
        await historyLock.run {
            guard let timeline = await awaitTimeline() else { return .failure(.timelineUnavailable) }
            inputs.isLoadingMore = true
            defer { inputs.isLoadingMore = false }
            
            let history = await paginateBackwards(timeline)
            inputs.readFailed = history.isFailure
            if case .failure(let error) = history {
                MXLog.warning("Could not read older Matcha history: \(error)")
            }
            if inputs.isThreadListIdle, inputs.hasMoreThreads {
                await paginateThreads()
            }
            if readsDocumentAnchor {
                await requestDocumentAnchor()
            }
            // Related events are read in full per anchor, so "no more history" also means every anchor has been read.
            if !history.isFailure {
                _ = await firstValue(of: inputsSubject.asCurrentValuePublisher(), timeout: MatchaConfig.anchorsTimeout) { $0.anchorsLoading.isEmpty || $0.isStopped }
            }
            return history.map { inputs.backPagination != .endReached }.mapError(MatchaRoomStoreError.timeline)
        }
    }
    
    /// Loads older history until `isFound` holds for the snapshot or the start of the room is reached, then returns once the
    /// snapshot shows what was read. A cancelled task stops between pages, and a stopped store fails.
    ///
    /// ponytail: reads page by page, so reaching the start of a long room takes many requests.
    func loadHistoryUntil(_ isFound: @escaping @Sendable (MatchaRoomSnapshot) -> Bool) async -> Result<Void, MatchaRoomStoreError> {
        while !isFound(snapshot) {
            guard !Task.isCancelled else { return .failure(.cancelled) }
            switch await loadMore() {
            case .failure(let error):
                return .failure(error)
            case .success(true):
                continue
            case .success(false):
                return await firstSnapshot { !$0.hasMoreHistory } == nil ? .failure(.timelineUnavailable) : .success(())
            }
        }
        return .success(())
    }
    
    /// Waits until the events related to the room's `m.room.create` event, which document frames relate to, have been read and
    /// the snapshot holds them, then until the store has loaded or shows why it may be incomplete (`loadFailed` or a `warning`).
    /// The anchor is requested here too, in case the room state didn't hold it when the store opened. A read that never ends
    /// keeps the store from loading, so callers bound the wait. Returns at once when the store stops.
    func awaitRelations() async {
        await requestDocumentAnchor()
        _ = await firstValue(of: inputsSubject.asCurrentValuePublisher(), timeout: MatchaConfig.anchorsTimeout) { $0.anchorsLoading.isEmpty || $0.isStopped }
        // Snapshots are built a moment after a read, so the latest one may be from before the anchor was requested.
        let read = Set(inputs.relationEvents.values.joined().compactMap(\.eventID))
        _ = await firstSnapshot { snapshot in
            (snapshot.isLoaded || snapshot.loadFailed || snapshot.warning != nil) && read.isSubset(of: snapshot.events.compactMap(\.eventID))
        }
    }
    
    /// Reads the board pointer again, right before creating a board: from the stored room state, then from the homeserver when
    /// the stored state holds none, so a board made elsewhere is never replaced. Returns the root id, nil when there is none, or
    /// the failure of the read.
    func readBoardPointer() async -> Result<String?, RoomProxyError> {
        let stored = await readStoredState()
        if case .success(.some) = stored {
            return stored
        }
        let server = await fetchServerPointer()
        if case .success(let pointer) = server {
            recordServerPointer(pointer)
        }
        return server
    }
    
    /// Sends a Matcha timeline event and shows it straight away, before its remote echo.
    func send(type: String, contentJSON: String) async -> Result<String, RoomProxyError> {
        await writeLock.run {
            let result = await room.sendRawEvent(type: type, contentJSON: contentJSON)
            // Only the Matcha types are read back, so an echo of any other type would never be replaced.
            if case .success(let eventID) = result, MatchaConfig.messageLikeEventTypes.contains(type), let content = JSONValue(json: contentJSON)?.objectValue {
                let echo = RawEvent(type: type,
                                    content: content,
                                    eventID: eventID,
                                    senderID: room.ownUserID,
                                    timestamp: Int64(Date.now.timeIntervalSince1970 * 1000))
                inputs.optimisticEvents.insert(echo, at: 0)
            }
            return result
        }
    }
    
    /// Sends a state event; it is read back from the stored state once synced.
    func sendState(type: String, stateKey: String, contentJSON: String) async -> Result<String, RoomProxyError> {
        await writeLock.run {
            let result = await room.sendRawStateEvent(type: type, stateKey: stateKey, contentJSON: contentJSON)
            if case .success = result {
                // The Tasks tab may remember that this chat had no board; it has one now.
                if type == MatchaConfig.stateKanban {
                    noBoardAnswers.pointed(roomID: room.id)
                }
                await readStoredState()
            }
            return result
        }
    }
    
    /// Shows the board this client created until its pointer is read back from the room.
    func rememberCreatedBoard(rootID: String) {
        inputs.storedState.createdBoardRoot = rootID
    }
    
    /// Waits until nothing the store started is still running, which tests use to let it settle.
    func settle() async {
        _ = await firstValue(of: pendingWorkSubject.asCurrentValuePublisher()) { $0 == 0 }
    }
    
    // MARK: - Reading
    
    private func start() {
        room.subscribeToRoomInfoUpdates()
        openTimeline()
        if !inputs.storedState.isServerRead {
            track { await $0.readServerPointer() }
        }
        
        let liveEvents = room.rawMessageLikeEvents(types: MatchaConfig.messageLikeEventTypes)
        liveEventsTask = Task { [weak self] in
            for await json in liveEvents {
                guard let self else { return }
                guard let event = RawEvent(json: json) else { continue }
                if !inputs.liveEvents.contains(where: { $0.eventID == event.eventID }) {
                    inputs.liveEvents.insert(event, at: 0)
                }
            }
        }
        
        if readsDocumentAnchor {
            track { await $0.requestDocumentAnchor() }
        }
        
        let threadListService = room.threadListService()
        self.threadListService = threadListService
        threadListService.itemsPublisher
            .sink { [weak self] items in
                self?.inputs.threadList = items.compactMap(\.matcha)
            }
            .store(in: &cancellables)
        threadListService.paginationStatePublisher
            .sink { [weak self] state in
                self?.inputs.threadsPagination = state
            }
            .store(in: &cancellables)
        track { await $0.paginateThreads() }
        
        room.infoPublisher
            .sink { [weak self] info in
                guard let self else { return }
                inputs.permissions = Self.permissions(info)
                inputs.directMembers = info.isDirect ? Set([room.ownUserID] + info.heroes.map(\.userId)) : []
                scheduleStoredStateRead()
            }
            .store(in: &cancellables)
    }
    
    private func openTimeline() {
        track { store in
            switch await store.room.eventTypesTimeline(types: MatchaConfig.scanTimelineEventTypes) {
            case .failure(let error):
                MXLog.warning("Could not open the Matcha timeline: \(error)")
                store.inputs.loadFailed = true
            case .success(let timeline):
                guard !store.isStopped else { return }
                store.scanTimeline = timeline
                timeline.timelineItemProvider.updatePublisher
                    .sink { [weak store] items, pagination in
                        store?.scanTimelineUpdated(items: items, pagination: pagination.backward)
                    }
                    .store(in: &store.cancellables)
                store.inputs.loadFailed = false
                store.inputs.isTimelineOpen = true
                // Read a bounded amount of history up front; older items are loaded on demand.
                await store.readInitialHistory(timeline)
            }
        }
    }
    
    private func scanTimelineUpdated(items: [TimelineItemProxy], pagination: PaginationState) {
        var inputs = inputs
        inputs.scanItems = items.compactMap { item in
            if case .event(let event) = item {
                event
            } else {
                nil
            }
        }
        inputs.backPagination = pagination
        self.inputs = inputs
        // Stored state changes arrive with syncs; read it again whenever something new arrives.
        scheduleStoredStateRead()
    }
    
    private func readInitialHistory(_ timeline: TimelineProxyProtocol) async {
        for _ in 0..<MatchaConfig.initialHistoryPages {
            guard inputs.backPagination != .endReached, !Task.isCancelled else { return }
            // Another read may have reached the start while this one waited for the lock; paginateBackwards allows for that.
            let result = await historyLock.run { await paginateBackwards(timeline) }
            inputs.readFailed = result.isFailure
            if case .failure(let error) = result {
                MXLog.warning("Could not read Matcha history: \(error)")
                return
            }
            inputs.historyPagesRead += 1
        }
    }
    
    /// Reads one older page once any running page is done, unless the start of the room has been reached.
    private func paginateBackwards(_ timeline: TimelineProxyProtocol) async -> Result<Void, TimelineProxyError> {
        let pagination = await firstValue(of: inputsSubject.asCurrentValuePublisher()) { $0.backPagination != .paginating || $0.isStopped }?.backPagination
        guard pagination != .endReached, !isStopped else { return .success(()) }
        return await timeline.paginateBackwards(requestSize: MatchaConfig.historyPageSize)
    }
    
    /// The open timeline, waiting for it to open; nil when opening failed or the store stopped.
    private func awaitTimeline() async -> TimelineProxyProtocol? {
        _ = await firstValue(of: inputsSubject.asCurrentValuePublisher()) { $0.isTimelineOpen || $0.loadFailed || $0.isStopped }
        return scanTimeline
    }
    
    /// The first snapshot that satisfies `condition`, the current one included; nil once the store stops, as no snapshot is built
    /// after that.
    private func firstSnapshot(where condition: @escaping @Sendable (MatchaRoomSnapshot) -> Bool) async -> MatchaRoomSnapshot? {
        await firstValue(of: snapshotPublisher, until: inputsSubject.asCurrentValuePublisher().map(\.isStopped), where: condition)
    }
    
    private func paginateThreads() async {
        guard let threadListService else { return }
        let result = await threadListService.paginate()
        if case .failure(let error) = result {
            MXLog.warning("Could not read the threads: \(error)")
        }
        inputs.readFailed = result.isFailure
    }
    
    private func scheduleStoredStateRead() {
        storedStateReadTask?.cancel()
        storedStateReadTask = track { store in
            try? await Task.sleep(for: MatchaConfig.storedStateDebounce)
            guard !Task.isCancelled else { return }
            await store.readStoredState()
        }
    }
    
    /// Reads the stored room state; returns the board pointer read, or the failure to read it.
    @discardableResult
    private func readStoredState() async -> Result<String?, RoomProxyError> {
        let pointerRead = await room.stateEventsJSON(type: MatchaConfig.stateKanban).map { KanbanProtocol.parseBoardPointer(json: $0[""]) }
        if case .failure(let error) = pointerRead {
            MXLog.warning("Could not read the board pointer: \(error)")
        }
        let legacy = await (try? room.stateEventsJSON(type: MatchaConfig.stateThreadArchive).get()) ?? [:]
        var state = inputs.storedState
        // A failed read keeps what was known.
        if case .success(let pointer) = pointerRead {
            state.boardPointer = pointer
        }
        state.legacyArchive = legacy.compactMapValues { JSONValue(json: $0)?.objectValue?.bool("archived") }
        state.isRead = true
        inputs.storedState = state
        return pointerRead
    }
    
    private func readServerPointer() async {
        if case .success(let pointer) = await fetchServerPointer() {
            recordServerPointer(pointer)
        }
    }
    
    /// The board pointer from the homeserver: the root id, or nil when the room has none.
    private func fetchServerPointer() async -> Result<String?, RoomProxyError> {
        let read = await room.fetchStateEventContentJSON(type: MatchaConfig.stateKanban, stateKey: "")
        if case .failure(let error) = read {
            MXLog.warning("Could not fetch the board pointer from the homeserver: \(error)")
        }
        return read.map(KanbanProtocol.parseBoardPointer(json:))
    }
    
    private func recordServerPointer(_ pointer: String?) {
        var state = inputs.storedState
        state.serverPointer = pointer
        state.isServerRead = true
        inputs.storedState = state
    }
    
    /// The room's `m.room.create` event, which document frames relate to.
    private func requestDocumentAnchor() async {
        if case .success(.some(let anchor)) = await room.storedStateEventID(type: "m.room.create", stateKey: "") {
            requestAnchors([anchor])
        }
    }
    
    // MARK: Relations
    
    /// Fetches, once each, the events related to new anchors by an `m.reference` relation, a few anchors at a time.
    private func requestAnchors(_ anchors: [String]) {
        for anchor in anchors where anchor.unicodeScalars.first == "$" && requestedAnchors.insert(anchor).inserted {
            launchRelationsRead(key: anchor, isFirstRead: true) { store in
                await store.fetchRelated(eventID: anchor, relation: .reference)
            } onRead: { store, events in
                store.inputs.relationEvents[anchor] = events
            }
        }
    }
    
    /// Reads each thread's replies: their senders are the thread's participants, and the hidden bootstrap reply among them (the
    /// thread's first) makes `MatchaThread.hasHiddenFirstReply`. A thread's first read pages back through all its replies. A
    /// thread is read again whenever the thread list's reply count changes, so new repliers and replies are seen, one read per
    /// thread at a time; only its first read holds up `isLoaded`. What is read is added to what was read before, so once a read has
    /// succeeded, the next one pages only until it reaches one of the newest replies read before. The replies read give the thread its
    /// reply count and the time of its latest reply (see `Inputs.readReplies`).
    ///
    /// ponytail: a first read takes up to `MatchaConfig.maxRelationPages` requests of `relationsPageSize` replies and holds up the
    /// load until done; a longer thread may count its hidden reply as a visible one, and misses repliers further back. Paging
    /// older replies on demand, as the web client's Load more does, would lift both. A later read that finds none of the newest
    /// replies read before (all redacted since) pages back through the whole thread too.
    private func requestReplies(_ threads: [MatchaThread]) {
        // Every read would fail the same way.
        guard !inputs.relationsUnavailable else { return }
        // A listed thread without replies has none to read; a card's thread that isn't listed yet may have some. A thread being
        // read is requested again when its read ends. The thread list's count tells when there are new replies to read.
        let listedCounts = Dictionary(inputs.threadList.map { ($0.thread.id, $0.thread.numberOfReplies) }) { first, _ in first }
        for thread in threads where !repliesReading.contains(thread.id) {
            let threadID = thread.id
            let count = listedCounts[threadID] ?? thread.numberOfReplies
            guard count > 0 || thread.rootSenderID == nil else { continue }
            let previous = repliesRequestedAt.updateValue(count, forKey: threadID)
            guard previous != count else { continue }
            repliesReading.insert(threadID)
            // A count that went down (a redaction) still reads the newest reply.
            let wanted = repliesReadAt[threadID].map { max(count - $0, 1) }
            let readBefore = newestRepliesRead[threadID] ?? []
            let key = threadID + "#thread"
            launchRelationsRead(key: key, isFirstRead: previous == nil) { store in
                await store.fetchRelated(eventID: threadID, relation: .thread, wanted: wanted, readBefore: readBefore)
            } onRead: { store, replies in
                store.repliesReadAt[threadID] = max(store.repliesReadAt[threadID] ?? count, count)
                let ids = replies.prefix(MatchaConfig.relationsPageSize).compactMap(\.eventID) + (store.newestRepliesRead[threadID] ?? [])
                store.newestRepliesRead[threadID] = Array(ids.uniqued().prefix(MatchaConfig.relationsPageSize))
                store.inputs.threadRepliers[threadID, default: []].formUnion(TaskParticipants.repliers(replies)[threadID] ?? [])
                // A read of every reply (below the page cap) counts them; a later one adds the newer ones.
                let readsAll = wanted == nil && replies.count < MatchaConfig.maxRelationPages * MatchaConfig.relationsPageSize
                if readsAll || store.inputs.readReplies[threadID] != nil {
                    store.inputs.readReplies[threadID, default: ReadReplies()].add(replies, threadID: threadID)
                }
                // Only the hidden bootstrap replies are kept with the Matcha events. A later read adds to the earlier ones: it no
                // longer reaches the thread's first reply.
                let bootstrap = replies.filter { $0.type == MatchaConfig.eventThreadMetadata }
                store.inputs.relationEvents[key] = Self.distinct((store.inputs.relationEvents[key] ?? []) + bootstrap)
            } onDone: { store in
                store.repliesReading.remove(threadID)
                store.requestReplies(store.snapshot.threads)
            }
        }
    }
    
    /// Runs `read` a few at a time, then `onRead` with what it read, then `onDone` whether it succeeded or not; a first read is
    /// waited for by `isLoaded`.
    private func launchRelationsRead(key: String,
                                     isFirstRead: Bool,
                                     read: @escaping @MainActor (MatchaRoomStore) async -> Result<[RawEvent], RoomProxyError>,
                                     onRead: @escaping @MainActor (MatchaRoomStore, [RawEvent]) -> Void,
                                     onDone: @escaping @MainActor (MatchaRoomStore) -> Void = { _ in }) {
        if isFirstRead {
            inputs.anchorsLoading.insert(key)
        }
        track { store in
            let result = await store.anchorReads.run { () async -> Result<[RawEvent], RoomProxyError>? in
                if Task.isCancelled {
                    return nil
                }
                return await read(store)
            }
            switch result {
            case .success(let events):
                onRead(store, events)
            case .failure(let error):
                if error.isUnrecognizedEndpoint {
                    store.inputs.relationsUnavailable = true
                } else {
                    store.inputs.readFailed = true
                }
                MXLog.warning("Could not read the events related to a Matcha anchor: \(error)")
            case nil:
                return
            }
            if isFirstRead {
                store.inputs.anchorsLoading.remove(key)
            }
            onDone(store)
        }
    }
    
    /// Reads the events related to `eventID` by `relation`, newest first, page by page: all of them, or only the newer ones. A
    /// read that knows some of the newest events `readBefore` pages until it reaches one of them, as events sent after the
    /// `wanted` ones were counted push those further back; its first page asks for one more than `wanted`, so it usually
    /// reaches one there. Without `readBefore`, it stops once `wanted` events are read.
    ///
    /// ponytail: a fixed page cap bounds very long histories (`maxRelationPages` × `relationsPageSize` events); add paging on
    /// demand if one anchor ever needs more.
    private func fetchRelated(eventID: String, relation: RawRelationType, wanted: Int? = nil, readBefore: [String] = []) async -> Result<[RawEvent], RoomProxyError> {
        let pageSize = MatchaConfig.relationsPageSize
        let toFetch = wanted.map { $0 + (readBefore.isEmpty ? 0 : 1) }
        let readBefore = Set(readBefore)
        var events = [RawEvent]()
        var from: String?
        var fetched = 0
        for _ in 0..<MatchaConfig.maxRelationPages {
            let limit = toFetch.map { $0 - fetched }.flatMap { $0 > 0 ? min($0, pageSize) : nil } ?? pageSize
            let page: RawEventsPage
            switch await room.fetchRelatedEventsJSON(eventID: eventID, relation: relation, from: from, limit: limit) {
            case .success(let result): page = result
            case .failure(let error): return .failure(error)
            }
            fetched += page.events.count
            let read = await Self.parse(page.events)
            events += read
            let isDone = readBefore.isEmpty ? toFetch.map { fetched >= $0 } ?? false : read.contains { $0.eventID.map(readBefore.contains) ?? false }
            // The SDK's requests don't end with the task, so a stopped store stops between pages.
            guard !isDone, !Task.isCancelled, let nextBatch = page.nextBatch else { return .success(events) }
            from = nextBatch
        }
        MXLog.warning("Stopped reading the events related to a Matcha anchor after \(MatchaConfig.maxRelationPages) pages")
        return .success(events)
    }
    
    // MARK: - Snapshots
    
    private func setNeedsSnapshot() {
        needsSnapshot = true
        guard !isBuildingSnapshot, !isStopped else { return }
        isBuildingSnapshot = true
        track { store in
            // Only the latest inputs matter, so a burst of changes is built once.
            while store.needsSnapshot, !store.isStopped {
                store.needsSnapshot = false
                let build = await Self.buildSnapshot(store.inputs, cache: store.scanCache)
                store.scanCache = build.cache
                if !build.echoedEventIDs.isEmpty {
                    // The remote copies are in, so the snapshot doesn't change: no new one is needed.
                    store.inputsSubject.value.optimisticEvents.removeAll { build.echoedEventIDs.contains($0.eventID ?? "") }
                }
                guard build.snapshot != store.snapshot else {
                    // The thread list's count, which says when a thread has new replies, changes without changing the snapshot.
                    store.requestReplies(build.snapshot.threads)
                    continue
                }
                store.snapshotSubject.send(build.snapshot)
                store.requestAnchors((build.snapshot.board.map { [$0.rootID] } ?? []) + build.snapshot.threads.map(\.id))
                store.requestReplies(build.snapshot.threads)
            }
            store.isBuildingSnapshot = false
        }
    }
    
    /// Builds a snapshot from `inputs` off the main actor, parsing the scan items `cache` doesn't hold yet.
    @concurrent
    private static func buildSnapshot(_ inputs: Inputs, cache: ScanCache) async -> SnapshotBuild {
        var cache = cache
        let (scanEvents, utdCauses) = cache.read(inputs.scanItems)
        let related = inputs.relationEvents.keys.sorted().flatMap { inputs.relationEvents[$0] ?? [] }
        let remote = distinct(inputs.liveEvents + related + scanEvents)
        let known = Set(remote.compactMap(\.eventID))
        let pending = inputs.optimisticEvents.filter { !known.contains($0.eventID ?? "") }
        let echoed = Set(inputs.optimisticEvents.compactMap(\.eventID)).intersection(known)
        let events = pending + remote
        
        let state = inputs.storedState
        // Only a pointer makes a board, as on the web client. A root without one is never a board: it is left behind by a create
        // whose pointer failed, and the pointer of a real board is newer than its root, so the scan holds it whenever it holds the
        // root. Cards are newer than the pointer, so the board they refer to stands in for a pointer older than the scan. The
        // homeserver's answer, read when the store opened, comes after the stored state and the scan, which can be newer.
        let boardRootID = state.boardPointer
            ?? events.first { $0.type == MatchaConfig.stateKanban && $0.stateKey == "" }.flatMap { KanbanProtocol.parseBoardPointer($0.content) }
            ?? state.serverPointer
            ?? state.createdBoardRoot
            ?? events.first { $0.type == MatchaConfig.eventKanbanCard }?.content.referenceTarget
        let threadList = inputs.threadList.map { inputs.readReplies[$0.thread.id]?.apply(to: $0.thread) ?? $0.thread }
        let (threads, board) = RoomProjection.threadsAndBoard(events: events,
                                                              boardRootID: boardRootID,
                                                              threadList: threadList,
                                                              threadRepliers: inputs.threadRepliers,
                                                              legacyArchive: state.legacyArchive,
                                                              directMembers: inputs.directMembers)
        
        // An undecryptable event's relation stays readable: one referring to the board or a thread is Matcha data.
        let matchaTargets = Set(threads.map(\.id) + [boardRootID].compactMap { $0 })
        let unreadableCauses = events
            .filter { $0.type == DocsProtocol.eventRoomEncrypted && $0.content.referenceTarget.map(matchaTargets.contains) == true }
            .map { $0.eventID.flatMap { utdCauses[$0] } }
        let nameSources = Dictionary(threads.map { ($0.id, $0.metadata.nameSource) }) { first, _ in first }
        let unreadableRootCauses = inputs.threadList
            .filter { $0.thread.isRootUnreadable && nameSources[$0.thread.id] != .explicit }
            .map(\.rootUTDCause)
        let warning = (unreadableCauses + unreadableRootCauses).map(warning(for:)).min()
            ?? (inputs.relationsUnavailable ? .historyUnavailable : nil)
            ?? (inputs.readFailed ? .network : nil)
        let isHistoryRead = inputs.backPagination == .endReached || inputs.historyPagesRead >= MatchaConfig.initialHistoryPages
        
        let snapshot = MatchaRoomSnapshot(isLoaded: isHistoryRead && inputs.isThreadListIdle && state.isRead && inputs.anchorsLoading.isEmpty,
                                          threads: threads,
                                          board: board,
                                          permissions: inputs.permissions,
                                          hasMoreHistory: inputs.backPagination != .endReached,
                                          hasMoreThreads: inputs.hasMoreThreads,
                                          isLoadingMore: inputs.isLoadingMore || inputs.backPagination == .paginating,
                                          events: events,
                                          unreadable: !unreadableCauses.isEmpty,
                                          warning: warning,
                                          // ponytail: history hidden from a member who joined later may hide an older pointer too;
                                          // the homeserver's answer settles it.
                                          isBoardResolved: boardRootID != nil || state.isServerRead || inputs.backPagination == .endReached,
                                          loadFailed: inputs.loadFailed,
                                          isDirect: !inputs.directMembers.isEmpty)
        return SnapshotBuild(snapshot: snapshot, cache: cache, echoedEventIDs: echoed)
    }
    
    @concurrent
    private static func parse(_ events: [String]) async -> [RawEvent] {
        events.compactMap { RawEvent(json: $0) }
    }
    
    /// The events without a repeated event id, the first of each kept, unless it can't be decrypted and a later copy can: a card read
    /// through relations before its key arrived gives way to the scan's decrypted copy.
    private nonisolated static func distinct(_ events: [RawEvent]) -> [RawEvent] {
        var result = [RawEvent]()
        var indices = [String: Int]()
        for event in events {
            guard let eventID = event.eventID else {
                result.append(event)
                continue
            }
            if let index = indices[eventID] {
                if result[index].type == DocsProtocol.eventRoomEncrypted {
                    result[index] = event
                }
            } else {
                indices[eventID] = result.count
                result.append(event)
            }
        }
        return result
    }
    
    /// The warning for one undecryptable event; Matrix only tells why for Megolm events, anything else is plainly undecryptable.
    private nonisolated static func warning(for cause: UtdCause?) -> MatchaWarning {
        switch cause {
        case .sentBeforeWeJoined: .noAccess
        case .historicalMessageAndBackupIsDisabled, .historicalMessageAndDeviceIsUnverified: .historyUnavailable
        default: .undecryptable
        }
    }
    
    private static func permissions(_ info: RoomInfoProxyProtocol) -> MatchaPermissions {
        guard let powerLevels = info.powerLevels else { return MatchaPermissions() }
        func canSend(_ type: String) -> Bool {
            powerLevels.canOwnUser(sendMessage: messageLikeEventTypeFromString(s: type)) && (!info.isEncrypted || powerLevels.canOwnUser(sendMessage: .roomEncrypted))
        }
        let canWriteCards = canSend(MatchaConfig.eventKanbanCard)
        return MatchaPermissions(canSendMessages: powerLevels.canOwnUser(sendMessage: .roomMessage),
                                 canManageThreads: canSend(MatchaConfig.eventThreadMetadata),
                                 canWriteCards: canWriteCards,
                                 canCreateBoard: canWriteCards && canSend(MatchaConfig.eventKanbanBoard)
                                     && powerLevels.canOwnUser(sendStateEvent: stateEventTypeFromString(s: MatchaConfig.stateKanban)),
                                 canInvite: powerLevels.canOwnUserInvite())
    }
    
    // MARK: - Tasks
    
    /// Runs `operation` until it ends or the store stops; `settle()` waits for it.
    @discardableResult
    private func track(_ operation: @escaping @MainActor (MatchaRoomStore) async -> Void) -> Task<Void, Never>? {
        guard !isStopped else { return nil }
        let id = UUID()
        pendingWorkSubject.value += 1
        let task = Task { [weak self] in
            guard let self else { return }
            await operation(self)
            tasks[id] = nil
            if !isStopped {
                pendingWorkSubject.value -= 1
            }
        }
        tasks[id] = task
        return task
    }
}

// MARK: - Inputs

private extension MatchaRoomStore {
    nonisolated struct StoredState: Sendable {
        /// The board pointer of the stored room state; only a hint, see `MatchaRoomSnapshot.isBoardResolved`.
        var boardPointer: String?
        var legacyArchive: [String: Bool] = [:]
        /// The board this client created, until its pointer is read back.
        var createdBoardRoot: String?
        /// The stored state was read at least once, successfully or not.
        var isRead = false
        /// The board pointer the homeserver returned, which the sync doesn't store; nil when it has none or wasn't asked.
        var serverPointer: String?
        /// The homeserver answered whether the room has a board pointer, so a missing board is really missing.
        var isServerRead: Bool
    }
    
    nonisolated struct Inputs: Sendable {
        /// The scan timeline's events, oldest first.
        var scanItems: [EventTimelineItemProxy] = []
        /// Matcha events read from the homeserver as relations of each anchor (board root, thread roots, document anchor) and
        /// the bootstrap replies of each thread (keyed by its root id and `#thread`), newest first.
        var relationEvents: [String: [RawEvent]] = [:]
        /// New Matcha events from sync, newest first; timelines drop custom message-like events, so they come from here.
        var liveEvents: [RawEvent] = []
        var optimisticEvents: [RawEvent] = []
        var threadList: [MatchaListedThread] = []
        var threadsPagination = RoomThreadListPaginationState.idle(endReached: false)
        /// The senders of each thread's replies, as far as read, by thread root id.
        var threadRepliers: [String: Set<String>] = [:]
        /// Each thread's replies read through relations, by thread root id, once a read reached its first reply; they give the thread
        /// its reply count and the time of its latest reply.
        ///
        /// ponytail: the SDK's thread list (matrix-sdk-ui `thread_list_service.rs`, `event_cache_listener_loop`) counts every event of
        /// a listed thread that the room's event cache receives as one more reply, those read back from history or decrypted again
        /// included, so the scan's history read counted replies again (Launch plan: 3 replies for 1). It also caps the latest reply's
        /// time at the root's. The relations read is the homeserver's own list; a thread longer than the page cap keeps the thread
        /// list's count, as does any thread until a read of all its replies succeeds or when none can be read (history hidden from
        /// the user). Counting only newer events in the SDK would let the list's count back.
        var readReplies: [String: ReadReplies] = [:]
        /// The current user and the other members of a direct chat, or empty in any other chat.
        var directMembers: Set<String> = []
        var storedState: StoredState
        var permissions = MatchaPermissions()
        var backPagination = PaginationState.idle
        var historyPagesRead = 0
        var isLoadingMore = false
        var isTimelineOpen = false
        var loadFailed = false
        /// The last read of history, of the thread list or of related events failed.
        var readFailed = false
        /// Anchors whose related events are still being read for the first time.
        var anchorsLoading: Set<String> = []
        var relationsUnavailable = false
        /// `MatchaRoomStore.stop()` was called, which ends every wait on these inputs and on the snapshots.
        var isStopped = false
        
        var isThreadListIdle: Bool {
            if case .idle = threadsPagination {
                true
            } else {
                false
            }
        }
        
        var hasMoreThreads: Bool {
            if case .idle(let endReached) = threadsPagination {
                !endReached
            } else {
                true
            }
        }
    }
    
    /// What was read of a thread's replies.
    nonisolated struct ReadReplies: Sendable {
        private var ids = Set<String>()
        private var latestTimestamp: Int64?
        
        /// Adds the replies of the thread `threadID` among `events`.
        mutating func add(_ events: [RawEvent], threadID: String) {
            for event in events where !event.isRedacted && event.content.relationTarget(MatchaConfig.relationTypeThread) == threadID {
                guard let id = event.eventID, ids.insert(id).inserted, let timestamp = event.timestamp else { continue }
                latestTimestamp = max(latestTimestamp ?? timestamp, timestamp)
            }
        }
        
        /// `thread` with the count and latest time of the replies read, unchanged when none could be read. The thread list's latest
        /// replier stays: whichever reply it took for the latest, its sender replied.
        func apply(to thread: ListedThread) -> ListedThread {
            guard !ids.isEmpty else { return thread }
            var thread = thread
            thread.numberOfReplies = ids.count
            thread.latestTimestamp = latestTimestamp ?? thread.latestTimestamp
            return thread
        }
    }
    
    nonisolated struct SnapshotBuild: Sendable {
        let snapshot: MatchaRoomSnapshot
        /// The cache for the next build.
        let cache: ScanCache
        /// The optimistic events whose remote copy has arrived.
        let echoedEventIDs: Set<String>
    }
    
    /// What was parsed of each scan item, kept while the item is in the timeline: parsing reads its JSON through the SDK.
    nonisolated struct ScanCache: Sendable {
        struct Entry: Sendable {
            let item: EventTimelineItemProxy
            let event: RawEvent?
            let utdCause: UtdCause?
        }
        
        private var entries: [ObjectIdentifier: Entry] = [:]
        
        /// The events of `items` (oldest first), newest first, with why each undecryptable one can't be decrypted. Keeps only
        /// what it parsed of `items`.
        mutating func read(_ items: [EventTimelineItemProxy]) -> (events: [RawEvent], utdCauses: [String: UtdCause]) {
            var next = [ObjectIdentifier: Entry]()
            var events = [RawEvent]()
            var utdCauses = [String: UtdCause]()
            for item in items.reversed() where item.id.eventID != nil {
                let key = ObjectIdentifier(item)
                let entry = entries[key] ?? Entry(item: item, event: RawEvent(json: item.originalJSON), utdCause: item.utdCause)
                next[key] = entry
                guard let event = entry.event else { continue }
                events.append(event)
                if let cause = entry.utdCause, let eventID = event.eventID {
                    utdCauses[eventID] = cause
                }
            }
            entries = next
            return (events, utdCauses)
        }
    }
}

private nonisolated extension EventTimelineItemProxy {
    /// Why the event can't be decrypted, `.unknown` when it isn't a Megolm event; nil when it isn't undecryptable.
    var utdCause: UtdCause? {
        guard case let .msgLike(content) = content, case let .unableToDecrypt(message) = content.kind else { return nil }
        if case let .megolmV1AesSha2(_, cause) = message {
            return cause
        }
        return .unknown
    }
}

private extension RoomProxyError {
    /// The homeserver doesn't know the endpoint, so every request to it fails the same way.
    var isUnrecognizedEndpoint: Bool {
        guard case .sdkError(let error) = self, case .MatrixApi(.unrecognized, _, _, _)? = error as? ClientError else { return false }
        return true
    }
}
