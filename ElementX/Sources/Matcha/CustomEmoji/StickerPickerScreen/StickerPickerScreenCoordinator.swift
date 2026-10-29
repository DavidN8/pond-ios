//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

struct StickerPickerScreenCoordinatorParameters {
    let roomProxy: JoinedRoomProxyProtocol
    /// The thread the sticker goes to, or nil for the room.
    let threadRootEventID: String?
    let customEmojiPacks: CustomEmojiPacks
    let mediaProvider: MediaProviderProtocol
    let userIndicatorController: UserIndicatorControllerProtocol
}

enum StickerPickerScreenCoordinatorAction {
    case dismiss
}

/// The composer's sticker sheet.
final class StickerPickerScreenCoordinator: CoordinatorProtocol {
    private let viewModel: StickerPickerScreenViewModelProtocol
    
    private var cancellables = Set<AnyCancellable>()
    
    private let actionsSubject: PassthroughSubject<StickerPickerScreenCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<StickerPickerScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(parameters: StickerPickerScreenCoordinatorParameters) {
        viewModel = StickerPickerScreenViewModel(roomProxy: parameters.roomProxy,
                                                 threadRootEventID: parameters.threadRootEventID,
                                                 loadStickerPacks: { [packs = parameters.customEmojiPacks, roomID = parameters.roomProxy.id] in
                                                     await packs.stickerPacks(roomID: roomID)
                                                 },
                                                 mediaProvider: parameters.mediaProvider,
                                                 userIndicatorController: parameters.userIndicatorController)
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
        AnyView(StickerPickerScreen(context: viewModel.context))
    }
    
    /// Shows the sheet above `stack`, in its own navigation stack for its toolbar and search, until it is done; keep the result while
    /// it shows.
    static func present(on stack: NavigationStackCoordinator, parameters: StickerPickerScreenCoordinatorParameters) -> AnyCancellable {
        let coordinator = StickerPickerScreenCoordinator(parameters: parameters)
        let sheetStack = NavigationStackCoordinator()
        sheetStack.setRootCoordinator(coordinator)
        stack.setSheetCoordinator(sheetStack)
        return coordinator.actionsPublisher.sink { [weak stack] _ in
            stack?.setSheetCoordinator(nil)
        }
    }
}
