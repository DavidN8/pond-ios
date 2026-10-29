//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import MatchaProtocol

/// Why a card write did not happen.
enum TaskWriteError: Error, Equatable {
    /// The room now points at another board than the one the user saw.
    case boardChanged
    /// Another card already belongs to the thread.
    case threadHasTask
    /// The history that may hold the card's newest revision could not be read, so writing could erase it.
    case historyIncomplete
    /// A new task's thread was started but could not be set up; saving again finishes it.
    case threadSetupFailed
    /// The send failed or was not allowed.
    case failed
}

enum CreateBoardResult: Equatable {
    case created
    /// Someone else created the board meanwhile; it is shown instead.
    case alreadyExists
    case failed
}

/// Writes a chat's task board the way the web client does: card content only travels in timeline events, every write is a complete
/// revision, and a linked card's thread is renamed or archived before the revision that reflects it.
struct TaskWriter {
    let store: MatchaRoomStore
    
    /// Creates the board: sends the root, then the state pointing at it. A board made elsewhere, whose cards may not be loaded, is
    /// never replaced: the homeserver is asked for the pointer first; when it can't answer, the history is read back to the start of
    /// the room instead. A root whose pointer failed is pointed at again rather than sent twice.
    func createBoard() async -> CreateBoardResult {
        guard case .success(let existing) = await store.readBoardPointer() else { return .failed }
        guard existing == nil else { return .alreadyExists }
        if !store.isServerPointerRead, case .failure(let error) = await store.loadHistoryUntil({ $0.board != nil }) {
            MXLog.warning("Could not make sure the room has no board: \(error)")
            return .failed
        }
        guard store.snapshot.board == nil else { return .alreadyExists }
        
        let root: String
        if let unpointed = store.unpointedBoardRoot {
            root = unpointed
        } else {
            switch await store.send(type: MatchaConfig.eventKanbanBoard, contentJSON: KanbanProtocol.boardRootContent()) {
            case .success(let eventID):
                root = eventID
            case .failure(let error):
                MXLog.warning("Could not send the board root: \(error)")
                return .failed
            }
        }
        store.unpointedBoardRoot = root
        if case .failure(let error) = await store.sendState(type: MatchaConfig.stateKanban, stateKey: "", contentJSON: KanbanProtocol.boardPointerContent(rootID: root)) {
            MXLog.warning("Could not point the room at its board: \(error)")
            return .failed
        }
        store.unpointedBoardRoot = nil
        store.rememberCreatedBoard(rootID: root)
        return .created
    }
    
    /// Sends the first revision of a new thread's card. Returns nil once sent.
    ///
    /// - Parameters:
    ///   - boardRootID: the board the user was looking at; the write is refused when the room now points elsewhere.
    ///   - renameThread: rename the thread to the card title first.
    func create(boardRootID: String, card: CardRevision, renameThread: Bool) async -> TaskWriteError? {
        await send(boardRootID: boardRootID, card: card, renameThread: renameThread, archiveThread: false)
    }
    
    /// Changes a card on the board: `change` gets the card's newest revision and returns it changed, and the result is sent as a
    /// complete revision. A linked card is renamed with its thread. Returns nil once sent.
    ///
    /// A thread's card that no revision read so far describes shows the defaults, while its revision may lie further back: the
    /// history is read until it is found, so fields the user didn't change are never reset for everyone.
    ///
    /// - Parameters:
    ///   - boardRootID: the board the user was looking at; the write is refused when the room now points elsewhere.
    ///   - archiveThread: archive or restore the card's thread like the card first.
    func update(boardRootID: String, cardID: String, archiveThread: Bool = false, change: (CardRevision) -> CardRevision) async -> TaskWriteError? {
        guard var current = store.snapshot.board?.cards.first(where: { $0.id == cardID }) else { return refuse(.failed) }
        if let threadID = current.threadID, !current.hasRevision, store.snapshot.hasMoreHistory {
            // A card can only be linked to the thread once the thread exists, so the history before its root holds no revision.
            let rootTimestamp = store.snapshot.threads.first { $0.id == threadID }?.rootTimestamp ?? 0
            let result = await store.loadHistoryUntil { snapshot in
                snapshot.board?.cards.contains { $0.threadID == threadID && $0.hasRevision } == true
                    || rootTimestamp > 0 && snapshot.events.last?.timestamp.map { (1...rootTimestamp).contains($0) } == true
            }
            if case .failure(let error) = result {
                MXLog.warning("Could not read the history of card \(cardID): \(error)")
                return refuse(.historyIncomplete)
            }
            guard let found = store.snapshot.board?.cards.first(where: { $0.threadID == threadID }) else { return refuse(.failed) }
            current = found
        }
        let card = change(current.revision)
        return await send(boardRootID: boardRootID,
                          card: card,
                          renameThread: current.threadID != nil && card.title != current.title,
                          archiveThread: archiveThread)
    }
    
