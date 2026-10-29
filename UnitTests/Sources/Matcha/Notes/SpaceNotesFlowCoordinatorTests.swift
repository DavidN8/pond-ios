//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import SwiftUI
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SpaceNotesFlowCoordinatorTests {
    @Test
    func aSkeletonShowsAtOnceAndTheListTakesItsPlaceOnceTheSpaceIsOpen() async {
        let flow = Flow()
        flow.coordinator.start(animated: false)
        #expect(flow.stack.stackCoordinators.map { $0 is SpaceNotesLoadingScreenCoordinator } == [true])
        
        flow.gate.open()
        await eventually { flow.stack.stackCoordinators.first is SpaceNotesListScreenCoordinator }
        #expect(flow.stack.stackCoordinators.count == 1)
        #expect(flow.finishedCount == 0)
        await eventually { flow.space.engine.documents.count == 1 }
        
        // Back from the list closes the space.
        flow.stack.pop(animated: false)
        #expect(flow.finishedCount == 1)
        await eventually { flow.space.engine.documents.allSatisfy(\.isClosed) }
    }
    
    @Test
    func aNoteAskedForTakesTheSkeletonsPlace() async {
        let flow = Flow(documentID: "11111111-1111-4111-8111-111111111111")
        flow.coordinator.start(animated: false)
        flow.gate.open()
        await eventually { flow.stack.stackCoordinators.first is NoteEditorScreenCoordinator }
        #expect(flow.stack.stackCoordinators.count == 1)
    }
    
    @Test
    func leavingTheSkeletonEndsTheFlowAndTheSpaceIsClosedOnceOpen() async throws {
        let flow = Flow()
        flow.coordinator.start(animated: false)
        // Back, or the Channels tab showing another space's notes, which replaces the whole stack.
        flow.stack.pop(animated: false)
        #expect(flow.finishedCount == 1)
        
        flow.gate.open()
        await eventually { flow.contextsMade == 1 }
        // Long enough for the catalog to open its document, as the first test shows it does.
        try await Task.sleep(for: .milliseconds(500))
        #expect(flow.stack.stackCoordinators.isEmpty)
        let isClosed = flow.space.engine.documents.allSatisfy(\.isClosed)
        #expect(isClosed)
        #expect(flow.finishedCount == 1)
    }
    
    @Test
    func theNotesTabsBarHidesOnAPhoneWhileItsNotesAreShown() {
        let flow = Flow()
        let details = NavigationTabCoordinator<UserSessionFlowCoordinator.HomeTab>.TabDetails(tag: .notes, title: "Notes", icon: \.document, selectedIcon: \.document)
        details.navigationStackCoordinator = flow.stack
        #expect(details.barVisibility(in: .compact) == .automatic)
        
        flow.coordinator.start(animated: false)
        #expect(details.barVisibility(in: .compact) == .hidden)
        #expect(details.barVisibility(in: .regular) == .automatic)
        
        flow.stack.pop(animated: false)
        #expect(details.barVisibility(in: .compact) == .automatic)
    }
    
    @Test
    func aRoomThatIsNotJoinedTakesTheSkeletonAwayAndEndsTheFlow() async {
        let flow = Flow(isJoined: false)
        flow.coordinator.start(animated: false)
        flow.gate.open()
        await eventually { flow.finishedCount == 1 }
        #expect(flow.stack.stackCoordinators.isEmpty)
    }
}

/// A space's notes flow on its own stack, whose space opens when `gate` opens.
@MainActor
private final class Flow {
    let space = NotesRoomFixture()
    let gate = Gate()
    let stack = NavigationStackCoordinator()
    let coordinator: SpaceNotesFlowCoordinator
    private(set) var finishedCount = 0
    private(set) var contextsMade = 0
    private var cancellables = Set<AnyCancellable>()
    
    init(documentID: String? = nil, isJoined: Bool = true) {
        space.turnNotesOn()
        let client = ClientProxyMock(.init())
        coordinator = SpaceNotesFlowCoordinator(entry: .space(spaceID: space.room.id, documentID: documentID),
                                                navigationStackCoordinator: stack,
                                                contextFactory: SpaceNotesContextFactory(clientProxy: client, engine: space.engine))
        client.roomForIdentifierClosure = { [weak self, space, gate] _ in
            await gate.wait()
            self?.contextsMade += 1
            return isJoined ? .joined(space.room) : nil
        }
        coordinator.actionsPublisher
            .sink { [weak self] _ in self?.finishedCount += 1 }
            .store(in: &cancellables)
    }
}
