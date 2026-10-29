//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import MatchaProtocol
import SwiftUI

typealias TasksBoardScreenViewModelType = StateStoreViewModelV2<TasksBoardScreenViewState, TasksBoardScreenViewAction>

/// A chat's task board and its archived tasks. When opened for a thread (a thread chip's "View task") it asks for the editor of
/// that thread's task once the board shows it. Writes outlive the screen: they run in their own tasks and finish when it is gone.
class TasksBoardScreenViewModel: TasksBoardScreenViewModelType, TasksBoardScreenViewModelProtocol {
    let store: MatchaRoomStore
    private let writer: TaskWriter
    private let formatDeadline: (Int64) -> String
    private let now: () -> Date
    private let bannerDuration: Duration
    private let isVoiceOverRunning: () -> Bool
    private let announce: (String) -> Void
    
    /// The thread whose task to open, until the board has shown whether it has one.
    private var pendingThreadID: String?
    /// False until the coordinator listens, which is after `init`: an action sent before it would be lost.
    private var isListened = false
    private var isCreatingBoard = false
    private var createFailed = false
    /// Reads the history back until the board shows up or the start of the room, while the board isn't proven absent; cancelled
    /// once the board is gone.
    private var historySearch: Task<Void, Never>?
    private var searchFailed = false
    private var bannerAction: (() -> Void)?
    private var bannerTimeout: Task<Void, Never>?
    /// Writes outlive the board; only their banners need it.
    private lazy var listActions = TaskListActions(writer: writer) { [weak self] message, actionTitle, action in
        self?.showBanner(message: message, actionTitle: actionTitle, action: action)
    }
    
