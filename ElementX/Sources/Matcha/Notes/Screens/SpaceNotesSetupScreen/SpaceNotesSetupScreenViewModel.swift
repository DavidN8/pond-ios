//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

typealias SpaceNotesSetupScreenViewModelType = StateStoreViewModelV2<SpaceNotesSetupScreenViewState, SpaceNotesSetupScreenViewAction>

/// The one-time Turn on notes screen: confirms encryption when it is off, then turns notes on for the space.
class SpaceNotesSetupScreenViewModel: SpaceNotesSetupScreenViewModelType, SpaceNotesSetupScreenViewModelProtocol {
    private let setup: SpaceNotesSetup
    
    private let actionsSubject: PassthroughSubject<SpaceNotesSetupScreenViewModelAction, Never> = .init()
    var actionsPublisher: AnyPublisher<SpaceNotesSetupScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(room: JoinedRoomProxyProtocol) {
        setup = SpaceNotesSetup(room: room)
        super.init(initialViewState: SpaceNotesSetupScreenViewState())
    }
    
    // MARK: - Public
    
    override func process(viewAction: SpaceNotesSetupScreenViewAction) {
        switch viewAction {
        case .turnOn:
            guard !state.isWorking else { return }
            state.isWorking = true
            Task {
                if await setup.status().isEncrypted {
                    await turnOn()
                } else {
                    state.isWorking = false
                    state.bindings.isConfirmingEncryption = true
                }
            }
        case .confirmEncryption:
            state.bindings.isConfirmingEncryption = false
            Task { await turnOn() }
        case .close:
            actionsSubject.send(.close)
        }
    }
    
    // MARK: - Private
    
    private func turnOn() async {
        state.isWorking = true
        state.hasFailed = false
        switch await setup.turnOn() {
        case .success:
            actionsSubject.send(.done)
        case .failure:
            state.hasFailed = true
        }
        state.isWorking = false
    }
}
