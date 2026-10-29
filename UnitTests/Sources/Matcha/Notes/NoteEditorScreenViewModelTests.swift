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
final class NoteEditorScreenViewModelTests {
    private let plans = "11111111-1111-4111-8111-111111111111"
    private var closeCount = 0
    private var viewModel: NoteEditorScreenViewModel?
    private var cancellables = Set<AnyCancellable>()
    
    @Test
    func aNoteLoadsIntoThePreviewWithItsNameAndIsSaved() async throws {
        let context = try editor(NotesRoomFixture(items: items()))
        #expect(context.viewState.status == .loading)
        await eventually { context.viewState.status == .saved }
        #expect(context.viewState.title == "Plans")
        #expect(context.viewState.text == "Hello")
        await eventually { context.viewState.blocks == [.paragraph("Hello")] }
        #expect(context.viewState.canEdit)
        #expect(context.viewState.canRename)
        #expect(!context.viewState.isEditing)
        #expect(context.viewState.notice == nil)
        #expect(!context.viewState.isLoadError)
    }
    
    @Test
    func editsAreTypedInEditModeAndSavedAfterTheDebounce() async throws {
        let fixture = try NotesRoomFixture(items: items())
        let context = editor(fixture)
        await eventually { context.viewState.canEdit }
        context.send(viewAction: .startEditing)
        #expect(context.viewState.isEditing)
        
        context.send(viewAction: .edit(before: "Hello", after: "Hello world"))
        await eventually { context.viewState.status == .saving }
        #expect(context.viewState.text == "Hello world")
        #expect(context.viewState.hasUnsavedChanges)
        await eventually { context.viewState.status == .saved && !context.viewState.hasUnsavedChanges }
        #expect(fixture.base.sent.count == 1)
        
        context.send(viewAction: .stopEditing)
        #expect(!context.viewState.isEditing)
        #expect(context.viewState.text == "Hello world")
        context.send(viewAction: .back)
        #expect(closeCount == 1)
    }
    
    @Test
    func backInEditModeReturnsToThePreviewAndLeavingWithUnsentEditsAsksFirst() async throws {
        let fixture = try NotesRoomFixture(items: items())
        fixture.base.sendResult = { _, _ in .failure(.eventNotFound) }
        let context = editor(fixture)
        await eventually { context.viewState.canEdit }
        context.send(viewAction: .startEditing)
        context.send(viewAction: .edit(before: "Hello", after: "Hello!"))
        await eventually { context.viewState.status == .failed }
        #expect(context.viewState.isEditing)
        
        context.send(viewAction: .back)
        #expect(!context.viewState.isEditing)
        context.send(viewAction: .back)
        await eventually { context.viewState.bindings.isShowingLeaveAlert }
        #expect(closeCount == 0)
        // Stay.
        context.isShowingLeaveAlert = false
        context.send(viewAction: .back)
        await eventually { context.viewState.bindings.isShowingLeaveAlert }
        context.send(viewAction: .confirmLeave)
        #expect(!context.viewState.bindings.isShowingLeaveAlert)
        #expect(closeCount == 1)
    }
    
    @Test
    func aFailedSaveSaysSoOfflineSaysThatInsteadAndRetrySendsAgain() async throws {
        let fixture = try NotesRoomFixture(items: items())
        fixture.base.sendResult = { _, _ in .failure(.eventNotFound) }
        let context = editor(fixture)
        await eventually { context.viewState.canEdit }
        context.send(viewAction: .edit(before: "Hello", after: "Hello!"))
        await eventually { context.viewState.status == .failed }
        
        fixture.reachability.send(.unreachable)
        await eventually { context.viewState.status == .offline }
        #expect(context.viewState.notice == .offline)
        
        fixture.base.sendResult = { _, _ in .success("$ok") }
        context.send(viewAction: .retry)
        await eventually { context.viewState.status == .saved && !context.viewState.hasUnsavedChanges }
        #expect(context.viewState.text == "Hello!")
    }
    
    @Test
    func withoutTheRightToWriteTheNoteIsViewOnly() async throws {
        let context = try editor(NotesRoomFixture(items: items(), canSend: false))
        await eventually { context.viewState.status == .viewOnly }
        #expect(!context.viewState.canEdit)
        #expect(!context.viewState.canRename)
        context.send(viewAction: .startEditing)
        context.send(viewAction: .rename)
        #expect(!context.viewState.isEditing)
        #expect(context.viewState.bindings.nameSheet == nil)
    }
    
    @Test
    func theEarlierChatDocumentIsViewOnlyAndNamedAfterTheChat() async throws {
        let old = try aFrameItem("$t1", content: aFrame(FakeYjsEngine.update(FakeYjsEngine.operation("t", text: "Old notes")), updateID: "t1"))
        let fixture = NotesRoomFixture(items: [old], roomID: "!chat:x", isSpace: false)
        fixture.updateInfo { $0.displayName = "Weekend trip" }
        let context = editor(fixture, documentID: DocsProtocol.mainDocumentID, isEarlierChatDocument: true)
        await eventually { context.viewState.status == .earlierChat }
        #expect(context.viewState.title == "Weekend trip")
        #expect(context.viewState.text == "Old notes")
        #expect(!context.viewState.canEdit)
        #expect(!context.viewState.canRename)
    }
    
