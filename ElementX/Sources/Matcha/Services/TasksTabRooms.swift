//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import MatchaProtocol

/// A chat with a board, held open by the Tasks tab.
final class TabRoom {
    let room: JoinedRoomProxyProtocol
    let store: MatchaRoomStore
    /// The chat screens reading through `store`, see `TasksTabRooms.acquire(roomID:)`; the room is let go only once they are gone.
    fileprivate let holders = CurrentValueSubject<Int, Never>(0)
    private var writes = [UUID: Task<Void, Never>]()
    
    init(room: JoinedRoomProxyProtocol, store: MatchaRoomStore) {
        self.room = room
        self.store = store
    }
    
    /// Runs a write started from the tab, which finishes even once the user has left the tab; the room is let go only once it is done.
    func write(_ operation: @escaping @MainActor () async -> Void) {
        let id = UUID()
        writes[id] = Task { [weak self] in
            await operation()
            self?.writes[id] = nil
        }
    }
    
    fileprivate var runningWrites: [Task<Void, Never>] {
        Array(writes.values)
    }
}

/// A chat with a board and what its store has read.
nonisolated struct TabChat: Sendable {
    let roomID: String
    let name: String
    let avatarURL: URL?
    let room: TabRoom
    let snapshot: MatchaRoomSnapshot
}

/// What the Tasks tab knows about the user's chats.
nonisolated struct TabChats: Sendable {
    /// The joined chats with a board, in the room list's order.
    var boards: [TabChat] = []
    /// Chats still being checked for a board.
    var checking: Set<String> = []
    /// Chats that could not be checked.
    var failed: Set<String> = []
    /// The joined DMs (the SDK's `isDm`, as the Channels tab and Android), known from the room list before any check.
    var dms: Set<String> = []
    /// False until the room list has loaded, so a chat that isn't listed isn't known to be absent yet.
    var isRoomListLoaded = false
}

/// The chats the Tasks tab reads, one per session. `run(first:)` checks every joined chat that isn't a space for a task board, a
/// few at a time, keeps a `MatchaRoomStore` open for each chat that has one, and lets go of each room it opened once the user
/// leaves that chat, or `MatchaConfig.tasksTabKeepAlive` after `run(first:)` ends unless it runs again: coming back to the tab,
/// or from a task's thread, finds every board read. A chat screen opened meanwhile reads through the same store (see
/// `acquire(roomID:)`), and a room it holds is let go only once it is gone. A chat has a board when its board pointer is set, as
/// on the web client: the stored room state proves it, but the sync only stores the custom state it asked for, so a chat without
/// a stored pointer asks the homeserver, and a chat without a board is skipped unread.
///
/// ponytail: at most `MatchaConfig.tasksTabMaxConcurrentChecks` chats are checked at once, every chat with a board stays open
/// while the tab is shown and for the keep-alive after, and a chat without one is only asked again once its "no board" answer
/// is old (see `NoBoardAnswers`) or this client gives it a board.
final class TasksTabRooms {
    private let clientProxy: ClientProxyProtocol
    private let noBoardAnswers: NoBoardAnswers
    private let clock: any Clock<Duration>
    
    private let chatsSubject = CurrentValueSubject<TabChats, Never>(.init())
    var chatsPublisher: CurrentValuePublisher<TabChats, Never> {
        chatsSubject.asCurrentValuePublisher()
    }
    
    private var checks = [String: Check]() {
        didSet { checksChanged() }
    }
    
    /// The joined chats in the room list's order, or nil until the room list has loaded.
    private var joinedChats: [ChatInfo]? {
        didSet { publishChats() }
    }
    
