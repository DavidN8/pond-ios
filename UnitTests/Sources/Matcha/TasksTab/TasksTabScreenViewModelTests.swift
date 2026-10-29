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
import SwiftUI
import Testing

@MainActor
struct TasksTabScreenViewModelTests {
    private let design = "!design:x"
    private let launch = "!launch:x"
    private let chat = "!chat:x"
    private let dm = "!dm:x"
    private let acme = "!acme:x"
    private let acmeSub = "!acme-sub:x"
    private let bob = "@bob:x"
    private let carol = "@carol:x"
    
    @Test
    func theTasksOfEveryChatWithABoardAreGroupedByDeadlineAndNameTheirChat() async throws {
        let tab = try TasksTab(rooms: [boardRoom(design,
                                                 linkedCard(1, "$t1", "Book the venue", dueAt: aNow - 3_600_000),
                                                 linkedCard(2, "$t2", "Draft the press release", dueAt: at(day: 5, hour: 12)),
                                                 linkedCard(3, "$t3", "Pick the date", status: .done)),
                                       boardRoom(launch,
                                                 linkedCard(1, "$t4", "Order the banners", status: .doing, dueAt: at(day: 0, hour: 23, minute: 59)),
                                                 linkedCard(2, "$t5", "Print the flyers", dueAt: at(day: 1, hour: 12)),
                                                 legacyCard(3, "Call the caterer"),
                                                 linkedCard(4, "$t6", "Old idea", archived: true)),
                                       MatchaRoomFixture(roomID: chat)])
        let viewModel = makeViewModel(tab)
        
        let state = try await waitForState(viewModel) { $0.checkingCount == 0 && $0.titles.count == 5 }
        guard case .tasks(let groups, let done, let isDoneExpanded) = state.content else {
            Issue.record("Not a list")
            return
        }
        #expect(groups.map(\.section) == [.overdue, .today, .tomorrow, .upcoming, .noDeadline])
        #expect(groups.map { $0.tasks.map(\.task.title) } == [["Book the venue"], ["Order the banners"], ["Print the flyers"], ["Draft the press release"], ["Call the caterer"]])
        #expect(groups.first?.tasks.first?.chat.name == design)
        #expect(done.map(\.task.title) == ["Pick the date"])
        #expect(!isDoneExpanded)
    }
    
    @Test
    func theDeadlineGroupsAreReadAgainWhenTheDayChanges() async throws {
        let tab = try TasksTab(rooms: [boardRoom(design, linkedCard(1, "$t1", "Print the flyers", dueAt: at(day: 1, hour: 12)))])
        var clock = aNowDate
        let rooms = tab.tasksTabRooms()
        let readClock = { clock }
        let viewModel = makeViewModel(tab, rooms: rooms, now: readClock)
        #expect(try await waitForState(viewModel) { !$0.titles.isEmpty && $0.checkingCount == 0 }.sections == [.tomorrow])
        await rooms.chatsPublisher.value.boards.first?.room.store.settle()
        
        // Just past midnight: nothing groups the tasks again until the system says the time changed.
        clock = Date(timeIntervalSince1970: TimeInterval(at(day: 1, hour: 0, minute: 1)) / 1000)
        try await Task.sleep(for: .milliseconds(200))
        #expect(viewModel.context.viewState.sections == [.tomorrow])
        NotificationCenter.default.post(name: UIApplication.significantTimeChangeNotification, object: nil)
        try await waitForState(viewModel) { $0.sections == [.today] }
    }
    
