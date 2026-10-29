//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import MatchaProtocol
import Observation
import SwiftUI

/// What the chat's screens outside the chip bar show of a thread: thread titles, the thread list and bubble thread summaries.
nonisolated struct MatchaThreadInfo: Sendable, Equatable {
    /// The shared name or the root message text; nil when only the event id is known, drawn as "Untitled thread".
    var name: String?
    /// Someone named the thread: renamed it, or named it when creating it (its hidden first reply marks that).
    var isNamed: Bool
    var isArchived: Bool
    /// Replies the homeserver counts that nobody sees: the hidden first reply of a named thread.
    var hiddenReplies: Int
}

/// A message at the bottom of a chat about a Matcha write, with Undo or Retry.
struct MatchaChatBanner: Identifiable {
    let id = UUID()
    let message: String
    let actionTitle: String
    let action: () -> Void
}

/// The Matcha features of one chat, shared by its room screen and its thread screens while the room flow shows the room. Writes
/// run here, so their banner still shows when the screen that started them is gone (archiving the open thread returns to General).
@Observable final class MatchaChat {
    let store: MatchaRoomStore
    var banner: MatchaChatBanner?
    /// The chat's joined parent spaces, whose notes its menus open; empty until read.
    var parentSpaces: [SpaceServiceRoom] = []
    @ObservationIgnored private var bannerDismissal: Task<Void, Never>?
    private let bannerDuration: Duration
    private let isVoiceOverRunning: () -> Bool
    
    var userID: String {
        store.room.ownUserID
    }
    
    /// - Parameter bannerDuration: as long as Android's `SnackbarDuration.Long`. While VoiceOver runs a banner stays until it is used
    ///   or dismissed, as Android's snackbars with an action do while TalkBack runs.
    init(store: MatchaRoomStore, bannerDuration: Duration = .seconds(10), isVoiceOverRunning: @escaping () -> Bool = { UIAccessibility.isVoiceOverRunning }) {
        self.store = store
        self.bannerDuration = bannerDuration
        self.isVoiceOverRunning = isVoiceOverRunning
    }
    
    /// Creates a named thread; one that could not be set up offers to finish setting it up.
    func createThread(name: String) async -> NamedThreadResult {
        let result = await store.createNamedThread(name: name)
        if case .rootOnly(let threadID) = result {
            showSetupFailed(threadID: threadID, name: name)
        }
        return result
    }
    
    /// Renames a thread for everyone; returns whether it was sent.
    func rename(threadID: String, name: String) async -> Bool {
        guard let content = try? ThreadMetadataProtocol.patchContent(rootID: threadID, name: name) else { return false }
        if case .failure(let error) = await store.send(type: MatchaConfig.eventThreadMetadata, contentJSON: content) {
            MXLog.warning("Could not rename the thread \(threadID): \(error)")
            return false
        }
        return true
    }
    
    /// Archives or restores a thread for everyone. When `announces`, a banner offers to undo it; a failure always offers to retry.
    /// Returns whether it was sent.
    @discardableResult
    func setArchived(threadID: String, archived: Bool, announces: Bool = true) async -> Bool {
        guard let content = try? ThreadMetadataProtocol.patchContent(rootID: threadID, archived: archived) else { return false }
        if case .failure(let error) = await store.send(type: MatchaConfig.eventThreadMetadata, contentJSON: content) {
            MXLog.warning("Could not update the thread \(threadID): \(error)")
            show(UntranslatedL10n.commonMatchaWriteFailed, actionTitle: L10n.actionRetry) { [weak self] in
                Task { await self?.setArchived(threadID: threadID, archived: archived, announces: announces) }
            }
            return false
        }
        if announces {
            let message = archived ? UntranslatedL10n.screenMatchaThreadsArchivedSnackbar : UntranslatedL10n.screenMatchaThreadsUnarchivedSnackbar
            show(message, actionTitle: UntranslatedL10n.actionMatchaUndo) { [weak self] in
                Task { await self?.setArchived(threadID: threadID, archived: !archived, announces: false) }
            }
        }
        return true
    }
    
    func dismissBanner() {
        bannerDismissal?.cancel()
        banner = nil
    }
    
    // MARK: - Private
    
    private func showSetupFailed(threadID: String, name: String) {
        show(UntranslatedL10n.screenMatchaThreadsSetupFailed, actionTitle: L10n.actionRetry) { [weak self] in
            Task { [weak self] in
                guard let self, case .failure = await self.store.retrySetup(threadID: threadID, name: name) else { return }
                self.showSetupFailed(threadID: threadID, name: name)
            }
        }
    }
    
    private func show(_ message: String, actionTitle: String, action: @escaping () -> Void) {
        let banner = MatchaChatBanner(message: message, actionTitle: actionTitle) { [weak self] in
            self?.dismissBanner()
            action()
        }
        self.banner = banner
        // Read out like TalkBack reads Android's snackbar, so a VoiceOver user knows there is something to undo or retry.
        AccessibilityNotification.Announcement(message).post()
        bannerDismissal?.cancel()
        guard !isVoiceOverRunning() else { return }
        bannerDismissal = Task { [weak self, bannerDuration] in
            try? await Task.sleep(for: bannerDuration)
            guard !Task.isCancelled, self?.banner?.id == banner.id else { return }
            self?.banner = nil
        }
    }
}

extension MatchaRoomSnapshot {
    /// The chip bar has something to show: an active thread someone named. A board alone doesn't count, since the top bar opens
    /// it, and a chat without named threads would only get General.
    var hasChatBar: Bool {
        // A thread named when it was created keeps the name as its root message, so its hidden first reply marks it as named.
        threads.contains { !$0.metadata.archived && $0.isNamed }
    }
    
    /// The To do and In progress tasks the board shows `userID`, once loaded; tasks hidden from them don't count.
    func openTaskCount(userID: String) -> Int {
        guard isLoaded, let board else { return 0 }
        return board.cards.count { $0.isShownOnBoard(userID: userID) && !$0.archived && $0.status != .done }
    }
    
    var threadInfos: [String: MatchaThreadInfo] {
        Dictionary(threads.map { thread in
            (thread.id, MatchaThreadInfo(name: thread.shownName,
                                         isNamed: thread.isNamed,
                                         isArchived: thread.metadata.archived,
                                         hiddenReplies: thread.hasHiddenFirstReply ? 1 : 0))
        }) { first, _ in first }
    }
}

extension MatchaThread {
    /// The name to show, or nil when only the event id is known.
    var shownName: String? {
        metadata.nameSource == .eventID ? nil : metadata.name
    }
    
    var isNamed: Bool {
        metadata.nameSource == .explicit || hasHiddenFirstReply
    }
}

extension TimelineViewModel {
    /// Shows the shared names of `store`'s threads in the bubble thread summaries, without their hidden replies.
    func showMatchaThreads(of store: MatchaRoomStore) {
        store.snapshotPublisher
            .map(\.threadInfos)
            .removeDuplicates()
            .sink { [weak self] infos in
                self?.state.matchaThreads = infos
            }
            .store(in: &cancellables)
    }
}
