//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

typealias ChangePasswordScreenViewModelType = StateStoreViewModelV2<ChangePasswordScreenViewState, ChangePasswordScreenViewAction>

class ChangePasswordScreenViewModel: ChangePasswordScreenViewModelType, ChangePasswordScreenViewModelProtocol {
    private let clientProxy: ClientProxyProtocol
    private let userIndicatorController: UserIndicatorControllerProtocol
    private let savingIndicatorID = "\(ChangePasswordScreenViewModel.self)-Saving"
    
    private let actionsSubject: PassthroughSubject<ChangePasswordScreenViewModelAction, Never> = .init()
    var actionsPublisher: AnyPublisher<ChangePasswordScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(clientProxy: ClientProxyProtocol, userIndicatorController: UserIndicatorControllerProtocol) {
        self.clientProxy = clientProxy
        self.userIndicatorController = userIndicatorController
        
        super.init(initialViewState: ChangePasswordScreenViewState())
    }
    
    override func process(viewAction: ChangePasswordScreenViewAction) {
        MXLog.info("View model: received view action: \(viewAction)")
        
        switch viewAction {
        case .save:
            Task { await changePassword() }
        }
    }
    
    // MARK: - Private
    
    private func changePassword() async {
        guard state.canSave else { return }
        
        userIndicatorController.submitIndicator(UserIndicator(id: savingIndicatorID,
                                                              type: .modal(progress: .indeterminate, interactiveDismissDisabled: true, allowsInteraction: false),
                                                              title: L10n.commonPleaseWait,
                                                              persistent: true))
        let result = await clientProxy.changePassword(oldPassword: state.bindings.oldPassword, newPassword: state.bindings.newPassword)
        userIndicatorController.retractIndicatorWithId(savingIndicatorID)
        
        switch result {
        case .success:
            MXLog.info("Password changed.")
            userIndicatorController.submitIndicator(UserIndicator(title: UntranslatedL10n.screenMatchaChangePasswordSuccess, icon: \.check))
            actionsSubject.send(.passwordChanged)
        case .failure(let failure):
            MXLog.info("Changing the password failed: \(failure)")
            state.bindings.alertInfo = .init(id: .failed,
                                             title: UntranslatedL10n.screenMatchaChangePasswordErrorTitle,
                                             message: message(for: failure))
        }
    }
    
    private func message(for failure: PasswordChangeFailure) -> String {
        switch failure {
        case .wrongPassword: UntranslatedL10n.screenMatchaChangePasswordErrorWrongPassword
        case .rejected(let reason): reason
        case .failed: L10n.errorNetworkOrServerIssue
        }
    }
}
