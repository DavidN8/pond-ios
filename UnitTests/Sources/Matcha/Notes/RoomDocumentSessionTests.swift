//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import Foundation
import MatchaProtocol
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RoomDocumentSessionTests {
    private let hello = FakeYjsEngine.update(FakeYjsEngine.operation("a", text: "Hello"))
    
    @Test
    func theWholeHistoryIsReplayedBeforeTheDocumentIsReady() async throws {
        let fixture = try NotesRoomFixture(items: [
            aFrameItem("$f1", content: aFrame(hello, updateID: "u1")),
            // Another document, another anchor, and a duplicate of the first update are all skipped.
            aFrameItem("$f2", content: aFrame(FakeYjsEngine.update(FakeYjsEngine.operation("x", text: "Other")), updateID: "u2", documentID: DocsProtocol.catalogDocumentID)),
            aFrameItem("$f3", content: aFrame(FakeYjsEngine.update(FakeYjsEngine.operation("y", text: "Elsewhere")), updateID: "u3", anchor: "$other")),
            aFrameItem("$f4", content: aFrame(FakeYjsEngine.update(FakeYjsEngine.operation("z", text: "Duplicate")), updateID: "u1"))
        ])
        let session = fixture.session()
        defer { session.close() }
        #expect(session.state.sync == .loading)
        
        let state = await waitForState(session) { $0.sync != .loading }
        #expect(state?.isReady == true)
        #expect(state?.canEdit == true)
        #expect(state?.sync == .saved)
        #expect(state?.text == "Hello")
        #expect(fixture.engine.documents.first?.applyCount == 1)
        // The replay crosses the bridge once.
        #expect(fixture.engine.documents.first?.applyAllCount == 1)
    }
    
    @Test
    func anUpdateTheEngineRefusesStopsTheReplayThereAndAgainOnRetry() async throws {
        let fixture = try NotesRoomFixture(items: [
            aFrameItem("$f1", content: aFrame(hello, updateID: "u1")),
            aFrameItem("$bad", content: aFrame(Data("garbage".utf8), updateID: "u2")),
            aFrameItem("$f3", content: aFrame(FakeYjsEngine.update(FakeYjsEngine.operation("c", text: "After", deps: ["a"])), updateID: "u3"))
        ])
        let session = fixture.session()
        defer { session.close() }
        await waitForState(session) { $0.error == .invalidUpdate }
        let document = try #require(fixture.engine.documents.first)
        #expect(try await document.snapshot().text == "Hello")
        
        await session.retry().value
        #expect(session.state.error == .invalidUpdate)
        #expect(try await document.snapshot().text == "Hello")
        #expect(document.applyCount == 1)
    }
    
    @Test
    func theFramesComeFromTheAnchorsRelations() async throws {
        let frame = try aMatchaEvent(1, type: MatchaConfig.eventDocsUpdate, content: aFrame(hello, updateID: "u1"), eventID: "$f1")
        let fixture = NotesRoomFixture()
        fixture.base.references[notesAnchor] = [frame]
        let session = fixture.session()
        defer { session.close() }
        let state = await waitForState(session) { $0.isReady }
        #expect(state?.text == "Hello")
    }
    
    @Test
    func chunksApplyOnceCommittedAndComplete() async throws {
        let big = FakeYjsEngine.update(FakeYjsEngine.operation("big", text: String(repeating: "x", count: MatchaConfig.docsChunkBytes * 2)))
        let frames = try frameItems("$big", update: big, updateID: "u-big")
        #expect(frames.count == 4)
        let fixture = NotesRoomFixture(items: [frames[1], frames[0], frames[2]])
        let session = fixture.session()
        defer { session.close() }
        // Uncommitted parts are not missing updates yet: the sender may still be sending.
        let state = await waitForState(session) { $0.sync != .loading }
        #expect(state?.isReady == true)
        #expect(state?.text.isEmpty == true)
        
        fixture.items += [frames[3]]
        await waitForState(session) { $0.text.utf16.count == MatchaConfig.docsChunkBytes * 2 }
    }
    
    @Test
    func aCommittedUpdateMissingAPartOrAPredecessorTurnsEditingOffUntilItArrives() async throws {
        let big = FakeYjsEngine.update(FakeYjsEngine.operation("big", text: String(repeating: "x", count: MatchaConfig.docsChunkBytes + 1)))
        let frames = try frameItems("$big", update: big, updateID: "u-big")
        let fixture = NotesRoomFixture(items: [frames[0], frames[2]])
        let session = fixture.session()
        defer { session.close() }
        let incomplete = await waitForState(session) { $0.sync != .loading }
        #expect(incomplete?.error == .incompleteUpdate)
        #expect(incomplete?.canEdit == false)
        
        fixture.items += [frames[1]]
        await waitForState(session) { $0.error == nil && $0.isReady }
        
        let second = FakeYjsEngine.update(FakeYjsEngine.operation("second", text: "After", deps: ["first"]))
        try fixture.items.append(aFrameItem("$second", content: aFrame(second, updateID: "u-second")))
        await waitForState(session) { $0.error == .incompleteUpdate }
        try fixture.items.append(aFrameItem("$first", content: aFrame(FakeYjsEngine.update(FakeYjsEngine.operation("first")), updateID: "u-first")))
        let complete = await waitForState(session) { $0.error == nil }
        #expect(complete?.text == "After")
    }
    
    @Test
    func framesThatBreakTheProtocolMakeTheDocumentInvalid() async {
        let garbage = Data("garbage".utf8).base64EncodedString()
        let malformed = [
            #""version": 2, "update_id": "u", "kind": "update", "chunks": 1, "chunk": 0, "data": "AAAA""#,
            #""version": 1, "update_id": "u", "kind": "update", "chunks": 2, "chunk": 0, "data": "AAAA""#,
            #""version": 1, "update_id": "u", "kind": "commit", "chunks": 2, "data": "AAAA""#,
            #""version": 1, "update_id": "u", "kind": "update", "chunks": 1, "chunk": 0, "data": "A=A=""#,
            #""version": 1, "update_id": "not valid!", "kind": "update", "chunks": 1, "chunk": 0, "data": "AAAA""#,
            #""version": 1, "update_id": "u", "kind": "update", "chunks": 1, "chunk": 0, "data": "\#(garbage)""#
        ].map { #"{"doc": "main", "m.relates_to": \#(notesRelation), \#($0)}"# }
        for content in malformed {
            let fixture = NotesRoomFixture(items: [aFrameItem("$bad", content: content)])
            let session = fixture.session()
            let state = await waitForState(session) { $0.sync != .loading }
            #expect(state?.error == .invalidUpdate, "\(content)")
            #expect(state?.isReady == false)
            session.close()
        }
    }
    
    @Test
    func anUndecryptableFrameBlocksTheDocumentUntilItIsDecrypted() async throws {
        let encrypted = aFrameItem("$enc", content: #"{"algorithm": "m.megolm.v1.aes-sha2", "ciphertext": "x", "m.relates_to": \#(notesRelation)}"#, type: "m.room.encrypted")
        let fixture = NotesRoomFixture(items: [encrypted])
        let session = fixture.session()
        defer { session.close() }
        let blocked = await waitForState(session) { $0.sync != .loading }
        #expect(blocked?.error == .decryptError)
        #expect(blocked?.canEdit == false)
        
        // The keys arrive: the same event comes back decrypted.
        fixture.items = try [aFrameItem("$enc", content: aFrame(hello, updateID: "u1"))]
        let decrypted = await waitForState(session) { $0.error == nil && $0.isReady }
        #expect(decrypted?.text == "Hello")
    }
    
    @Test
    func editsAreDebouncedFramedAndOnlySavedOnceAcknowledged() async throws {
        let fixture = NotesRoomFixture()
        let session = fixture.session()
        defer { session.close() }
        await waitForState(session) { $0.canEdit }
        
        await session.edit(from: "", to: "Hel")
        await session.edit(from: "Hel", to: "Hello")
        #expect(session.state.text == "Hello")
        #expect(session.state.sync == .saving)
        #expect(session.state.pendingUpdates == 2)
        #expect(fixture.base.sent.isEmpty)
        
        await waitForState(session) { $0.sync == .saved }
        #expect(fixture.base.sent.count == 1)
        let sent = try #require(fixture.base.sent.first)
        #expect(sent.type == MatchaConfig.eventDocsUpdate)
        let frame = try #require(JSONValue(json: sent.content)?.objectValue)
        #expect(frame.integer("version") == 1)
        #expect(frame.string("doc") == "main")
        #expect(frame.string("update_id") == "main-update-0")
        #expect(frame.string("kind") == "update")
        #expect(frame.integer("chunks") == 1)
        #expect(frame.integer("chunk") == 0)
        #expect(frame.referenceTarget == notesAnchor)
        #expect(session.state.pendingUpdates == 0)
        // The echo of our own frame is not applied again.
        #expect(fixture.engine.documents.first?.applyCount == 0)
    }
    
    @Test
    func aLargeEditIsSentInChunksFollowedByACommit() async {
        let fixture = NotesRoomFixture()
        let session = fixture.session()
        defer { session.close() }
        await waitForState(session) { $0.canEdit }
        
        await session.edit(from: "", to: String(repeating: "y", count: MatchaConfig.docsChunkBytes * 2))
        await session.flush()
        #expect(fixture.base.sent.compactMap { JSONValue(json: $0.content)?.objectValue?.string("kind") } == ["chunk", "chunk", "chunk", "commit"])
        #expect(session.state.sync == .saved)
    }
    
    @Test
    func aFailedSendKeepsTheEditsShowsOfflineAndResendsThemOnReconnection() async {
        let fixture = NotesRoomFixture()
        fixture.base.sendResult = { _, _ in .failure(.eventNotFound) }
        let session = fixture.session()
        defer { session.close() }
        await waitForState(session) { $0.canEdit }
        fixture.reachability.send(.unreachable)
        
        await session.edit(from: "", to: "Draft")
        await session.flush()
        #expect(session.state.error == .sendError)
        #expect(session.state.sync == .offline)
        #expect(session.state.pendingUpdates == 1)
        // Editing goes on while offline.
        #expect(session.state.canEdit)
        await session.edit(from: "Draft", to: "Draft 2")
        await session.flush()
        
        fixture.reachability.send(.reachable)
        await waitForState(session) { $0.sync == .error }
        var sentCount = 0
        fixture.base.sendResult = { _, _ in
            sentCount += 1
            return .success("$ok-\(sentCount)")
        }
        fixture.reachability.send(.unreachable)
        fixture.reachability.send(.reachable)
        let saved = await waitForState(session) { $0.sync == .saved }
        #expect(saved?.error == nil)
        // The first edit was already framed; the second followed as its own update.
        #expect(fixture.base.sent.compactMap { JSONValue(json: $0.content)?.objectValue?.string("update_id") } == ["main-update-0", "main-update-1"])
    }
    
    @Test
    func editsThatArrivedWhileTypingAreKept() async throws {
        let fixture = try NotesRoomFixture(items: [aFrameItem("$f1", content: aFrame(hello, updateID: "u1"))])
        let session = fixture.session()
        defer { session.close() }
        await waitForState(session) { $0.text == "Hello" }
        try fixture.items.append(aFrameItem("$f2", content: aFrame(FakeYjsEngine.update(FakeYjsEngine.operation("b", text: "Oh Hello", deps: ["a"])), updateID: "u2")))
        await waitForState(session) { $0.text == "Oh Hello" }
        
        // The field still showed "Hello" when the user typed "!".
        await session.edit(from: "Hello", to: "Hello!")
        #expect(session.state.text == "Oh Hello!")
    }
    
    @Test
    func withoutPermissionTheDocumentIsViewOnly() async {
        let fixture = NotesRoomFixture(canSend: false)
        let session = fixture.session()
        defer { session.close() }
        let state = await waitForState(session) { $0.sync != .loading }
        #expect(state?.isReady == true)
        #expect(state?.canEdit == false)
        
        await session.edit(from: "", to: "Nope")
        await session.flush()
        #expect(session.state.text.isEmpty)
        #expect(fixture.base.sent.isEmpty)
    }
    
    @Test
    func losingThePermissionWithUnsentEditsIsAPermissionError() async {
        let fixture = NotesRoomFixture()
        fixture.base.sendResult = { _, _ in .failure(.eventNotFound) }
        let session = fixture.session()
        defer { session.close() }
        await waitForState(session) { $0.canEdit }
        await session.edit(from: "", to: "Draft")
        await session.flush()
        
        fixture.updateInfo { ($0.powerLevels as? RoomPowerLevelsProxyMock)?.canOwnUserSendMessageReturnValue = false }
        let state = await waitForState(session) { $0.error == .permissionError }
        #expect(state?.canEdit == false)
        #expect(state?.pendingUpdates == 1)
    }
    
    @Test
    func aReadOnlySessionNeverEdits() async {
        let session = NotesRoomFixture().session(isReadOnly: true)
        defer { session.close() }
        let state = await waitForState(session) { $0.sync != .loading }
        #expect(state?.isReady == true)
        #expect(state?.canEdit == false)
    }
    
    @Test
    func historyThatCantBeReadIsALoadErrorAndRetryRecovers() async {
        let fixture = NotesRoomFixture()
        var fails = true
        fixture.base.olderPages = [[], []]
        fixture.base.hasMoreHistory = true
        fixture.base.paginateResult = { fails ? .failure(.sdkError(RoomProxyMockError.generic)) : .success(()) }
        let session = fixture.session()
        defer { session.close() }
        await waitForState(session) { $0.error == .loadError }
        
        fails = false
        session.retry()
        await waitForState(session) { $0.isReady }
    }
    
    @Test
    func theAnchorIsTheCreateEventOfTheRoomStateOrOfAVersion12RoomIDNeverWhatTheFramesPointAt() async throws {
        let frame = try aFrameItem("$f1", content: aFrame(hello, updateID: "u1"))
        // The create event is not in the room state, as in a room whose start is hidden.
        let noAnchor = NotesRoomFixture(items: [frame], createEventID: nil).session()
        let v12RoomID = String(repeating: "a", count: 43)
        let fromRoomID = try NotesRoomFixture(items: [aFrameItem("$f2", content: aFrame(hello, updateID: "u2", anchor: "$\(v12RoomID)"))],
                                              roomID: "!\(v12RoomID)",
                                              createEventID: nil).session()
        // A member's frame related to another event is not part of this room's document.
        let spoofed = try aFrameItem("$f3", content: aFrame(FakeYjsEngine.update(FakeYjsEngine.operation("s", text: "Spoofed")), updateID: "u3", anchor: "$spoof"))
        let fromState = NotesRoomFixture(items: [spoofed, frame]).session()
        defer { [noAnchor, fromRoomID, fromState].forEach { $0.close() } }
        
        let noAnchorState = await waitForState(noAnchor) { $0.sync != .loading }
        #expect(noAnchorState?.error == .anchorError)
        #expect(noAnchorState?.canEdit == false)
        await waitForState(fromRoomID) { $0.text == "Hello" }
        await waitForState(fromState) { $0.text == "Hello" }
    }
    
    @Test
    func anEngineThatCantStartIsALoadErrorAndRetryRecovers() async {
        let fixture = NotesRoomFixture()
        fixture.engine.openError = .stopped
        let session = fixture.session()
        defer { session.close() }
        await waitForState(session) { $0.error == .loadError }
        
        fixture.engine.openError = nil
        session.retry()
        await waitForState(session) { $0.isReady }
    }
    
    @Test
    func aSessionReplaysItsHistoryAndSendsItsEditsThroughTheRealEngine() async throws {
        let engine = WebViewYjsEngine()
        let writerDocument = try await engine.open()
        let update = try #require(try await writerDocument.edit([TextChange(index: 0, remove: 0, insert: "From the web")]))
        writerDocument.close()
        let fixture = try NotesRoomFixture(items: frameItems("$w", update: update, updateID: "web-1"))
        let session = RoomDocumentSession(documentID: DocsProtocol.mainDocumentID,
                                          room: fixture.room,
                                          store: fixture.store(),
                                          engine: engine,
                                          reachability: fixture.reachability.asCurrentValuePublisher())
        defer { session.close() }
        await waitForState(session) { $0.text == "From the web" && $0.canEdit }
        
        await session.edit(from: "From the web", to: "From the web and iOS")
        await session.flush()
        #expect(session.state.sync == .saved)
        let frame = try #require(fixture.base.sent.first.flatMap { RawEvent(type: $0.type, content: JSONValue(json: $0.content)?.objectValue ?? [:], eventID: "$x", senderID: "@me:x") })
        guard case .frame(_, let sent) = DocsProtocol.parseFrame(frame, anchor: notesAnchor, documentID: DocsProtocol.mainDocumentID), let data = sent.data else {
            Issue.record("The session sent no frame")
            return
        }
        let reader = try await engine.open()
        defer { reader.close() }
        #expect(try await reader.applyAll([update, data]) == 2)
        #expect(try await reader.snapshot().text == "From the web and iOS")
    }
    
    @Test
    func aSessionClosedWhileItLoadsLeavesNoDocumentOpen() async throws {
        let fixture = try NotesRoomFixture(items: [aFrameItem("$f1", content: aFrame(hello, updateID: "u1"))])
        let store = fixture.store()
        defer { store.stop() }
        let session = fixture.session(store: store)
        session.close()
        await waitForSnapshot(store) { $0.isLoaded }
        try? await Task.sleep(for: .milliseconds(200))
        let isEveryDocumentClosed = fixture.engine.documents.allSatisfy(\.isClosed)
        #expect(isEveryDocumentClosed)
    }
    
    @Test
    func aStoppedEngineIsReadAgainWithTheUnsentEditsKept() async throws {
        let fixture = try NotesRoomFixture(items: [aFrameItem("$f1", content: aFrame(hello, updateID: "u1"))])
        fixture.base.sendResult = { _, _ in .failure(.eventNotFound) }
        let session = fixture.session()
        defer { session.close() }
        await waitForState(session) { $0.canEdit }
        await session.edit(from: "Hello", to: "Hello, unsent")
        await session.flush()
        #expect(session.state.error == .sendError)
        
        fixture.engine.stop()
        await eventually { fixture.engine.documents.count == 2 }
        let state = await waitForState(session) { $0.isReady && $0.sync != .loading }
        #expect(state?.text == "Hello, unsent")
        #expect(state?.pendingUpdates == 1)
        #expect(fixture.engine.documents.first?.isClosed == true)
        
        fixture.base.sendResult = { _, _ in .success("$ok") }
        await session.flush()
        #expect(session.state.sync == .saved)
        #expect(fixture.base.sent.count == 1)
    }
    
    @Test
    func anEndedWebContentProcessIsRecoveredWithoutLosingUnsentEdits() async throws {
        let engine = CountingEngine()
        let writerDocument = try await engine.engine.open()
        let update = try #require(try await writerDocument.edit([TextChange(index: 0, remove: 0, insert: "From the web")]))
        writerDocument.close()
        let fixture = try NotesRoomFixture(items: frameItems("$w", update: update, updateID: "web-1"))
        fixture.base.sendResult = { _, _ in .failure(.eventNotFound) }
        let session = RoomDocumentSession(documentID: DocsProtocol.mainDocumentID,
                                          room: fixture.room,
                                          store: fixture.store(),
                                          engine: engine,
                                          reachability: fixture.reachability.asCurrentValuePublisher())
        defer { session.close() }
        await waitForState(session) { $0.text == "From the web" && $0.canEdit }
        await session.edit(from: "From the web", to: "From the web, unsent")
        await session.flush()
        #expect(session.state.pendingUpdates == 1)
        
        // The system ends the engine's web content process, as it may under memory pressure.
        engine.engine.killContentProcessForTesting()
        await eventually { engine.openCount == 2 }
        let state = await waitForState(session) { $0.isReady && $0.sync != .loading }
        #expect(state?.text == "From the web, unsent")
        #expect(state?.canEdit == true)
        
        fixture.base.sendResult = { _, _ in .success("$ok") }
        await session.flush()
        #expect(session.state.sync == .saved)
        let frame = try #require(fixture.base.sent.first.flatMap { RawEvent(type: $0.type, content: JSONValue(json: $0.content)?.objectValue ?? [:], eventID: "$x", senderID: "@me:x") })
        guard case .frame(_, let sent) = DocsProtocol.parseFrame(frame, anchor: notesAnchor, documentID: DocsProtocol.mainDocumentID), let data = sent.data else {
            Issue.record("The session sent no frame")
            return
        }
        let reader = try await engine.engine.open()
        defer { reader.close() }
        #expect(try await reader.applyAll([update, data]) == 2)
        #expect(try await reader.snapshot().text == "From the web, unsent")
    }
    
    @Test
    func aDocumentWaitsForTheAnchorsRelationsEvenWhenTheStoreLoadedBeforeTheRoomStateHeldTheAnchor() async throws {
        let frame = try aMatchaEvent(1, type: MatchaConfig.eventDocsUpdate, content: aFrame(hello, updateID: "u1"), eventID: "$f1")
        let fixture = NotesRoomFixture(createEventID: nil)
        fixture.base.references[notesAnchor] = [frame]
        let store = fixture.store()
        defer { store.stop() }
        await waitForSnapshot(store) { $0.isLoaded }
        fixture.base.createEventID = notesAnchor
        let session = fixture.session(store: store)
        defer { session.close() }
        let state = await waitForState(session) { $0.sync != .loading }
        #expect(state?.isReady == true)
        #expect(state?.text == "Hello")
    }
    
    @Test
    func anUpdateMissingItsPredecessorTurnsEditingOffEvenAfterAFailedSendAndUnsentEditsStillGoOut() async throws {
        let fixture = NotesRoomFixture()
        fixture.base.sendResult = { _, _ in .failure(.eventNotFound) }
        let session = fixture.session()
        defer { session.close() }
        await waitForState(session) { $0.canEdit }
        await session.edit(from: "", to: "Draft")
        await session.flush()
        #expect(session.state.error == .sendError)
        #expect(session.state.canEdit)
        
        let second = FakeYjsEngine.update(FakeYjsEngine.operation("second", text: "After", deps: ["first"]))
        try fixture.items.append(aFrameItem("$second", content: aFrame(second, updateID: "u-second")))
        let incomplete = await waitForState(session) { $0.error == .incompleteUpdate }
        #expect(incomplete?.canEdit == false)
        
        fixture.base.sendResult = { _, _ in .success("$ok") }
        await session.flush()
        // Saving cleared the send error, not the missing update.
        #expect(fixture.base.sent.count == 1)
        #expect(session.state.pendingUpdates == 0)
        #expect(session.state.error == .incompleteUpdate)
        #expect(!session.state.isReady)
        #expect(!session.state.canEdit)
        
        try fixture.items.append(aFrameItem("$first", content: aFrame(FakeYjsEngine.update(FakeYjsEngine.operation("first")), updateID: "u-first")))
        let complete = await waitForState(session) { $0.error == nil }
        #expect(complete?.canEdit == true)
    }
    
    @Test
    func aPartSentAgainWithDifferentBytesIsInvalidAnIdenticalOneIsFine() async throws {
        let big = FakeYjsEngine.update(FakeYjsEngine.operation("big", text: String(repeating: "x", count: MatchaConfig.docsChunkBytes + 1)))
        let frames = try DocsProtocol.frames(update: big, anchor: notesAnchor, updateID: "u-big", documentID: DocsProtocol.mainDocumentID)
        var altered = try #require(JSONValue(json: frames[0])?.objectValue)
        altered["data"] = .string(Data(repeating: 1, count: 10).base64EncodedString())
        let same = NotesRoomFixture(items: [aFrameItem("$a", content: frames[0]), aFrameItem("$b", content: frames[0]),
                                            aFrameItem("$c", content: frames[1]), aFrameItem("$d", content: frames[2])])
        let conflicting = NotesRoomFixture(items: [aFrameItem("$a", content: frames[0]), aFrameItem("$b", content: JSONValue.object(altered).jsonString)])
        let sameSession = same.session()
        let conflictingSession = conflicting.session()
        defer { [sameSession, conflictingSession].forEach { $0.close() } }
        
        let sameState = await waitForState(sameSession) { $0.sync != .loading }
        #expect(sameState?.isReady == true)
        let conflictingState = await waitForState(conflictingSession) { $0.sync != .loading }
        #expect(conflictingState?.error == .invalidUpdate)
    }
    
    @Test
    func theTextIsReadBackFromTheEngineOnlyWhenAnUpdateWasApplied() async throws {
        let fixture = try NotesRoomFixture(items: [aFrameItem("$f1", content: aFrame(hello, updateID: "u1"))])
        let store = fixture.store()
        defer { store.stop() }
        let session = fixture.session(store: store)
        defer { session.close() }
        await waitForState(session) { $0.canEdit }
        await session.edit(from: "Hello", to: "Hello!")
        await session.flush()
        let document = try #require(fixture.engine.documents.first)
        let reads = document.snapshotCount
        let echo = try #require(fixture.base.sent.first)
        
        // The echo of our own frame, a frame of another note and a duplicate are skipped without reading the text back.
        fixture.items += try [aFrameItem("$echo", content: echo.content, sender: matchaUser),
                              aFrameItem("$f2", content: aFrame(FakeYjsEngine.update(FakeYjsEngine.operation("x", text: "Other")), updateID: "u2",
                                                                documentID: DocsProtocol.catalogDocumentID)),
                              aFrameItem("$f3", content: aFrame(hello, updateID: "u1"))]
        await waitForSnapshot(store) { $0.events.contains { $0.eventID == "$f3" } }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(document.snapshotCount == reads)
        #expect(session.state.text == "Hello!")
        
        try fixture.items.append(aFrameItem("$f4", content: aFrame(FakeYjsEngine.update(FakeYjsEngine.operation("b", text: "Hi", deps: ["a"])), updateID: "u4")))
        await waitForState(session) { $0.text == "Hi" }
        #expect(document.snapshotCount == reads + 1)
    }
    
    @Test
    func anEngineThatStopsWhileTheSessionCatchesUpAfterItsReplayIsReadAgain() async throws {
        let fixture = try NotesRoomFixture(items: [aFrameItem("$f1", content: aFrame(hello, updateID: "u1"))])
        let store = fixture.store()
        defer { store.stop() }
        let later = try aFrameItem("$f2", content: aFrame(FakeYjsEngine.update(FakeYjsEngine.operation("b", text: "Hello again", deps: ["a"])), updateID: "u2"))
        var replays = 0
        fixture.engine.beforeApplyAll = { document in
            replays += 1
            if replays == 1 {
                // A frame arrives while the history replays…
                fixture.items.append(later)
                await waitForSnapshot(store) { $0.events.contains { $0.eventID == "$f2" } }
            } else if replays == 2 {
                // …and the engine's web content process ends while the session applies it, before the engine says so.
                document.isStopped = true
            }
        }
        let session = fixture.session(store: store)
        defer { session.close() }
        
        await waitForState(session) { $0.isReady && $0.text == "Hello again" }
        #expect(fixture.engine.documents.count == 2)
    }
    
    @Test
    func anEditTheStoppedEngineMissedIsMadeAgainWhenTheNoteIsReadAgain() async throws {
        let fixture = try NotesRoomFixture(items: [aFrameItem("$f1", content: aFrame(hello, updateID: "u1"))])
        let session = fixture.session()
        defer { session.close() }
        await waitForState(session) { $0.canEdit }
        
        // The engine's web content process ends while a keystroke is on its way into it, before the engine says so.
        fixture.engine.documents.first?.isStopped = true
        await session.edit(from: "Hello", to: "Hello!")
        await waitForState(session) { $0.isReady && $0.text == "Hello!" }
        #expect(fixture.engine.documents.count == 2)
        
        await waitForState(session) { $0.sync == .saved }
        #expect(fixture.base.sent.count == 1)
        let reader = try #require(fixture.engine.documents.last)
        #expect(try await reader.snapshot().text == "Hello!")
    }
    
    // MARK: - Catalog
    
    @Test
    func theCatalogListsNamesKeepsMainFirstAndWritesNamesOnceAcknowledged() async throws {
        let first = aCatalogEntry("c1", documentID: "11111111-1111-4111-8111-111111111111", title: "Plans", createdAt: 5)
        let fixture = try NotesRoomFixture(items: frameItems("$c", update: first, updateID: "c1", documentID: DocsProtocol.catalogDocumentID))
        let session = fixture.session(documentID: DocsProtocol.catalogDocumentID)
        defer { session.close() }
        let catalog = DocumentCatalog(session: session, room: fixture.room, clock: { 42 }, newDocumentID: { "22222222-2222-4222-8222-222222222222" })
        
        let state = await firstValue(of: catalog.statePublisher, timeout: .seconds(10)) { $0.isReady }
        #expect(state?.documents.map(\.id) == ["main", "11111111-1111-4111-8111-111111111111"])
        #expect(state?.documents.map(\.title) == [nil, "Plans"])
        #expect(state?.canEdit == true)
        
        let created = await catalog.create(title: "  Guide ")
        #expect(try created.get() == "22222222-2222-4222-8222-222222222222")
        #expect(catalog.state.documents.last?.title == "Guide")
        #expect(catalog.state.documents.last?.createdAt == 42)
        #expect(fixture.base.sent.first?.content.contains(#""doc":"catalog""#) == true)
        
        let renamed = await catalog.rename(documentID: "main", title: "Notes")
        #expect((try? renamed.get()) != nil)
        #expect(catalog.state.documents.first { $0.id == "main" }?.title == "Notes")
        
        let invalid = await catalog.create(title: " ")
        #expect(invalid == .failure(.init(error: .invalidUpdate)))
    }
    
    @Test
    func aCatalogWithAnInvalidEntryIsNotReadyAndNamesNeedAnEncryptedSpace() async throws {
        let bad = aCatalogEntry("c1", documentID: "not-a-uuid", title: "Plans", createdAt: 5)
        let invalidFixture = try NotesRoomFixture(items: frameItems("$c", update: bad, updateID: "c1", documentID: DocsProtocol.catalogDocumentID))
        let invalidSession = invalidFixture.session(documentID: DocsProtocol.catalogDocumentID)
        let invalid = DocumentCatalog(session: invalidSession, room: invalidFixture.room)
        let plainFixture = NotesRoomFixture(isEncrypted: false)
        let plainSession = plainFixture.session(documentID: DocsProtocol.catalogDocumentID)
        let plain = DocumentCatalog(session: plainSession, room: plainFixture.room)
        defer { [invalidSession, plainSession].forEach { $0.close() } }
        
        let invalidState = await firstValue(of: invalid.statePublisher, timeout: .seconds(10)) { $0.sync != .loading }
        #expect(invalidState?.error == .invalidUpdate)
        #expect(invalidState?.isReady == false)
        let plainState = await firstValue(of: plain.statePublisher, timeout: .seconds(10)) { $0.sync != .loading }
        #expect(plainState?.isReady == true)
        #expect(plainState?.canEdit == false)
        #expect(plainState?.documents.map(\.id) == ["main"])
    }
    
    @Test
    func aNewNoteWhoseSaveFailedKeepsItsEntrySoARetryRenamesIt() async {
        let fixture = NotesRoomFixture()
        fixture.base.sendResult = { _, _ in .failure(.eventNotFound) }
        let session = fixture.session(documentID: DocsProtocol.catalogDocumentID)
        defer { session.close() }
        let newDocumentID = { "44444444-4444-4444-8444-444444444444" }
        let catalog = DocumentCatalog(session: session, room: fixture.room, newDocumentID: newDocumentID)
        _ = await firstValue(of: catalog.statePublisher, timeout: .seconds(10)) { $0.canEdit }
        
        let created = await catalog.create(title: "Trip")
        #expect(created == .failure(.init(error: .sendError, documentID: "44444444-4444-4444-8444-444444444444")))
        
        fixture.base.sendResult = { _, _ in .success("$ok") }
        let renamed = await catalog.rename(documentID: "44444444-4444-4444-8444-444444444444", title: "Trip")
        #expect((try? renamed.get()) != nil)
        #expect(catalog.state.documents.map(\.title) == [nil, "Trip"])
    }
}

/// The bundled engine, counting the documents opened through it.
private final class CountingEngine: YjsEngineProtocol {
    let engine = WebViewYjsEngine()
    private(set) var openCount = 0
    
    var stoppedPublisher: AnyPublisher<Void, Never> {
        engine.stoppedPublisher
    }
    
    func open() async throws(YjsEngineError) -> YjsDocumentProtocol {
        openCount += 1
        return try await engine.open()
    }
}
