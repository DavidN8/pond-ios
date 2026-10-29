//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum SpaceNotesSetupScreenViewModelAction {
    /// Notes are on.
    case done
    case close
}

struct SpaceNotesSetupScreenViewState: BindableState {
    var isWorking = false
    var hasFailed = false
    var bindings = SpaceNotesSetupScreenViewStateBindings()
}

struct SpaceNotesSetupScreenViewStateBindings {
    /// Encryption is off: confirm turning it on, which can't be undone.
    var isConfirmingEncryption = false
}

enum SpaceNotesSetupScreenViewAction {
    case turnOn
    case confirmEncryption
    case close
}
