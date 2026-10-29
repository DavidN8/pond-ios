//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import MatchaProtocol
import MatrixRustSDK
import UIKit

/// Failures that must never be shown as an empty or saved document. Same codes as the web client.
nonisolated enum DocumentError: Equatable, Sendable {
    case loadError
    case decryptError
    case invalidUpdate
    case incompleteUpdate
    case permissionError
    case sendError
    case tooLargeError
    case anchorError
}

nonisolated enum DocumentSync: Equatable, Sendable {
    case loading
    case saved
    case saving
    case offline
    case error
}

nonisolated struct DocumentSessionState: Equatable, Sendable {
    /// The whole history has been replayed and nothing is missing.
    var isReady = false
    var canEdit = false
    var sync = DocumentSync.loading
    /// Local updates not yet acknowledged by the server.
    var pendingUpdates = 0
    var error: DocumentError?
    var text = ""
    /// The raw entries of the "documents" map, for the catalog.
    var entries: JSONObject = [:]
}

/// One shared document of a room, synced like the web client's `RoomDocumentSession`: every `com.matchahoneylatte.docs.update`
/// frame related to the room's `m.room.create` event is replayed from the store (once it has read that event's relations) before
/// editing is allowed; complete updates are deduplicated by sender and update id and checked by the engine before they apply;
/// local edits are debounced for 500 ms, merged, split into frames and only count as saved once the server accepted every frame.
/// Unsent edits live in memory only. A port of Android's `RoomDocumentSession.kt`.
///
/// Known difference: `JoinedRoomProxyProtocol.sendRawEvent` can't reuse transaction ids, so retrying a frame whose first attempt
/// reached the server sends it twice. That is harmless: the copies are identical, and receivers deduplicate by sender and update id.
final class RoomDocumentSession {
    private let documentID: String
    private let room: JoinedRoomProxyProtocol
    private let store: MatchaRoomStore
    private let engine: YjsEngineProtocol
    private let reachability: CurrentValuePublisher<HomeserverReachability, Never>
    private let isReadOnly: Bool
    private let newUpdateID: () -> String
    
    private let stateSubject = CurrentValueSubject<DocumentSessionState, Never>(.init())
    var statePublisher: CurrentValuePublisher<DocumentSessionState, Never> {
        stateSubject.asCurrentValuePublisher()
    }
    
    var state: DocumentSessionState {
        stateSubject.value
    }
    
    private let lock = TaskLimiter(limit: 1)
    private var document: YjsDocumentProtocol?
    private var anchor: String?
    private var isLoading = true
    /// The whole history has been replayed; `publish()` also checks that no update is missing.
    private var isReady = false
    private var error: DocumentError?
    private var text = ""
    private var entries: JSONObject = [:]
    private var isMissingInEngine = false
    /// Joined, allowed to send document frames, and to send encrypted events in an encrypted room.
    private var canSend = false
    private var buffered: [Data] = []
    /// Text changes, and the text they change, that an ended web content process never turned into updates.
    private var missedEdits: [(changes: [TextChange], base: String)] = []
    private var packets: [OutgoingPacket] = []
    private var incoming: [String: DocPacket] = [:]
    private var applied = Set<String>()
    private var seen = Set<String>()
    
    private var loadTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var cancellables = Set<AnyCancellable>()
    private var isClosed = false
    
    /// An update being sent; `unsent` shrinks as the server accepts each frame.
    private final class OutgoingPacket {
        let key: String
        let update: Data
        var unsent: [String]
        
        init(key: String, update: Data, frames: [String]) {
            self.key = key
            self.update = update
            unsent = frames
        }
    }
    
