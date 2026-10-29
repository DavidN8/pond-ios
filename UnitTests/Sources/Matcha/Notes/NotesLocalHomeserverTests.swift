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

/// Notes against the real Rust SDK, the bundled Yjs engine in its web view and the local throwaway homeserver of
/// `MatchaLocalHomeserverTests` (same `MATCHA_LOCAL_TEST_ENV` file, skipped without it): one member turns notes on for a new space,
/// names a note and writes it, the other reads the name and the text and writes back, and the first sees that edit arrive.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: MatchaLocalHomeserver.configuration != nil, "No local homeserver is configured"))
struct NotesLocalHomeserverTests {
    @Test
    func aNoteWrittenByOneMemberIsReadAndAnsweredByAnother() async throws {
        let server = try #require(MatchaLocalHomeserver.configuration)
        try await server.signedIn(.a) { alice in
            try await server.signedIn(.b) { bob in
                let spaceID = try await alice.client.createRoom(name: "Matcha notes \(UUID().uuidString.prefix(8))", topic: nil, accessType: .private,
                                                                isSpace: true, userIDs: [bob.userID], avatarURL: nil, aliasLocalPart: nil).get()
                try await bob.client.joinRoom(spaceID, via: []).get()
                
                // Alice, who made the space, turns notes on.
                let aliceSpace = try await alice.joinedRoom(spaceID)
                let setup = SpaceNotesSetup(room: aliceSpace)
                #expect(await setup.status().canSetUp)
                try await setup.turnOn().get()
                #expect(await setup.status().isConfigured)
                
                // She names a note and writes it.
                let aliceEngine = WebViewYjsEngine()
                let aliceNotes = try #require(await SpaceNotesContextFactory(clientProxy: alice.client, engine: aliceEngine).makeContext(roomID: spaceID))
                defer { aliceNotes.close() }
                let aliceCatalog = try #require(aliceNotes.catalog)
                try #require(await firstValue(of: aliceCatalog.statePublisher, timeout: .seconds(30)) { $0.canEdit } != nil, "Alice can't write the catalog")
                let documentID = try await aliceCatalog.create(title: "Trip plans").get()
                let aliceNote = aliceNotes.openDocument(documentID)
                defer { aliceNote.close() }
                try #require(await firstValue(of: aliceNote.statePublisher, timeout: .seconds(30)) { $0.canEdit } != nil, "Alice can't write the note")
                await aliceNote.edit(from: "", to: "# Plans\nWe leave on Friday.")
                await aliceNote.flush()
                #expect(aliceNote.state.pendingUpdates == 0)
                #expect(aliceNote.state.sync == .saved)
                
                // Bob's device needs the room key before his store reads the frames, or it keeps the encrypted copies.
                let bobSpace = try await bob.joinedRoom(spaceID)
                let anchor = try #require(try await bobSpace.storedStateEventID(type: "m.room.create", stateKey: "").get())
                let isDecrypted = await poll(timeout: .seconds(60)) {
                    let page = try? await bobSpace.fetchRelatedEventsJSON(eventID: anchor, relation: .reference, from: nil, limit: 100).get()
                    let events = page?.events.compactMap(RawEvent.init(json:)) ?? []
                    return events.count >= 2 && events.allSatisfy { $0.type == MatchaConfig.eventDocsUpdate }
                }
                try #require(isDecrypted, "Bob's device never got the room key")
                
                // Bob's Notes tab finds the space and its note.
                let bobEngine = WebViewYjsEngine()
                let bobFactory = SpaceNotesContextFactory(clientProxy: bob.client, engine: bobEngine)
                let reader = NotesTabReader(clientProxy: bob.client, contextFactory: bobFactory)
                reader.start()
                defer { reader.stop() }
                let listed = await firstValue(of: reader.spacesPublisher, timeout: .seconds(60)) { spaces in
                    spaces?.contains { $0.id == spaceID && $0.notes != .unknown } == true
                }
                #expect(listed??.first { $0.id == spaceID }?.notes != .off)
                reader.setShown([spaceID])
                let read = await firstValue(of: reader.spacesPublisher, timeout: .seconds(60)) { spaces in
                    guard case .on(let read) = spaces?.first(where: { $0.id == spaceID })?.notes else { return false }
                    return read.catalog?.documents.contains { $0.id == documentID } == true
                }
                guard case .on(let notes) = read??.first(where: { $0.id == spaceID })?.notes else {
                    Issue.record("Bob's Notes tab never listed the note")
                    return
                }
                #expect(notes.catalog?.documents.first { $0.id == documentID }?.title == "Trip plans")
                reader.stop()
                
                // Bob opens the note, reads it and writes back.
                let bobNotes = try #require(await bobFactory.makeContext(roomID: spaceID))
                defer { bobNotes.close() }
                let bobNote = bobNotes.openDocument(documentID)
                defer { bobNote.close() }
                let bobState = await firstValue(of: bobNote.statePublisher, timeout: .seconds(60)) { $0.canEdit && $0.text.contains("Friday") }
                #expect(bobState?.text == "# Plans\nWe leave on Friday.")
                await bobNote.edit(from: "# Plans\nWe leave on Friday.", to: "# Plans\nWe leave on Friday at nine.")
                await bobNote.flush()
                #expect(bobNote.state.pendingUpdates == 0)
                
                // The edit reaches Alice's open note through her sync.
                let aliceState = await firstValue(of: aliceNote.statePublisher, timeout: .seconds(60)) { $0.text.contains("at nine") }
                #expect(aliceState?.text == "# Plans\nWe leave on Friday at nine.")
                #expect(aliceState?.canEdit == true)
            }
        }
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
