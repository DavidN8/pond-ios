//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine

@MainActor
protocol NoteEditorScreenViewModelProtocol {
    var actionsPublisher: AnyPublisher<NoteEditorScreenViewModelAction, Never> { get }
    var context: NoteEditorScreenViewModelType.Context { get }
    /// Closes the note's document session, once its screen has gone.
    func stop()
}
