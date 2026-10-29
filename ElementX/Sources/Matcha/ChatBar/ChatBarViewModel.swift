//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import MatchaProtocol
import SwiftUI

typealias ChatBarViewModelType = StateStoreViewModelV2<ChatBarViewState, ChatBarViewAction>

/// The chip bar under a chat's top bar (General, the active named threads, New thread) and the Matcha actions of the top bar
/// (All threads, the board with its open-task count, New thread in ⋯), for one chat screen. Writes run in the chat's
/// `MatchaChat`, so they finish when the screen is replaced.
class ChatBarViewModel: ChatBarViewModelType {
    static let maxThreadChips = 4
    
    private let chat: MatchaChat
    /// Threads created from this bar, named until the thread list includes them.
    private var createdNames = [String: String]()
    private var snapshot: MatchaRoomSnapshot
    
    private let actionsSubject = PassthroughSubject<ChatBarRoute, Never>()
    var actions: AnyPublisher<ChatBarRoute, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(chat: MatchaChat, selection: ChatBarSelection) {
        self.chat = chat
        snapshot = chat.store.snapshot
        super.init(initialViewState: ChatBarViewState(selection: selection, chat: chat))
        
        update()
        chat.store.snapshotPublisher
            .sink { [weak self] snapshot in
                self?.snapshot = snapshot
                self?.update()
            }
            .store(in: &cancellables)
        chat.store.room.infoPublisher
            .map { MatchaChatSubtitle(isDM: $0.isDM, isTombstoned: $0.successor != nil, joinedMemberCount: $0.joinedMembersCount) }
            .removeDuplicates()
            .weakAssign(to: \.state.subtitle, on: self)
            .store(in: &cancellables)
        // In a DM Remind me waits for the reminder bot, whose membership the room may load after the store's last snapshot.
        chat.store.room.membersPublisher
            .dropFirst()
            .sink { [weak self] _ in self?.updateCanRemind() }
            .store(in: &cancellables)
    }
    
    override func process(viewAction: ChatBarViewAction) {
        switch viewAction {
        case .select(let target):
            guard target != state.selection else { return }
            switch target {
            case .general: actionsSubject.send(.general)
            case .thread(let id): actionsSubject.send(.thread(id: id))
            case .board: actionsSubject.send(.board(threadID: nil))
            }
        case .allThreads:
            actionsSubject.send(.allThreads)
        case .board:
            actionsSubject.send(.board(threadID: nil))
        case .newThread:
            guard state.canCreateThread else { return }
            state.bindings.threadNameSheet = ThreadNameSheet(threadID: nil, name: "")
        case .renameThread(let id):
            guard state.canManageThreads, let thread = state.threads.first(where: { $0.id == id }) else { return }
            state.bindings.threadNameSheet = ThreadNameSheet(threadID: id, name: thread.name ?? "")
        case .updateThreadName(let name):
            guard var sheet = state.bindings.threadNameSheet, !sheet.isSending else { return }
            sheet.name = name
            sheet.error = Self.validate(name, isSubmitting: false)
            state.bindings.threadNameSheet = sheet
        case .submitThreadName:
            submitThreadName()
        case .setArchived(let threadID, let archived):
            guard state.canManageThreads else { return }
            Task { [chat, selection = state.selection, weak self] in
                let isDone = await chat.setArchived(threadID: threadID, archived: archived)
                if isDone, archived, selection == .thread(id: threadID) {
                    self?.actionsSubject.send(.general)
                }
            }
        case .viewTask(let threadID):
            actionsSubject.send(.board(threadID: threadID))
        case .remindMe(let threadID):
            guard state.canRemind else { return }
            actionsSubject.send(.remindMe(threadID: threadID ?? selectedThreadID))
        case .openSpaceNotes(let spaceID):
            actionsSubject.send(.spaceNotes(spaceID: spaceID))
        case .newTask:
            actionsSubject.send(.newTask)
        case .stickers:
            actionsSubject.send(.stickers(threadID: selectedThreadID))
        }
    }
    
    // MARK: - Private
    
    private var selectedThreadID: String? {
        if case .thread(let id) = state.selection {
            id
        } else {
            nil
        }
    }
    
    private func update() {
        let selectedID = selectedThreadID
        state.threads = chips(selectedID: selectedID)
        state.threadName = selectedID.flatMap { id in snapshot.threads.first { $0.id == id }?.shownName ?? createdNames[id] }
        state.canCreateThread = snapshot.permissions.canCreateThreads
        state.canManageThreads = snapshot.permissions.canManageThreads
        updateCanRemind()
        state.warning = snapshot.warning
        state.openTaskCount = snapshot.openTaskCount(userID: chat.userID)
        // The board always draws the bar; elsewhere it waits for the data, and appears only once the chat uses the features.
        state.showsBar = state.selection == .board || snapshot.isLoaded && snapshot.hasChatBar
    }
    
