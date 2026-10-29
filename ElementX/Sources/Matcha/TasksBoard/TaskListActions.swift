//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import MatchaProtocol

/// Moves, archives and restores the tasks of one chat from a list of tasks, for the board and the Tasks tab, as Android's
/// `TaskListActions`: archiving offers Undo and a failed write offers Retry, through `showBanner`. Each write starts through `run`
/// and finishes once the list is gone; only its banner needs the list.
struct TaskListActions {
    let writer: TaskWriter
    /// Starts a write; the Tasks tab holds the write's chat open until it is done.
    var run: @MainActor (@escaping @MainActor () async -> Void) -> Void = { operation in
        Task { await operation() }
    }
    
    let showBanner: @MainActor (_ message: String, _ actionTitle: String, _ action: @escaping () -> Void) -> Void
    
    func move(_ id: String, to status: TaskStatus) {
        run {
            if let error = await writer.move(cardID: id, to: status) {
                showBanner(error.message, L10n.actionRetry) { move(id, to: status) }
            }
        }
    }
    
    /// Archives or restores a task and, for a thread's task, the thread too, with Undo; an Undo says nothing more once done. A task
    /// that already is, say archived elsewhere since its row was drawn, is left alone, as on Android, so no Undo flips it back.
    func setArchived(_ id: String, archived: Bool, announces: Bool = true) {
        run {
            guard let card = writer.store.snapshot.board?.cards.first(where: { $0.id == id }), card.archived != archived else { return }
            if let error = await writer.setArchived(cardID: id, archived: archived) {
                showBanner(error.message, L10n.actionRetry) { setArchived(id, archived: archived, announces: announces) }
            } else if announces {
                showBanner(archived ? UntranslatedL10n.screenMatchaTasksArchivedSnackbar : UntranslatedL10n.screenMatchaTasksUnarchivedSnackbar,
                           UntranslatedL10n.actionMatchaUndo) { setArchived(id, archived: !archived, announces: false) }
            }
        }
    }
}
