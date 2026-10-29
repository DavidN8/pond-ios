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

@MainActor
struct TaskEditorScreenViewModelTests {
    private let thread = "$t1"
    private var threadCardID: String {
        KanbanProtocol.threadCardID(thread)
    }
    
    @Test
    func addingATaskCreatesItsNamedThreadThenItsCard() async throws {
        let fixture = MatchaRoomFixture()
        fixture.boardPointer = .success(aBoardRoot)
        fixture.sendResult = { type, _ in .success(type == "m.room.message" ? "$root" : "$e\(UUID().uuidString)") }
        let viewModel = try await makeViewModel(fixture, target: .new(status: .doing))
        #expect(viewModel.context.viewState.isNew)
        #expect(viewModel.context.status == .doing)
        
        viewModel.context.title = "  Book the venue "
        viewModel.context.description = "Near the station"
        try await save(viewModel)
        
        #expect(fixture.sent.map(\.type) == ["m.room.message", MatchaConfig.eventThreadMetadata, MatchaConfig.eventKanbanCard])
        #expect(json(fixture.sent[0])?.string("body") == "Book the venue")
        #expect(json(fixture.sent[1])?.relationTarget(MatchaConfig.relationTypeThread) == "$root")
        let card = try #require(json(fixture.sent[2]))
        #expect(card.string("card_id") == KanbanProtocol.threadCardID("$root"))
        #expect(card.string("thread_id") == "$root")
        #expect(card.string("title") == "Book the venue")
        #expect(card.string("description") == "Near the station")
        #expect(card.string("column") == "doing")
        // A new task is only for the people it involves until it is shared.
        #expect(card.bool("show_to_room") == false)
    }
    
    @Test
    func aTaskNameIsValidatedBeforeAnythingIsSent() async throws {
        let fixture = MatchaRoomFixture()
        fixture.boardPointer = .success(aBoardRoot)
        fixture.sendResult = { _, _ in
            Issue.record("Nothing must be sent")
            return .success("$sent")
        }
        let viewModel = try await makeViewModel(fixture, target: .new(status: .todo))
        #expect(viewModel.context.viewState.titleError == nil)
        
        viewModel.context.send(viewAction: .save)
        #expect(viewModel.context.viewState.titleError == .empty)
        // Blank as the protocol reads names, with Kotlin's trim, though Foundation's whitespace leaves U+001C–U+001F.
        viewModel.context.title = "\u{1C}\u{1F}"
        #expect(viewModel.context.viewState.titleError == .empty)
        viewModel.context.title = String(repeating: "a", count: MatchaConfig.threadNameMaxLength + 1)
        #expect(viewModel.context.viewState.titleError == .tooLong(MatchaConfig.threadNameMaxLength))
        viewModel.context.description = String(repeating: "d", count: MatchaConfig.cardDescriptionMaxLength + 1)
        #expect(viewModel.context.viewState.descriptionError == .tooLong(MatchaConfig.cardDescriptionMaxLength))
        viewModel.context.send(viewAction: .save)
        #expect(!viewModel.context.viewState.isSaving)
    }
    
    @Test
    func editingATaskWritesACompleteRevisionAndRenamesItsThreadWhenTheNameChanged() async throws {
        let fixture = try linkedTaskFixture()
        let store = fixture.store()
        await store.settle()
        
        var viewModel = TaskEditorScreenViewModel(store: store, target: .edit(taskID: threadCardID))
        #expect(!viewModel.context.viewState.isNew)
        #expect(viewModel.context.title == "Plan")
        #expect(viewModel.context.description == "Steps")
        viewModel.context.description = "More steps"
        try await save(viewModel)
        #expect(fixture.sent.map(\.type) == [MatchaConfig.eventKanbanCard])
        #expect(json(fixture.sent[0])?.string("title") == "Plan")
        #expect(json(fixture.sent[0])?.integer("due_at") == dueAt)
        
        await waitForSnapshot(store) { $0.board?.cards.first?.description == "More steps" }
        viewModel = TaskEditorScreenViewModel(store: store, target: .edit(taskID: threadCardID))
        viewModel.context.title = "Launch plan"
        try await save(viewModel)
        #expect(fixture.sent.dropFirst().map(\.type) == [MatchaConfig.eventThreadMetadata, MatchaConfig.eventKanbanCard])
        #expect(json(fixture.sent[1])?.string("name") == "Launch plan")
        #expect(json(fixture.sent[1])?.referenceTarget == thread)
        #expect(json(fixture.sent[2])?.string("title") == "Launch plan")
        #expect(json(fixture.sent[2])?.string("description") == "More steps")
    }
    
