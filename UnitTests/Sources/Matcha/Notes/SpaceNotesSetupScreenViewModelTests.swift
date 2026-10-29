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
final class SpaceNotesSetupScreenViewModelTests {
    private let powerLevels = #"{"users": {"@admin:x": 100}, "events_default": 50, "events": {"m.room.name": 50}}"#
    private let encryption = #"{"algorithm": "m.megolm.v1.aes-sha2"}"#
    private var actions: [SpaceNotesSetupScreenViewModelAction] = []
    private var viewModel: SpaceNotesSetupScreenViewModel?
    private var cancellables = Set<AnyCancellable>()
    
    @Test
    func turningNotesOnAsksToTurnOnEncryptionFirstThenSetsOnlyTheTwoPowerLevels() async throws {
        let fixture = aSpace(isEncrypted: false)
        #expect(await SpaceNotesSetup(room: fixture.room).status() == SpaceNotesStatus(isConfigured: false, canSetUp: true, isEncrypted: false))
        let context = setupScreen(fixture)
        
        context.send(viewAction: .turnOn)
        await eventually { context.viewState.bindings.isConfirmingEncryption }
        context.send(viewAction: .confirmEncryption)
        await eventually { actions == [.done] }
        #expect(!context.viewState.isWorking)
        
        let sent = try #require(fixture.sentState.first)
        #expect(fixture.sentState.count == 1)
        #expect(sent.type == "m.room.power_levels")
        let content = try #require(JSONValue(json: sent.content)?.objectValue)
        #expect(content.integer("events_default") == 50)
        #expect(content.object("users") == ["@admin:x": .integer(100)])
        let events = try #require(content.object("events"))
        #expect(events.integer("m.room.name") == 50)
        #expect(events.integer(MatchaConfig.eventDocsUpdate) == 0)
        #expect(events.integer("m.room.encrypted") == 0)
        #expect(await SpaceNotesSetup(room: fixture.room).status().isConfigured)
    }
    
    @Test
    func anEncryptedSpaceGoesStraightToThePowerLevelsAndTheAlertCanBeDismissed() async {
        let encrypted = aSpace(isEncrypted: true)
        let context = setupScreen(encrypted)
        context.send(viewAction: .turnOn)
        await eventually { actions == [.done] }
        #expect(!context.viewState.bindings.isConfirmingEncryption)
        #expect(encrypted.sentState.count == 1)
        
        let plain = aSpace(isEncrypted: false)
        let plainContext = setupScreen(plain)
        plainContext.send(viewAction: .turnOn)
        await eventually { plainContext.viewState.bindings.isConfirmingEncryption }
        // Cancel.
        plainContext.isConfirmingEncryption = false
        #expect(!plainContext.viewState.isWorking)
        #expect(plain.sentState.isEmpty)
    }
    
    @Test
    func powerLevelsThatSyncLateStillFinishTheSetup() async {
        let fixture = aSpace(isEncrypted: true)
        fixture.room.sendRawStateEventTypeStateKeyContentJSONClosure = { [fixture] type, _, content in
            Task {
                try? await Task.sleep(for: .seconds(1))
                fixture.stateEvents[type] = content
            }
            return .success("$pl")
        }
        #expect(await SpaceNotesSetup(room: fixture.room).turnOn().isSuccess)
    }
    
    @Test
    func aFailureIsShownAboveTheButton() async {
        let fixture = aSpace(isEncrypted: false)
        fixture.enableEncryptionResult = .failure(.eventNotFound)
        let context = setupScreen(fixture)
        context.send(viewAction: .turnOn)
        await eventually { context.viewState.bindings.isConfirmingEncryption }
        context.send(viewAction: .confirmEncryption)
        await eventually { context.viewState.hasFailed && !context.viewState.isWorking }
        #expect(actions.isEmpty)
        #expect(fixture.sentState.isEmpty)
    }
    
    @Test
    func aChatIsNeverSetUpAsASpace() async {
        let fixture = NotesRoomFixture(isSpace: false, canSendState: true)
        fixture.turnNotesOn()
        let setup = SpaceNotesSetup(room: fixture.room)
        #expect(await setup.status() == SpaceNotesStatus(isConfigured: false, canSetUp: false, isEncrypted: true))
        #expect(await !(setup.turnOn().isSuccess))
        #expect(fixture.sentState.isEmpty)
    }
    
    @Test
    func aMemberCantSetNotesUp() async {
        let fixture = NotesRoomFixture()
        fixture.stateEvents[DocsProtocol.eventPowerLevels] = powerLevels
        let setup = SpaceNotesSetup(room: fixture.room)
        #expect(await !setup.status().canSetUp)
        #expect(await !(setup.turnOn().isSuccess))
        #expect(fixture.sentState.isEmpty)
    }
    
    @Test
    func aSpacesNotesOpenOnlyInASpaceWhileAChatsEarlierDocumentOpensInTheChat() async {
        let space = NotesRoomFixture()
        let chat = NotesRoomFixture(roomID: "!chat:x", isSpace: false)
        let client = ClientProxyMock(.init())
        client.roomForIdentifierClosure = { roomID in
            [space, chat].first { $0.room.id == roomID }.map { .joined($0.room) }
        }
        let factory = SpaceNotesContextFactory(clientProxy: client, engine: FakeYjsEngine())
        
        let spaceNotes = await factory.makeContext(roomID: space.room.id)
        #expect(spaceNotes?.isEarlierChatDocument == false)
        #expect(await factory.makeContext(roomID: chat.room.id) == nil)
        let earlier = await factory.makeContext(roomID: chat.room.id, isEarlierChatDocument: true)
        #expect(earlier?.isEarlierChatDocument == true)
        spaceNotes?.close()
        earlier?.close()
    }
    
    // MARK: - Helpers
    
    /// A space an admin can set up, whose writes sync back at once as its state.
    private func aSpace(isEncrypted: Bool) -> NotesRoomFixture {
        let fixture = NotesRoomFixture(isEncrypted: isEncrypted, canSendState: true)
        fixture.stateEvents[DocsProtocol.eventPowerLevels] = powerLevels
        if isEncrypted {
            fixture.stateEvents["m.room.encryption"] = encryption
        }
        return fixture
    }
    
    private func setupScreen(_ fixture: NotesRoomFixture) -> SpaceNotesSetupScreenViewModel.Context {
        let viewModel = SpaceNotesSetupScreenViewModel(room: fixture.room)
        viewModel.actionsPublisher
            .sink { [weak self] in self?.actions.append($0) }
            .store(in: &cancellables)
        self.viewModel = viewModel
        return viewModel.context
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self {
            return true
        }
        return false
    }
}
