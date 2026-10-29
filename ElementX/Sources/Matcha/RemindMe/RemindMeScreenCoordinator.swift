//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import MatchaProtocol
import SwiftUI

struct RemindMeScreenCoordinatorParameters {
    let target: RemindMeTarget
    let roomProxy: JoinedRoomProxyProtocol
    let userIndicatorController: UserIndicatorControllerProtocol
    /// Called once the command is sent, before the sheet closes; a task records the request on its card here.
    var onRequested: ((ReminderRequestRef) async -> Void)?
}

enum RemindMeScreenCoordinatorAction {
    case dismiss
}

/// The "Remind me" sheet for flows: set it as the root of a `NavigationStackCoordinator` presented as a sheet, and dismiss the
/// sheet on `.dismiss`.
final class RemindMeScreenCoordinator: CoordinatorProtocol {
    private let viewModel: RemindMeScreenViewModelProtocol
    
    private var cancellables = Set<AnyCancellable>()
    
    private let actionsSubject: PassthroughSubject<RemindMeScreenCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<RemindMeScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(parameters: RemindMeScreenCoordinatorParameters) {
        viewModel = RemindMeScreenViewModel(target: parameters.target,
                                            roomProxy: parameters.roomProxy,
                                            userIndicatorController: parameters.userIndicatorController,
                                            onRequested: parameters.onRequested)
    }
    
    func start() {
        viewModel.actionsPublisher.sink { [weak self] action in
            switch action {
            case .dismiss:
                self?.actionsSubject.send(.dismiss)
            }
        }
        .store(in: &cancellables)
    }
    
    func toPresentable() -> AnyView {
        AnyView(RemindMeScreen(context: viewModel.context))
    }
    
    /// Shows the sheet above `stack`, in its own navigation stack for its toolbar, until it is done; keep the result while it shows.
    static func present(on stack: NavigationStackCoordinator, parameters: RemindMeScreenCoordinatorParameters) -> AnyCancellable {
        let coordinator = RemindMeScreenCoordinator(parameters: parameters)
        let sheetStack = NavigationStackCoordinator()
        sheetStack.setRootCoordinator(coordinator)
        stack.setSheetCoordinator(sheetStack)
        return coordinator.actionsPublisher.sink { [weak stack] _ in
            stack?.setSheetCoordinator(nil)
        }
    }
}

extension RemindMeScreenCoordinatorParameters {
    /// A reminder about a task, recorded on its card once requested.
    static func task(_ target: RemindMeTarget,
                     cardID: String,
                     store: MatchaRoomStore,
                     userIndicatorController: UserIndicatorControllerProtocol) -> Self {
        .init(target: target, roomProxy: store.room, userIndicatorController: userIndicatorController) { request in
            if let error = await TaskWriter(store: store).recordReminder(cardID: cardID, request: request) {
                MXLog.warning("Reminder requested, but card \(cardID) could not be updated: \(error)")
            }
        }
    }
}