    @Test
    func aNewTaskWaitsForItsThreadToBeSetUpBeforeItsCardIsWritten() async throws {
        var attempts = [String]()
        var failsSetup = true
        let fixture = MatchaRoomFixture()
        fixture.boardPointer = .success(aBoardRoot)
        fixture.sendResult = { type, _ in
            attempts.append(type)
            switch type {
            case "m.room.message": return .success("$root")
            case MatchaConfig.eventThreadMetadata where failsSetup: return .failure(.sdkError(RoomProxyMockError.generic))
            default: return .success("$e\(attempts.count)")
            }
        }
        let viewModel = try await makeViewModel(fixture, target: .new(status: .todo))
        viewModel.context.title = "Book the venue"
        
        viewModel.context.send(viewAction: .save)
        try await deferFulfillment(viewModel.context.observe(\.viewState.saveError)) { $0 != nil }.fulfill()
        #expect(viewModel.context.viewState.saveError == .threadSetupFailed)
        #expect(attempts == ["m.room.message", MatchaConfig.eventThreadMetadata])
        
        failsSetup = false
        try await save(viewModel)
        // The root isn't sent again: the setup reply is, then the card.
        #expect(attempts.dropFirst(2) == [MatchaConfig.eventThreadMetadata, MatchaConfig.eventKanbanCard])
    }
    
    @Test
    func aRetryAfterRenamingANewTaskNamesItsThread() async throws {
        var failsSetup = true
        let fixture = MatchaRoomFixture()
        fixture.boardPointer = .success(aBoardRoot)
        fixture.sendResult = { type, _ in
            switch type {
            case "m.room.message": .success("$root")
            case MatchaConfig.eventThreadMetadata where failsSetup: .failure(.sdkError(RoomProxyMockError.generic))
            default: .success("$e\(UUID().uuidString)")
            }
        }
        let viewModel = try await makeViewModel(fixture, target: .new(status: .todo))
        viewModel.context.title = "Book the venue"
        viewModel.context.send(viewAction: .save)
        try await deferFulfillment(viewModel.context.observe(\.viewState.saveError)) { $0 != nil }.fulfill()
        
        failsSetup = false
        viewModel.context.title = "Book the hall"
        try await save(viewModel)
        // The root still reads "Book the venue", so the thread is renamed before its card is written.
        #expect(fixture.sent.map(\.type) == ["m.room.message", MatchaConfig.eventThreadMetadata, MatchaConfig.eventThreadMetadata, MatchaConfig.eventKanbanCard])
        #expect(json(fixture.sent[2])?.string("name") == "Book the hall")
        #expect(json(fixture.sent[3])?.string("title") == "Book the hall")
    }
    
    @Test
    func anUntitledThreadsTaskAsksForANameWhichAlsoNamesTheThread() async throws {
        let fixture = MatchaRoomFixture(threads: [aThreadListItem(thread, body: "")])
        fixture.boardPointer = .success(aBoardRoot)
        fixture.sendResult = { _, _ in .success("$e\(UUID().uuidString)") }
        let viewModel = try await makeViewModel(fixture, target: .edit(taskID: threadCardID))
        #expect(viewModel.context.title.isEmpty)
        #expect(!viewModel.context.viewState.hasChanges)
        
        viewModel.context.send(viewAction: .save)
        #expect(viewModel.context.viewState.titleError == .empty)
        #expect(fixture.sent.isEmpty)
        
        viewModel.context.title = "Plan"
        try await save(viewModel)
        #expect(fixture.sent.map(\.type) == [MatchaConfig.eventThreadMetadata, MatchaConfig.eventKanbanCard])
        #expect(json(fixture.sent[0])?.string("name") == "Plan")
    }
    
