//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import MatchaProtocol
import Testing

@MainActor
struct MatchaRoomStoreServerPointerTests {
    private let root = "$board-root"
    
    @Test
    func aBoardPointerTheSyncDidntStoreIsReadFromTheHomeserver() async {
        let store = aStore { .success("$board-root") }.store()
        await store.settle()
        
        #expect(store.snapshot.board?.rootID == root)
        #expect(store.snapshot.isBoardResolved)
    }
    
    @Test
    func theHomeserverSayingThereIsNoPointerSettlesThatTheRoomHasNoBoard() async {
        let store = aStore { .success(nil) }.store()
        await store.settle()
        
        #expect(store.snapshot.board == nil)
        #expect(store.snapshot.isBoardResolved)
    }
    
    @Test
    func aMissingBoardStaysUnresolvedWhileTheHomeserverCantBeAskedAndTheHistoryIsntRead() async {
        let store = aStore { .failure(.sdkError(RoomProxyMockError.generic)) }.store()
        await store.settle()
        
        #expect(store.snapshot.board == nil)
        #expect(!store.snapshot.isBoardResolved)
        #expect(!store.isServerPointerRead)
    }
    
    @Test
    func aFailedHomeserverReadIsTriedAgainOnRetry() async {
        var answer: Result<String?, RoomProxyError> = .failure(.sdkError(RoomProxyMockError.generic))
        let store = aStore { answer }.store()
        await store.settle()
        #expect(!store.snapshot.isBoardResolved)
        
        answer = .success(root)
        store.retryLoad()
        await store.settle()
        #expect(store.snapshot.board?.rootID == root)
    }
    
    @Test
    func creatingABoardFirstAsksTheHomeserverSoABoardMadeElsewhereIsNeverReplaced() async throws {
        let fixture = aStore { .success("$board-root") }
        let store = fixture.store()
        await store.settle()
        
        #expect(try await store.readBoardPointer().get() == root)
        #expect(fixture.serverPointerReads == 2)
    }
    
    @Test
    func aPointerTheCallerAlreadyReadIsUsedWithoutAskingAgain() async {
        let fixture = aStore { .failure(.sdkError(RoomProxyMockError.generic)) }
        let store = fixture.store(knownServerPointer: root)
        await store.settle()
        
        #expect(store.snapshot.board?.rootID == root)
        #expect(fixture.serverPointerReads == 0)
    }
    
    @Test
    func onceTheHomeserverSaysThereIsNoBoardCreatingOneDoesntReadTheWholeHistory() async throws {
        let fixture = aStore { .success(nil) }
        // Any history read past the first pages fails, so the board would stay unresolved if it needed the history.
        fixture.paginateResult = { .failure(.sdkError(RoomProxyMockError.generic)) }
        let store = fixture.store()
        await store.settle()
        
        #expect(store.snapshot.isBoardResolved)
        #expect(store.isServerPointerRead)
        #expect(try await store.readBoardPointer().get() == nil)
    }
    
    @Test
    func creatingABoardFailsWhenTheHomeserverCantBeAsked() async {
        let store = aStore { .failure(.sdkError(RoomProxyMockError.generic)) }.store()
        await store.settle()
        
        #expect(await store.readBoardPointer().isFailure)
    }
    
    // MARK: - Helpers
    
    /// A room with more history than the store reads up front, so only the homeserver can settle whether it has a board.
    private func aStore(serverPointer: @escaping () -> Result<String?, RoomProxyError>) -> MatchaRoomFixture {
        let fixture = MatchaRoomFixture(olderPages: Array(repeating: [], count: MatchaConfig.initialHistoryPages + 5))
        fixture.serverPointer = serverPointer
        return fixture
    }
}
