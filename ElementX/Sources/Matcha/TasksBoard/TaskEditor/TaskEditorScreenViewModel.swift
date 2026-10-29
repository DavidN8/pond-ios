//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import MatchaProtocol
import SwiftUI

typealias TaskEditorScreenViewModelType = StateStoreViewModelV2<TaskEditorScreenViewState, TaskEditorScreenViewAction>

/// The task editor, for a new task or an existing one, in one room. Shared by the board, the chip bar and the Tasks tab, which each
/// pass the room's store. A save outlives the editor: it runs in its own task and finishes when the editor is gone.
class TaskEditorScreenViewModel: TaskEditorScreenViewModelType, TaskEditorScreenViewModelProtocol {
    private let store: MatchaRoomStore
    private let writer: TaskWriter
    private let calendar: Calendar
    private let now: () -> Date
    private let announce: (String) -> Void
    /// The card as it was when the editor opened; changes are measured against it. Nil for a new task.
    private let card: ProjectedCard?
    
    /// The board the user saw; a save refused because it changed adopts the new one, so Save again writes there.
    private var boardRootID: String?
    /// Set once a new task's thread exists, so a retry writes the card instead of creating another thread.
    private var createdThreadID: String?
    private var createdThreadName: String?
    /// False while the new thread's root was sent without the reply that makes it a thread; its card waits until it is.
    private var isThreadSetUp = false
    private var exitsToThread = false
    /// The editor asked its host to close it or to show the thread. A save that ends later says nothing more: by then the host may
    /// show another sheet, which a second close would dismiss.
    private var hasLeft = false
    
    private let actionsSubject: PassthroughSubject<TaskEditorScreenViewModelAction, Never> = .init()
    var actionsPublisher: AnyPublisher<TaskEditorScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(store: MatchaRoomStore,
         target: TaskEditorTarget,
         calendar: Calendar = .current,
         now: @escaping () -> Date = { .now },
         announce: @escaping (String) -> Void = { AccessibilityNotification.Announcement($0).post() }) {
        self.store = store
        writer = TaskWriter(store: store)
        self.calendar = calendar
        self.now = now
        self.announce = announce
        let snapshot = store.snapshot
        let card: ProjectedCard? = if case .edit(let taskID) = target {
            snapshot.board?.cards.first { $0.id == taskID }
        } else {
            nil
        }
        self.card = card
        boardRootID = snapshot.board?.rootID
        
        let status = if case .new(let status) = target {
            status
        } else {
            card?.status ?? .todo
        }
        // Without a shared name or a readable root, the name falls back to the thread id: the user is asked for a name instead.
        let initial = TaskEditorFields(title: card.map { $0.title == $0.threadID ? "" : $0.title } ?? "",
                                       description: card?.description ?? "",
                                       status: status,
                                       dueAt: card?.dueAt,
                                       // A new task is only on the boards of the people it involves until it is shared, as on the web.
                                       showToRoom: card?.showToRoom ?? false)
        let isLinked = card == nil || card?.threadID != nil
        super.init(initialViewState: .init(isNew: card == nil,
                                           isLinked: isLinked,
                                           canRename: card?.threadID == nil || snapshot.permissions.canManageThreads,
                                           canShare: !snapshot.isDirect,
                                           titleMaxLength: isLinked ? MatchaConfig.threadNameMaxLength : MatchaConfig.cardTitleMaxLength,
                                           earlierCards: card?.earlierCards.map(\.title) ?? [],
                                           canRemind: card.map { !$0.archived } == true && snapshot.permissions.canSendMessages
                                               && RemindMeScreenViewModel.isOffered(in: store.room),
                                           reminderRequestedAt: card?.reminderRequested.map { DeadlineFormatter.format($0.at, now: now(), calendar: calendar) },
                                           dueAt: initial.dueAt,
                                           isDeadlinePast: initial.dueAt.map { $0 < Self.millis(now()) } ?? false,
                                           initial: initial,
                                           bindings: .init(title: initial.title, description: initial.description, status: initial.status, showToRoom: initial.showToRoom)))
        
        if case .edit = target, card == nil {
            // The task is gone; close once the coordinator listens.
            Task { [weak self] in self?.leave(.close) }
        }
        if let cardID = card?.id {
            // Read live, like Android: Remind me leaves the editor open under its sheet, which records the request on the card.
            store.snapshotPublisher
                .map { [now, calendar] in
                    $0.board?.cards.first { $0.id == cardID }?.reminderRequested.map { DeadlineFormatter.format($0.at, now: now(), calendar: calendar) }
                }
                .removeDuplicates()
                .weakAssign(to: \.state.reminderRequestedAt, on: self)
                .store(in: &cancellables)
        }
    }
    
    // MARK: - Public
    