    @Test
    func anOlderCardWithoutAThreadKeepsTheLongerNameLimit() async throws {
        let fixture = try MatchaRoomFixture(items: [aBoardCardItem(1, id: "c-legacy", title: "Legacy")])
        fixture.boardPointer = .success(aBoardRoot)
        let viewModel = try await makeViewModel(fixture, target: .edit(taskID: "c-legacy"))
        #expect(!viewModel.context.viewState.isLinked)
        #expect(viewModel.context.viewState.titleMaxLength == MatchaConfig.cardTitleMaxLength)
    }
    
    @Test
    func theDeadlineIsPickedWarnedAboutWhenPastAndCleared() async throws {
        let viewModel = try await makeViewModel(linkedTaskFixture(), target: .edit(taskID: threadCardID))
        #expect(viewModel.context.viewState.deadlineWarning == nil)
        
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let past = try #require(calendar.date(from: DateComponents(year: 2020, month: 1, day: 1, hour: 9, minute: 0)))
        viewModel.context.send(viewAction: .setDeadline(past))
        #expect(viewModel.context.viewState.dueAt == Int64(past.timeIntervalSince1970 * 1000))
        #expect(viewModel.context.viewState.deadlineWarning == .past)
        
        viewModel.context.send(viewAction: .clearDeadline)
        #expect(viewModel.context.viewState.dueAt == nil)
        #expect(viewModel.context.viewState.deadlineWarning == nil)
        #expect(viewModel.context.viewState.hasChanges)
        
        viewModel.context.send(viewAction: .addDeadline)
        #expect(viewModel.context.viewState.dueAt.map { calendar.component(.hour, from: Date(timeIntervalSince1970: TimeInterval($0) / 1000)) } == 17)
    }
    
    @Test
    func closingWithChangesAsksBeforeDiscardingThem() async throws {
        let viewModel = try await makeViewModel(linkedTaskFixture(), target: .edit(taskID: threadCardID))
        viewModel.context.description = "Changed"
        
        viewModel.context.send(viewAction: .cancel)
        #expect(viewModel.context.isDiscardConfirmationPresented)
        viewModel.context.isDiscardConfirmationPresented = false
        
        viewModel.context.send(viewAction: .cancel)
        #expect(viewModel.context.isDiscardConfirmationPresented)
        let deferred = deferFulfillment(viewModel.actionsPublisher) { _ in true }
        viewModel.context.send(viewAction: .discard)
        #expect(try await deferred.fulfill() == .close)
    }
    
    @Test
    func openingTheThreadWithChangesAsksFirstThenOpensIt() async throws {
        let fixture = try linkedTaskFixture()
        var viewModel = try await makeViewModel(fixture, target: .edit(taskID: threadCardID))
        var deferred = deferFulfillment(viewModel.actionsPublisher) { _ in true }
        viewModel.context.send(viewAction: .openThread)
        #expect(try await deferred.fulfill() == .openThread(threadRootEventID: thread))
        
        // Its host has closed that editor, so the thread's task is edited in a new one.
        viewModel = try await makeViewModel(fixture, target: .edit(taskID: threadCardID))
        viewModel.context.description = "Changed"
        viewModel.context.send(viewAction: .openThread)
        #expect(viewModel.context.isDiscardConfirmationPresented)
        deferred = deferFulfillment(viewModel.actionsPublisher) { _ in true }
        viewModel.context.send(viewAction: .discard)
        #expect(try await deferred.fulfill() == .openThread(threadRootEventID: thread))
    }
    
    @Test
    func remindMeIsAboutTheTaskAsEditedAndLeavesTheEditorOpen() async throws {
        let viewModel = try await makeViewModel(linkedTaskFixture(), target: .edit(taskID: threadCardID))
        #expect(viewModel.context.viewState.canRemind)
        #expect(viewModel.context.viewState.reminderRequestedAt == nil)
        viewModel.context.title = " Plan B "
        viewModel.context.send(viewAction: .clearDeadline)
        
        let deferred = deferFulfillment(viewModel.actionsPublisher) { _ in true }
        viewModel.context.send(viewAction: .remindMe)
        #expect(try await deferred.fulfill() == .remindMe(RemindMeTarget(message: "Plan B", threadID: thread, dueAt: nil), cardID: threadCardID))
        
        // The editor is still open, so it can still close once.
        let close = deferFulfillment(viewModel.actionsPublisher) { $0 == .close }
        viewModel.context.send(viewAction: .discard)
        try await close.fulfill()
    }
    
