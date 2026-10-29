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
import MatrixRustSDK
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NotesTabScreenViewModelTests {
    private let design = "!design:x"
    private let launch = "!launch:x"
    private let company = "!company:x"
    private let research = "!research:x"
    private let lab = "!lab:x"
    private let drafts = "!drafts:x"
    private let plans = "11111111-1111-4111-8111-111111111111"
    private let guide = "22222222-2222-4222-8222-222222222222"
    
    @Test
    func everySpaceWithNotesListsThemAndASpaceWhereTheUserCanTurnThemOnOffersIt() async throws {
        let edit = try aFrame(FakeYjsEngine.update(FakeYjsEngine.operation("e")), updateID: "e1", documentID: plans)
        let designSpace = try aNotesSpace(design, items: catalogItems() + [aFrameItem("$edit", content: edit, timestamp: 50)])
        let canTurnOn = NotesRoomFixture(roomID: company, canSendState: true)
        let cannotTurnOn = NotesRoomFixture(roomID: launch)
        let tab = Tab([canTurnOn, designSpace, cannotTurnOn])
        tab.viewModel.context.send(viewAction: .appeared)
        
        await eventually { tab.sections.count == 2 }
        // In the Spaces list's order.
        #expect(tab.sections.map(\.space.id) == [company, design])
        #expect(tab.sections.first?.content == .turnOn)
        // Nothing is read before it is on screen.
        #expect(tab.sections.last?.content == .loading)
        #expect(tab.engine.documents.isEmpty)
        
        tab.show([company, design])
        await eventually { tab.notes(design)?.count == 3 }
        let notes = try #require(tab.notes(design))
        #expect(notes.map(\.id) == ["main", plans, guide])
        #expect(notes.map(\.title) == [nil, "Plans", "Guide"])
        #expect(notes.first?.editedAt == nil)
        #expect(tab.viewModel.context.viewState.canCreate)
        
        tab.viewModel.context.send(viewAction: .openNote(spaceID: design, documentID: plans))
        tab.viewModel.context.send(viewAction: .openNote(spaceID: company, documentID: nil))
        #expect(tab.opened == [.openNote(spaceID: design, documentID: plans), .openNote(spaceID: company, documentID: nil)])
    }
    
    @Test
    func whetherASpaceHasNotesIsReadWithoutOpeningIt() async {
        let tab = Tab([aNotesSpace(design)])
        tab.viewModel.context.send(viewAction: .appeared)
        await eventually { tab.sections.count == 1 }
        #expect(tab.sections.first?.content == .loading)
        #expect(tab.client.roomInfoRoomIDCallsCount == 1)
        #expect(tab.client.roomForIdentifierCallsCount == 0)
    }
    
    @Test
    func withoutASpaceOrWithoutASpaceWithNotesTheTabSaysWhereNotesLive() async {
        let none = Tab([])
        none.viewModel.context.send(viewAction: .appeared)
        await eventually { none.viewModel.context.viewState.content == .empty(hasSpaces: false) }
        
        let off = Tab([NotesRoomFixture(roomID: launch)])
        off.viewModel.context.send(viewAction: .appeared)
        await eventually { off.viewModel.context.viewState.content == .empty(hasSpaces: true) }
        #expect(!off.viewModel.context.viewState.canCreate)
    }
    
    @Test
    func aSpaceWhoseNotesCantBeReadShowsRetryWithoutHoldingUpTheOthers() async {
        let invalidFrame = #"{"doc": "catalog", "version": 2, "m.relates_to": \#(notesRelation)}"#
        let broken = aNotesSpace(design, items: [aFrameItem("$bad", content: invalidFrame)])
        let tab = Tab([broken, aNotesSpace(launch)])
        tab.viewModel.context.send(viewAction: .appeared)
        await eventually { tab.sections.count == 2 }
        tab.show([design, launch])
        
        await eventually { tab.sections.first?.content == .loadError && tab.notes(launch) != nil }
        // The broken catalog is closed; the other stays open while it is on screen.
        await eventually { tab.engine.documents.filter(\.isClosed).count == 1 }
        #expect(tab.engine.documents.count == 2)
        
        tab.viewModel.context.send(viewAction: .retry(spaceID: design))
        await eventually { tab.engine.documents.count == 3 && tab.engine.documents.filter(\.isClosed).count == 2 }
        #expect(tab.sections.first?.content == .loadError)
    }
    
    @Test
    func notesAreReadOnlyWhileTheirSpaceIsOnScreenAndWhatWasReadStays() async throws {
        let tab = try Tab([aNotesSpace(design, items: catalogItems())])
        tab.viewModel.context.send(viewAction: .appeared)
        await eventually { tab.sections.count == 1 }
        tab.show([design])
        await eventually { tab.notes(design)?.count == 3 }
        #expect(tab.engine.documents.first?.isClosed == false)
        
        tab.hide([design])
        await eventually { tab.engine.documents.first?.isClosed == true }
        // The notes read stay listed: closing the catalog changes nothing on screen.
        #expect(tab.notes(design)?.count == 3)
        
        tab.show([design])
        await eventually { tab.engine.documents.count == 2 }
        
        // Leaving the tab closes everything.
        tab.viewModel.context.send(viewAction: .disappeared)
        await eventually { tab.engine.documents.allSatisfy(\.isClosed) }
        #expect(tab.notes(design)?.count == 3)
        
        // Back from a note pushed above the tab, whose rows may not appear again: the space on screen is read again.
        tab.viewModel.context.send(viewAction: .appeared)
        await eventually { tab.engine.documents.count == 3 }
    }
    
    @Test
    func aRowReportedOnScreenTwiceIsOffScreenOnceItGoes() async throws {
        let tab = try Tab([aNotesSpace(design, items: catalogItems())])
        tab.viewModel.context.send(viewAction: .appeared)
        await eventually { tab.sections.count == 1 }
        // SwiftUI can report a row's appearance again without its disappearance in between.
        tab.viewModel.context.send(viewAction: .rowAppeared(spaceID: design, rowID: "header"))
        tab.viewModel.context.send(viewAction: .rowAppeared(spaceID: design, rowID: "header"))
        await eventually { tab.notes(design)?.count == 3 }
        
        tab.viewModel.context.send(viewAction: .rowDisappeared(spaceID: design, rowID: "header"))
        await eventually { tab.engine.documents.first?.isClosed == true }
    }
    
    @Test
    func theTabSaysThereAreNoSpacesOnlyOnceTheRoomListHasLoaded() async {
        let roomListState = CurrentValueSubject<RoomSummaryProviderState, Never>(.notLoaded)
        let tab = Tab([], roomListState: roomListState)
        tab.viewModel.context.send(viewAction: .appeared)
        // The space filters start empty before the space service has listed anything.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(tab.viewModel.context.viewState.content == .loading)
        
        roomListState.send(.loaded(totalNumberOfRooms: 0))
        await eventually { tab.viewModel.context.viewState.content == .empty(hasSpaces: false) }
    }
    
    @Test
    func withOneSpaceThatCanTakeANoteNewNoteAsksForItsNameCreatesItThereAndOpensIt() async throws {
        let space = aNotesSpace(design)
        let tab = Tab([space, NotesRoomFixture(roomID: company, canSendState: true)])
        tab.viewModel.context.send(viewAction: .appeared)
        await eventually { tab.viewModel.context.viewState.canCreate && tab.sections.count == 2 }
        
        tab.viewModel.context.send(viewAction: .newNote)
        #expect(tab.nameSheet == .new())
        tab.viewModel.context.send(viewAction: .submitName)
        #expect(tab.nameSheet?.error == .empty)
        tab.viewModel.context.send(viewAction: .updateName("Trip plans"))
        tab.viewModel.context.send(viewAction: .submitName)
        await eventually { tab.viewModel.context.viewState.bindings.sheet == nil }
        
        await eventually { !tab.opened.isEmpty }
        guard case .openNote(let spaceID, let documentID) = try #require(tab.opened.first) else { return }
        #expect(spaceID == design)
        #expect(DocsProtocol.isDocumentID(documentID ?? ""))
        #expect(space.base.sent.map { JSONValue(json: $0.content)?.objectValue?.string("doc") } == [DocsProtocol.catalogDocumentID])
        await eventually { tab.engine.documents.first?.isClosed == true }
    }
    
    @Test
    func withSeveralSpacesThatCanTakeANoteNewNoteAsksForTheSpaceFirst() async {
        let tab = Tab([aNotesSpace(design), aNotesSpace(launch)])
        tab.viewModel.context.send(viewAction: .appeared)
        await eventually { tab.sections.count == 2 }
        
        tab.viewModel.context.send(viewAction: .newNote)
        guard case .chooseSpace(let spaces) = tab.viewModel.context.viewState.bindings.sheet else {
            Issue.record("Choose a space is not shown")
            return
        }
        #expect(spaces.map(\.id) == [design, launch])
        tab.viewModel.context.send(viewAction: .chooseSpace(spaceID: launch))
        #expect(tab.nameSheet == .new())
        tab.viewModel.context.send(viewAction: .dismissSheet)
        #expect(tab.viewModel.context.viewState.bindings.sheet == nil)
        // Every document the sheet's catalog opened, if it got that far, is closed.
        try? await Task.sleep(for: .milliseconds(300))
        let isEveryDocumentClosed = tab.engine.documents.allSatisfy(\.isClosed)
        #expect(isEveryDocumentClosed)
        #expect(tab.opened.isEmpty)
    }
    
    @Test
    func eachSpaceIsFollowedByItsJoinedSubspacesAndASubspaceOfTwoSpacesIsListedOnce() async {
        let spaces = [design, research, drafts, launch, lab].map { aNotesSpace($0) }
        let filters = [aFilter(design),
                       aFilter(research, level: 1),
                       // A subspace the user was only invited to.
                       aFilter(drafts, level: 1, state: .invited),
                       aFilter(launch),
                       // Research is also a subspace of Launch.
                       aFilter(research, level: 1),
                       aFilter(lab, level: 1)]
        let tab = Tab(spaces, filters: filters)
        tab.viewModel.context.send(viewAction: .appeared)
        await eventually { tab.sections.count == 4 }
        #expect(tab.sections.map(\.space.id) == [design, research, launch, lab])
        #expect(tab.sections.map(\.space.parentName) == [nil, "design", nil, "launch"])
        
        tab.viewModel.context.send(viewAction: .newNote)
        guard case .chooseSpace(let choices) = tab.viewModel.context.viewState.bindings.sheet else {
            Issue.record("Choose a space is not shown")
            return
        }
        #expect(choices == tab.sections.map(\.space))
        tab.viewModel.context.send(viewAction: .chooseSpace(spaceID: lab))
        #expect(tab.nameSheet == .new())
    }
    
    @Test
    func aNoteWhoseSheetIsDismissedWhileItSavesIsStillCreatedOnceAndOpened() async throws {
        let space = aNotesSpace(design)
        let tab = Tab([space])
        tab.viewModel.context.send(viewAction: .appeared)
        await eventually { tab.viewModel.context.viewState.canCreate }
        
        tab.viewModel.context.send(viewAction: .newNote)
        tab.viewModel.context.send(viewAction: .updateName("Trip plans"))
        tab.viewModel.context.send(viewAction: .submitName)
        // A swipe or Cancel while the note saves.
        tab.viewModel.context.send(viewAction: .dismissSheet)
        #expect(tab.viewModel.context.viewState.bindings.sheet == nil)
        // New note shows the sheet of the note still saving rather than starting another.
        tab.viewModel.context.send(viewAction: .newNote)
        #expect(tab.nameSheet?.isSaving == true)
        tab.viewModel.context.send(viewAction: .dismissSheet)
        
        await eventually { !tab.opened.isEmpty }
        guard case .openNote(let spaceID, let documentID) = try #require(tab.opened.first) else { return }
        #expect(spaceID == design)
        #expect(tab.opened.count == 1)
        #expect(space.base.sent.count == 1)
        let catalog = try #require(tab.engine.documents.first)
        #expect(try await catalog.snapshot().entries.keys.sorted() == [documentID].compactMap(\.self))
        await eventually { catalog.isClosed }
    }
    
    @Test
    func aSaveThatFailsAfterItsSheetWasDismissedShowsTheSheetAgainAndCreateSavesTheSameNote() async throws {
        let space = aNotesSpace(design)
        space.base.sendResult = { _, _ in .failure(.eventNotFound) }
        let tab = Tab([space])
        tab.viewModel.context.send(viewAction: .appeared)
        await eventually { tab.viewModel.context.viewState.canCreate }
        
        tab.viewModel.context.send(viewAction: .newNote)
        tab.viewModel.context.send(viewAction: .updateName("Trip plans"))
        tab.viewModel.context.send(viewAction: .submitName)
        tab.viewModel.context.send(viewAction: .dismissSheet)
        await eventually { tab.nameSheet?.error == .saveFailed }
        let sheet = try #require(tab.nameSheet)
        #expect(sheet.name == "Trip plans")
        let unsavedID = try #require(sheet.unsavedDocumentID)
        #expect(tab.opened.isEmpty)
        // The sheet's catalog stays open for Create.
        #expect(tab.engine.documents.first?.isClosed == false)
        
        space.base.sendResult = { _, _ in .success("$ok") }
        tab.viewModel.context.send(viewAction: .submitName)
        await eventually { !tab.opened.isEmpty }
        #expect(tab.opened == [.openNote(spaceID: design, documentID: unsavedID)])
        #expect(space.base.sent.count == 1)
        let catalog = try #require(tab.engine.documents.first)
        #expect(try await catalog.snapshot().entries.keys.sorted() == [unsavedID])
        await eventually { catalog.isClosed }
    }
    
    @Test
    func leavingTheTabWhileADismissedNoteSavesStillCreatesItWithoutOpeningIt() async {
        let space = aNotesSpace(design)
        let tab = Tab([space])
        tab.viewModel.context.send(viewAction: .appeared)
        await eventually { tab.viewModel.context.viewState.canCreate }
        
        tab.viewModel.context.send(viewAction: .newNote)
        tab.viewModel.context.send(viewAction: .updateName("Trip plans"))
        tab.viewModel.context.send(viewAction: .submitName)
        tab.viewModel.context.send(viewAction: .dismissSheet)
        // Unlike Android, the save belongs to the tab's view model, not to what is on screen. Opening the note would replace a note
        // opened above the tab meanwhile, and its unsent edits with it.
        tab.viewModel.context.send(viewAction: .disappeared)
        
        await eventually { space.base.sent.count == 1 }
        await eventually { !tab.engine.documents.isEmpty && tab.engine.documents.allSatisfy(\.isClosed) }
        #expect(tab.opened.isEmpty)
    }
    
    @Test
    func stoppingTheTabClosesTheNameSheetsCatalog() async {
        let tab = Tab([aNotesSpace(design)])
        tab.viewModel.context.send(viewAction: .appeared)
        await eventually { tab.viewModel.context.viewState.canCreate }
        tab.viewModel.context.send(viewAction: .newNote)
        await eventually { tab.engine.documents.count == 1 }
        
        tab.viewModel.stop()
        await eventually { tab.engine.documents.first?.isClosed == true }
    }
    
    // MARK: - Helpers
    
    private func catalogItems() throws -> [TimelineItemProxy] {
        try frameItems("$c1", update: aCatalogEntry("c1", documentID: plans, title: "Plans", createdAt: 5), updateID: "c1", documentID: DocsProtocol.catalogDocumentID)
            + frameItems("$c2", update: aCatalogEntry("c2", documentID: guide, title: "Guide", createdAt: 6), updateID: "c2", documentID: DocsProtocol.catalogDocumentID)
    }
    
    /// A space with notes turned on, holding `items`.
    private func aNotesSpace(_ roomID: String, items: [TimelineItemProxy] = []) -> NotesRoomFixture {
        let fixture = NotesRoomFixture(items: items, roomID: roomID)
        fixture.turnNotesOn()
        return fixture
    }
    
    /// The space filter of `roomID`, a top-level space at level 0 and a subspace at level 1, named after its id.
    private func aFilter(_ roomID: String, level: UInt = 0, state: Membership = .joined) -> SpaceServiceFilter {
        let name = String(roomID.dropFirst().prefix { $0 != ":" })
        return SpaceServiceFilter(room: .mock(id: roomID, name: name, isSpace: true, state: state), level: level, descendants: [])
    }
}

