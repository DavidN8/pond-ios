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
final class SpaceNotesListScreenViewModelTests {
    private let plans = "11111111-1111-4111-8111-111111111111"
    private let guide = "22222222-2222-4222-8222-222222222222"
    private var actions: [SpaceNotesListScreenViewModelAction] = []
    private var viewModel: SpaceNotesListScreenViewModel?
    private var cancellables = Set<AnyCancellable>()
    
    @Test
    func notesNotTurnedOnShowTheAdminTipOrTheMemberLine() async {
        let admin = list(NotesRoomFixture(canSendState: true))
        await eventually { admin.viewState.content == .notSetUp(canSetUp: true) }
        #expect(!admin.viewState.canCreate)
        admin.send(viewAction: .openSetup)
        #expect(actions == [.openSetup])
        
        let member = list(NotesRoomFixture())
        await eventually { member.viewState.content == .notSetUp(canSetUp: false) }
    }
    
    @Test
    func spaceNotesComeFirstThenTheNotesByLastEdit() async throws {
        let edit = try aFrame(FakeYjsEngine.update(FakeYjsEngine.operation("e")), updateID: "e1", documentID: plans)
        let fixture = try NotesRoomFixture(items: catalogItems() + [aFrameItem("$edit", content: edit, timestamp: 50)])
        fixture.turnNotesOn()
        let context = list(fixture)
        await eventually { context.rows?.count == 3 }
        let rows = try #require(context.rows)
        #expect(rows.map(\.id) == ["main", plans, guide])
        #expect(rows.map(\.title) == [nil, "Plans", "Guide"])
        #expect(rows.first?.editedAt == nil)
        #expect(rows.allSatisfy { $0.id == "main" || $0.editedAt != nil })
        #expect(context.viewState.canCreate)
        #expect(context.viewState.spaceName == "Matcha team")
        
        context.send(viewAction: .openNote(documentID: guide))
        #expect(actions == [.openNote(documentID: guide)])
    }
    
    @Test
    func aNewNoteNeedsANameIsSavedThenOpens() async {
        let fixture = NotesRoomFixture()
        fixture.turnNotesOn()
        let context = list(fixture)
        await eventually { context.viewState.canCreate }
        
        context.send(viewAction: .newNote)
        #expect(context.viewState.bindings.nameSheet?.documentID == nil)
        context.send(viewAction: .submitName)
        #expect(context.viewState.bindings.nameSheet?.error == .empty)
        context.send(viewAction: .updateName(String(repeating: "A", count: 101)))
        #expect(context.viewState.bindings.nameSheet?.error == .tooLong)
        context.send(viewAction: .updateName("Trip plans"))
        #expect(context.viewState.bindings.nameSheet?.error == nil)
        context.send(viewAction: .submitName)
        
        await eventually { !actions.isEmpty }
        #expect(context.viewState.bindings.nameSheet == nil)
        #expect(actions == [.openNote(documentID: "33333333-3333-4333-8333-333333333333")])
        #expect(fixture.base.sent.map { JSONValue(json: $0.content)?.objectValue?.string("doc") } == [DocsProtocol.catalogDocumentID])
    }
    
    @Test
    func aFailedSaveKeepsTheSheetOpenAndRetriesTheSameNote() async {
        let fixture = NotesRoomFixture()
        fixture.turnNotesOn()
        fixture.base.sendResult = { _, _ in .failure(.eventNotFound) }
        var ids = 0
        let context = list(fixture) {
            defer { ids += 1 }
            return "4444444\(ids)-4444-4444-8444-444444444444"
        }
        await eventually { context.viewState.canCreate }
        context.send(viewAction: .newNote)
        context.send(viewAction: .updateName("Trip plans"))
        context.send(viewAction: .submitName)
        await eventually { context.viewState.bindings.nameSheet?.error == .saveFailed }
        #expect(context.viewState.bindings.nameSheet?.unsavedDocumentID == "44444440-4444-4444-8444-444444444444")
        
        fixture.base.sendResult = { _, _ in .success("$ok") }
        context.send(viewAction: .submitName)
        await eventually { !actions.isEmpty }
        #expect(context.viewState.bindings.nameSheet == nil)
        #expect(actions == [.openNote(documentID: "44444440-4444-4444-8444-444444444444")])
        #expect(ids == 1)
    }
    
