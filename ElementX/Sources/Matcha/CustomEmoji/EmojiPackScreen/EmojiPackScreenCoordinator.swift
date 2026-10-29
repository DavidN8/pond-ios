//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import MatchaProtocol
import SwiftUI

struct EmojiPackScreenCoordinatorParameters {
    let target: EmojiPackTarget
    let userSession: UserSessionProtocol
    /// The stack the screen is pushed on, which presents the photo picker.
    weak var navigationStackCoordinator: NavigationStackCoordinator?
    let userIndicatorController: UserIndicatorControllerProtocol
    let orientationManager: OrientationManagerProtocol
}

/// The Emoji screen of the user settings, room details and space settings: a custom emoji pack's emoji and stickers, uploads, renames
/// and removals.
final class EmojiPackScreenCoordinator: CoordinatorProtocol {
    private let parameters: EmojiPackScreenCoordinatorParameters
    private let viewModel: EmojiPackScreenViewModelProtocol
    private var cancellables = Set<AnyCancellable>()
    
    init(parameters: EmojiPackScreenCoordinatorParameters) {
        self.parameters = parameters
        viewModel = EmojiPackScreenViewModel(target: parameters.target,
                                             clientProxy: parameters.userSession.clientProxy,
                                             customEmojiPacks: parameters.userSession.matchaService.customEmojiPacks,
                                             mediaProvider: parameters.userSession.mediaProvider)
    }
    
    func start() {
        viewModel.actionsPublisher
            .sink { [weak self] action in
                switch action {
                case .pickImages(let usage):
                    self?.presentPhotoLibrary(usage: usage)
                }
            }
            .store(in: &cancellables)
    }
    
    func toPresentable() -> AnyView {
        AnyView(EmojiPackScreen(context: viewModel.context))
    }
    
    /// For the flows' Emoji rows: pushes the pack's screen on `stack`, which then presents the photo picker.
    static func push(_ target: EmojiPackTarget, on stack: NavigationStackCoordinator, flowParameters: CommonFlowParameters) {
        stack.push(EmojiPackScreenCoordinator(parameters: .init(target: target,
                                                                userSession: flowParameters.userSession,
                                                                navigationStackCoordinator: stack,
                                                                userIndicatorController: flowParameters.userIndicatorController,
                                                                orientationManager: flowParameters.windowManager)))
    }
    
    // MARK: - Private
    
    private func presentPhotoLibrary(usage: ImageUsage) {
        let stackCoordinator = NavigationStackCoordinator()
        let picker = MediaPickerScreenCoordinator(mode: .init(source: .photoLibrary, selectionType: .multiple(limit: MediaPickerScreenSelectionType.individualUploadLimit)),
                                                  userIndicatorController: parameters.userIndicatorController,
                                                  orientationManager: parameters.orientationManager) { [weak self] action in
            guard let self else { return }
            parameters.navigationStackCoordinator?.setSheetCoordinator(nil)
            if case .selectedMediaAtURLs(let urls) = action {
                viewModel.upload(urls: urls, usage: usage)
            }
        }
        stackCoordinator.setRootCoordinator(picker)
        parameters.navigationStackCoordinator?.setSheetCoordinator(stackCoordinator)
    }
}
