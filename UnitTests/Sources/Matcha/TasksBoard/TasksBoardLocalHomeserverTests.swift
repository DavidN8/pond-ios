//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import MatchaProtocol
import Testing

/// The task board against the real Rust SDK and the local throwaway homeserver of `MatchaLocalHomeserverTests`: one member creates
/// the board, adds tasks and moves one, another member's board shows what is shared with the chat and moves it on. Skipped unless
/// `MATCHA_LOCAL_TEST_ENV` names the accounts file.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: MatchaLocalHomeserver.configuration != nil, "No local homeserver is configured"))
struct TasksBoardLocalHomeserverTests {
    @Test
    func aBoardCreatedAndChangedHereIsWhatAnotherMemberSees() async throws {
        let server = try #require(MatchaLocalHomeserver.configuration)
        try await server.signedIn(.a) { alice in
            try await server.signedIn(.b) { bob in
                let roomID = try await alice.client.createRoom(name: "Matcha board \(UUID().uuidString.prefix(8))", topic: nil, accessType: .private,
                                                               isSpace: false, userIDs: [bob.userID], avatarURL: nil, aliasLocalPart: nil).get()
                try await bob.client.joinRoom(roomID, via: []).get()
                
                let aliceStore = try await MatchaRoomStore(room: alice.joinedRoom(roomID), noBoardAnswers: NoBoardAnswers())
                defer { aliceStore.stop() }
                let aliceBoard = TasksBoardScreenViewModel(store: aliceStore)
                // The homeserver said the room has no pointer, so creating one can't replace a board made elsewhere.
                try await wait(aliceBoard, timeout: .seconds(30)) { $0 == .setup(canCreate: true, isCreating: false, createFailed: false) }
                #expect(aliceStore.isServerPointerRead)
                aliceBoard.context.send(viewAction: .createBoard)
                try await wait(aliceBoard) { $0.board != nil }
                let rootID = try #require(aliceStore.snapshot.board?.rootID)
                #expect(try await aliceStore.readBoardPointer().get() == rootID)
                
                try await addTask(named: "Book the venue", sharedWithChat: true, to: aliceStore)
                try await addTask(named: "Alice's own note", sharedWithChat: false, to: aliceStore)
                let shared = try await wait(aliceBoard) { $0.board?.todo.count == 2 }.board?.todo.first { $0.title == "Book the venue" }
                let sharedID = try #require(shared?.id)
                aliceBoard.context.send(viewAction: .move(id: sharedID, status: .doing))
                try await wait(aliceBoard) { $0.board?.doing.map(\.id) == [sharedID] }
                
                let bobRoom = try await bob.joinedRoom(roomID)
                // The store reads each anchor once, so it waits for the room key to reach Bob's device first.
                let isDecrypted = await poll(timeout: .seconds(30)) {
                    let page = try? await bobRoom.fetchRelatedEventsJSON(eventID: rootID, relation: .reference, from: nil, limit: 100).get()
                    return page?.events.compactMap(RawEvent.init(json:)).count { $0.type == MatchaConfig.eventKanbanCard } == 3
                }
                try #require(isDecrypted, "Bob's device never got the room key")
                let bobStore = MatchaRoomStore(room: bobRoom, noBoardAnswers: NoBoardAnswers())
                defer { bobStore.stop() }
                let bobBoard = TasksBoardScreenViewModel(store: bobStore)
                
                // A task that isn't shared with the chat only shows to the people it involves.
                let bobsView = try await wait(bobBoard, timeout: .seconds(30)) { $0.board?.doing.map(\.id) == [sharedID] && $0.board?.isLoading == false }.board
                #expect(bobsView?.todo.isEmpty == true)
                #expect(bobsView?.hidden.map(\.title) == ["Alice's own note"])
                #expect(bobsView?.doing.first?.isSharedWithChat == true)
                
                bobBoard.context.send(viewAction: .move(id: sharedID, status: .done))
                try await wait(bobBoard) { $0.board?.done.map(\.id) == [sharedID] }
                // Alice's board reads the move from her sync.
                try await wait(aliceBoard, timeout: .seconds(30)) { $0.board?.done.map(\.id) == [sharedID] }
            }
        }
    }
    
    // MARK: - Private
    
    /// Adds a task with the editor, which creates its named thread first.
    private func addTask(named name: String, sharedWithChat: Bool, to store: MatchaRoomStore) async throws {
        let editor = TaskEditorScreenViewModel(store: store, target: .new(status: .todo))
        editor.context.title = name
        editor.context.showToRoom = sharedWithChat
        let closed = deferFulfillment(editor.actionsPublisher, timeout: .seconds(30)) { $0 == .close }
        editor.context.send(viewAction: .save)
        try await closed.fulfill()
        #expect(editor.context.viewState.saveError == nil)
    }
    
    @discardableResult
    private func wait(_ viewModel: TasksBoardScreenViewModel,
                      timeout: Duration = .seconds(15),
                      sourceLocation: SourceLocation = #_sourceLocation,
                      _ condition: @escaping (TasksBoardContent) -> Bool) async throws -> TasksBoardContent {
        try await deferFulfillment(viewModel.context.observe(\.viewState.content), timeout: timeout, sourceLocation: sourceLocation, until: condition).fulfill()
    }
    
    /// Whether `condition` held within `timeout`, asking twice a second.
    private func poll(timeout: Duration, _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }
}

private extension TasksBoardContent {
    var board: TasksBoard? {
        if case .board(let board) = self {
            board
        } else {
            nil
        }
    }
}
