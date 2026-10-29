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

/// The Tasks tab against the real Rust SDK and the local throwaway homeserver of `MatchaLocalHomeserverTests`. Skipped unless
/// `MATCHA_LOCAL_TEST_ENV` names the accounts file.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)), .enabled(if: MatchaLocalHomeserver.configuration != nil, "No local homeserver is configured"))
struct TasksTabLocalHomeserverTests {
    @Test
    func theTabListsTheUsersTasksFromEveryChatIncludingABoardMadeOnAnotherDeviceAndNeverOpenedHere() async throws {
        let server = try #require(MatchaLocalHomeserver.configuration)
        let run = UUID().uuidString.prefix(8)
        try await server.signedIn(.a) { alice in
            try await server.signedIn(.b) { bob in
                // Two chats where Bob makes the board and a task himself.
                var expected = [String: String]()
                for index in 1...2 {
                    let roomID = try await bob.client.createRoom(name: "Matcha tab \(index) \(run)", topic: nil, accessType: .private, isSpace: false,
                                                                 userIDs: [alice.userID], avatarURL: nil, aliasLocalPart: nil).get()
                    let store = try await MatchaRoomStore(room: bob.joinedRoom(roomID), noBoardAnswers: NoBoardAnswers())
                    let name = "Bob's task \(index) \(run)"
                    try await makeBoard(with: name, in: store)
                    store.stop()
                    expected[name] = roomID
                }
                
                // A chat whose board Alice made on her device; Bob only answers the task's thread and never opens the board here.
                let aliceRoomID = try await alice.client.createRoom(name: "Matcha tab 3 \(run)", topic: nil, accessType: .private, isSpace: false,
                                                                    userIDs: [bob.userID], avatarURL: nil, aliasLocalPart: nil).get()
                try await bob.client.joinRoom(aliceRoomID, via: []).get()
                let aliceStore = try await MatchaRoomStore(room: alice.joinedRoom(aliceRoomID), noBoardAnswers: NoBoardAnswers())
                defer { aliceStore.stop() }
                let aliceTask = "Alice's task \(run)"
                try await makeBoard(with: aliceTask, in: aliceStore)
                let board = try #require(aliceStore.snapshot.board)
                let threadID = try #require(board.cards.first { $0.title == aliceTask }?.threadID)
                expected[aliceTask] = aliceRoomID
                
                let bobRoom = try await bob.joinedRoom(aliceRoomID)
                // The tab's store reads each anchor once, so the room key has to reach Bob's device first.
                let isDecrypted = await poll(timeout: .seconds(30)) {
                    let page = try? await bobRoom.fetchRelatedEventsJSON(eventID: board.rootID, relation: .reference, from: nil, limit: 100).get()
                    return page?.events.compactMap(RawEvent.init(json:)).contains { $0.type == MatchaConfig.eventKanbanCard } == true
                }
                try #require(isDecrypted, "Bob's device never got the room key")
                let reply = #"{"msgtype": "m.text", "body": "On it", "m.relates_to": {"rel_type": "m.thread", "event_id": "\#(threadID)", "is_falling_back": true, "m.in_reply_to": {"event_id": "\#(threadID)"}}}"#
                _ = try await bobRoom.sendRawEvent(type: "m.room.message", contentJSON: reply).get()
                
                let rooms = TasksTabRooms(clientProxy: bob.client, noBoardAnswers: NoBoardAnswers())
                let tab = TasksTabScreenViewModel(rooms: rooms, clientProxy: bob.client)
                tab.context.send(viewAction: .appeared)
                defer {
                    tab.context.send(viewAction: .disappeared)
                    rooms.stop()
                }
                // Bob's earlier test chats are listed too; these three must be among them, each under its own chat.
                let state = try await deferFulfillment(tab.context.observe(\.viewState), timeout: .seconds(180)) { state in
                    let tasks = state.content.allTasks.filter { $0.task.title.map { expected.keys.contains($0) } == true }
                    return Set(tasks.compactMap(\.task.title)) == Set(expected.keys)
                }.fulfill()
                for task in state.content.allTasks {
                    if let title = task.task.title, let roomID = expected[title] {
                        #expect(task.chat.roomID == roomID)
                    }
                }
                // Alice started the thread Bob answered.
                #expect(state.content.allTasks.first { $0.task.title == aliceTask }?.people.count == 1)
            }
        }
    }
    
    // MARK: - Private
    
    /// Creates the chat's board and adds a task shared with the chat, with the editor, which creates its named thread first.
    private func makeBoard(with taskName: String, in store: MatchaRoomStore) async throws {
        #expect(await TaskWriter(store: store).createBoard() == .created)
        await waitForSnapshot(store) { $0.board != nil }
        let editor = TaskEditorScreenViewModel(store: store, target: .new(status: .todo))
        editor.context.title = taskName
        editor.context.showToRoom = true
        let closed = deferFulfillment(editor.actionsPublisher, timeout: .seconds(30)) { $0 == .close }
        editor.context.send(viewAction: .save)
        try await closed.fulfill()
        #expect(editor.context.viewState.saveError == nil)
        await waitForSnapshot(store) { $0.board?.cards.contains { $0.title == taskName } == true }
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