    private let actionsSubject: PassthroughSubject<TasksBoardScreenViewModelAction, Never> = .init()
    var actionsPublisher: AnyPublisher<TasksBoardScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(store: MatchaRoomStore,
         initialThreadID: String? = nil,
         formatDeadline: ((Int64) -> String)? = nil,
         now: @escaping () -> Date = { .now },
         bannerDuration: Duration = .seconds(10),
         isVoiceOverRunning: @escaping () -> Bool = { UIAccessibility.isVoiceOverRunning },
         announce: @escaping (String) -> Void = { AccessibilityNotification.Announcement($0).post() }) {
        self.store = store
        writer = TaskWriter(store: store)
        self.formatDeadline = formatDeadline ?? { DeadlineFormatter.format($0, now: now()) }
        self.now = now
        self.bannerDuration = bannerDuration
        self.isVoiceOverRunning = isVoiceOverRunning
        self.announce = announce
        pendingThreadID = initialThreadID
        super.init(initialViewState: .init(roomName: store.room.infoPublisher.value.displayName ?? store.room.id))
        
        store.room.infoPublisher
            .map { $0.displayName ?? store.room.id }
            .removeDuplicates()
            .weakAssign(to: \.state.roomName, on: self)
            .store(in: &cancellables)
        store.snapshotPublisher
            .sink { [weak self] _ in self?.update() }
            .store(in: &cancellables)
        // Today, Tomorrow and Overdue change with the day, the time zone and the clock.
        NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)
            .sink { [weak self] _ in self?.update() }
            .store(in: &cancellables)
        // The store may already know the task; ask for its editor once the coordinator listens.
        Task { [weak self] in
            self?.isListened = true
            self?.openPendingThread()
        }
    }
    
    isolated deinit {
        historySearch?.cancel()
    }
    
    // MARK: - Public
    
    override func process(viewAction: TasksBoardScreenViewAction) {
        guard case .board(let board) = state.content else {
            switch viewAction {
            case .createBoard: createBoard()
            case .retryLoad: retryLoad()
            default: break
            }
            return
        }
        
        switch viewAction {
        case .createBoard, .retryLoad:
            break
        case .openTask(let id):
            guard let task = board.allTasks.first(where: { $0.id == id }) else { return }
            if let threadID = task.threadID {
                actionsSubject.send(.presentThread(threadRootEventID: threadID))
            } else if board.canEdit {
                actionsSubject.send(.presentEditor(.edit(taskID: id)))
            } else {
                state.bindings.actionsTaskID = id
            }
        case .showActions(let id):
            state.bindings.actionsTaskID = id
        case .move(let id, let status):
            state.bindings.actionsTaskID = nil
            if board.canEdit {
                listActions.move(id, to: status)
            }
        case .setArchived(let id, let archived):
            state.bindings.actionsTaskID = nil
            if let task = board.allTasks.first(where: { $0.id == id }), task.isArchived != archived, board.canArchive(task) {
                listActions.setArchived(id, archived: archived)
            }
        case .newTask(let status):
            if board.canAdd {
                actionsSubject.send(.presentEditor(.new(status: status)))
            }
        case .editTask(let id):
            state.bindings.actionsTaskID = nil
            if board.canEdit {
                actionsSubject.send(.presentEditor(.edit(taskID: id)))
            }
        case .remindMe(let id):
            state.bindings.actionsTaskID = nil
            if board.canRemind, let task = board.allTasks.first(where: { $0.id == id }), !task.isArchived {
                actionsSubject.send(.presentRemindMe(RemindMeTarget(message: task.title ?? "", threadID: task.threadID, dueAt: task.dueAt), cardID: task.id))
            }
        case .showArchived:
            actionsSubject.send(.presentArchived)
        case .loadMore:
            Task { _ = await store.loadMore() }
        case .bannerAction:
            let action = bannerAction
            dismissBanner()
            action?()
        case .dismissBanner:
            dismissBanner()
        }
    }
    
    // MARK: - Private
    
    private func update() {
        let snapshot = store.snapshot
        let userID = store.room.ownUserID
        let tasks = snapshot.taskItems(formatDeadline: formatDeadline, now: now()) { _ in true }
        // A task that isn't shared with the chat is only shown to the people it involves, and left out of every count.
        let shownIDs = Set(snapshot.board?.cards.filter { $0.isShownOnBoard(userID: userID) }.map(\.id) ?? [])
        state.content = content(snapshot, shown: tasks.filter { shownIDs.contains($0.id) }, hidden: tasks.filter { !shownIDs.contains($0.id) })
        
        // A board made elsewhere may lie further back than the history read so far: offering to create one could orphan its cards.
        if state.content == .lookingForBoard, snapshot.isLoaded, historySearch == nil {
            historySearch = Task { [weak self, store] in
                let result = await store.loadHistoryUntil { $0.board != nil }
                guard let self else { return }
                searchFailed = result.isFailure
                historySearch = nil
                update()
            }
        }
        openPendingThread()
    }
    
    private func content(_ snapshot: MatchaRoomSnapshot, shown: [TaskItem], hidden: [TaskItem]) -> TasksBoardContent {
        let permissions = snapshot.permissions
        if snapshot.board != nil {
            let active = shown.filter { !$0.isArchived }
            return .board(TasksBoard(todo: active.filter { $0.status == .todo },
                                     doing: active.filter { $0.status == .doing },
                                     done: active.filter { $0.status == .done },
                                     archived: shown.filter(\.isArchived),
                                     hidden: hidden,
                                     isLoading: !snapshot.isLoaded && shown.isEmpty,
                                     canEdit: permissions.canWriteCards,
                                     canManageThreads: permissions.canManageThreads,
                                     canAdd: permissions.canAddTasks,
                                     canRemind: permissions.canSendMessages && RemindMeScreenViewModel.isOffered(in: store.room),
                                     isUnreadable: snapshot.unreadable,
                                     hasMore: snapshot.hasMoreHistory,
                                     isLoadingMore: snapshot.isLoadingMore))
        } else if snapshot.loadFailed || searchFailed {
            return .loadFailed
        } else if !snapshot.isLoaded || !snapshot.isBoardResolved {
            // Until the board is proven absent, a board made elsewhere may exist: offering to create one could orphan its cards.
            return .lookingForBoard
        } else {
            return .setup(canCreate: permissions.canCreateBoard, isCreating: isCreatingBoard, createFailed: createFailed)
        }
    }
    
    private func openPendingThread() {
        guard isListened, let threadID = pendingThreadID, case .board(let board) = state.content else { return }
        // Asked for from its thread, which everyone in the chat can read, a task the board leaves out still opens.
        if let task = board.allTasks.first(where: { $0.threadID == threadID }) {
            pendingThreadID = nil
            if board.canEdit {
                actionsSubject.send(.presentEditor(.edit(taskID: task.id)))
            } else {
                state.bindings.actionsTaskID = task.id
            }
        } else if store.snapshot.isLoaded {
            // The thread has no task on a loaded board.
            pendingThreadID = nil
        }
    }
    
    private func createBoard() {
        guard !isCreatingBoard, store.snapshot.board == nil, store.snapshot.permissions.canCreateBoard else { return }
        isCreatingBoard = true
        createFailed = false
        update()
        Task {
            switch await writer.createBoard() {
            case .created:
                break
            case .alreadyExists:
                showBanner(message: UntranslatedL10n.screenMatchaTasksAlreadyHasBoard)
            case .failed:
                createFailed = true
                announce(UntranslatedL10n.screenMatchaTasksSetupFailed)
            }
            isCreatingBoard = false
            update()
        }
    }
    
    private func retryLoad() {
        searchFailed = false
        store.retryLoad()
        update()
    }
    
    private func showBanner(message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        let banner = TaskBanner(message: message, actionTitle: actionTitle)
        state.banner = banner
        bannerAction = action
        announce(message)
        bannerTimeout?.cancel()
        // Reaching Undo takes a VoiceOver user longer: the banner stays until it is used, dismissed or replaced.
        guard !isVoiceOverRunning() else { return }
        bannerTimeout = Task { [weak self, bannerDuration] in
            try? await Task.sleep(for: bannerDuration)
            guard !Task.isCancelled, let self, state.banner?.id == banner.id else { return }
            dismissBanner()
        }
    }
    
    private func dismissBanner() {
        state.banner = nil
        bannerAction = nil
        bannerTimeout?.cancel()
    }
}

extension TaskWriteError {
    var message: String {
        switch self {
        case .boardChanged: UntranslatedL10n.screenMatchaTasksBoardChanged
        case .threadHasTask: UntranslatedL10n.screenMatchaTasksThreadHasTask
        case .historyIncomplete: UntranslatedL10n.screenMatchaTasksHistoryIncomplete
        case .threadSetupFailed: UntranslatedL10n.screenMatchaThreadsSetupFailed
        case .failed: UntranslatedL10n.commonMatchaWriteFailed
        }
    }
}