    @Test
    func aNewNoteWhoseSheetIsDismissedWhileItSavesStillOpensOnceSaved() async {
        let fixture = NotesRoomFixture()
        fixture.turnNotesOn()
        let context = list(fixture)
        await eventually { context.viewState.canCreate }
        context.send(viewAction: .newNote)
        context.send(viewAction: .updateName("Trip plans"))
        context.send(viewAction: .submitName)
        context.send(viewAction: .dismissNameSheet)
        #expect(context.viewState.bindings.nameSheet == nil)
        // New note shows the sheet still saving rather than starting another.
        context.send(viewAction: .newNote)
        #expect(context.viewState.bindings.nameSheet?.isSaving == true)
        context.send(viewAction: .dismissNameSheet)
        
        await eventually { !actions.isEmpty }
        #expect(actions == [.openNote(documentID: "33333333-3333-4333-8333-333333333333")])
        #expect(fixture.base.sent.count == 1)
    }
    
    @Test
    func aRenameStartsFromTheCurrentName() async throws {
        let fixture = try NotesRoomFixture(items: catalogItems())
        fixture.turnNotesOn()
        let context = list(fixture)
        await eventually { context.viewState.canCreate && context.rows?.count == 3 }
        
        context.send(viewAction: .rename(documentID: plans))
        #expect(context.viewState.bindings.nameSheet?.documentID == plans)
        #expect(context.viewState.bindings.nameSheet?.name == "Plans")
        context.send(viewAction: .updateName("Plans 2027"))
        context.send(viewAction: .submitName)
        await eventually { context.viewState.bindings.nameSheet == nil }
        #expect(actions.isEmpty)
        #expect(fixture.base.sent.count == 1)
        await eventually { context.rows?.contains { $0.title == "Plans 2027" } == true }
    }
    
    @Test
    func anUnreadableCatalogShowsTheNoticeABrokenOneTheErrorPage() async {
        let encrypted = aFrameItem("$enc",
                                   content: #"{"algorithm": "m.megolm.v1.aes-sha2", "ciphertext": "…", "m.relates_to": \#(notesRelation)}"#,
                                   type: "m.room.encrypted")
        let unreadable = NotesRoomFixture(items: [encrypted])
        unreadable.turnNotesOn()
        let context = list(unreadable)
        await eventually { context.viewState.hasUnreadableNames }
        #expect(!context.viewState.canCreate)
        #expect(context.rows?.map(\.id) == ["main"])
        
        let broken = NotesRoomFixture(createEventID: nil)
        broken.turnNotesOn()
        let brokenContext = list(broken)
        await eventually { brokenContext.viewState.content == .loadError }
        #expect(!brokenContext.viewState.canCreate)
        brokenContext.send(viewAction: .retry)
    }
    
    @Test
    func aSetupCheckThatAnswersLateNeverHidesNotesTurnedOnSince() async {
        let fixture = NotesRoomFixture()
        let gate = Gate()
        var holdsNextRead = false
        var isHolding = false
        fixture.room.stateEventsJSONTypeClosure = { [fixture] type in
            let content = fixture.stateEvents[type].map { ["": $0] } ?? [:]
            // A slow check answers with the state as it was when it started.
            if type == "m.room.encryption", holdsNextRead {
                holdsNextRead = false
                isHolding = true
                await gate.wait()
            }
            return .success(content)
        }
        let context = list(fixture)
        await eventually { context.viewState.content == .notSetUp(canSetUp: false) }
        holdsNextRead = true
        context.send(viewAction: .appeared)
        await eventually { isHolding }
        
        // Notes are turned on elsewhere, which the room info says.
        fixture.turnNotesOn()
        fixture.updateInfo { _ in }
        await eventually { context.viewState.content != .notSetUp(canSetUp: false) }
        gate.open()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(context.viewState.content != .notSetUp(canSetUp: false))
    }
    
    // MARK: - Helpers
    
    private func catalogItems() throws -> [TimelineItemProxy] {
        try frameItems("$c1", update: aCatalogEntry("c1", documentID: plans, title: "Plans", createdAt: 5), updateID: "c1", documentID: DocsProtocol.catalogDocumentID)
            + frameItems("$c2", update: aCatalogEntry("c2", documentID: guide, title: "Guide", createdAt: 6), updateID: "c2", documentID: DocsProtocol.catalogDocumentID)
    }
    
    private func list(_ fixture: NotesRoomFixture, newDocumentID: (() -> String)? = nil) -> SpaceNotesListScreenViewModel.Context {
        let notesContext = if let newDocumentID {
            fixture.context(newDocumentID: newDocumentID)
        } else {
            fixture.context()
        }
        let viewModel = SpaceNotesListScreenViewModel(notesContext: notesContext)
        viewModel.actionsPublisher
            .sink { [weak self] in self?.actions.append($0) }
            .store(in: &cancellables)
        self.viewModel = viewModel
        viewModel.context.send(viewAction: .appeared)
        return viewModel.context
    }
}

private extension SpaceNotesListScreenViewModel.Context {
    var rows: [NoteRowItem]? {
        guard case .notes(let rows) = viewState.content else { return nil }
        return rows
    }
}