/// The Notes tab of a client holding `spaces`, whose space service lists `filters`; by default every space is a joined top-level space,
/// in this order. The name sheet opens its catalog through the same client and engine as the reader.
@MainActor
private final class Tab {
    let client = ClientProxyMock(.init())
    let engine = FakeYjsEngine()
    let reader: NotesTabReader
    let viewModel: NotesTabScreenViewModel
    private(set) var opened: [NotesTabScreenViewModelAction] = []
    private var shown = Set<String>()
    private var cancellables = Set<AnyCancellable>()
    
    init(_ spaces: [NotesRoomFixture],
         filters: [SpaceServiceFilter]? = nil,
         roomListState: CurrentValueSubject<RoomSummaryProviderState, Never> = .init(.loaded(totalNumberOfRooms: 0))) {
        let roomList = RoomSummaryProviderMock()
        roomList.statePublisher = roomListState.asCurrentValuePublisher()
        client.staticRoomSummaryProvider = roomList
        let rooms = Dictionary(spaces.map { ($0.room.id, $0) }) { first, _ in first }
        let spaceService = SpaceServiceProxyMock(.init(spaceFilters: filters ?? spaces.map {
            SpaceServiceFilter(room: .mock(id: $0.room.id, name: String($0.room.id.dropFirst().prefix { $0 != ":" }), isSpace: true, state: .joined), level: 0, descendants: [])
        }))
        client.spaceService = spaceService
        client.roomForIdentifierClosure = { roomID in rooms[roomID].map { .joined($0.room) } }
        client.roomInfoRoomIDClosure = { roomID in
            guard let room = rooms[roomID] else { return .failure(.roomNotInLocalStore) }
            return .success(room.info.value)
        }
        client.stateEventsJSONRoomIDTypeClosure = { roomID, type in
            .success(rooms[roomID]?.stateEvents[type].map { ["": $0] } ?? [:])
        }
        let contextFactory = SpaceNotesContextFactory(clientProxy: client, engine: engine)
        reader = NotesTabReader(clientProxy: client, contextFactory: contextFactory, closeDelay: .milliseconds(50))
        viewModel = NotesTabScreenViewModel(reader: reader, contextFactory: contextFactory, mediaProvider: nil, loadTimeout: .seconds(10))
        viewModel.actionsPublisher
            .sink { [weak self] in self?.opened.append($0) }
            .store(in: &cancellables)
    }
    
    var sections: [NotesSection] {
        guard case .spaces(let sections) = viewModel.context.viewState.content else { return [] }
        return sections
    }
    
    var nameSheet: NoteNameSheetState? {
        guard case .name(let sheet) = viewModel.context.viewState.bindings.sheet else { return nil }
        return sheet
    }
    
    func notes(_ spaceID: String) -> [NoteRowItem]? {
        guard case .notes(let notes) = sections.first(where: { $0.space.id == spaceID })?.content else { return nil }
        return notes
    }
    
    /// A row of each space comes on screen.
    func show(_ spaceIDs: [String]) {
        for spaceID in spaceIDs where shown.insert(spaceID).inserted {
            viewModel.context.send(viewAction: .rowAppeared(spaceID: spaceID, rowID: "header"))
        }
    }
    
    func hide(_ spaceIDs: [String]) {
        for spaceID in spaceIDs where shown.remove(spaceID) != nil {
            viewModel.context.send(viewAction: .rowDisappeared(spaceID: spaceID, rowID: "header"))
        }
    }
}