    @Test
    func theTabRecomputesNothingWhileHiddenAndCatchesUpOnceShownAgain() async throws {
        let tab = try TasksTab(rooms: [boardRoom(design, linkedCard(1, "$t1", "Book the venue"))])
        let rooms = tab.tasksTabRooms(clock: tab.clock)
        let viewModel = makeViewModel(tab, rooms: rooms)
        try await waitForState(viewModel) { $0.titles == ["Book the venue"] }
        
        viewModel.context.send(viewAction: .disappeared)
        // The tab's chats are let go a while after it goes, and say so.
        await tab.clock.waitForScheduledSleep()
        tab.clock.advance(by: MatchaConfig.tasksTabKeepAlive + .seconds(1))
        await eventually { rooms.chatsPublisher.value.boards.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        #expect(viewModel.context.viewState.titles == ["Book the venue"])
        
        viewModel.context.send(viewAction: .appeared)
        try await waitForState(viewModel) { $0.titles == ["Book the venue"] && $0.checkingCount == 0 }
    }
    
    @Test
    func theChipsSelectAStatusTheDoneTasksOrTheArchivedOnes() async throws {
        let tab = try TasksTab(rooms: [boardRoom(design,
                                                 linkedCard(1, "$t1", "Book the venue"),
                                                 linkedCard(2, "$t2", "Order the banners", status: .doing),
                                                 linkedCard(3, "$t3", "Pick the date", status: .done),
                                                 linkedCard(4, "$t4", "Old idea", archived: true))])
        let viewModel = makeViewModel(tab)
        
        // Newest thread first, with no deadline.
        #expect(try await waitForState(viewModel) { $0.titles.count == 2 }.titles == ["Order the banners", "Book the venue"])
        viewModel.context.send(viewAction: .toggleDone)
        #expect(viewModel.context.viewState.titles == ["Order the banners", "Book the venue", "Pick the date"])
        viewModel.context.send(viewAction: .setFilter(.doing))
        #expect(viewModel.context.viewState.titles == ["Order the banners"])
        viewModel.context.send(viewAction: .setFilter(.done))
        #expect(viewModel.context.viewState.titles == ["Pick the date"])
        guard case .tasks(let groups, _, _) = viewModel.context.viewState.content else {
            Issue.record("Not a list")
            return
        }
        #expect(groups.map(\.section) == [nil])
        viewModel.context.send(viewAction: .setFilter(.archived))
        #expect(viewModel.context.viewState.titles == ["Old idea"])
    }
    
    @Test
    func chatNarrowsTheListToAChosenChatAndTappingItAgainShowsEveryChat() async throws {
        let tab = try TasksTab(rooms: [boardRoom(design, linkedCard(1, "$t1", "Book the venue")),
                                       boardRoom(launch, linkedCard(1, "$t2", "Print the flyers")),
                                       MatchaRoomFixture(roomID: chat)])
        let viewModel = makeViewModel(tab)
        try await waitForState(viewModel) { $0.titles.count == 2 && $0.checkingCount == 0 }
        
        viewModel.context.send(viewAction: .toggleChatFilter)
        #expect(viewModel.context.sheet == .chooseChat(.filter))
        // Only the chats with a board are offered, and the search narrows them.
        #expect(viewModel.context.viewState.chatChoices.map(\.roomID) == [design, launch])
        viewModel.context.chatSearchQuery = "LAUN"
        #expect(viewModel.context.viewState.visibleChatChoices.map(\.roomID) == [launch])
        
        viewModel.context.send(viewAction: .chooseChat(roomID: launch))
        #expect(viewModel.context.sheet == nil)
        #expect(viewModel.context.viewState.chatFilter?.roomID == launch)
        #expect(viewModel.context.viewState.titles == ["Print the flyers"])
        viewModel.context.send(viewAction: .toggleChatFilter)
        #expect(viewModel.context.viewState.chatFilter == nil)
        #expect(viewModel.context.viewState.titles.count == 2)
    }
    
    @Test
    func leavingAChatDropsItsTasksAtOnce() async throws {
        let tab = try TasksTab(rooms: [boardRoom(design, linkedCard(1, "$t1", "Book the venue")),
                                       boardRoom(launch, linkedCard(1, "$t2", "Print the flyers"))])
        let viewModel = makeViewModel(tab)
        try await waitForState(viewModel) { $0.titles.count == 2 }
        
        tab.summaries.send([RoomSummary.mock(id: design, name: design)])
        #expect(try await waitForState(viewModel) { $0.titles.count == 1 }.titles == ["Book the venue"])
    }
    
    @Test
    func tappingATaskOpensItsThreadAndAnOlderCardWithoutOneOpensItsChat() async throws {
        let tab = try TasksTab(rooms: [boardRoom(design, linkedCard(1, "$t1", "Book the venue"), legacyCard(2, "Call the caterer"))])
        let viewModel = makeViewModel(tab)
        let actions = record(viewModel)
        try await waitForState(viewModel) { $0.titles.count == 2 }
        
        viewModel.context.send(viewAction: .openTask(TabTaskID(roomID: design, taskID: KanbanProtocol.threadCardID("$t1"))))
        viewModel.context.send(viewAction: .openTask(TabTaskID(roomID: design, taskID: "legacy")))
        #expect(actions.values == [.presentThread(roomID: design, threadRootEventID: "$t1"), .presentRoom(roomID: design)])
    }
    
    @Test
    func theActionsActOnTheTaskInItsOwnChatAndOfferItsChat() async throws {
        let designRoom = try boardRoom(design, linkedCard(1, "$t1", "Book the venue"))
        let launchRoom = try boardRoom(launch, linkedCard(1, "$t2", "Print the flyers"))
        launchRoom.sendResult = { _, _ in
            Issue.record("Nothing must be sent here")
            return .success("$sent")
        }
        let tab = TasksTab(rooms: [designRoom, launchRoom])
        let viewModel = makeViewModel(tab)
        let actions = record(viewModel)
        try await waitForState(viewModel) { $0.titles.count == 2 }
        let id = TabTaskID(roomID: design, taskID: KanbanProtocol.threadCardID("$t1"))
        
        viewModel.context.send(viewAction: .showActions(id))
        let task = try #require(viewModel.context.viewState.actionsTask)
        #expect(task.chat.roomID == design)
        #expect(task.canEdit)
        #expect(task.canArchive)
        
        viewModel.context.send(viewAction: .move(id, status: .doing))
        #expect(viewModel.context.actionsTaskID == nil)
        await eventually { !designRoom.sent.isEmpty }
        #expect(designRoom.sent.map(\.type) == [MatchaConfig.eventKanbanCard])
        #expect(JSONValue(json: designRoom.sent.last?.content ?? "")?.objectValue?.string("column") == "doing")
        
        viewModel.context.send(viewAction: .openChat(roomID: design))
        #expect(actions.values == [.presentRoom(roomID: design)])
    }
    
    @Test
    func aNewTaskAsksForAChatWhereTasksCanBeAddedThenOpensItsEditorInTheChipsStatus() async throws {
        let launchRoom = try boardRoom(launch, linkedCard(1, "$t2", "Print the flyers"))
        // Adding a task creates its thread, so a chat where the user can't post isn't offered.
        (launchRoom.roomInfo.powerLevels as? RoomPowerLevelsProxyMock)?.canOwnUserSendMessageClosure = { $0 != .roomMessage }
        let tab = try TasksTab(rooms: [boardRoom(design, linkedCard(1, "$t1", "Book the venue")), launchRoom])
        let viewModel = makeViewModel(tab)
        let actions = record(viewModel)
        try await waitForState(viewModel) { $0.titles.count == 2 && $0.checkingCount == 0 }
        
        viewModel.context.send(viewAction: .setFilter(.doing))
        viewModel.context.send(viewAction: .newTask)
        #expect(viewModel.context.sheet == .chooseChat(.newTask))
        #expect(viewModel.context.viewState.chatChoices.map(\.roomID) == [design])
        viewModel.context.send(viewAction: .chooseChat(roomID: design))
        #expect(viewModel.context.sheet == nil)
        #expect(actions.values == [.presentEditor(roomID: design, target: .new(status: .doing))])
    }
    
    @Test
    func withAChatChosenANewTaskGoesThereWithoutAsking() async throws {
        let tab = try TasksTab(rooms: [boardRoom(design, linkedCard(1, "$t1", "Book the venue"))])
        let viewModel = makeViewModel(tab)
        let actions = record(viewModel)
        try await waitForState(viewModel) { !$0.titles.isEmpty }
        
        viewModel.context.send(viewAction: .toggleChatFilter)
        viewModel.context.send(viewAction: .chooseChat(roomID: design))
        viewModel.context.send(viewAction: .newTask)
        #expect(viewModel.context.sheet == nil)
        #expect(actions.values == [.presentEditor(roomID: design, target: .new(status: .todo))])
    }
    
    @Test
    func chatsThatCantBeCheckedAreCountedAndRetryChecksThemAgain() async throws {
        let room = MatchaRoomFixture(roomID: design)
        room.serverPointer = { .failure(.sdkError(RoomProxyMockError.generic)) }
        let tab = TasksTab(rooms: [room])
        let viewModel = makeViewModel(tab)
        
        #expect(try await waitForState(viewModel) { $0.failedCount == 1 }.content == .empty)
        room.serverPointer = { .success(nil) }
        viewModel.context.send(viewAction: .retry)
        #expect(try await waitForState(viewModel) { $0.failedCount == 0 && $0.checkingCount == 0 }.content == .empty)
    }
    
    @Test
    func archivingATaskOffersUndoWhichRestoresItAndItsThread() async throws {
        let room = try boardRoom(design, linkedCard(1, "$t1", "Book the venue"))
        let tab = TasksTab(rooms: [room])
        let viewModel = makeViewModel(tab)
        try await waitForState(viewModel) { !$0.titles.isEmpty }
        
        viewModel.context.send(viewAction: .setArchived(TabTaskID(roomID: design, taskID: KanbanProtocol.threadCardID("$t1")), archived: true))
        // The archived task leaves the list once its echo shows.
        let banner = try #require(try await waitForState(viewModel) { $0.banner != nil && $0.titles.isEmpty }.banner)
        #expect(banner.actionTitle == UntranslatedL10n.actionMatchaUndo)
        #expect(room.sent.map(\.type) == [MatchaConfig.eventThreadMetadata, MatchaConfig.eventKanbanCard])
        
        viewModel.context.send(viewAction: .bannerAction)
        try await waitForState(viewModel) { !$0.titles.isEmpty }
        await eventually { room.sent.count == 4 }
        #expect(room.sent.dropFirst(2).map(\.type) == [MatchaConfig.eventThreadMetadata, MatchaConfig.eventKanbanCard])
        #expect(JSONValue(json: room.sent.last?.content ?? "")?.objectValue?.bool("archived") == false)
    }
    
    @Test
    func whileVoiceOverRunsTheBannerStaysUntilItIsUsedOrDismissed() async throws {
        let tab = try TasksTab(rooms: [boardRoom(design, linkedCard(1, "$t1", "Book the venue"))])
        let viewModel = TasksTabScreenViewModel(rooms: tab.tasksTabRooms(), clientProxy: tab.client, bannerDuration: .milliseconds(50),
                                                isVoiceOverRunning: { true }, announce: { _ in })
        viewModel.context.send(viewAction: .appeared)
        try await waitForState(viewModel) { !$0.titles.isEmpty }
        
        viewModel.context.send(viewAction: .setArchived(TabTaskID(roomID: design, taskID: KanbanProtocol.threadCardID("$t1")), archived: true))
        try await waitForState(viewModel) { $0.banner != nil }
        try await Task.sleep(for: .milliseconds(300))
        #expect(viewModel.context.viewState.banner != nil)
        viewModel.context.send(viewAction: .dismissBanner)
        #expect(viewModel.context.viewState.banner == nil)
    }
    
    @Test
    func archivingATaskSomeoneElseHasArchivedMeanwhileSendsNothingAndOffersNoUndo() async throws {
        let room = try boardRoom(design, linkedCard(1, "$t1", "Book the venue"), linkedCard(2, "$t2", "Old idea", archived: true))
        let tab = TasksTab(rooms: [room])
        let viewModel = makeViewModel(tab)
        try await waitForState(viewModel) { !$0.titles.isEmpty }
        
        // A row drawn before the task was archived elsewhere still offers Archive; Undo would then restore it.
        viewModel.context.send(viewAction: .setArchived(TabTaskID(roomID: design, taskID: KanbanProtocol.threadCardID("$t2")), archived: true))
        // A write after it, so the first one has had its turn once this one is sent.
        viewModel.context.send(viewAction: .move(TabTaskID(roomID: design, taskID: KanbanProtocol.threadCardID("$t1")), status: .doing))
        await eventually { !room.sent.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        #expect(room.sent.map(\.type) == [MatchaConfig.eventKanbanCard])
        #expect(viewModel.context.viewState.banner == nil)
    }
    
    @Test
    func aTasksPeopleAreListedInAndroidsOrderWithTheThreadsStarterFirst() async throws {
        let designRoom = try boardRoom(design,
                                       linkedCard(1, "$carols", "Carol's thread", startedBy: carol),
                                       threadReplies: ["$carols": [reply(1, in: "$carols", sender: bob), reply(2, in: "$carols", sender: matchaUser)]])
        let viewModel = makeViewModel(TasksTab(rooms: [designRoom]))
        
        let state = try await waitForState(viewModel) { state in
            state.checkingCount == 0 && state.titles == ["Carol's thread"] && state.tasks.allSatisfy { $0.people.allSatisfy { !$0.hasPrefix("@") } }
        }
        #expect(state.tasks.first?.people == ["Carol", "Bob"])
    }
    
    @Test
    func onlyTheTasksThatInvolveTheUserAreListedFromTheirThreadsAndTheirDirectChats() async throws {
        let designRoom = try boardRoom(design,
                                       linkedCard(1, "$mine", "My thread"),
                                       linkedCard(2, "$replied", "Bob's thread I replied to", startedBy: bob),
                                       // Shared with the chat, but not the user's: it stays on the chat's board.
                                       linkedCard(3, "$others", "Bob's thread", startedBy: bob),
                                       legacyCard(4, "My older card", id: "mine"),
                                       legacyCard(5, "Bob's older card", id: "bobs", writtenBy: bob),
                                       threadReplies: ["$replied": [reply(1, in: "$replied", sender: carol), reply(2, in: "$replied", sender: matchaUser)]])
        let dmRoom = try boardRoom(dm, linkedCard(1, "$dm", "Bob's task in our chat", startedBy: bob, showToRoom: false), isDirect: true, heroes: [bob])
        let tab = TasksTab(rooms: [designRoom, dmRoom])
        let viewModel = makeViewModel(tab)
        
        let state = try await waitForState(viewModel) { state in
            state.checkingCount == 0 && state.titles.count == 4 && state.tasks.allSatisfy { $0.people.allSatisfy { !$0.hasPrefix("@") } }
        }
        #expect(Set(state.titles) == ["My thread", "Bob's thread I replied to", "My older card", "Bob's task in our chat"])
        let people = Dictionary(uniqueKeysWithValues: state.tasks.map { ($0.task.title ?? "", $0.people) })
        #expect(people["My thread"] == [])
        #expect(people["Bob's thread I replied to"] == ["Bob", "Carol"])
        #expect(people["Bob's task in our chat"] == ["Bob"])
        // A direct chat's members are in every task anyway, so its tasks aren't marked as shared.
        #expect(Set(state.tasks.filter(\.task.isSharedWithChat).map(\.task.title)) == ["My thread", "Bob's thread I replied to", "My older card"])
        #expect(state.people.map(\.name) == ["Bob", "Carol"])
    }
    
    @Test
    func peopleNarrowsTheListToOnePersonsTasksAndTappingItAgainShowsEveryonesTasks() async throws {
        let tab = try TasksTab(rooms: [boardRoom(design,
                                                 linkedCard(1, "$t1", "With Bob", startedBy: bob),
                                                 linkedCard(2, "$t2", "With Carol"),
                                                 linkedCard(3, "$t3", "Alone"),
                                                 threadReplies: ["$t1": [reply(1, in: "$t1", sender: matchaUser)], "$t2": [reply(2, in: "$t2", sender: carol)]])])
        let viewModel = makeViewModel(tab)
        try await waitForState(viewModel) { $0.titles.count == 3 && Set($0.tasks.flatMap(\.people)) == ["Bob", "Carol"] }
        
        viewModel.context.send(viewAction: .togglePersonFilter)
        #expect(viewModel.context.sheet == .choosePerson)
        // Everyone else the user's tasks involve, by name.
        #expect(viewModel.context.viewState.people == [TasksTabPerson(userID: bob, name: "Bob"), TasksTabPerson(userID: carol, name: "Carol")])
        viewModel.context.send(viewAction: .choosePerson(userID: carol))
        #expect(viewModel.context.sheet == nil)
        #expect(viewModel.context.viewState.personFilter == TasksTabPerson(userID: carol, name: "Carol"))
        #expect(viewModel.context.viewState.titles == ["With Carol"])
        viewModel.context.send(viewAction: .togglePersonFilter)
        #expect(viewModel.context.viewState.personFilter == nil)
        #expect(viewModel.context.viewState.titles.count == 3)
    }
    
    @Test
    func theTableHoldsTheTasksTheChipsSelectAndSortsByTheTappedColumn() async throws {
        let tab = try TasksTab(rooms: [boardRoom(design,
                                                 linkedCard(1, "$t1", "Book the venue", dueAt: aNow + 2000),
                                                 linkedCard(2, "$t2", "Archive me", archived: true),
                                                 linkedCard(3, "$t3", "Call the caterer"),
                                                 linkedCard(4, "$t4", "Draft the release", status: .done, dueAt: aNow + 1000)),
                                       boardRoom(launch, linkedCard(1, "$t5", "Order the banners", status: .doing, dueAt: aNow + 3000))])
        let viewModel = makeViewModel(tab)
        try await waitForState(viewModel) { $0.checkingCount == 0 && $0.titles.count == 3 }
        
        viewModel.context.send(viewAction: .toggleTable)
        // By deadline, soonest first and none last, done tasks included under All.
        #expect(viewModel.context.viewState.isTable)
        #expect(viewModel.context.viewState.titles == ["Draft the release", "Book the venue", "Order the banners", "Call the caterer"])
        #expect(viewModel.context.viewState.tableSort == TaskTableSort(column: .due, isAscending: true))
        viewModel.context.send(viewAction: .sortTable(.due))
        // The other way round, still with the tasks without a deadline last.
        #expect(viewModel.context.viewState.titles == ["Order the banners", "Book the venue", "Draft the release", "Call the caterer"])
        viewModel.context.send(viewAction: .sortTable(.status))
        #expect(viewModel.context.viewState.titles == ["Book the venue", "Call the caterer", "Order the banners", "Draft the release"])
        viewModel.context.send(viewAction: .sortTable(.chat))
        #expect(viewModel.context.viewState.titles.first != "Order the banners")
        viewModel.context.send(viewAction: .sortTable(.chat))
        #expect(viewModel.context.viewState.titles.first == "Order the banners")
        viewModel.context.send(viewAction: .setFilter(.archived))
        #expect(viewModel.context.viewState.titles == ["Archive me"])
        viewModel.context.send(viewAction: .setFilter(.done))
        #expect(viewModel.context.viewState.titles == ["Draft the release"])
        viewModel.context.send(viewAction: .toggleTable)
        guard case .tasks = viewModel.context.viewState.content else {
            Issue.record("Not a list")
            return
        }
    }
    
    @Test
    func theTablePutsRowsWithoutAValueInTheSortedColumnLastEitherWay() {
        func row(_ title: String?, people: [String], chat: String) -> TabTask {
            TabTask(chat: TasksTabChat(roomID: design, name: chat, avatarURL: nil),
                    task: TaskItem(id: title ?? "untitled", title: title, summary: "", status: .todo, isArchived: false, threadID: nil, dueAt: nil, deadline: nil,
                                   isOverdue: false, replyCount: nil, hasReminder: false, isSharedWithChat: false, participants: []),
                    createdAt: 0,
                    people: people,
                    canEdit: true,
                    canArchive: true)
        }
        let rows = [row("b", people: [], chat: "gamma"), row(nil, people: ["Carol"], chat: "Alpha"), row("A", people: ["bob"], chat: "beta")]
        func titles(_ column: TaskTableColumn, isAscending: Bool) -> [String?] {
            rows.sorted(for: TaskTableSort(column: column, isAscending: isAscending)).map(\.task.title)
        }
        #expect(titles(.task, isAscending: true) == ["A", "b", nil])
        #expect(titles(.task, isAscending: false) == ["b", "A", nil])
        #expect(titles(.people, isAscending: true) == ["A", nil, "b"])
        #expect(titles(.people, isAscending: false) == [nil, "A", "b"])
        #expect(titles(.chat, isAscending: false) == ["b", "A", nil])
        // Equal rows keep their order.
        #expect(titles(.due, isAscending: false) == ["b", nil, "A"])
    }
    
    // MARK: A space's boards
    
    @Test
    func withASpaceTheBoardsOfItsChannelsAreListedWithWhatEachBoardShows() async throws {
        let tab = try TasksTab(rooms: [boardRoom(design,
                                                 linkedCard(1, "$shared", "Bob's shared task", startedBy: bob),
                                                 linkedCard(2, "$private", "Bob's private task", startedBy: bob, showToRoom: false)),
                                       boardRoom(launch, linkedCard(1, "$launch", "My launch task")),
                                       boardRoom(chat, linkedCard(1, "$chat", "My task elsewhere")),
                                       boardRoom(dm, linkedCard(1, "$dm", "My task in a direct chat"), isDirect: true, heroes: [bob])])
        let filters = spaceFilters(tab)
        let viewModel = makeViewModel(tab, spaceID: acme)
        #expect(viewModel.context.viewState.content == .loading)
        
        filters.send(acmeFilters(chats: [design, dm], subspaceChats: [launch]))
        let state = try await waitForState(viewModel) { $0.checkingCount == 0 && $0.titles.count == 2 }
        // Shared with the chat, so on its board, though it doesn't involve the user; a direct chat is no channel.
        #expect(Set(state.titles) == ["Bob's shared task", "My launch task"])
        #expect(state.spaceName == "Acme")
        viewModel.context.send(viewAction: .toggleChatFilter)
        #expect(viewModel.context.viewState.chatChoices.map(\.roomID) == [design, launch])
    }
    
    @Test
    func withASpaceTheListLoadsUntilTheSpacesFiltersArrive() async throws {
        let room = try boardRoom(design, linkedCard(1, "$t1", "Book the venue"))
        let tab = TasksTab(rooms: [room])
        let filters = spaceFilters(tab)
        let viewModel = makeViewModel(tab, spaceID: acme)
        
        try await Task.sleep(for: .milliseconds(200))
        // The boards wait for the space's chats, so no chat is read yet.
        #expect(viewModel.context.viewState.content == .loading)
        #expect(viewModel.context.viewState.spaceName == "")
        #expect(room.timelinesOpened == 0)
        filters.send(acmeFilters(chats: [design]))
        #expect(try await waitForState(viewModel) { !$0.titles.isEmpty }.titles == ["Book the venue"])
    }
    
    @Test
    func withASpaceLoadingAndCheckingOnlyWaitForTheSpacesChats() async throws {
        // The space's only chat has no board, and the chat outside the space is never done being checked.
        let tab = TasksTab(rooms: [MatchaRoomFixture(roomID: design), MatchaRoomFixture(roomID: chat)])
        let silent = Gate()
        let fetch = try #require(tab.client.fetchStateEventContentJSONRoomIDTypeStateKeyClosure)
        tab.client.fetchStateEventContentJSONRoomIDTypeStateKeyClosure = { [chat] roomID, type, stateKey in
            if roomID == chat {
                await silent.wait()
            }
            return await fetch(roomID, type, stateKey)
        }
        let filters = spaceFilters(tab)
        let viewModel = makeViewModel(tab, spaceID: acme)
        
        filters.send(acmeFilters(chats: [design]))
        #expect(try await waitForState(viewModel) { $0.content == .empty }.checkingCount == 0)
        silent.open()
    }
    
    @Test
    func withASpaceLeavingTheLastSpaceEmptiesItsBoards() async throws {
        let tab = try TasksTab(rooms: [boardRoom(design, linkedCard(1, "$t1", "Book the venue"))])
        let filters = spaceFilters(tab)
        let viewModel = makeViewModel(tab, spaceID: acme)
        filters.send(acmeFilters(chats: [design]))
        try await waitForState(viewModel) { !$0.titles.isEmpty }
        
        // Once spaces were listed, none means the user left the last one rather than that they aren't known yet.
        filters.send([])
        try await waitForState(viewModel) { $0.content == .empty }
    }
    
    @Test
    func withASpaceADirectChatInItIsNeitherWaitedForNorCountedAsFailed() async throws {
        let failing = MatchaRoomFixture(roomID: dm, isDirect: true, heroes: [bob])
        failing.serverPointer = { .failure(.sdkError(RoomProxyMockError.generic)) }
        let tab = TasksTab(rooms: [MatchaRoomFixture(roomID: design), failing])
        let filters = spaceFilters(tab)
        let viewModel = makeViewModel(tab, spaceID: acme)
        
        filters.send(acmeFilters(chats: [design, dm]))
        let state = try await waitForState(viewModel) { $0.content == .empty }
        #expect(state.checkingCount == 0)
        #expect(state.failedCount == 0)
    }
    
    @Test
    func withASpaceAGroupChatFlaggedDirectKeepsItsBoardAsOnTheChannelsTab() async throws {
        // m.direct alone makes no DM: the SDK's isDm, which the Channels tab and Android go by, says it is a group.
        let tab = try TasksTab(rooms: [boardRoom(design, linkedCard(1, "$design", "My design task")),
                                       boardRoom(chat, linkedCard(1, "$chat", "My task in a group flagged direct"), isDirect: true, heroes: [bob, carol])])
        tab.summaries.value = tab.summaries.value.map { summary in
            var summary = summary
            summary.isDM = false
            return summary
        }
        let filters = spaceFilters(tab)
        let viewModel = makeViewModel(tab, spaceID: acme)
        
        filters.send(acmeFilters(chats: [design, chat]))
        let state = try await waitForState(viewModel) { $0.checkingCount == 0 && $0.titles.count == 2 }
        #expect(Set(state.titles) == ["My design task", "My task in a group flagged direct"])
    }
    
    @Test
    func withASpaceTheUserIsInNoChannelOfTheBoardsAreEmpty() async throws {
        let tab = try TasksTab(rooms: [boardRoom(design, linkedCard(1, "$t1", "Book the venue"))])
        let filters = spaceFilters(tab)
        let viewModel = makeViewModel(tab, spaceID: acme)
        
        filters.send(acmeFilters(chats: ["!not-joined:x"]))
        #expect(try await waitForState(viewModel) { $0.content == .empty }.spaceName == "Acme")
    }
    
    @Test
    func withASpaceItsChatsAreCheckedBeforeTheOthers() async {
        let tab = TasksTab(rooms: (1...6).map { MatchaRoomFixture(roomID: "!r\($0):x") })
        let filters = spaceFilters(tab)
        let viewModel = makeViewModel(tab, spaceID: acme)
        
        filters.send(acmeFilters(chats: ["!r5:x", "!r6:x"]))
        await eventually { tab.client.stateEventsJSONRoomIDTypeReceivedInvocations.count >= MatchaConfig.tasksTabMaxConcurrentChecks }
        let firstTurn = Set(tab.client.stateEventsJSONRoomIDTypeReceivedInvocations.prefix(MatchaConfig.tasksTabMaxConcurrentChecks).map(\.roomID))
        #expect(firstTurn.isSuperset(of: ["!r5:x", "!r6:x"]))
        withExtendedLifetime(viewModel) { }
    }
    
    // MARK: The flow
    
    @Test
    func theFlowsEditorHoldsItsChatUntilTheSheetGoesAndKeepsNothingOfItAfter() async throws {
        let tab = try TasksTab(rooms: [boardRoom(design, linkedCard(1, "$t1", "Book the venue"))])
        let rooms = tab.tasksTabRooms(clock: tab.clock)
        let stack = NavigationStackCoordinator()
        let flow = TasksTabFlowCoordinator(navigationStackCoordinator: stack,
                                           rooms: rooms,
                                           clientProxy: tab.client,
                                           mediaProvider: MediaProviderMock(.init()),
                                           userIndicatorController: UserIndicatorControllerMock())
        flow.start(animated: false)
        let screen = try #require(stack.rootCoordinator as? TasksTabScreenCoordinator)
        screen.context.send(viewAction: .appeared)
        try await deferFulfillment(screen.context.observe(\.viewState)) { !$0.content.allTasks.isEmpty }.fulfill()
        weak var tabRoom = rooms.acquire(roomID: design)
        let store = try #require(tabRoom?.store)
        try rooms.release(#require(tabRoom))
        
        screen.context.send(viewAction: .editTask(TabTaskID(roomID: design, taskID: KanbanProtocol.threadCardID("$t1"))))
        #expect((stack.sheetCoordinator as? NavigationStackCoordinator)?.rootCoordinator is TaskEditorScreenCoordinator)
        // The tab goes, and a while after its chats; the edited one stays open while its editor shows.
        screen.context.send(viewAction: .disappeared)
        await tab.clock.waitForScheduledSleep()
        tab.clock.advance(by: MatchaConfig.tasksTabKeepAlive + .seconds(1))
        await eventually { rooms.chatsPublisher.value.boards.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!store.isStopped)
        
        stack.setSheetCoordinator(nil)
        await eventually { store.isStopped }
        // The flow lives as long as the session, so it keeps nothing of a chat once its editor is gone.
        await eventually { tabRoom == nil }
        withExtendedLifetime(flow) { }
    }
    
    @Test
    func theFlowPushesASpacesBoardsAndFinishesOnceTheyArePopped() async throws {
        let tab = try TasksTab(rooms: [boardRoom(design, linkedCard(1, "$t1", "Book the venue"))])
        let filters = spaceFilters(tab)
        // A stack with a root, such as a space's; on a stack of their own the boards are its root (MatchaHomeTabsTests).
        let stack = NavigationStackCoordinator()
        let root = PlaceholderScreenCoordinator(hideBrandChrome: false)
        stack.setRootCoordinator(root, animated: false)
        let flow = TasksTabFlowCoordinator(navigationStackCoordinator: stack,
                                           rooms: tab.tasksTabRooms(),
                                           clientProxy: tab.client,
                                           mediaProvider: MediaProviderMock(.init()),
                                           userIndicatorController: UserIndicatorControllerMock(),
                                           spaceID: acme)
        flow.start(animated: false)
        #expect(stack.rootCoordinator === root)
        let screen = try #require(stack.stackCoordinators.last as? TasksTabScreenCoordinator)
        screen.context.send(viewAction: .appeared)
        filters.send(acmeFilters(chats: [design]))
        #expect(try await deferFulfillment(screen.context.observe(\.viewState)) { !$0.content.allTasks.isEmpty }.fulfill().spaceName == "Acme")
        
        let finished = deferFulfillment(flow.actionsPublisher) { $0 == .finished }
        stack.pop(animated: false)
        try await finished.fulfill()
    }
    
    // MARK: - Helpers
    
    private let aNow: Int64 = 1_700_000_000_000
    /// The start of `aNow`'s day in UTC.
    private let aToday: Int64 = 1_699_920_000_000
    
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }
    
    private func at(day: Int64, hour: Int64, minute: Int64 = 0) -> Int64 {
        aToday + ((day * 24 + hour) * 60 + minute) * 60000
    }
    
    private var aNowDate: Date {
        Date(timeIntervalSince1970: TimeInterval(aNow) / 1000)
    }
    
    /// A view model reading `tab`'s chats (through `rooms`, else rooms of its own) as though on screen; it reads them until it goes.
    private func makeViewModel(_ tab: TasksTab,
                               rooms: TasksTabRooms? = nil,
                               spaceID: String? = nil,
                               now: (() -> Date)? = nil) -> TasksTabScreenViewModel {
        let aNowDate = aNowDate
        let announce: (String) -> Void = { _ in }
        let viewModel = TasksTabScreenViewModel(rooms: rooms ?? tab.tasksTabRooms(),
                                                clientProxy: tab.client,
                                                spaceID: spaceID,
                                                formatDeadline: { "at \($0)" },
                                                now: now ?? { aNowDate },
                                                calendar: calendar,
                                                announce: announce)
        viewModel.context.send(viewAction: .appeared)
        return viewModel
    }
    
    /// The space filters of `tab`'s session, empty until sent.
    private func spaceFilters(_ tab: TasksTab) -> CurrentValueSubject<[SpaceServiceFilter], Never> {
        let filters = CurrentValueSubject<[SpaceServiceFilter], Never>([])
        let spaceService = SpaceServiceProxyMock(.init())
        spaceService.spaceFilterPublisher = filters.asCurrentValuePublisher()
        tab.client.spaceService = spaceService
        return filters
    }
    
    /// Acme with `chats` and its subspace with `subspaceChats`.
    private func acmeFilters(chats: [String], subspaceChats: [String] = []) -> [SpaceServiceFilter] {
        [SpaceServiceFilter(room: .mock(id: acme, name: "Acme", isSpace: true, state: .joined), level: 0, descendants: Set(chats + [acmeSub])),
         SpaceServiceFilter(room: .mock(id: acmeSub, name: "Acme team", isSpace: true, state: .joined), level: 1, descendants: Set(subspaceChats))]
    }
    
    private struct Card {
        let index: Int
        let id: String
        let title: String
        var status = TaskStatus.todo
        var threadID: String?
        var dueAt: Int64?
        var archived = false
        /// The thread's root sender, or the older card's author.
        var author = matchaUser
        var showToRoom = true
    }
    
    private func linkedCard(_ index: Int,
                            _ threadID: String,
                            _ title: String,
                            status: TaskStatus = .todo,
                            dueAt: Int64? = nil,
                            archived: Bool = false,
                            startedBy: String = matchaUser,
                            showToRoom: Bool = true) -> Card {
        Card(index: index, id: KanbanProtocol.threadCardID(threadID), title: title, status: status, threadID: threadID, dueAt: dueAt, archived: archived,
             author: startedBy, showToRoom: showToRoom)
    }
    
    private func legacyCard(_ index: Int, _ title: String, id: String = "legacy", writtenBy: String = matchaUser) -> Card {
        Card(index: index, id: id, title: title, author: writtenBy)
    }
    
    /// A chat whose board holds `cards`, each thread's started at its index; Bob and Carol go by their names.
    private func boardRoom(_ roomID: String,
                           _ cards: Card...,
                           isDirect: Bool = false,
                           heroes: [String] = [],
                           threadReplies: [String: [String]] = [:]) throws -> MatchaRoomFixture {
        let items = try cards.map { card in
            try aBoardCardItem(card.index, id: card.id, title: card.title, status: card.status, threadID: card.threadID, dueAt: card.dueAt, archived: card.archived,
                               showToRoom: card.showToRoom, sender: card.threadID == nil ? card.author : "@writer:x")
        }
        let threads = cards.compactMap { card in
            card.threadID.map { aThreadListItem($0, body: card.title, timestamp: Int64(card.index), sender: card.author) }
        }
        let fixture = MatchaRoomFixture(roomID: roomID, items: items, threads: threads, isDirect: isDirect, heroes: heroes)
        fixture.boardPointer = .success(aBoardRoot)
        fixture.threadReplies = threadReplies
        fixture.sendResult = { _, _ in .success("$e\(UUID().uuidString)") }
        let names = [bob: "Bob", carol: "Carol"]
        fixture.room.getMemberUserIDClosure = { userID in
            guard let name = names[userID] else { return .failure(.sdkError(RoomProxyMockError.generic)) }
            return .success(RoomMemberProxyMock(with: .init(userID: userID, displayName: name, membership: .join)))
        }
        return fixture
    }
    
    private func reply(_ index: Int, in threadID: String, sender: String) -> String {
        aMatchaEvent(index, type: "m.room.message", content: #"{"m.relates_to": {"rel_type": "m.thread", "event_id": "\#(threadID)"}}"#, sender: sender, eventID: "$r\(threadID)\(index)")
    }
    
    @discardableResult
    private func waitForState(_ viewModel: TasksTabScreenViewModel,
                              sourceLocation: SourceLocation = #_sourceLocation,
                              _ condition: @escaping (TasksTabScreenViewState) -> Bool) async throws -> TasksTabScreenViewState {
        try await deferFulfillment(viewModel.context.observe(\.viewState), sourceLocation: sourceLocation, until: condition).fulfill()
    }
    
    private func record(_ viewModel: TasksTabScreenViewModel) -> ActionRecorder {
        let recorder = ActionRecorder()
        recorder.cancellable = viewModel.actionsPublisher.sink { recorder.values.append($0) }
        return recorder
    }
}

private final class ActionRecorder {
    var values: [TasksTabScreenViewModelAction] = []
    var cancellable: AnyCancellable?
}

private extension TasksTabScreenViewState {
    /// The tasks shown, done ones only when expanded.
    var tasks: [TabTask] {
        switch content {
        case .loading, .empty: []
        case .tasks(let groups, let done, let isDoneExpanded): groups.flatMap(\.tasks) + (isDoneExpanded ? done : [])
        case .table(let rows, _): rows
        }
    }
    
    var titles: [String?] {
        tasks.map(\.task.title)
    }
    
    var sections: [TaskSection?] {
        if case .tasks(let groups, _, _) = content {
            groups.map(\.section)
        } else {
            []
        }
    }
    
    var tableSort: TaskTableSort? {
        if case .table(_, let sort) = content {
            sort
        } else {
            nil
        }
    }
}
