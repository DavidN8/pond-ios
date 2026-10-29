//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

struct ChannelsScreenCoordinatorParameters {
    let userSession: UserSessionProtocol
    let selectedIDPublisher: CurrentValuePublisher<String?, Never>
    let userIndicatorController: UserIndicatorControllerProtocol
}

final class ChannelsScreenCoordinator: CoordinatorProtocol {
    private let viewModel: ChannelsScreenViewModelProtocol
    
    /// The view model's own actions: the screen adds nothing to them.
    var actionsPublisher: AnyPublisher<ChannelsScreenViewModelAction, Never> {
        viewModel.actionsPublisher
    }
    
    init(parameters: ChannelsScreenCoordinatorParameters) {
        viewModel = ChannelsScreenViewModel(userSession: parameters.userSession,
                                            selectedIDPublisher: parameters.selectedIDPublisher,
                                            userIndicatorController: parameters.userIndicatorController)
    }
    
    func toPresentable() -> AnyView {
        AnyView(ChannelsScreen(context: viewModel.context))
    }
}