    /// The sheet checks the bot again before it sends.
    private func updateCanRemind() {
        state.canRemind = snapshot.permissions.canSendMessages && RemindMeScreenViewModel.isOffered(in: chat.store.room)
    }
    
    /// Thread chips appear once the metadata has loaded, so names never change under the user's finger.
    private func chips(selectedID: String?) -> [ChatBarThread] {
        guard snapshot.isLoaded else { return [] }
        // The store's order: newest activity first.
        let active = snapshot.threads
            .filter { !$0.metadata.archived }
            .prefix(Self.maxThreadChips)
            .map(ChatBarThread.init)
        guard let selectedID, !active.contains(where: { $0.id == selectedID }) else { return active }
        let selected = snapshot.threads.first { $0.id == selectedID }.map(ChatBarThread.init)
            ?? ChatBarThread(id: selectedID, name: createdNames[selectedID], isArchived: false)
        return active + [selected]
    }
    
    private func submitThreadName() {
        guard var sheet = state.bindings.threadNameSheet, !sheet.isSending else { return }
        let name = sheet.name.kotlinTrimmed
        if let error = Self.validate(sheet.name, isSubmitting: true) {
            sheet.error = error
            state.bindings.threadNameSheet = sheet
            return
        }
        if let threadID = sheet.threadID, name == state.threads.first(where: { $0.id == threadID })?.name {
            state.bindings.threadNameSheet = nil
            return
        }
        sheet.error = nil
        sheet.isSending = true
        state.bindings.threadNameSheet = sheet
        
        // The write finishes without this screen, but only a bar that is still shown reacts to it, as on Android.
        Task { [chat, weak self] in
            if let threadID = sheet.threadID {
                let isRenamed = await chat.rename(threadID: threadID, name: name)
                // A sheet dismissed while sending comes back only to say the rename failed.
                self?.state.bindings.threadNameSheet = isRenamed ? nil : ThreadNameSheet(threadID: threadID, name: sheet.name, error: .renameFailed)
            } else {
                let result = await chat.createThread(name: name)
                guard let self else { return }
                switch result {
                // A thread that could not be set up opens anyway; the chat's banner offers to finish setting it up.
                case .created(let threadID), .rootOnly(let threadID):
                    createdNames[threadID] = name
                    update()
                    state.bindings.threadNameSheet = nil
                    actionsSubject.send(.thread(id: threadID))
                case .failed:
                    state.bindings.threadNameSheet = ThreadNameSheet(threadID: nil, name: sheet.name, error: .createFailed)
                }
            }
        }
    }
    
    /// The protocol decides what a valid name is. An empty name is only an error once the user tries to save; a name that is too
    /// long is flagged while typing.
    private static func validate(_ name: String, isSubmitting: Bool) -> ThreadNameError? {
        guard !ThreadMetadataProtocol.isValidName(name) else { return nil }
        if name.isKotlinBlank {
            return isSubmitting ? .empty : nil
        }
        return .tooLong
    }
}

extension ChatBarViewModel {
    /// A bar showing the given state, for previews; it doesn't follow the room.
    static func mock(selection: ChatBarSelection = .general,
                     showsBar: Bool = true,
                     threads: [ChatBarThread] = [],
                     canCreateThread: Bool = false,
                     canRemind: Bool = false,
                     warning: MatchaWarning? = nil,
                     openTaskCount: Int = 0,
                     threadNameSheet: ThreadNameSheet? = nil) -> ChatBarViewModel {
        let store = MatchaRoomStore(room: JoinedRoomProxyMock(.init()), noBoardAnswers: NoBoardAnswers())
        store.stop()
        let viewModel = ChatBarViewModel(chat: MatchaChat(store: store), selection: selection)
        viewModel.cancellables = []
        viewModel.state.showsBar = showsBar
        viewModel.state.threads = threads
        viewModel.state.canCreateThread = canCreateThread
        viewModel.state.canManageThreads = canCreateThread
        viewModel.state.canRemind = canRemind
        viewModel.state.warning = warning
        viewModel.state.openTaskCount = openTaskCount
        viewModel.state.bindings.threadNameSheet = threadNameSheet
        return viewModel
    }
}

private extension ChatBarThread {
    init(_ thread: MatchaThread) {
        self.init(id: thread.id, name: thread.shownName, isArchived: thread.metadata.archived)
    }
}