    override func process(viewAction: TaskEditorScreenViewAction) {
        switch viewAction {
        case .setDeadline(let date):
            setDeadline(date)
        case .addDeadline:
            // Today at 17:00, like the other clients.
            setDeadline(calendar.date(bySettingHour: 17, minute: 0, second: 0, of: now()) ?? now())
        case .clearDeadline:
            state.dueAt = nil
            state.deadlineError = nil
            state.isDeadlinePast = false
        case .save:
            save()
        case .openThread:
            guard let threadID = card?.threadID else { return }
            if state.hasChanges {
                exitsToThread = true
                state.bindings.isDiscardConfirmationPresented = true
            } else {
                leave(.openThread(threadRootEventID: threadID))
            }
        case .remindMe:
            // About the task as edited so far, like Android: its deadline is offered even before it is saved.
            guard state.canRemind, !hasLeft, let card else { return }
            actionsSubject.send(.remindMe(RemindMeTarget(message: state.bindings.title.kotlinTrimmed,
                                                         threadID: card.threadID,
                                                         dueAt: state.dueAt),
                                          cardID: card.id))
        case .cancel:
            if state.hasChanges {
                exitsToThread = false
                state.bindings.isDiscardConfirmationPresented = true
            } else {
                leave(.close)
            }
        case .discard:
            state.bindings.isDiscardConfirmationPresented = false
            if exitsToThread, let threadID = card?.threadID {
                leave(.openThread(threadRootEventID: threadID))
            } else {
                leave(.close)
            }
        }
    }
    
    // MARK: - Private
    
    private func setDeadline(_ date: Date) {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        switch KanbanProtocol.deadline(components, in: calendar.timeZone) {
        case .valid(let epochMillis):
            state.dueAt = epochMillis
            state.deadlineError = nil
            state.isDeadlinePast = epochMillis < Self.millis(now())
        case .skipped:
            state.deadlineError = .skipped
        case .outOfRange:
            state.deadlineError = .outOfRange
        }
        if let warning = state.deadlineWarning {
            announce(warning.message)
        }
    }
    
    private func save() {
        guard !state.isSaving else { return }
        state.showsEmptyTitleError = true
        // A name the user can't change isn't written, so it can't stop the save.
        if let error = state.titleError ?? state.descriptionError {
            announce(error.message)
            return
        }
        state.isSaving = true
        state.saveError = nil
        let fields = state.fields
        Task {
            let error = await write(fields)
            if error == .boardChanged {
                boardRootID = store.snapshot.board?.rootID
            }
            state.isSaving = false
            state.saveError = error
            if let error {
                if !hasLeft {
                    announce(error.message)
                }
            } else {
                leave(.close)
            }
        }
    }
    
    private func leave(_ action: TaskEditorScreenViewModelAction) {
        guard !hasLeft else { return }
        hasLeft = true
        actionsSubject.send(action)
    }
    
    private func write(_ fields: TaskEditorFields) async -> TaskWriteError? {
        guard let boardRootID else { return .failed }
        let title = fields.title.kotlinTrimmed
        guard let card else {
            return await create(fields, title: title, boardRootID: boardRootID)
        }
        // Read-modify-write: only the fields the user changed are written over the newest revision.
        let initial = state.initial
        let canRename = state.canRename
        return await writer.update(boardRootID: boardRootID, cardID: card.id) { current in
            current.with { revision in
                if canRename, title != initial.title {
                    revision.title = title
                }
                if fields.description != initial.description {
                    revision.description = fields.description
                }
                if fields.status != initial.status {
                    revision.status = fields.status
                }
                if fields.dueAt != initial.dueAt {
                    revision.dueAt = fields.dueAt
                }
                if fields.showToRoom != initial.showToRoom {
                    revision.showToRoom = fields.showToRoom
                }
            }
        }
    }
    
    /// Creates the task's named thread, then its card. A retry reuses the thread the first attempt created.
    private func create(_ fields: TaskEditorFields, title: String, boardRootID: String) async -> TaskWriteError? {
        let threadID: String
        if let createdThreadID {
            threadID = createdThreadID
        } else {
            switch await store.createNamedThread(name: title) {
            case .created(let id):
                threadID = id
                isThreadSetUp = true
            case .rootOnly(let id):
                createdThreadID = id
                createdThreadName = title
                return .threadSetupFailed
            case .failed:
                return .failed
            }
            createdThreadID = threadID
            createdThreadName = title
        }
        // A card linked to a root that isn't a thread breaks the board on the web client, so it waits for the thread.
        if !isThreadSetUp {
            guard case .success = await store.retrySetup(threadID: threadID, name: title) else { return .threadSetupFailed }
            // The thread keeps its root's name until renamed: readers don't take a name from the setup reply.
            isThreadSetUp = true
        }
        let card = CardRevision(cardID: KanbanProtocol.threadCardID(threadID),
                                title: title,
                                description: fields.description,
                                status: fields.status,
                                archived: false,
                                threadID: threadID,
                                dueAt: fields.dueAt,
                                reminderRequested: nil,
                                showToRoom: fields.showToRoom)
        // A retry after the name was changed renames the thread the first attempt created.
        return await writer.create(boardRootID: boardRootID, card: card, renameThread: createdThreadName != title)
    }
    
    private static func millis(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }
}