    @Test
    func undecryptableEditsTurnEditingOffWithANotice() async throws {
        let encrypted = aFrameItem("$enc",
                                   content: #"{"algorithm": "m.megolm.v1.aes-sha2", "ciphertext": "…", "m.relates_to": \#(notesRelation)}"#,
                                   type: "m.room.encrypted")
        let context = try editor(NotesRoomFixture(items: items(encrypted)))
        await eventually { context.viewState.notice == .decryptError }
        #expect(context.viewState.status == .viewOnly)
        #expect(!context.viewState.canEdit)
    }
    
    @Test
    func aNoteMissingFromTheCatalogCantBeLoaded() async throws {
        let context = try editor(NotesRoomFixture(items: items()), documentID: "99999999-9999-4999-8999-999999999999")
        await eventually { context.viewState.isLoadError }
        #expect(context.viewState.title == "")
    }
    
    @Test
    func aRoomWithoutAnAnchorCantBeLoaded() async {
        let context = editor(NotesRoomFixture(createEventID: nil), documentID: DocsProtocol.mainDocumentID)
        await eventually { context.viewState.isLoadError }
        #expect(context.viewState.title == nil)
    }
    
    @Test
    func renamingKeepsTheSheetOpenUntilTheNameIsSaved() async throws {
        let context = try editor(NotesRoomFixture(items: items()))
        await eventually { context.viewState.canRename }
        context.send(viewAction: .rename)
        #expect(context.viewState.bindings.nameSheet?.name == "Plans")
        context.send(viewAction: .updateName(""))
        context.send(viewAction: .submitName)
        #expect(context.viewState.bindings.nameSheet?.error == .empty)
        
        context.send(viewAction: .updateName("Plans 2027"))
        context.send(viewAction: .submitName)
        #expect(context.viewState.bindings.nameSheet?.isSaving == true)
        await eventually { context.viewState.bindings.nameSheet == nil && context.viewState.title == "Plans 2027" }
        
        context.send(viewAction: .rename)
        #expect(context.viewState.bindings.nameSheet != nil)
        context.send(viewAction: .dismissNameSheet)
        #expect(context.viewState.bindings.nameSheet == nil)
    }
    
    @Test
    func aRenameThatCantBeSavedKeepsTheSheetOpenWithTheError() async throws {
        let fixture = try NotesRoomFixture(items: items())
        let context = editor(fixture)
        await eventually { context.viewState.canRename }
        fixture.base.sendResult = { _, _ in .failure(.eventNotFound) }
        context.send(viewAction: .rename)
        context.send(viewAction: .updateName("Plans 2027"))
        context.send(viewAction: .submitName)
        await eventually { context.viewState.bindings.nameSheet?.error == .saveFailed }
        #expect(context.viewState.bindings.nameSheet?.isSaving == false)
        #expect(context.viewState.bindings.nameSheet?.name == "Plans 2027")
    }
    
    @Test
    func aRenameDismissedWhileItSavesStillSavesAndItsSheetComesBackIfItFails() async throws {
        let fixture = try NotesRoomFixture(items: items())
        let context = editor(fixture)
        await eventually { context.viewState.canRename }
        fixture.base.sendResult = { _, _ in .failure(.eventNotFound) }
        context.send(viewAction: .rename)
        context.send(viewAction: .updateName("Plans 2027"))
        context.send(viewAction: .submitName)
        context.send(viewAction: .dismissNameSheet)
        #expect(context.viewState.bindings.nameSheet == nil)
        await eventually { context.viewState.bindings.nameSheet?.error == .saveFailed }
        
        fixture.base.sendResult = { _, _ in .success("$ok") }
        context.send(viewAction: .submitName)
        context.send(viewAction: .dismissNameSheet)
        await eventually { context.viewState.title == "Plans 2027" && !context.viewState.hasUnsavedChanges }
        #expect(context.viewState.bindings.nameSheet == nil)
    }
    
    // MARK: - Helpers
    
    private func items(_ extra: TimelineItemProxy...) throws -> [TimelineItemProxy] {
        try frameItems("$c1", update: aCatalogEntry("c1", documentID: plans, title: "Plans"), updateID: "c1", documentID: DocsProtocol.catalogDocumentID)
            + [aFrameItem("$t1", content: aFrame(FakeYjsEngine.update(FakeYjsEngine.operation("t", text: "Hello")), updateID: "t1", documentID: plans))]
            + extra
    }
    
    private func editor(_ fixture: NotesRoomFixture, documentID: String? = nil, isEarlierChatDocument: Bool = false) -> NoteEditorScreenViewModel.Context {
        fixture.turnNotesOn()
        let viewModel = NoteEditorScreenViewModel(notesContext: fixture.context(isEarlierChatDocument: isEarlierChatDocument), documentID: documentID ?? plans)
        viewModel.actionsPublisher
            .sink { [weak self] action in
                switch action {
                case .close:
                    self?.closeCount += 1
                }
            }
            .store(in: &cancellables)
        self.viewModel = viewModel
        return viewModel.context
    }
}
