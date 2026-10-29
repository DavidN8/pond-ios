//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Testing

@MainActor
struct SpaceScreenNotesTests {
    @Test
    func theSpaceScreenOpensItsNotesWhileTheWorkspacesAreOn() async throws {
        let userSession = UserSessionMock(.init(clientProxy: ClientProxyMock(.init())))
        let viewModel = SpaceScreenViewModel(spaceRoomListProxy: SpaceRoomListProxyMock(.init(spaceServiceRoom: SpaceServiceRoom.mock(isSpace: true))),
                                             spaceServiceProxy: SpaceServiceProxyMock(.init()),
                                             selectedSpaceRoomPublisher: .init(nil),
                                             userSession: userSession,
                                             userIndicatorController: UserIndicatorControllerMock())
        #expect(viewModel.context.viewState.showsMatchaNotes)
        
        let deferred = deferFulfillment(viewModel.actionsPublisher) { _ in true }
        viewModel.context.send(viewAction: .matchaNotes)
        let action = try await deferred.fulfill()
        guard case .displayMatchaNotes = action else {
            Issue.record("The notes row should open the space's notes, not \(action)")
            return
        }
    }
}
