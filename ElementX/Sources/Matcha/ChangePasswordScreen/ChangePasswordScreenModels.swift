//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum ChangePasswordScreenViewModelAction {
    case passwordChanged
}

struct ChangePasswordScreenViewState: BindableState {
    var bindings = ChangePasswordScreenViewStateBindings()
    
    var canSave: Bool {
        !bindings.oldPassword.isEmpty && !bindings.newPassword.isEmpty && bindings.newPassword == bindings.confirmedPassword
    }
    
    /// Once the confirmation is typed: it differs from the new password.
    var showsMismatch: Bool {
        !bindings.confirmedPassword.isEmpty && bindings.newPassword != bindings.confirmedPassword
    }
}

struct ChangePasswordScreenViewStateBindings {
    var oldPassword = ""
    var newPassword = ""
    var confirmedPassword = ""
    var alertInfo: AlertInfo<ChangePasswordScreenAlert>?
}

enum ChangePasswordScreenAlert {
    case failed
}

enum ChangePasswordScreenViewAction {
    case save
}