    @Test
    func aReminderRequestedFromTheOpenEditorShowsOnIt() async throws {
        let fixture = try linkedTaskFixture()
        let store = fixture.store()
        await store.settle()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let viewModel = TaskEditorScreenViewModel(store: store, target: .edit(taskID: threadCardID), now: { now }, announce: { _ in })
        #expect(viewModel.context.viewState.reminderRequestedAt == nil)
        
        // What the Remind me sheet's onRequested writes while the editor stays open under it, as Android's editor reads it live.
        let shown = deferFulfillment(viewModel.context.observe(\.viewState.reminderRequestedAt)) { $0 != nil }
        #expect(await TaskWriter(store: store).recordReminder(cardID: threadCardID, request: ReminderRequestRef(eventID: "$remind", at: dueAt)) == nil)
        try await shown.fulfill()
        // "Reminder requested for …" with the time it's due, like a deadline.
        #expect(viewModel.context.viewState.reminderRequestedAt == DeadlineFormatter.format(dueAt, now: now))
    }
    
    @Test
    func aNewTaskOffersNoReminderUntilItExists() async throws {
        let fixture = MatchaRoomFixture()
        fixture.boardPointer = .success(aBoardRoot)
        let viewModel = try await makeViewModel(fixture, target: .new(status: .todo))
        #expect(!viewModel.context.viewState.canRemind)
    }
    
    @Test
    func choosingOnlyANewTasksStatusClosesWithoutAsking() async throws {
        let fixture = MatchaRoomFixture()
        fixture.boardPointer = .success(aBoardRoot)
        let viewModel = try await makeViewModel(fixture, target: .new(status: .todo))
        viewModel.context.status = .done
        #expect(!viewModel.context.viewState.hasChanges)
        
        let deferred = deferFulfillment(viewModel.actionsPublisher) { _ in true }
        viewModel.context.send(viewAction: .cancel)
        #expect(try await deferred.fulfill() == .close)
    }
    
    @Test
    func sharingATaskWithTheChatIsWrittenAndAnEditKeepsWhatTheCardSays() async throws {
        let fixture = try linkedTaskFixture()
        let viewModel = try await makeViewModel(fixture, target: .edit(taskID: threadCardID))
        #expect(viewModel.context.showToRoom)
        #expect(viewModel.context.viewState.canShare)
        
        viewModel.context.showToRoom = false
        #expect(viewModel.context.viewState.hasChanges)
        try await save(viewModel)
        let written = try #require(json(fixture.sent.last))
        #expect(written.bool("show_to_room") == false)
        #expect(written.string("description") == "Steps")
    }
    
    @Test
    func inADirectChatSharingIsntOffered() async throws {
        let fixture = try MatchaRoomFixture(items: [aBoardCardItem(1, id: threadCardID, title: "Plan", threadID: thread, showToRoom: false)],
                                            threads: [aThreadListItem(thread, body: "Plan")],
                                            isDirect: true,
                                            heroes: ["@bob:x"])
        fixture.boardPointer = .success(aBoardRoot)
        let viewModel = try await makeViewModel(fixture, target: .edit(taskID: threadCardID))
        #expect(!viewModel.context.viewState.canShare)
    }
    
    @Test
    func aTaskThatIsGoneClosesTheEditor() async throws {
        let fixture = MatchaRoomFixture()
        fixture.boardPointer = .success(aBoardRoot)
        let store = fixture.store()
        await store.settle()
        let viewModel = TaskEditorScreenViewModel(store: store, target: .edit(taskID: "c-gone"))
        let deferred = deferFulfillment(viewModel.actionsPublisher) { _ in true }
        #expect(try await deferred.fulfill() == .close)
    }
    