    init(documentID: String,
         room: JoinedRoomProxyProtocol,
         store: MatchaRoomStore,
         engine: YjsEngineProtocol,
         reachability: CurrentValuePublisher<HomeserverReachability, Never>,
         isReadOnly: Bool = false,
         newUpdateID: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.documentID = documentID
        self.room = room
        self.store = store
        self.engine = engine
        self.reachability = reachability
        self.isReadOnly = isReadOnly
        self.newUpdateID = newUpdateID
        
        room.infoPublisher
            .map(Self.canSend)
            .removeDuplicates()
            .sink { [weak self] allowed in
                guard let self else { return }
                canSend = allowed
                if !allowed, hasPending {
                    error = .permissionError
                }
                publish()
            }
            .store(in: &cancellables)
        reachability
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] reachability in
                guard let self else { return }
                publish()
                if reachability == .reachable, error == .sendError {
                    startFlush()
                }
            }
            .store(in: &cancellables)
        store.snapshotPublisher
            .map(\.events)
            .removeDuplicates()
            .sink { [weak self] events in
                Task { await self?.onEvents(events) }
            }
            .store(in: &cancellables)
        engine.stoppedPublisher
            .sink { [weak self] in self?.engineStopped() }
            .store(in: &cancellables)
        retry()
    }
    
    /// Replays the whole history again, keeping unsent edits, then sends them. Used to recover from any error.
    @discardableResult
    func retry() -> Task<Void, Never> {
        // A load that has replayed the history and is catching up with what arrived meanwhile starts again too: it can't recover
        // from a failure itself.
        if isLoading, let loadTask {
            return loadTask
        }
        isLoading = true
        isReady = false
        error = nil
        publish()
        let task = Task { [weak self] in
            guard let self else { return }
            await load()
        }
        loadTask = task
        return task
    }
    
    /// Applies an edit of the text field, from `before` to `after`; edits that arrived meanwhile are kept.
    func edit(from before: String, to after: String) async {
        await lock.run {
            guard let document, state.canEdit else { return }
            let changes = TextDiff.rebase(TextDiff.changes(from: before, to: after), from: before, onto: text)
            guard !changes.isEmpty else { return }
            var update: Data?
            do {
                update = try await document.edit(changes)
            } catch {
                // The engine's web content process ended with this keystroke: it is made again on the note read again.
                if error as? YjsEngineError == .stopped {
                    missedEdits.append((changes, text))
                }
                fail(error)
            }
            if error == nil || error == .sendError {
                text = TextDiff.apply(changes, to: text)
                if let update {
                    buffered.append(update)
                }
            }
        }
        publish()
        scheduleFlush()
    }
    
    /// Sets an entry of the catalog's "documents" map; call `flush()` to save it. False when it could not be set.
    func setEntry(key: String, value: JSONObject) async -> Bool {
        let isSet = await lock.run { () async -> Bool in
            guard let document, state.canEdit else { return false }
            do {
                if let update = try await document.setEntry(key: key, value: value) {
                    buffered.append(update)
                }
                entries = try await document.snapshot().entries
                return true
            } catch {
                fail(error)
                return false
            }
        }
        publish()
        return isSet
    }
    
    /// Sends unsent edits now and waits until they are acknowledged or failed.
    func flush() async {
        debounceTask?.cancel()
        await startFlush()?.value
    }
    
    func close() {
        isClosed = true
        cancellables = []
        loadTask?.cancel()
        flushTask?.cancel()
        debounceTask?.cancel()
        document?.close()
        document = nil
    }
    
    // MARK: - Loading
    
    private func load() async {
        do {
            try await awaitFrames()
            let anchor = if let anchor = self.anchor {
                anchor
            } else {
                await findAnchor()
            }
            guard let anchor else { throw DocumentFailure(.anchorError) }
            try await lock.run { () async throws(Error) in
                guard !isClosed else { return }
                let events = Array(store.snapshot.events.reversed())
                self.anchor = anchor
                let document = if let document = self.document {
                    document
                } else {
                    try await openDocument()
                }
                try await ingestAll(document, anchor: anchor, events: events)
                try await refresh(document)
                try await remakeMissedEdits(document)
                isReady = true
            }
        } catch {
            fail(error)
        }
        isLoading = false
        publish()
        guard !isClosed else { return }
        // Frames that arrived while loading, then the edits kept from before.
        await onEvents(store.snapshot.events)
        if isReady, hasPending {
            startFlush()
        }
    }
    
    /// Waits until the store holds every frame it can read. Frames relate to the anchor, whose relations the store reads in full;
    /// this SDK's timelines drop custom events, so older history would only add undecryptable copies of frames the relations hold
    /// too. When the store warns that some events are unreadable or a read failed (relations unavailable included), the whole
    /// history is read instead.
    private func awaitFrames() async throws {
        // Bounded: a failed read cleared by a later one leaves the store unloaded without a warning.
        await withTimeout(Self.storeReadTimeout) { [store] in await store.awaitRelations() }
        if case .failure(let error) = await store.loadHistoryUntil({ $0.isLoaded && $0.warning == nil }) {
            MXLog.warning("Could not read the history of a document: \(error)")
            throw DocumentFailure(.loadError)
        }
    }
    
    private func onEvents(_ events: [RawEvent]) async {
        guard !isLoading, !isClosed else { return }
        var needsReload = false
        await lock.run {
            guard let document, let anchor else { return }
            switch error {
            case .decryptError:
                // The keys arrived: read everything again.
                needsReload = !events.contains { DocsProtocol.isUndecryptedFrame($0, anchor: anchor) }
                return
            case .loadError, .invalidUpdate, .anchorError:
                return
            default:
                break
            }
            do {
                // Only an applied update changes the text, the entries or what is missing; edits update them locally.
                if try await ingestAll(document, anchor: anchor, events: events.reversed()) {
                    try await refresh(document)
                }
            } catch {
                fail(error)
            }
        }
        publish()
        if needsReload {
            retry()
        }
    }
    
    /// Ingests `events`, oldest first, and applies the updates they complete in one engine call. Returns whether an update was
    /// applied. Fails like ingesting the events one at a time would: on the same event, with the same events seen.
    @discardableResult
    private func ingestAll(_ document: YjsDocumentProtocol, anchor: String, events: [RawEvent]) async throws -> Bool {
        let seenBefore = seen
        let appliedBefore = applied
        let incomingBefore = incoming
        var updates = [Data]()
        var failure: Error?
        do {
            for event in events {
                try ingest(anchor: anchor, event: event) { update in
                    updates.append(update)
                    return true
                }
            }
        } catch {
            failure = error
        }
        let count = updates.isEmpty ? 0 : try await document.applyAll(updates)
        if count < updates.count {
            // An update was malformed: go through the events again as if each update had been applied on its own, which fails on it.
            seen = seenBefore
            applied = appliedBefore
            incoming = incomingBefore
            var index = 0
            for event in events {
                try ingest(anchor: anchor, event: event) { _ in
                    defer { index += 1 }
                    return index < count
                }
            }
        }
        if let failure {
            throw failure
        }
        return count > 0
    }
    
    /// Hands the update `event` completes, if any, to `apply`, which returns false when the engine refused it.
    private func ingest(anchor: String, event: RawEvent, apply: (Data) -> Bool) throws {
        guard let eventID = event.eventID, !seen.contains(eventID) else { return }
        // Not marked as seen: once decrypted, the same event comes back as a frame.
        if DocsProtocol.isUndecryptedFrame(event, anchor: anchor) {
            throw DocumentFailure(.decryptError)
        }
        switch DocsProtocol.parseFrame(event, anchor: anchor, documentID: documentID) {
        case .unrelated:
            break
        case .invalid:
            throw DocumentFailure(.invalidUpdate)
        case .frame(let senderID, let frame):
            try ingest(frame, senderID: senderID, apply: apply)
        }
        seen.insert(eventID)
    }
    
    private func ingest(_ frame: DocFrame, senderID: String, apply: (Data) -> Bool) throws {
        let key = DocsProtocol.packetKey(senderID: senderID, updateID: frame.updateID)
        guard !applied.contains(key) else { return }
        guard let packet = (incoming[key] ?? DocPacket(count: frame.chunks)).adding(frame) else { throw DocumentFailure(.invalidUpdate) }
        guard packet.isComplete else {
            incoming[key] = packet
            return
        }
        guard apply(packet.update) else { throw DocumentFailure(.invalidUpdate) }
        applied.insert(key)
        incoming[key] = nil
    }
    
    /// The room's `m.room.create` event, from the room state like the web client, or the one a room id of room version 12 is
    /// derived from. Never taken from the frames: any member can relate a frame to any event.
    private func findAnchor() async -> String? {
        switch await room.storedStateEventID(type: "m.room.create", stateKey: "") {
        case .success(.some(let eventID)):
            return eventID
        case .success(.none):
            break
        case .failure(let error):
            MXLog.warning("Could not read the create event of the room: \(error)")
        }
        guard !room.id.contains(":") else { return nil }
        return "$" + (room.id.hasPrefix("!") ? room.id.dropFirst() : Substring(room.id))
    }
    
    /// Opens the engine document; after an engine restart this replays everything again, with the local edits kept.
    private func openDocument() async throws -> YjsDocumentProtocol {
        let document = try await engine.open()
        // Closed while the engine opened it: nothing would close it later, and its web view would stay.
        guard !isClosed else {
            document.close()
            throw CancellationError()
        }
        seen = []
        incoming = [:]
        applied = []
        do {
            for packet in packets {
                applied.insert(packet.key)
                _ = try await document.apply(packet.update)
            }
            for update in buffered {
                _ = try await document.apply(update)
            }
        } catch {
            document.close()
            throw error
        }
        self.document = document
        return document
    }
    
    private func refresh(_ document: YjsDocumentProtocol) async throws {
        let snapshot = try await document.snapshot()
        text = snapshot.text
        entries = snapshot.entries
        isMissingInEngine = snapshot.isMissingUpdates
    }
    
    private func remakeMissedEdits(_ document: YjsDocumentProtocol) async throws {
        while let edit = missedEdits.first {
            let changes = TextDiff.rebase(edit.changes, from: edit.base, onto: text)
            if let update = try await document.edit(changes) {
                buffered.append(update)
            }
            text = TextDiff.apply(changes, to: text)
            missedEdits.removeFirst()
        }
    }
    
    // MARK: - Sending
    
    private var hasMissingUpdates: Bool {
        isMissingInEngine || incoming.values.contains { $0.isCommitted && !$0.isComplete }
    }
    
    private var hasPending: Bool {
        !buffered.isEmpty || !packets.isEmpty
    }
    
    private func scheduleFlush() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.startFlush()
        }
    }
    
    @discardableResult
    private func startFlush() -> Task<Void, Never>? {
        guard isReady, !isLoading, !isClosed else { return nil }
        if let flushTask {
            return flushTask
        }
        let task = Task { [weak self] in
            await self?.sendPending()
            self?.flushTask = nil
        }
        flushTask = task
        return task
    }
    
    private func sendPending() async {
        // The app may be put in the background while frames are on their way; they are worth the extra seconds, but no more than
        // the system gives: it ends an app whose background task outlives them.
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Matcha notes") { [weak self] in
            self?.endBackgroundTask()
        }
        defer {
            endBackgroundTask()
            publish()
        }
        guard canSend else {
            if hasPending {
                error = .permissionError
            }
            return
        }
        if let error, Self.sendErrors.contains(error) {
            self.error = nil
        }
        publish()
        do {
            while hasPending, !isClosed {
                let packet = if let first = packets.first {
                    first
                } else {
                    try await lock.run { () async throws(Error) in try await nextPacket() }
                }
                while let frame = packet.unsent.first {
                    guard canSend else { throw DocumentFailure(.permissionError) }
                    if case .failure(let error) = await store.send(type: MatchaConfig.eventDocsUpdate, contentJSON: frame) {
                        MXLog.warning("Could not send a document frame: \(error)")
                        throw DocumentFailure(.sendError)
                    }
                    packet.unsent.removeFirst()
                }
                packets.removeFirst()
                publish()
            }
        } catch let failure as DocumentFailure {
            MXLog.warning("Document edits remain unsent: \(failure.error)")
            error = failure.error
        } catch {
            fail(error)
        }
    }
    
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
    
    /// Merges the buffered edits into one update and splits it into frames.
    private func nextPacket() async throws -> OutgoingPacket {
        guard let document else { throw DocumentFailure(.loadError) }
        guard let anchor else { throw DocumentFailure(.anchorError) }
        let update = if buffered.count == 1, let single = buffered.first {
            single
        } else {
            try await document.merge(buffered)
        }
        let updateID = newUpdateID()
        let frames: [String]
        do {
            frames = try DocsProtocol.frames(update: update, anchor: anchor, updateID: updateID, documentID: documentID)
        } catch {
            throw DocumentFailure(.tooLargeError)
        }
        // Already in the local document: our own echo is skipped.
        let packet = OutgoingPacket(key: DocsProtocol.packetKey(senderID: room.ownUserID, updateID: updateID), update: update, frames: frames)
        packets.append(packet)
        applied.insert(packet.key)
        buffered = []
        return packet
    }
    
    // MARK: - State
    
    private func fail(_ failure: Error) {
        isReady = false
        if failure is YjsEngineError {
            document?.close()
            document = nil
        }
        // The system ends the engine's web content process as it likes, in the background above all: a document that was open is
        // read again into a new one, with the unsent edits kept. An engine that can't start is a load error.
        if failure as? YjsEngineError == .stopped, !isLoading, !isClosed {
            MXLog.warning("The notes engine stopped, reading the document again")
            retry()
            return
        }
        let error = (failure as? DocumentFailure)?.error ?? .loadError
        MXLog.warning("Could not sync the document: \(error)")
        self.error = error
    }
    
    /// The engine stopped while nothing was asking it anything.
    private func engineStopped() {
        guard let stopped = document else { return }
        Task {
            await lock.run {
                // An edit or a replay that was running has already failed on it, and maybe opened a new document since.
                guard document === stopped else { return }
                fail(YjsEngineError.stopped)
            }
            publish()
        }
    }
    
    private func publish() {
        let pending = buffered.count + packets.count + missedEdits.count
        // The causal guard: while an update misses its predecessors the document is incomplete and read-only, even when a send
        // failed meanwhile. Unsent edits are still sent; they only build on what this device has.
        let isMissing = !isLoading && hasMissingUpdates
        let error = if isMissing, self.error.map(Self.sendErrors.contains) ?? true {
            DocumentError.incompleteUpdate
        } else {
            self.error
        }
        let isReady = isReady && !isMissing
        let isOffline = reachability.value == .unreachable
        let sync: DocumentSync = if isLoading {
            .loading
        } else if error == .sendError, isOffline {
            .offline
        } else if error != nil {
            .error
        } else if pending > 0 {
            .saving
        } else {
            .saved
        }
        let state = DocumentSessionState(isReady: isReady,
                                         canEdit: isReady && !isLoading && !isReadOnly && canSend && (error == nil || error == .sendError),
                                         sync: sync,
                                         pendingUpdates: pending,
                                         error: error,
                                         text: text,
                                         entries: entries)
        if state != stateSubject.value {
            stateSubject.send(state)
        }
    }
    
    private static func canSend(_ info: RoomInfoProxyProtocol) -> Bool {
        guard info.membership == .joined, let powerLevels = info.powerLevels else { return false }
        return powerLevels.canOwnUser(sendMessage: messageLikeEventTypeFromString(s: MatchaConfig.eventDocsUpdate))
            && (!info.isEncrypted || powerLevels.canOwnUser(sendMessage: .roomEncrypted))
    }
    
    private static let debounce: Duration = .milliseconds(500)
    private static let storeReadTimeout: Duration = .seconds(10)
    private static let sendErrors: Set<DocumentError> = [.sendError, .permissionError, .tooLargeError]
}

private nonisolated struct DocumentFailure: Error {
    let error: DocumentError
    
    init(_ error: DocumentError) {
        self.error = error
    }
}

/// Runs `operation` until it ends or `timeout` passes, whichever comes first; the operation is cancelled at the timeout.
func withTimeout(_ timeout: Duration, _ operation: @escaping @Sendable () async -> Void) async {
    await withTaskGroup(of: Void.self) { group in
        group.addTask { await operation() }
        group.addTask { try? await Task.sleep(for: timeout) }
        await group.next()
        group.cancelAll()
    }
}

private extension TaskLimiter {
    /// `run(_:)` for an operation that throws.
    func run<T>(_ operation: () async throws(Error) -> T) async throws -> T {
        let result: Result<T, Error> = await run {
            do {
                return try await .success(operation())
            } catch {
                return .failure(error)
            }
        }
        return try result.get()
    }
}
