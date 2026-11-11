//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

struct ChangePasswordScreenCoordinatorParameters {
    let clientProxy: ClientProxyProtocol
    let userIndicatorController: UserIndicatorControllerProtocol
}

enum ChangePasswordScreenCoordinatorAction {
    case passwordChanged
}

final class ChangePasswordScreenCoordinator: CoordinatorProtocol {
    private let viewModel: ChangePasswordScreenViewModelProtocol
    
    private var cancellables = Set<AnyCancellable>()
    
    private let actionsSubject: PassthroughSubject<ChangePasswordScreenCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<ChangePasswordScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(parameters: ChangePasswordScreenCoordinatorParameters) {
        viewModel = ChangePasswordScreenViewModel(clientProxy: parameters.clientProxy,
                                                  userIndicatorController: parameters.userIndicatorController)
    }
    
    func start() {
        viewModel.actionsPublisher.sink { [weak self] action in
            MXLog.info("Coordinator: received view model action: \(action)")
            
            guard let self else { return }
            switch action {
            case .passwordChanged:
                actionsSubject.send(.passwordChanged)
            }
        }
        .store(in: &cancellables)
    }
    
    func toPresentable() -> AnyView {
        AnyView(ChangePasswordScreen(context: viewModel.context))
    }
    
    /// For Settings' Change password row: pushes the screen on `stack`, which goes back once the password changed.
    static func push(on stack: NavigationStackCoordinator, flowParameters: CommonFlowParameters) {
        let coordinator = ChangePasswordScreenCoordinator(parameters: .init(clientProxy: flowParameters.userSession.clientProxy,
                                                                            userIndicatorController: flowParameters.userIndicatorController))
        coordinator.actionsPublisher
            .sink { [weak stack] _ in stack?.pop() }
            .store(in: &coordinator.cancellables)
        stack.push(coordinator)
    }
}
