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

/// The Matcha room store against the real Rust SDK and a local throwaway homeserver: the events go out through the room proxies
/// and come back through relations, the thread list, the scan timeline and the homeserver's state. Runs only when
/// `MATCHA_LOCAL_TEST_ENV` names a file of `KEY=VALUE` lines (`MATCHA_LOCAL_HOMESERVER`, `MATCHA_LOCAL_USER_A`,
/// `MATCHA_LOCAL_PASSWORD_A`, `MATCHA_LOCAL_USER_B`, `MATCHA_LOCAL_PASSWORD_B`); pass it to xcodebuild as
/// `TEST_RUNNER_MATCHA_LOCAL_TEST_ENV=<path>`. Never point it at a real server: each run creates rooms. Signing in and waiting for
/// a room key and for the store can take longer than the test plan's minute on a busy machine.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: MatchaLocalHomeserver.configuration != nil, "No local homeserver is configured"))
struct MatchaLocalHomeserverTests {
    private let threadName = "Ship the store"
    
    @Test
    func aStoreReadsBackTheBoardNamedThreadAndCardItsRoomSentThroughTheHomeserver() async throws {
        let server = try #require(MatchaLocalHomeserver.configuration)
        try await server.signedIn(.a) { alice in
            let roomID = try await alice.client.createRoom(name: "Matcha store \(UUID().uuidString.prefix(8))", topic: nil, accessType: .private,
                                                           isSpace: false, userIDs: [], avatarURL: nil, aliasLocalPart: nil).get()
            let room = try await alice.joinedRoom(roomID)
            let writer = MatchaRoomStore(room: room, noBoardAnswers: NoBoardAnswers())
            defer { writer.stop() }
            // The room is encrypted, so every Matcha event goes out as `m.room.encrypted` with its relation in the clear.
            #expect(await firstValue(of: room.infoPublisher, timeout: .seconds(10)) { $0.isEncrypted } != nil)
            let sent = try await sendBoard(through: writer)
            // The writer shows its own events at once.
            await waitForSnapshot(writer) { $0.board?.cards.first?.threadID == sent.threadID }
            writer.stop()
            
            // The patched SDK reads the card back decrypted through relations, and the pointer from the homeserver.
            let related = try await room.fetchRelatedEventsJSON(eventID: sent.boardRootID, relation: .reference, from: nil, limit: 100).get()
            #expect(related.events.compactMap(RawEvent.init(json:)).contains { $0.type == MatchaConfig.eventKanbanCard })
            let pointer = try await room.fetchStateEventContentJSON(type: MatchaConfig.stateKanban, stateKey: "").get()
            #expect(KanbanProtocol.parseBoardPointer(json: pointer) == sent.boardRootID)
            
            // A new store has no echoes to show, so it reads everything back.
            let reader = MatchaRoomStore(room: room, noBoardAnswers: NoBoardAnswers())
            defer { reader.stop() }
            let snapshot = try #require(await waitForBoard(reader, sent))
            expectBoard(snapshot, sent, participant: alice.userID)
            #expect(!reader.relationsUnavailable)
            #expect(try await reader.readBoardPointer().get() == sent.boardRootID)
        }
    }
    
    @Test
    func aRoomsNamedPackIsReadFromTheHomeserversStateThoughTheSyncNeverStoresIt() async throws {
        let server = try #require(MatchaLocalHomeserver.configuration)
        try await server.signedIn(.a) { alice in
            let roomID = try await alice.client.createRoom(name: "Matcha packs \(UUID().uuidString.prefix(8))", topic: nil, accessType: .private,
                                                           isSpace: false, userIDs: [], avatarURL: nil, aliasLocalPart: nil).get()
            let room = try await alice.joinedRoom(roomID)
            let pepe = #"{"images": {"pepe": {"url": "mxc://localhost/pepe"}}, "pack": {"display_name": "Pepe", "usage": ["sticker"]}}"#
            _ = try await room.sendRawStateEvent(type: ImagePacks.roomEmotesEventType, stateKey: "pepe", contentJSON: pepe).get()
            
            let contents = try await alice.client.fetchStateEventsJSON(roomID: roomID, type: ImagePacks.roomEmotesEventType).get()
            #expect(contents.keys.sorted() == ["pepe"])
            let packs = await CustomEmojiPacks(clientProxy: alice.client).stickerPacks(roomID: roomID)
            #expect(packs.first { $0.id == "\(roomID)|pepe" }?.name == "Pepe")
        }
    }
    