    /// Moves a task to `status`; nothing is sent when it is already there.
    func move(cardID: String, to status: TaskStatus) async -> TaskWriteError? {
        guard let board = store.snapshot.board, let card = board.cards.first(where: { $0.id == cardID }) else { return refuse(.failed) }
        guard card.status != status else { return nil }
        return await update(boardRootID: board.rootID, cardID: cardID) { $0.with { $0.status = status } }
    }
    
    /// Archives or restores a task and, for a thread's task, the thread too; nothing is sent when it already is.
    func setArchived(cardID: String, archived: Bool) async -> TaskWriteError? {
        guard let board = store.snapshot.board, let card = board.cards.first(where: { $0.id == cardID }) else { return refuse(.failed) }
        guard card.archived != archived else { return nil }
        return await update(boardRootID: board.rootID, cardID: cardID, archiveThread: card.threadID != nil) { $0.with { $0.archived = archived } }
    }
    
    /// Records on a task's card that a reminder was asked for, as Android's `recordRequest`; only the bot's reply confirms it.
    func recordReminder(cardID: String, request: ReminderRequestRef) async -> TaskWriteError? {
        guard let board = store.snapshot.board else { return refuse(.failed) }
        return await update(boardRootID: board.rootID, cardID: cardID) { $0.with { $0.reminderRequested = request } }
    }
    
    // MARK: - Private
    
    private func send(boardRootID: String, card: CardRevision, renameThread: Bool, archiveThread: Bool) async -> TaskWriteError? {
        let snapshot = store.snapshot
        // ponytail: checks the pointer the store last read, where the web client re-reads room state; the SDK only caches it anyway.
        guard let board = snapshot.board, board.rootID == boardRootID else { return refuse(.boardChanged) }
        guard snapshot.permissions.canWriteCards, let content = try? KanbanProtocol.cardContent(card, rootID: boardRootID) else { return refuse(.failed) }
        if let threadID = card.threadID {
            if board.cards.contains(where: { $0.threadID == threadID && $0.id != card.cardID }) {
                return refuse(.threadHasTask)
            }
            if renameThread || archiveThread {
                guard let patch = try? ThreadMetadataProtocol.patchContent(rootID: threadID,
                                                                           name: renameThread ? card.title : nil,
                                                                           archived: archiveThread ? card.archived : nil) else { return refuse(.failed) }
                if case .failure(let error) = await store.send(type: MatchaConfig.eventThreadMetadata, contentJSON: patch) {
                    MXLog.warning("Could not update thread \(threadID) of card \(card.cardID): \(error)")
                    return .failed
                }
            }
        }
        if case .failure(let error) = await store.send(type: MatchaConfig.eventKanbanCard, contentJSON: content) {
            MXLog.warning("Could not save card \(card.cardID): \(error)")
            return .failed
        }
        return nil
    }
    
    private func refuse(_ error: TaskWriteError) -> TaskWriteError {
        MXLog.warning("Card write refused: \(error)")
        return error
    }
}

extension ProjectedCard {
    /// The complete revision that reproduces this card as shown, to be changed and written back.
    var revision: CardRevision {
        CardRevision(cardID: id,
                     title: title,
                     description: description,
                     status: status,
                     archived: archived,
                     threadID: threadID,
                     dueAt: dueAt,
                     reminderRequested: reminderRequested,
                     showToRoom: showToRoom)
    }
}

extension CardRevision {
    /// A copy changed by `update`.
    func with(_ update: (inout CardRevision) -> Void) -> CardRevision {
        var copy = self
        update(&copy)
        return copy
    }
}
