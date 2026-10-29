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

/// The chip bar against the real Rust SDK and the local throwaway homeserver of `MatchaLocalHomeserverTests`: a thread named the
/// way the web client names one shows as a chip with no visible replies, and a rename from the bar reaches the other member.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: MatchaLocalHomeserver.configuration != nil, "No local homeserver is configured"))
struct ChatBarLocalHomeserverTests {
    @Test
    func aThreadNamedOnTheWebGetsAChipAndARenameFromTheBarReachesTheWeb() async throws {
        let server = try #require(MatchaLocalHomeserver.configuration)
        try await server.signedIn(.a) { alice in
            try await server.signedIn(.b) { bob in
                let roomID = try await bob.client.createRoom(name: "Matcha chip bar \(UUID().uuidString.prefix(8))", topic: nil, accessType: .private,
                                                             isSpace: false, userIDs: [alice.userID], avatarURL: nil, aliasLocalPart: nil).get()
                try await alice.client.joinRoom(roomID, via: []).get()
                let bobRoom = try await bob.joinedRoom(roomID)
                
                // What the web client sends for a new named thread, written out rather than built by the package: the root, then
                // the hidden first reply that names it.
                let rootID = try await bobRoom.sendRawEvent(type: "m.room.message", contentJSON: #"{"msgtype": "m.text", "body": "Launch plan"}"#).get()
                let bootstrap = #"{"version": 1, "name": "Launch plan", "archived": false, "m.relates_to": {"rel_type": "m.thread", "event_id": "\#(rootID)", "is_falling_back": true, "m.in_reply_to": {"event_id": "\#(rootID)"}}}"#
                _ = try await bobRoom.sendRawEvent(type: MatchaConfig.eventThreadMetadata, contentJSON: bootstrap).get()
                
                // The store reads each anchor once, so wait for Bob's room key to reach Alice's device first.
                let aliceRoom = try await alice.joinedRoom(roomID)
                try #require(await poll {
                    await relatedEvents(of: rootID, .thread, in: aliceRoom).contains { $0.type == MatchaConfig.eventThreadMetadata }
                }, "Alice's device never got the room key")
                
                let store = MatchaRoomStore(room: aliceRoom, noBoardAnswers: NoBoardAnswers())
                defer { store.stop() }
                let chatBar = ChatBarViewModel(chat: MatchaChat(store: store), selection: .general)
                try #require(await poll { chatBar.context.viewState.threads.contains { $0.id == rootID } },
                             "No chip came: \(String(describing: store.snapshot))")
                
                #expect(chatBar.context.viewState.showsBar)
                #expect(chatBar.context.viewState.threads == [ChatBarThread(id: rootID, name: "Launch plan", isArchived: false)])
                // The homeserver counts the hidden reply; the bubble summary and All threads leave it out.
                #expect(store.snapshot.threads.first { $0.id == rootID }?.numberOfReplies == 1)
                #expect(store.snapshot.threadInfos[rootID] == MatchaThreadInfo(name: "Launch plan", isNamed: true, isArchived: false, hiddenReplies: 1))
                
                chatBar.context.send(viewAction: .renameThread(id: rootID))
                chatBar.context.send(viewAction: .updateThreadName("Launch plan v2"))
                chatBar.context.send(viewAction: .submitThreadName)
                try #require(await poll { chatBar.context.threadNameSheet == nil }, "The rename never finished")
                
                // The web client reads names from the thread's metadata patches.
                let isRenamed = await poll {
                    await relatedEvents(of: rootID, .reference, in: bobRoom).contains {
                        $0.type == MatchaConfig.eventThreadMetadata && $0.content["name"] == .string("Launch plan v2")
                    }
                }
                #expect(isRenamed, "Bob never read the new name")
                #expect(await poll { chatBar.context.viewState.threads.first?.name == "Launch plan v2" })
            }
        }
    }
    
    // MARK: - Private
    
    private func relatedEvents(of eventID: String, _ relation: RawRelationType, in room: JoinedRoomProxyProtocol) async -> [RawEvent] {
        let page = try? await room.fetchRelatedEventsJSON(eventID: eventID, relation: relation, from: nil, limit: 100).get()
        return page?.events.compactMap(RawEvent.init(json:)) ?? []
    }
    
    /// Whether `condition` held within 30 seconds, asking twice a second.
    private func poll(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }
}
