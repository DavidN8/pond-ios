//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine

@MainActor
protocol NotesTabScreenViewModelProtocol {
    var actionsPublisher: AnyPublisher<NotesTabScreenViewModelAction, Never> { get }
    var context: NotesTabScreenViewModelType.Context { get }
    /// Closes every catalog the tab opened, once the tab has gone.
    func stop()
}
