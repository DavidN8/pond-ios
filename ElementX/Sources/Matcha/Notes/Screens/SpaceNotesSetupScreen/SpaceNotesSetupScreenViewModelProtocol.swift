//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine

@MainActor
protocol SpaceNotesSetupScreenViewModelProtocol {
    var actionsPublisher: AnyPublisher<SpaceNotesSetupScreenViewModelAction, Never> { get }
    var context: SpaceNotesSetupScreenViewModelType.Context { get }
}