    @Test
    func aMemberWhoDidntSendTheBoardReadsItFromTheHomeserver() async throws {
        let server = try #require(MatchaLocalHomeserver.configuration)
        try await server.signedIn(.a) { alice in
            try await server.signedIn(.b) { bob in
                let roomID = try await alice.client.createRoom(name: "Matcha shared \(UUID().uuidString.prefix(8))", topic: nil, accessType: .private,
                                                               isSpace: false, userIDs: [bob.userID], avatarURL: nil, aliasLocalPart: nil).get()
                try await bob.client.joinRoom(roomID, via: []).get()
                let writer = try await MatchaRoomStore(room: alice.joinedRoom(roomID), noBoardAnswers: NoBoardAnswers())
                defer { writer.stop() }
                let sent = try await sendBoard(through: writer)
                writer.stop()
                
                let bobRoom = try await bob.joinedRoom(roomID)
                // The room key reaches Bob's device through his sync. A related event read before then stays encrypted in the
                // store (it reads each anchor once, as on Android), so wait for the key first.
                let isDecrypted = await poll(timeout: .seconds(30)) {
                    let page = try? await bobRoom.fetchRelatedEventsJSON(eventID: sent.boardRootID, relation: .reference, from: nil, limit: 100).get()
                    return page?.events.compactMap(RawEvent.init(json:)).contains { $0.type == MatchaConfig.eventKanbanCard } == true
                }
                try #require(isDecrypted, "Bob's device never got the room key")
                
                let reader = MatchaRoomStore(room: bobRoom, noBoardAnswers: NoBoardAnswers())
                defer { reader.stop() }
                let snapshot = try #require(await waitForBoard(reader, sent))
                expectBoard(snapshot, sent, participant: alice.userID)
                #expect(snapshot.threads.first { $0.id == sent.threadID }?.rootSenderID == alice.userID)
                #expect(!snapshot.permissions.canCreateBoard)
            }
        }
    }
    
