//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import MatchaProtocol
import MatrixRustSDK
import SwiftUI
import Testing

@MainActor
struct TasksBoardScreenViewModelTests {
    private let thread = "$t1"
    private var threadCardID: String {
        KanbanProtocol.threadCardID(thread)
    }
    
    // MARK: Finding and creating the board
    
    @Test
    func theBoardIsLookedForUntilTheThreadsAndTheHistoryAreRead() async {
        let fixture = MatchaRoomFixture(threadsPagination: .loading)
        let viewModel = makeViewModel(fixture)
        await viewModel.store.settle()
        #expect(viewModel.context.viewState.content == .lookingForBoard)
    }
    
    @Test
    func aBoardFurtherBackThanTheFirstPagesIsFoundBeforeSetupIsOffered() async throws {
        // Ten pages are read up front; the board's pointer and a card are in the twelfth.
        let fixture = try MatchaRoomFixture(olderPages: Array(repeating: [], count: 11) + [[aBoardPointerItem(1, rootID: aBoardRoot), aBoardCardItem(2, id: "c-old", title: "Old task")]])
        fixture.serverPointer = { .failure(.sdkError(RoomProxyMockError.generic)) }
        let viewModel = makeViewModel(fixture)
        let contents = recordContents(of: viewModel)
        
        let board = try await waitForBoard(viewModel) { !$0.todo.isEmpty }
        #expect(board.todo.map(\.title) == ["Old task"])
        #expect(!contents.values.contains {
            if case .setup = $0 {
                true
            } else {
                false
            }
        })
    }
    
    @Test
    func historyThatCantBeReadToLookForTheBoardOffersToTryAgain() async throws {
        let fixture = MatchaRoomFixture(olderPages: Array(repeating: [], count: 12))
        fixture.serverPointer = { .failure(.sdkError(RoomProxyMockError.generic)) }
        let store = fixture.store()
        await store.settle()
        fixture.paginateResult = { .failure(.sdkError(RoomProxyMockError.generic)) }
        let viewModel = TasksBoardScreenViewModel(store: store, formatDeadline: formatDeadline, now: now)
        
        try await waitForContent(viewModel) { $0 == .loadFailed }
        fixture.paginateResult = { .success(()) }
        viewModel.context.send(viewAction: .retryLoad)
        try await waitForContent(viewModel) { $0 == .setup(canCreate: true, isCreating: false, createFailed: false) }
    }
    
    @Test
    func leavingTheBoardWhileItIsLookedForStopsReadingTheHistory() async throws {
        // The homeserver can't say whether the room has a board, so the history is read back to its start: 30 pages.
        let fixture = MatchaRoomFixture(olderPages: Array(repeating: [], count: 30))
        fixture.serverPointer = { .failure(.sdkError(RoomProxyMockError.generic)) }
        let paginate = try #require(fixture.timeline.paginateBackwardsRequestSizeClosure)
        var pagesRead = 0
        fixture.timeline.paginateBackwardsRequestSizeClosure = { size in
            pagesRead += 1
            try? await Task.sleep(for: .milliseconds(20))
            return await paginate(size)
        }
        var viewModel: TasksBoardScreenViewModel? = makeViewModel(fixture)
        weak var leftViewModel = viewModel
        await eventually { pagesRead > MatchaConfig.initialHistoryPages }
        #expect(viewModel?.context.viewState.content == .lookingForBoard)
        
        viewModel = nil
        #expect(leftViewModel == nil)
        let pagesWhenLeft = pagesRead
        try await Task.sleep(for: .milliseconds(400))
        // The page being read when the board went may still finish; no other is asked for.
        #expect(pagesRead <= pagesWhenLeft + 1)
    }
    
    @Test
    func creatingTheBoardSendsItsRootThenPointsTheRoomAtIt() async throws {
        let fixture = MatchaRoomFixture()
        var pointers = [(type: String, content: String)]()
        fixture.sendResult = { _, _ in .success("$root") }
        fixture.sendStateResult = { type, _, content in
            pointers.append((type, content))
            return .success("$pointer")
        }
        let viewModel = makeViewModel(fixture)
        try await waitForContent(viewModel) { $0 == .setup(canCreate: true, isCreating: false, createFailed: false) }
        
        viewModel.context.send(viewAction: .createBoard)
        // The board shows once the room points at its root.
        _ = try await waitForBoard(viewModel)
        #expect(fixture.sent.map(\.type) == [MatchaConfig.eventKanbanBoard])
        #expect(pointers.map(\.type) == [MatchaConfig.stateKanban])
        #expect(KanbanProtocol.parseBoardPointer(json: pointers.first?.content) == "$root")
    }
    
    @Test
    func aBoardCreatedElsewhereMeanwhileIsShownInsteadOfCreatingAnother() async throws {
        let fixture = MatchaRoomFixture()
        fixture.sendResult = { _, _ in
            Issue.record("Nothing must be sent")
            return .success("$root")
        }
        let viewModel = makeViewModel(fixture)
        try await waitForContent(viewModel) {
            if case .setup = $0 {
                true
            } else {
                false
            }
        }
        
        fixture.serverPointer = { .success(aBoardRoot) }
        viewModel.context.send(viewAction: .createBoard)
        _ = try await waitForBoard(viewModel)
        #expect(viewModel.context.viewState.banner?.message == UntranslatedL10n.screenMatchaTasksAlreadyHasBoard)
    }
    
    @Test
    func aFailedCreateSaysSoAndOffersToTryAgain() async throws {
        let fixture = MatchaRoomFixture()
        fixture.sendResult = { _, _ in .failure(.sdkError(RoomProxyMockError.generic)) }
        var announcements = [String]()
        let announce: (String) -> Void = { announcements.append($0) }
        let viewModel = TasksBoardScreenViewModel(store: fixture.store(), formatDeadline: formatDeadline, now: now, announce: announce)
        try await waitForContent(viewModel) {
            if case .setup = $0 {
                true
            } else {
                false
            }
        }
        
        viewModel.context.send(viewAction: .createBoard)
        try await waitForContent(viewModel) { $0 == .setup(canCreate: true, isCreating: false, createFailed: true) }
        #expect(announcements == [UntranslatedL10n.screenMatchaTasksSetupFailed])
    }
    
    @Test
    func aBoardWhosePointerCouldntBeSetIsPointedAtAgainRatherThanSentTwice() async throws {
        let fixture = MatchaRoomFixture()
        var pointers = [String]()
        var failsPointer = true
        fixture.sendResult = { _, _ in .success("$root") }
        fixture.sendStateResult = { _, _, content in
            pointers.append(content)
            return failsPointer ? .failure(.sdkError(RoomProxyMockError.generic)) : .success("$pointer")
        }
        let viewModel = makeViewModel(fixture)
        try await waitForContent(viewModel) {
            if case .setup = $0 {
                true
            } else {
                false
            }
        }
        
        viewModel.context.send(viewAction: .createBoard)
        try await waitForContent(viewModel) { $0 == .setup(canCreate: true, isCreating: false, createFailed: true) }
        // The root alone is no board, for this client or any other.
        #expect(viewModel.store.snapshot.board == nil)
        
        failsPointer = false
        viewModel.context.send(viewAction: .createBoard)
        _ = try await waitForBoard(viewModel)
        #expect(fixture.sent.map(\.type) == [MatchaConfig.eventKanbanBoard])
        #expect(pointers.count == 2)
        #expect(pointers.allSatisfy { KanbanProtocol.parseBoardPointer(json: $0) == "$root" })
    }
    
    @Test
    func withoutPermissionTheBoardCantBeCreated() async throws {
        let fixture = MatchaRoomFixture(canSendState: false)
        fixture.sendResult = { _, _ in
            Issue.record("Nothing must be sent")
            return .success("$root")
        }
        let viewModel = makeViewModel(fixture)
        try await waitForContent(viewModel) { $0 == .setup(canCreate: false, isCreating: false, createFailed: false) }
        viewModel.context.send(viewAction: .createBoard)
        // A create that started would show its progress straight away.
        #expect(viewModel.context.viewState.content == .setup(canCreate: false, isCreating: false, createFailed: false))
        await viewModel.store.settle()
    }
    
    // MARK: Showing tasks
    
    @Test
    func tasksAreSplitByStatusAndOrderedByDeadlineWithRepliesAfterTheSetupReply() async throws {
        let fixture = try MatchaRoomFixture(items: [aBoardCardItem(1, id: "c-late", title: "Late", dueAt: aNow + 2000),
                                                    aBoardCardItem(2, id: "c-soon", title: "Soon", dueAt: aNow - 1000),
                                                    aBoardCardItem(3, id: "c-none", title: "No deadline"),
                                                    aBoardCardItem(4, id: "c-done", title: "Done", status: .done, dueAt: aNow - 1000),
                                                    aBoardCardItem(5, id: "c-archived", title: "Archived", status: .doing, archived: true),
                                                    aMatchaEventItem(6, type: MatchaConfig.eventThreadMetadata,
                                                                     content: ThreadMetadataProtocol.bootstrapReplyContent(rootID: thread, name: "Plan"))],
                                            threads: [aThreadListItem(thread, body: "Plan"), aThreadListItem("$t2", body: "")])
        fixture.boardPointer = .success(aBoardRoot)
        let viewModel = makeViewModel(fixture)
        
        let board = try await waitForBoard(viewModel) { !$0.archived.isEmpty }
        // Without a deadline, threads come newest first and older standalone cards last.
        #expect(board.todo.map(\.title) == ["Soon", "Late", "Plan", nil, "No deadline"])
        #expect(board.todo.first?.isOverdue == true)
        #expect(board.todo.first?.deadline == "at \(aNow - 1000)")
        #expect(board.done.map(\.isOverdue) == [false])
        #expect(board.archived.map(\.title) == ["Archived"])
        // The named thread's only reply is the hidden one that set it up.
        #expect(board.todo.first { $0.title == "Plan" }?.replyCount == 0)
        #expect(board.todo.first { $0.title == nil }?.replyCount == 1)
        #expect(board.todo.last?.replyCount == nil)
        #expect(board.canAdd)
    }
    
    @Test
    func aTaskThatIsntSharedWithTheChatIsOnlyOnTheBoardsOfThePeopleItInvolves() async throws {
        let fixture = try MatchaRoomFixture(items: [aBoardCardItem(1, id: KanbanProtocol.threadCardID("$bobs"), title: "Bob's", threadID: "$bobs", showToRoom: false),
                                                    aBoardCardItem(2, id: KanbanProtocol.threadCardID("$shared"), title: "Shared", threadID: "$shared"),
                                                    aBoardCardItem(3, id: KanbanProtocol.threadCardID("$mine"), title: "Mine", status: .doing, threadID: "$mine", showToRoom: false),
                                                    aBoardCardItem(4, id: "c-bobs", title: "Bob's older card", showToRoom: false),
                                                    aBoardCardItem(5, id: "c-mine", title: "My older card", showToRoom: false, sender: matchaUser)],
                                            threads: [aThreadListItem("$bobs", body: "Bob's"),
                                                      aThreadListItem("$shared", body: "Shared"),
                                                      aThreadListItem("$mine", body: "Mine", sender: matchaUser)])
        fixture.boardPointer = .success(aBoardRoot)
        let viewModel = makeViewModel(fixture)
        
        let board = try await waitForBoard(viewModel) { !$0.doing.isEmpty }
        // Hidden tasks are left out of the counts too.
        #expect(board.todo.map(\.title) == ["Shared", "My older card"])
        #expect(board.doing.map(\.title) == ["Mine"])
        #expect(board.todo.first?.isSharedWithChat == true)
        #expect(board.doing.first?.isSharedWithChat == false)
    }
    
    @Test
    func inADirectChatEveryTaskIsShownAndNoneIsMarkedShared() async throws {
        let fixture = try MatchaRoomFixture(items: [aBoardCardItem(1, id: threadCardID, title: "Plan", threadID: thread, showToRoom: false)],
                                            threads: [aThreadListItem(thread, body: "Plan")],
                                            isDirect: true,
                                            heroes: ["@bob:x"])
        fixture.boardPointer = .success(aBoardRoot)
        let viewModel = makeViewModel(fixture)
        
        let board = try await waitForBoard(viewModel) { !$0.todo.isEmpty }
        #expect(board.todo.map(\.isSharedWithChat) == [false])
    }
    
    @Test
    func theDeadlineIsWrittenRelativeToTheBoardsNow() async throws {
        let fixture = try linkedTaskFixture()
        let viewModel = TasksBoardScreenViewModel(store: fixture.store(), now: now)
        
        let board = try await waitForBoard(viewModel) { !$0.todo.isEmpty }
        #expect(board.todo.first?.deadline == DeadlineFormatter.format(aNow + 5000, now: now()))
    }
    
    @Test
    func theDeadlinesAreReadAgainWhenTheDayOrTheClockChanges() async throws {
        let fixture = try linkedTaskFixture()
        var clock = now()
        let readClock = { clock }
        let viewModel = TasksBoardScreenViewModel(store: fixture.store(), formatDeadline: formatDeadline, now: readClock)
        _ = try await waitForBoard(viewModel) { !$0.todo.isEmpty }
        await viewModel.store.settle()
        
        // Past the deadline, 5 s after now: nothing reads the tasks again until the system says the time changed, as it does at
        // midnight, or when the time zone or the clock changes.
        clock = now().addingTimeInterval(10)
        try await Task.sleep(for: .milliseconds(200))
        #expect(viewModel.context.viewState.content.board?.todo.first?.isOverdue == false)
        NotificationCenter.default.post(name: UIApplication.significantTimeChangeNotification, object: nil)
        _ = try await waitForBoard(viewModel) { $0.todo.first?.isOverdue == true }
    }
    
    @Test
    func aCardIDThatLooksLikeARowOfTheListIsJustATask() async throws {
        let fixture = try MatchaRoomFixture(items: [aBoardCardItem(1, id: "archived", title: "Hostile"), aBoardCardItem(2, id: "load-older", title: "Also hostile", archived: true)])
        fixture.boardPointer = .success(aBoardRoot)
        let viewModel = makeViewModel(fixture)
        
        let board = try await waitForBoard(viewModel) { !$0.todo.isEmpty && !$0.archived.isEmpty }
        #expect(board.todo.map(\.id) == ["archived"])
        #expect(board.archived.map(\.id) == ["load-older"])
    }
    
    // MARK: Opening tasks
    
    @Test
    func tappingATaskOpensItsThreadAndAnOlderCardWithoutOneOpensTheEditor() async throws {
        let fixture = try linkedTaskFixture(extraItems: [aBoardCardItem(9, id: "c-legacy", title: "Legacy")])
        let viewModel = makeViewModel(fixture)
        _ = try await waitForBoard(viewModel) { $0.todo.count == 2 }
        
        var deferred = deferFulfillment(viewModel.actionsPublisher) { _ in true }
        viewModel.context.send(viewAction: .openTask(id: threadCardID))
        #expect(try await deferred.fulfill() == .presentThread(threadRootEventID: thread))
        
        deferred = deferFulfillment(viewModel.actionsPublisher) { _ in true }
        viewModel.context.send(viewAction: .openTask(id: "c-legacy"))
        #expect(try await deferred.fulfill() == .presentEditor(.edit(taskID: "c-legacy")))
    }
    
    @Test
    func theBoardOpensTheEditorForTheThreadItWasOpenedFor() async throws {
        let fixture = try linkedTaskFixture()
        let store = fixture.store()
        await store.settle()
        let viewModel = TasksBoardScreenViewModel(store: store, initialThreadID: thread, formatDeadline: formatDeadline, now: now)
        let deferred = deferFulfillment(viewModel.actionsPublisher) { _ in true }
        #expect(try await deferred.fulfill() == .presentEditor(.edit(taskID: threadCardID)))
    }
    
    @Test
    func aTaskLeftOffTheBoardStillOpensFromItsThread() async throws {
        let fixture = try MatchaRoomFixture(items: [aBoardCardItem(1, id: threadCardID, title: "Plan", threadID: thread, showToRoom: false)],
                                            threads: [aThreadListItem(thread, body: "Plan")])
        fixture.boardPointer = .success(aBoardRoot)
        let viewModel = TasksBoardScreenViewModel(store: fixture.store(), initialThreadID: thread, formatDeadline: formatDeadline, now: now)
        let deferred = deferFulfillment(viewModel.actionsPublisher) { _ in true }
        
        #expect(try await deferred.fulfill() == .presentEditor(.edit(taskID: threadCardID)))
        let board = try await waitForBoard(viewModel)
        #expect(board.todo.isEmpty)
    }
    
    @Test
    func aReadOnlyBoardChangesNothing() async throws {
        let fixture = try linkedTaskFixture()
        (fixture.roomInfo.powerLevels as? RoomPowerLevelsProxyMock)?.canOwnUserSendMessageClosure = { type in
            type != messageLikeEventTypeFromString(s: MatchaConfig.eventKanbanCard)
        }
        fixture.sendResult = { _, _ in
            Issue.record("Nothing must be sent")
            return .success("$sent")
        }
        let viewModel = makeViewModel(fixture)
        let board = try await waitForBoard(viewModel) { !$0.todo.isEmpty }
        #expect(!board.canEdit)
        #expect(!board.canAdd)
        #expect(board.todo.first.map(board.canArchive) == false)
        
        let noEditor = deferFailure(viewModel.actionsPublisher, timeout: .milliseconds(300)) { _ in true }
        viewModel.context.send(viewAction: .move(id: threadCardID, status: .done))
        viewModel.context.send(viewAction: .setArchived(id: threadCardID, archived: true))
        viewModel.context.send(viewAction: .newTask(status: .todo))
        viewModel.context.send(viewAction: .editTask(id: threadCardID))
        try await noEditor.fulfill()
        await viewModel.store.settle()
        // A write that started would be refused by the writer and say so.
        #expect(viewModel.context.viewState.banner == nil)
        
        viewModel.context.send(viewAction: .showActions(id: threadCardID))
        #expect(viewModel.context.viewState.actionsTask?.id == threadCardID)
    }
    
    // MARK: Reminders
    
    @Test
    func remindMeOnAnActiveTaskAsksForItsSheetAndTheRequestIsRecordedOnTheCard() async throws {
        let fixture = try linkedTaskFixture(extraItems: [aBoardCardItem(9, id: "c-old", title: "Old", archived: true)])
        let viewModel = makeViewModel(fixture)
        let board = try await waitForBoard(viewModel) { !$0.todo.isEmpty }
        #expect(board.canRemind)
        
        let noSheet = deferFailure(viewModel.actionsPublisher, timeout: .milliseconds(300)) { _ in true }
        viewModel.context.send(viewAction: .remindMe(id: "c-old"))
        try await noSheet.fulfill()
        
        let deferred = deferFulfillment(viewModel.actionsPublisher) { _ in true }
        viewModel.context.send(viewAction: .remindMe(id: threadCardID))
        let target = RemindMeTarget(message: "Plan", threadID: thread, dueAt: aNow + 5000)
        #expect(try await deferred.fulfill() == .presentRemindMe(target, cardID: threadCardID))
        
        // The sheet the board's flow presents records the command on the card through its onRequested, keeping what the card says.
        let parameters = RemindMeScreenCoordinatorParameters.task(target, cardID: threadCardID, store: viewModel.store, userIndicatorController: UserIndicatorControllerMock())
        #expect(parameters.target == target)
        let onRequested = try #require(parameters.onRequested)
        await onRequested(ReminderRequestRef(eventID: "$remind", at: aNow + 7200))
        let written = try #require(card(fixture.sent.last))
        #expect(written.object("reminder_requested")?.string("event_id") == "$remind")
        #expect(written.string("description") == "Steps")
    }
    
    @Test
    func remindMeIsntOfferedToSomeoneWhoCantPost() async throws {
        let fixture = try linkedTaskFixture()
        (fixture.roomInfo.powerLevels as? RoomPowerLevelsProxyMock)?.canOwnUserSendMessageClosure = { type in
            type != .roomMessage
        }
        let viewModel = makeViewModel(fixture)
        let board = try await waitForBoard(viewModel) { !$0.todo.isEmpty }
        #expect(!board.canRemind)
    }
    
    // MARK: Moving and archiving
    
    @Test
    func movingATaskWritesItsNewStatus() async throws {
        let fixture = try linkedTaskFixture()
        let viewModel = makeViewModel(fixture)
        _ = try await waitForBoard(viewModel) { !$0.todo.isEmpty }
        
        viewModel.context.send(viewAction: .move(id: threadCardID, status: .done))
        let board = try await waitForBoard(viewModel) { !$0.done.isEmpty }
        #expect(board.done.map(\.id) == [threadCardID])
        #expect(fixture.sent.map(\.type) == [MatchaConfig.eventKanbanCard])
        #expect(card(fixture.sent.last)?.string("column") == "done")
        #expect(card(fixture.sent.last)?.string("description") == "Steps")
        
        // Moving to the current status sends nothing.
        viewModel.context.send(viewAction: .move(id: threadCardID, status: .done))
        await viewModel.store.settle()
        #expect(fixture.sent.count == 1)
    }
    
    @Test
    func movingATaskWhoseCardIsOlderThanTheHistoryReadKeepsWhatTheCardSays() async throws {
        // The thread started at 100 ms; its card was written at 150 ms, in the eleventh page, older than the ten read up front.
        let fixture = try MatchaRoomFixture(olderPages: Array(repeating: [], count: 10)
            + [[aBoardCardItem(150, id: threadCardID, title: "Plan", status: .doing, threadID: thread, description: "Steps", dueAt: aNow + 5000)],
               [aBoardCardItem(50, id: "c-older", title: "Older")]],
            threads: [aThreadListItem(thread, body: "Plan", timestamp: 100)])
        fixture.boardPointer = .success(aBoardRoot)
        let viewModel = makeViewModel(fixture)
        
        // Until its card is read, the thread's task shows the defaults.
        _ = try await waitForBoard(viewModel) { !$0.todo.isEmpty }
        viewModel.context.send(viewAction: .move(id: threadCardID, status: .done))
        _ = try await waitForBoard(viewModel) { !$0.done.isEmpty }
        let written = try #require(card(fixture.sent.last))
        #expect(fixture.sent.count == 1)
        #expect(written.string("column") == "done")
        #expect(written.string("description") == "Steps")
        #expect(written.integer("due_at") == aNow + 5000)
    }
    
    @Test
    func historyFromBeforeAThreadStartedIsntReadForItsTask() async throws {
        var pagesRead = 0
        // The history read so far already reaches back before the thread started.
        let fixture = try MatchaRoomFixture(items: [aBoardCardItem(50, id: "c-older", title: "Older")],
                                            olderPages: Array(repeating: [], count: 12),
                                            threads: [aThreadListItem(thread, body: "Plan", timestamp: 100)])
        fixture.boardPointer = .success(aBoardRoot)
        fixture.paginateResult = {
            pagesRead += 1
            return .success(())
        }
        let viewModel = makeViewModel(fixture)
        
        _ = try await waitForBoard(viewModel) { $0.todo.count == 2 }
        await viewModel.store.settle()
        viewModel.context.send(viewAction: .move(id: threadCardID, status: .done))
        _ = try await waitForBoard(viewModel) { !$0.done.isEmpty }
        #expect(card(fixture.sent.last)?.string("column") == "done")
        #expect(pagesRead == MatchaConfig.initialHistoryPages)
    }
    
    @Test
    func aTaskWhoseHistoryCantBeReadIsntWrittenOver() async throws {
        let fixture = MatchaRoomFixture(olderPages: Array(repeating: [], count: 12), threads: [aThreadListItem(thread, body: "Plan", timestamp: 100)])
        fixture.boardPointer = .success(aBoardRoot)
        fixture.sendResult = { _, _ in
            Issue.record("Nothing must be sent")
            return .success("$sent")
        }
        let viewModel = makeViewModel(fixture)
        _ = try await waitForBoard(viewModel) { !$0.todo.isEmpty }
        await viewModel.store.settle()
        
        fixture.paginateResult = { .failure(.sdkError(RoomProxyMockError.generic)) }
        viewModel.context.send(viewAction: .move(id: threadCardID, status: .done))
        let banner = try await waitForBanner(viewModel)
        #expect(banner.message == UntranslatedL10n.screenMatchaTasksHistoryIncomplete)
        #expect(banner.actionTitle == L10n.actionRetry)
    }
    
    @Test
    func archivingAThreadsTaskArchivesTheThreadTooAndUndoRestoresBoth() async throws {
        let fixture = try linkedTaskFixture()
        let viewModel = makeViewModel(fixture)
        _ = try await waitForBoard(viewModel) { !$0.todo.isEmpty }
        
        viewModel.context.send(viewAction: .setArchived(id: threadCardID, archived: true))
        _ = try await waitForBoard(viewModel) { !$0.archived.isEmpty }
        let banner = try await waitForBanner(viewModel)
        #expect(fixture.sent.map(\.type) == [MatchaConfig.eventThreadMetadata, MatchaConfig.eventKanbanCard])
        #expect(fixture.sent.allSatisfy { JSONValue(json: $0.content)?.objectValue?.bool("archived") == true })
        #expect(banner.message == UntranslatedL10n.screenMatchaTasksArchivedSnackbar)
        #expect(banner.actionTitle == UntranslatedL10n.actionMatchaUndo)
        
        viewModel.context.send(viewAction: .bannerAction)
        _ = try await waitForBoard(viewModel) { $0.archived.isEmpty && !$0.todo.isEmpty }
        await viewModel.store.settle()
        #expect(fixture.sent.count == 4)
        #expect(fixture.sent.dropFirst(2).allSatisfy { JSONValue(json: $0.content)?.objectValue?.bool("archived") == false })
        // Undo says nothing more.
        #expect(viewModel.context.viewState.banner == nil)
    }
    
    @Test
    func unarchivingFromTheArchivedTasksOffersUndo() async throws {
        let fixture = try MatchaRoomFixture(items: [aBoardCardItem(1, id: "c-legacy", title: "Legacy", archived: true)])
        fixture.boardPointer = .success(aBoardRoot)
        let viewModel = makeViewModel(fixture)
        _ = try await waitForBoard(viewModel) { !$0.archived.isEmpty }
        
        let deferred = deferFulfillment(viewModel.actionsPublisher) { _ in true }
        viewModel.context.send(viewAction: .showArchived)
        #expect(try await deferred.fulfill() == .presentArchived)
        
        viewModel.context.send(viewAction: .setArchived(id: "c-legacy", archived: false))
        _ = try await waitForBoard(viewModel) { !$0.todo.isEmpty }
        let banner = try await waitForBanner(viewModel)
        #expect(banner.message == UntranslatedL10n.screenMatchaTasksUnarchivedSnackbar)
        #expect(banner.actionTitle == UntranslatedL10n.actionMatchaUndo)
    }
    
    @Test(arguments: [false, true])
    func theBannerClosesByItselfUnlessVoiceOverRuns(isVoiceOverRunning: Bool) async throws {
        let fixture = try linkedTaskFixture()
        let viewModel = TasksBoardScreenViewModel(store: fixture.store(), formatDeadline: formatDeadline, now: now, bannerDuration: .milliseconds(50),
                                                  isVoiceOverRunning: { isVoiceOverRunning }, announce: { _ in })
        _ = try await waitForBoard(viewModel) { !$0.todo.isEmpty }
        
        viewModel.context.send(viewAction: .setArchived(id: threadCardID, archived: true))
        _ = try await waitForBanner(viewModel)
        try await Task.sleep(for: .milliseconds(300))
        // With VoiceOver, Undo stays until it is used or the banner dismissed.
        #expect((viewModel.context.viewState.banner != nil) == isVoiceOverRunning)
        viewModel.context.send(viewAction: .dismissBanner)
        #expect(viewModel.context.viewState.banner == nil)
    }
    
    @Test
    func aFailedWriteOffersToRetryTheSameWrite() async throws {
        var fails = true
        let fixture = try linkedTaskFixture()
        fixture.sendResult = { _, _ in fails ? .failure(.sdkError(RoomProxyMockError.generic)) : .success("$e\(UUID().uuidString)") }
        let viewModel = makeViewModel(fixture)
        _ = try await waitForBoard(viewModel) { !$0.todo.isEmpty }
        
        viewModel.context.send(viewAction: .move(id: threadCardID, status: .doing))
        let banner = try await waitForBanner(viewModel)
        #expect(banner.message == UntranslatedL10n.commonMatchaWriteFailed)
        #expect(banner.actionTitle == L10n.actionRetry)
        
        fails = false
        viewModel.context.send(viewAction: .bannerAction)
        _ = try await waitForBoard(viewModel) { !$0.doing.isEmpty }
        #expect(card(fixture.sent.last)?.string("column") == "doing")
    }
    
    @Test
    func aMoveFinishesAfterTheBoardIsGone() async throws {
        let fixture = try linkedTaskFixture()
        let sendGate = Gate()
        var sent = [String]()
        fixture.room.sendRawEventTypeContentJSONClosure = { type, _ in
            await sendGate.wait()
            sent.append(type)
            return .success("$e\(UUID().uuidString)")
        }
        var viewModel: TasksBoardScreenViewModel? = makeViewModel(fixture)
        let store = try #require(viewModel?.store)
        _ = try await waitForBoard(#require(viewModel)) { !$0.todo.isEmpty }
        
        viewModel?.context.send(viewAction: .move(id: threadCardID, status: .done))
        viewModel = nil
        sendGate.open()
        await waitForSnapshot(store) { $0.board?.cards.first?.status == .done }
        #expect(sent == [MatchaConfig.eventKanbanCard])
    }
    
    // MARK: - Helpers
    
    private let aNow: Int64 = 1_700_000_000_000
    
    private func now() -> Date {
        Date(timeIntervalSince1970: TimeInterval(aNow) / 1000)
    }
    
    private func formatDeadline(_ millis: Int64) -> String {
        "at \(millis)"
    }
    
    private func makeViewModel(_ fixture: MatchaRoomFixture) -> TasksBoardScreenViewModel {
        TasksBoardScreenViewModel(store: fixture.store(), formatDeadline: formatDeadline, now: now)
    }
    
    /// A board with one thread, "Plan", whose task has a description and a deadline. Every send gets its own event id.
    private func linkedTaskFixture(extraItems: [TimelineItemProxy] = []) throws -> MatchaRoomFixture {
        let fixture = try MatchaRoomFixture(items: [aBoardCardItem(1, id: threadCardID, title: "Plan", threadID: thread, description: "Steps", dueAt: aNow + 5000)] + extraItems,
                                            threads: [aThreadListItem(thread, body: "Plan")])
        fixture.boardPointer = .success(aBoardRoot)
        fixture.sendResult = { _, _ in .success("$e\(UUID().uuidString)") }
        return fixture
    }
    
    private func card(_ sent: (type: String, content: String)?) -> JSONObject? {
        sent.flatMap { JSONValue(json: $0.content)?.objectValue }
    }
    
    @discardableResult
    private func waitForContent(_ viewModel: TasksBoardScreenViewModel,
                                sourceLocation: SourceLocation = #_sourceLocation,
                                _ condition: @escaping (TasksBoardContent) -> Bool) async throws -> TasksBoardContent {
        try await deferFulfillment(viewModel.context.observe(\.viewState.content), sourceLocation: sourceLocation, until: condition).fulfill()
    }
    
    private func waitForBoard(_ viewModel: TasksBoardScreenViewModel,
                              sourceLocation: SourceLocation = #_sourceLocation,
                              _ condition: @escaping (TasksBoard) -> Bool = { _ in true }) async throws -> TasksBoard {
        let content = try await waitForContent(viewModel, sourceLocation: sourceLocation) { content in
            if case .board(let board) = content {
                condition(board)
            } else {
                false
            }
        }
        guard case .board(let board) = content else { throw CancellationError() }
        return board
    }
    
    private func waitForBanner(_ viewModel: TasksBoardScreenViewModel, sourceLocation: SourceLocation = #_sourceLocation) async throws -> TaskBanner {
        let banner = try await deferFulfillment(viewModel.context.observe(\.viewState.banner), sourceLocation: sourceLocation) { $0 != nil }.fulfill()
        return try #require(banner)
    }
    
    /// Every content the view model shows from now on, as far as observed.
    private func recordContents(of viewModel: TasksBoardScreenViewModel) -> ContentRecorder {
        let recorder = ContentRecorder()
        Task {
            for await content in viewModel.context.observe(\.viewState.content) {
                recorder.values.append(content)
            }
        }
        return recorder
    }
}

private final class ContentRecorder {
    var values: [TasksBoardContent] = []
}

private extension TasksBoardContent {
    var board: TasksBoard? {
        if case .board(let board) = self {
            board
        } else {
            nil
        }
    }
}

/// A scan timeline item carrying a card revision with every field, of the board at `aBoardRoot`.
func aBoardCardItem(_ index: Int,
                    id: String,
                    title: String,
                    status: TaskStatus = .todo,
                    threadID: String? = nil,
                    description: String = "",
                    dueAt: Int64? = nil,
                    archived: Bool = false,
                    showToRoom: Bool = true,
                    sender: String = "@bob:x") throws -> TimelineItemProxy {
    let card = CardRevision(cardID: id, title: title, description: description, status: status, archived: archived, threadID: threadID,
                            dueAt: dueAt, reminderRequested: nil, showToRoom: showToRoom)
    return try aMatchaEventItem(index, type: MatchaConfig.eventKanbanCard, content: KanbanProtocol.cardContent(card, rootID: aBoardRoot), sender: sender)
}
