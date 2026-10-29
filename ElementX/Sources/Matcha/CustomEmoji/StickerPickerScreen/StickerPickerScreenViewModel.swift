//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import MatchaProtocol
import SwiftUI

typealias StickerPickerScreenViewModelType = StateStoreViewModelV2<StickerPickerScreenViewState, StickerPickerScreenViewAction>

/// The room's sticker packs, one tab each, and a search of every pack; a tapped sticker is sent as an `m.sticker` event, in the
/// thread when there is one. The timeline API can't send stickers, so it goes through `sendRawEvent`, which encrypts in encrypted
/// rooms but has no local echo: the sticker shows once the server has it.
class StickerPickerScreenViewModel: StickerPickerScreenViewModelType, StickerPickerScreenViewModelProtocol {
    private let roomProxy: JoinedRoomProxyProtocol
    private let threadRootEventID: String?
    private let userIndicatorController: UserIndicatorControllerProtocol
    private var loadTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    
    private let actionsSubject = PassthroughSubject<StickerPickerScreenViewModelAction, Never>()
    var actionsPublisher: AnyPublisher<StickerPickerScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(roomProxy: JoinedRoomProxyProtocol,
         threadRootEventID: String?,
         loadStickerPacks: @escaping () async -> [EmojiPack],
         mediaProvider: MediaProviderProtocol?,
         userIndicatorController: UserIndicatorControllerProtocol) {
        self.roomProxy = roomProxy
        self.threadRootEventID = threadRootEventID
        self.userIndicatorController = userIndicatorController
        super.init(initialViewState: .init(), mediaProvider: mediaProvider)
        
        loadTask = Task { [weak self] in
            let packs = await loadStickerPacks()
            self?.state.packs = packs
            self?.state.selectedPackID = packs.first?.id
        }
    }
    
    override func process(viewAction: StickerPickerScreenViewAction) {
        switch viewAction {
        case .selectPack(let id):
            state.selectedPackID = id
        case .send(let sticker):
            send(sticker)
        case .dismiss:
            actionsSubject.send(.dismiss)
        }
    }
    
    /// Waits for the packs and the last send, for tests.
    func settle() async {
        await loadTask?.value
        await sendTask?.value
    }
    
    // MARK: - Private
    
    /// The sheet closes at once and the send finishes without it.
    private func send(_ sticker: CustomEmoji) {
        actionsSubject.send(.dismiss)
        let content = ImagePacks.stickerContent(sticker, threadRootID: threadRootEventID).jsonString
        sendTask = Task { [roomProxy, userIndicatorController] in
            if case .failure = await roomProxy.sendRawEvent(type: ImagePacks.stickerEventType, contentJSON: content) {
                userIndicatorController.submitIndicator(.init(title: UntranslatedL10n.screenMatchaStickersErrorSend))
            }
        }
    }
}