    @Test
    func aReceiptOnAMatchaEventCountsForTheMessageBeforeIt() async throws {
        let server = try #require(MatchaLocalHomeserver.configuration)
        try await server.signedIn(.a) { alice in
            try await server.signedIn(.b) { bob in
                let roomID = try await alice.client.createRoom(name: "Matcha ticks \(UUID().uuidString.prefix(8))", topic: nil, accessType: .private,
                                                               isSpace: false, userIDs: [bob.userID], avatarURL: nil, aliasLocalPart: nil).get()
                try await bob.client.joinRoom(roomID, via: []).get()
                let room = try await alice.joinedRoom(roomID)
                await room.timeline.subscribeForUpdates()
                let messageID = try await room.sendRawEvent(type: "m.room.message", contentJSON: #"{"msgtype": "m.text", "body": "Hello"}"#).get()
                
                // Bob reads up to a card he posts after it. The app draws no Matcha event, so the read ticks only count his receipt
                // because the SDK leaves the card out of the timeline and moves the receipt to the message before it.
                let bobRoom = try await bob.joinedRoom(roomID)
                let cardID = try await bobRoom.sendRawEvent(type: MatchaConfig.eventKanbanCard, contentJSON: "{}").get()
                _ = await bobRoom.timeline.sendReadReceipt(for: cardID, type: .read)
                
                let bobUserID = bob.userID
                var readEventID: String?
                let hasReceipt = await poll(timeout: .seconds(30)) {
                    for case .event(let event) in room.timeline.timelineItemProvider.itemProxies where event.readReceipts[bobUserID] != nil {
                        readEventID = event.id.eventID
                        return true
                    }
                    return false
                }
                try #require(hasReceipt, "Bob's receipt never reached Alice's timeline")
                #expect(readEventID == messageID, "Bob's receipt is on \(readEventID ?? "nothing"), the card is \(cardID)")
            }
        }
    }
    
    // MARK: - Private
    
    private struct SentBoard {
        let boardRootID: String
        let threadID: String
    }
    
    /// A board as the web client makes one, a named thread with one visible reply, and the thread's card on the board.
    private func sendBoard(through store: MatchaRoomStore) async throws -> SentBoard {
        let boardRootID = try await store.send(type: MatchaConfig.eventKanbanBoard, contentJSON: KanbanProtocol.boardRootContent()).get()
        _ = try await store.sendState(type: MatchaConfig.stateKanban, stateKey: "", contentJSON: KanbanProtocol.boardPointerContent(rootID: boardRootID)).get()
        
        guard case .created(let threadID) = await store.createNamedThread(name: threadName) else {
            Issue.record("The named thread wasn't created")
            throw CancellationError()
        }
        let reply = #"{"msgtype": "m.text", "body": "On it", "m.relates_to": {"rel_type": "m.thread", "event_id": "\#(threadID)", "is_falling_back": true, "m.in_reply_to": {"event_id": "\#(threadID)"}}}"#
        _ = try await store.room.sendRawEvent(type: "m.room.message", contentJSON: reply).get()
        
        let card = CardRevision(cardID: KanbanProtocol.threadCardID(threadID), title: threadName, description: "", status: .doing, archived: false,
                                threadID: threadID, dueAt: nil, reminderRequested: nil, showToRoom: true)
        _ = try await store.send(type: MatchaConfig.eventKanbanCard, contentJSON: KanbanProtocol.cardContent(card, rootID: boardRootID)).get()
        return SentBoard(boardRootID: boardRootID, threadID: threadID)
    }
    
    /// The first loaded snapshot of `store` with the board, the named thread with its reply counted and the card.
    private func waitForBoard(_ store: MatchaRoomStore, _ sent: SentBoard) async -> MatchaRoomSnapshot? {
        let threadID = sent.threadID
        let name = threadName
        let snapshot = await firstValue(of: store.snapshotPublisher, timeout: .seconds(30)) { snapshot in
            snapshot.isLoaded && snapshot.board?.cards.contains { $0.threadID == threadID && $0.hasRevision } == true
                && snapshot.threads.contains { $0.id == threadID && $0.metadata.name == name && $0.numberOfReplies == 2 }
        }
        if snapshot == nil {
            Issue.record("The store never showed the board: \(String(describing: store.snapshot))")
        }
        return snapshot
    }
    
    private func expectBoard(_ snapshot: MatchaRoomSnapshot, _ sent: SentBoard, participant: String) {
        #expect(snapshot.board?.rootID == sent.boardRootID)
        #expect(snapshot.isBoardResolved)
        #expect(snapshot.warning == nil)
        #expect(!snapshot.loadFailed)
        
        let card = snapshot.board?.cards.first { $0.threadID == sent.threadID }
        #expect(snapshot.board?.cards.count == 1)
        #expect(card?.id == KanbanProtocol.threadCardID(sent.threadID))
        #expect(card?.title == threadName)
        #expect(card?.status == .doing)
        #expect(card?.participants.contains(participant) == true)
        
        let thread = snapshot.threads.first { $0.id == sent.threadID }
        #expect(thread?.metadata.name == threadName)
        #expect(thread?.rootBody == threadName)
        #expect(thread?.hasHiddenFirstReply == true)
        #expect(thread?.visibleReplies == 1)
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

/// The local throwaway homeserver the Matcha end-to-end tests sign in to, from the file `MATCHA_LOCAL_TEST_ENV` names.
nonisolated struct MatchaLocalHomeserver: Sendable {
    enum User {
        case a
        case b
    }
    
    let url: String
    private let values: [String: String]
    
    static let configuration: MatchaLocalHomeserver? = {
        guard let path = ProcessInfo.processInfo.environment["MATCHA_LOCAL_TEST_ENV"],
              let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        let values = Dictionary(text.split(whereSeparator: \.isNewline).compactMap { line -> (String, String)? in
            guard !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { return nil }
            return (String(line[..<separator]), String(line[line.index(after: separator)...]))
        }) { _, last in last }
        guard let url = values["MATCHA_LOCAL_HOMESERVER"] else { return nil }
        return MatchaLocalHomeserver(url: url, values: values)
    }()
    
    /// Runs `body` with `user` signed in on a new in-memory client whose sync runs, then signs them out again.
    @MainActor
    func signedIn(_ user: User, _ body: (SignedInClient) async throws -> Void) async throws {
        let client = try await signIn(user)
        do {
            try await body(client)
        } catch {
            await client.signOut()
            throw error
        }
        await client.signOut()
    }
    
    @MainActor
    private func signIn(_ user: User) async throws -> SignedInClient {
        let suffix = user == .a ? "A" : "B"
        let name = try #require(values["MATCHA_LOCAL_USER_\(suffix)"])
        let password = try #require(values["MATCHA_LOCAL_PASSWORD_\(suffix)"])
        
        let appSettings = AppSettings.volatile()
        // The Matcha app turns the SDK's threads on (`MatchaAppSettingsHook`), which changes how thread events reach the client.
        appSettings.threadsEnabled = true
        let client = try await ClientFactory().makeInMemoryClient(serverNameOrBaseURL: url,
                                                                  clientSessionDelegate: KeychainControllerMock(),
                                                                  appSettings: appSettings,
                                                                  appHooks: AppHooks())
        try await client.login(username: name, password: password, initialDeviceName: "Matcha store tests", deviceId: nil)
        let userID = try client.userId()
        let proxy = try await ClientProxy(client: client,
                                          networkMonitor: NetworkMonitorMock(.init()),
                                          userSettings: appSettings.userSettings(for: userID),
                                          analyticsService: AnalyticsServiceMock(.init()))
        await proxy.resumeServices()
        return SignedInClient(client: proxy, userID: userID)
    }
}

@MainActor
struct SignedInClient {
    let client: ClientProxy
    let userID: String
    
    func joinedRoom(_ roomID: String) async throws -> JoinedRoomProxyProtocol {
        guard case .joined(let room) = await client.roomForIdentifier(roomID) else {
            Issue.record("\(userID) hasn't joined \(roomID)")
            throw CancellationError()
        }
        return room
    }
    
    /// Stops the sync and removes the device from the homeserver.
    func signOut() async {
        await client.pauseServices()
        await client.logout()
    }
}