    @Test
    func aSaveThatEndsAfterTheEditorWasDiscardedDoesntCloseItAgain() async throws {
        let fixture = try linkedTaskFixture()
        let sendGate = Gate()
        fixture.room.sendRawEventTypeContentJSONClosure = { _, _ in
            await sendGate.wait()
            return .success("$e\(UUID().uuidString)")
        }
        let viewModel = try await makeViewModel(fixture, target: .edit(taskID: threadCardID))
        viewModel.context.description = "Changed"
        viewModel.context.send(viewAction: .save)
        #expect(viewModel.context.viewState.isSaving)
        
        viewModel.context.send(viewAction: .cancel)
        let closed = deferFulfillment(viewModel.actionsPublisher) { $0 == .close }
        viewModel.context.send(viewAction: .discard)
        try await closed.fulfill()
        
        // The host has dismissed the editor and may show another sheet by now: a second close would dismiss that one.
        let closedAgain = deferFailure(viewModel.actionsPublisher, timeout: .milliseconds(500)) { _ in true }
        let saved = deferFulfillment(viewModel.context.observe(\.viewState.isSaving)) { !$0 }
        sendGate.open()
        try await saved.fulfill()
        try await closedAgain.fulfill()
    }
    
    @Test
    func validationAndSaveErrorsAreAnnouncedToVoiceOver() async throws {
        let fixture = MatchaRoomFixture()
        fixture.boardPointer = .success(aBoardRoot)
        fixture.sendResult = { _, _ in .failure(.sdkError(RoomProxyMockError.generic)) }
        let store = fixture.store()
        await store.settle()
        var announcements = [String]()
        let announce: (String) -> Void = { announcements.append($0) }
        let viewModel = TaskEditorScreenViewModel(store: store, target: .new(status: .todo), announce: announce)
        
        viewModel.context.send(viewAction: .save)
        #expect(announcements == [UntranslatedL10n.commonMatchaErrorNameEmpty])
        
        viewModel.context.title = "Book the venue"
        viewModel.context.description = String(repeating: "d", count: MatchaConfig.cardDescriptionMaxLength + 1)
        viewModel.context.send(viewAction: .save)
        #expect(announcements.last == TaskFieldError.tooLong(MatchaConfig.cardDescriptionMaxLength).message)
        
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let tooLate = try #require(calendar.date(from: DateComponents(year: 10001, month: 1, day: 1, hour: 9)))
        viewModel.context.send(viewAction: .setDeadline(tooLate))
        #expect(announcements.last == UntranslatedL10n.screenMatchaTasksDeadlineRange)
        
        viewModel.context.description = ""
        viewModel.context.send(viewAction: .save)
        try await deferFulfillment(viewModel.context.observe(\.viewState.saveError)) { $0 != nil }.fulfill()
        #expect(announcements.last == UntranslatedL10n.commonMatchaWriteFailed)
    }
    
    // MARK: - Helpers
    
    private let dueAt: Int64 = 1_900_000_000_000
    
    /// A board with one thread, "Plan", whose task has a description and a deadline. Every send gets its own event id.
    private func linkedTaskFixture() throws -> MatchaRoomFixture {
        let fixture = try MatchaRoomFixture(items: [aBoardCardItem(1, id: threadCardID, title: "Plan", threadID: thread, description: "Steps", dueAt: dueAt)],
                                            threads: [aThreadListItem(thread, body: "Plan")])
        fixture.boardPointer = .success(aBoardRoot)
        fixture.sendResult = { _, _ in .success("$e\(UUID().uuidString)") }
        return fixture
    }
    
    /// An editor over the settled store of `fixture`.
    private func makeViewModel(_ fixture: MatchaRoomFixture, target: TaskEditorTarget) async throws -> TaskEditorScreenViewModel {
        let store = fixture.store()
        await store.settle()
        return TaskEditorScreenViewModel(store: store, target: target)
    }
    
    /// Saves and waits for the editor to close.
    private func save(_ viewModel: TaskEditorScreenViewModel, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deferred = deferFulfillment(viewModel.actionsPublisher, sourceLocation: sourceLocation) { $0 == .close }
        viewModel.context.send(viewAction: .save)
        try await deferred.fulfill()
    }
    
    private func json(_ sent: (type: String, content: String)?) -> JSONObject? {
        sent.flatMap { JSONValue(json: $0.content)?.objectValue }
    }
}
