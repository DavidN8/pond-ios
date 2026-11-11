//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct ChangePasswordScreen: View {
    @Bindable var context: ChangePasswordScreenViewModel.Context
    
    var body: some View {
        Form {
            Section {
                ListRow(label: .plain(title: L10n.commonPassword),
                        kind: .secureField(text: $context.oldPassword))
                    .textContentType(.password)
            } header: {
                Text(UntranslatedL10n.screenMatchaChangePasswordCurrent)
                    .compoundListSectionHeader()
            }
            
            Section {
                ListRow(label: .plain(title: UntranslatedL10n.screenMatchaChangePasswordNew),
                        kind: .secureField(text: $context.newPassword))
                    .textContentType(.newPassword)
                ListRow(label: .plain(title: UntranslatedL10n.screenMatchaChangePasswordConfirm),
                        kind: .secureField(text: $context.confirmedPassword))
                    .textContentType(.newPassword)
                    .submitLabel(.done)
                    .onSubmit { context.send(viewAction: .save) }
            } header: {
                Text(UntranslatedL10n.screenMatchaChangePasswordNew)
                    .compoundListSectionHeader()
            } footer: {
                Text(context.viewState.showsMismatch ? UntranslatedL10n.screenMatchaChangePasswordMismatch : UntranslatedL10n.screenMatchaChangePasswordFooter)
                    .compoundListSectionFooter()
            }
        }
        .compoundList()
        .navigationTitle(UntranslatedL10n.screenMatchaChangePasswordTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.actionSave) {
                    context.send(viewAction: .save)
                }
                .disabled(!context.viewState.canSave)
            }
        }
        .alert(item: $context.alertInfo)
    }
}

// MARK: - Previews

struct ChangePasswordScreen_Previews: PreviewProvider, TestablePreview {
    static let viewModel = ChangePasswordScreenViewModel(clientProxy: ClientProxyMock(.init()),
                                                         userIndicatorController: UserIndicatorControllerMock())
    static let mismatchViewModel = {
        let viewModel = ChangePasswordScreenViewModel(clientProxy: ClientProxyMock(.init()),
                                                      userIndicatorController: UserIndicatorControllerMock())
        viewModel.context.oldPassword = "old"
        viewModel.context.newPassword = "new password"
        viewModel.context.confirmedPassword = "new pasword"
        return viewModel
    }()
    
    static var previews: some View {
        ElementNavigationStack {
            ChangePasswordScreen(context: viewModel.context)
        }
        .previewDisplayName("Empty")
        
        ElementNavigationStack {
            ChangePasswordScreen(context: mismatchViewModel.context)
        }
        .previewDisplayName("Mismatch")
    }
}