    private var snapshotCancellables = [String: AnyCancellable]()
    /// Holds back publishing while the room list's changes are applied, so no one sees the list without its checks.
    private var isApplyingRoomList = false
    private let retriesSubject = CurrentValueSubject<Int, Never>(0)
    /// The chats waiting for a check, in turn order, and the checks running.
    private var queuedChecks = [String]()
    private var checkTasks = [String: Task<Void, Never>]()
    /// Each run's checks record only into that run, so a check cut short can't record into the next one.
    private var runGeneration = 0
    private var runTask: Task<Void, Never>?
    /// Lets everything go once the tab has been gone for the keep-alive; the next run cancels it.
    private var closeTask: Task<Void, Never>?
    /// `stop()` let everything go for good (logout), so no run has anything left to let go later.
    private var isStopped = false
    
    init(clientProxy: ClientProxyProtocol, noBoardAnswers: NoBoardAnswers, clock: any Clock<Duration> = ContinuousClock()) {
        self.clientProxy = clientProxy
        self.noBoardAnswers = noBoardAnswers
        self.clock = clock
    }
    
    /// Follows the user's joined chats until the calling task is cancelled, then lets go of every room it opened once the
    /// keep-alive passes without another run. The chats in `first`, such as a space's, are checked before the others. One run
    /// goes at a time: a new one waits for the previous one to end.
    func run(first: Set<String> = []) async {
        let previous = runTask
        let task = Task {
            await previous?.value
            await runUntilCancelled(first: first)
        }
        runTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
    
    /// Checks the chats again that could not be checked, and opens again the boards that failed to open.
    func retry() {
        retriesSubject.value += 1
    }
    
    /// Holds the board the tab has open for `roomID`, so the chat's screens read through its store rather than opening a second
    /// one; nil when the tab has none. The room isn't let go until each hold is let go with `release(_:)`, even once the tab lets
    /// it go.
    func acquire(roomID: String) -> TabRoom? {
        guard case .board(let room) = checks[roomID] else { return nil }
        room.holders.value += 1
        return room
    }
    
    /// Lets go of a hold taken by `acquire(roomID:)`.
    func release(_ room: TabRoom) {
        room.holders.value -= 1
    }
    
    /// Lets go of everything at once, on logout.
    func stop() {
        isStopped = true
        runTask?.cancel()
        closeTask?.cancel()
        queuedChecks = []
        checkTasks.values.forEach { $0.cancel() }
        checkTasks = [:]
        for check in checks.values {
            check.room?.store.stop()
        }
        checks = [:]
        joinedChats = nil
    }
    
    // MARK: - Private
    
    private enum Check {
        case pending
        case noBoard
        case failed
        case board(TabRoom)
        
        var room: TabRoom? {
            if case .board(let room) = self {
                room
            } else {
                nil
            }
        }
    }
    
    private struct ChatInfo: Equatable {
        let id: String
        let name: String
        let avatarURL: URL?
        let isDM: Bool
    }
    
    /// What the homeserver says about a chat's board pointer.
    private enum ServerPointer {
        case present(rootID: String)
        case absent
    }
    
    private func runUntilCancelled(first: Set<String>) async {
        closeTask?.cancel()
        closeTask = nil
        runGeneration += 1
        // A chat found without a board that this client has given one since is checked again.
        for (roomID, check) in checks {
            if case .noBoard = check, noBoardAnswers.takePointed(roomID: roomID) {
                checks[roomID] = nil
            }
        }
        
        var handledRetries = retriesSubject.value
        let provider = clientProxy.staticRoomSummaryProvider
        let subscription = provider.statePublisher.combineLatest(provider.roomListPublisher, retriesSubject)
            .sink { [weak self] state, summaries, retry in
                guard let self, state.isLoaded else { return }
                let joined = summaries.filter { $0.isJoined && !$0.isSpace }.map { ChatInfo(id: $0.id, name: $0.name, avatarURL: $0.avatarURL, isDM: $0.isDM) }
                joinedChatsChanged(joined, first: first)
                if retry != handledRetries {
                    handledRetries = retry
                    retryChecks()
                }
            }
        
        let (untilCancelled, continuation) = AsyncStream<Never>.makeStream()
        for await _ in untilCancelled { }
        continuation.finish()
        subscription.cancel()
        
        // A check cut short is done again next time, rather than counting as checking for ever, and so is one that failed.
        queuedChecks = []
        checkTasks.values.forEach { $0.cancel() }
        checkTasks = [:]
        checks = checks.filter { _, check in
            switch check {
            case .pending, .failed: false
            case .noBoard, .board: true
            }
        }
        guard !isStopped else { return }
        closeTask = Task { [weak self, clock] in
            try? await clock.sleep(for: MatchaConfig.tasksTabKeepAlive)
            guard !Task.isCancelled, let self else { return }
            // Everything goes, chats without a board too, so a board made meanwhile is found next time.
            checks.keys.forEach(close)
            joinedChats = nil
        }
    }
    
    private func joinedChatsChanged(_ joined: [ChatInfo], first: Set<String>) {
        isApplyingRoomList = true
        defer {
            isApplyingRoomList = false
            publishChats()
        }
        if joinedChats != joined {
            joinedChats = joined
        }
        let joinedIDs = Set(joined.map(\.id))
        // A chat the user left drops out at once, with its tasks.
        for roomID in checks.keys where !joinedIDs.contains(roomID) {
            queuedChecks.removeAll { $0 == roomID }
            checkTasks.removeValue(forKey: roomID)?.cancel()
            close(roomID)
        }
        // The checks take their turns in the order they start, so `first` goes first and the rest keep the room list's order.
        let unchecked = joined.map(\.id).filter { checks[$0] == nil }
        for roomID in unchecked.filter(first.contains) + unchecked.filter({ !first.contains($0) }) {
            startCheck(roomID)
        }
        startQueuedChecks()
    }
    
    private func retryChecks() {
        for (roomID, check) in checks {
            switch check {
            case .failed: startCheck(roomID)
            case .board(let room): room.store.retryLoad()
            case .pending, .noBoard: break
            }
        }
        startQueuedChecks()
    }
    
    private func startCheck(_ roomID: String) {
        checks[roomID] = .pending
        queuedChecks.append(roomID)
    }
    
    /// Starts the queued checks in turn while fewer than `MatchaConfig.tasksTabMaxConcurrentChecks` run.
    private func startQueuedChecks() {
        while checkTasks.count < MatchaConfig.tasksTabMaxConcurrentChecks, !queuedChecks.isEmpty {
            let roomID = queuedChecks.removeFirst()
            let generation = runGeneration
            checkTasks[roomID] = Task { [weak self] in
                await self?.check(roomID, generation: generation)
                guard let self, generation == runGeneration, !Task.isCancelled else { return }
                checkTasks[roomID] = nil
                startQueuedChecks()
            }
        }
    }
    
    private func check(_ roomID: String, generation: Int) async {
        func recordUnopened() {
            MXLog.warning("Could not open \(roomID) to look for its board")
            record(roomID, .failed, generation: generation)
        }
        
        // The pointer is read without opening the room's timeline; only a chat with a board is opened in full.
        let hasStoredPointer: Bool
        switch await clientProxy.stateEventsJSON(roomID: roomID, type: MatchaConfig.stateKanban) {
        case .success(let states):
            hasStoredPointer = KanbanProtocol.parseBoardPointer(json: states[""]) != nil
        case .failure(.roomNotInLocalStore):
            return recordUnopened()
        case .failure(let error):
            MXLog.warning("Could not read the board pointer of \(roomID): \(error)")
            hasStoredPointer = false
        }
        var knownServerPointer: String?
        if !hasStoredPointer {
            // The sync doesn't store the pointer, so ask the homeserver; a chat without a board is then skipped unread.
            switch await readServerPointer(roomID, generation: generation) {
            case nil:
                return
            case .absent:
                record(roomID, .noBoard, generation: generation)
                return
            case .present(let rootID):
                knownServerPointer = rootID
            }
        }
        guard !Task.isCancelled else { return }
        guard case .joined(let room) = await clientProxy.roomForIdentifier(roomID) else { return recordUnopened() }
        guard !Task.isCancelled else { return }
        
        // The store starts from the homeserver's answer rather than asking again, so a failed second read can't lose the board.
        let store = MatchaRoomStore(room: room, noBoardAnswers: noBoardAnswers, knownServerPointer: knownServerPointer)
        guard record(roomID, .board(TabRoom(room: room, store: store)), generation: generation) else {
            store.stop()
            return
        }
        // Keep the turn while the store reads the chat, so only a few chats read at once.
        _ = await firstValue(of: store.snapshotPublisher, timeout: MatchaConfig.tasksTabStoreLoadTimeout) { $0.isLoaded || $0.loadFailed }
    }
    
    /// Asks the homeserver whether the chat has a board pointer; nil after recording a failed check. A recent "no board" answer
    /// is reused, so showing the tab again doesn't ask every chat again.
    private func readServerPointer(_ roomID: String, generation: Int) async -> ServerPointer? {
        if noBoardAnswers.isRecent(roomID: roomID) {
            return .absent
        }
        let read = await clientProxy.fetchStateEventContentJSON(roomID: roomID, type: MatchaConfig.stateKanban, stateKey: "")
        // A check cut short records nothing: the chat may be checked again already, and its answer may be newer.
        guard !Task.isCancelled else { return nil }
        switch read {
        case .success(let json):
            if let rootID = KanbanProtocol.parseBoardPointer(json: json) {
                noBoardAnswers.forget(roomID: roomID)
                return .present(rootID: rootID)
            }
            noBoardAnswers.record(roomID: roomID)
            return .absent
        case .failure(let error):
            MXLog.warning("Could not fetch the board pointer of \(roomID): \(error)")
            record(roomID, .failed, generation: generation)
            return nil
        }
    }
    
    /// Records `check` unless the chat was dropped meanwhile, its check was cut short or the run ended; returns whether it was
    /// recorded.
    @discardableResult
    private func record(_ roomID: String, _ check: Check, generation: Int) -> Bool {
        guard generation == runGeneration, !Task.isCancelled, checks[roomID] != nil else { return false }
        checks[roomID] = check
        return true
    }
    
    private func close(_ roomID: String) {
        guard let room = checks.removeValue(forKey: roomID)?.room else { return }
        // A write the user started still finishes; the room goes once nothing uses it, so an Undo or Retry tapped after the user
        // left the tab still writes. A chat screen still reading the store keeps it until it goes; nothing new can take a hold
        // once the room is dropped from the checks.
        Task {
            _ = await firstValue(of: room.holders.asCurrentValuePublisher()) { $0 == 0 }
            while case let running = room.runningWrites, !running.isEmpty {
                for write in running {
                    await write.value
                }
            }
            room.store.stop()
        }
    }
    
    private func checksChanged() {
        let boards = checks.compactMapValues(\.room)
        for roomID in snapshotCancellables.keys where boards[roomID] == nil {
            snapshotCancellables[roomID] = nil
        }
        for (roomID, room) in boards where snapshotCancellables[roomID] == nil {
            snapshotCancellables[roomID] = room.store.snapshotPublisher
                .dropFirst()
                .sink { [weak self] _ in self?.publishChats() }
        }
        publishChats()
    }
    
    private func publishChats() {
        guard !isApplyingRoomList else { return }
        let boards = (joinedChats ?? []).compactMap { chat in
            checks[chat.id]?.room.map { TabChat(roomID: chat.id, name: chat.name, avatarURL: chat.avatarURL, room: $0, snapshot: $0.store.snapshot) }
        }
        chatsSubject.send(TabChats(boards: boards,
                                   checking: Set(checks.filter {
                                       if case .pending = $0.value {
                                           true
                                       } else {
                                           false
                                       }
                                   }.keys),
                                   failed: Set(checks.filter {
                                       if case .failed = $0.value {
                                           true
                                       } else {
                                           false
                                       }
                                   }.keys),
                                   dms: Set((joinedChats ?? []).filter(\.isDM).map(\.id)),
                                   isRoomListLoaded: joinedChats != nil))
    }
}
