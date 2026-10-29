//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import MatchaProtocol
import Testing

@MainActor
struct TasksTabRoomsTests {
    private let pointer = KanbanProtocol.boardPointerContent(rootID: "$board-root")
    
    @Test
    func aChatTheHomeserverSaysHasNoBoardIsSkippedWithoutReadingItsHistory() async {
        let room = MatchaRoomFixture(roomID: "!plain:x")
        room.serverPointer = { .success(nil) }
        let tab = TasksTab(rooms: [room])
        
        let chats = await tab.check(tab.tasksTabRooms())
        #expect(chats.boards.isEmpty)
        #expect(chats.failed.isEmpty)
        #expect(room.timelinesOpened == 0)
    }
    
    @Test
    func aChatIsCheckedWithoutOpeningItAndOnlyAChatWithABoardIsOpenedInFull() async {
        let plain = MatchaRoomFixture(roomID: "!light:x")
        plain.serverPointer = { .success(nil) }
        let board = MatchaRoomFixture(roomID: "!full:x")
        board.serverPointer = { .success("$board-root") }
        let tab = TasksTab(rooms: [plain, board])
        
        let chats = await tab.check(tab.tasksTabRooms())
        #expect(chats.boards.map(\.roomID) == ["!full:x"])
        #expect(chats.failed.isEmpty)
        #expect(tab.client.roomForIdentifierReceivedInvocations == ["!full:x"])
    }
    
    @Test
    func aChatWhoseBoardPointerOnlyTheHomeserverHasIsFound() async {
        let room = MatchaRoomFixture(roomID: "!board:x")
        room.serverPointer = { .success("$board-root") }
        let tab = TasksTab(rooms: [room])
        
        let rooms = tab.tasksTabRooms()
        #expect(await tab.check(rooms).boards.map(\.roomID) == ["!board:x"])
        // The tab follows each board's store as it reads the chat.
        await tab.waitForChats(rooms) { $0.boards.first?.snapshot.board?.rootID == "$board-root" }
    }
    
    @Test
    func aChatWithAStoredPointerIsFoundWithoutAskingTheHomeserver() async {
        let room = MatchaRoomFixture(roomID: "!stored:x")
        room.boardPointer = .success("$board-root")
        let tab = TasksTab(rooms: [room])
        
        let chats = await tab.check(tab.tasksTabRooms())
        #expect(chats.boards.map(\.roomID) == ["!stored:x"])
        #expect(tab.client.fetchStateEventContentJSONRoomIDTypeStateKeyCallsCount == 0)
    }
    
    @Test
    func aChatTheHomeserverCantBeAskedAboutCountsAsFailed() async {
        let room = MatchaRoomFixture(roomID: "!offline:x")
        room.serverPointer = { .failure(.sdkError(RoomProxyMockError.generic)) }
        let tab = TasksTab(rooms: [room])
        
        let chats = await tab.check(tab.tasksTabRooms())
        #expect(chats.boards.isEmpty)
        #expect(chats.failed == ["!offline:x"])
    }
    
    @Test
    func aBoardThisDeviceCreatesIsFoundAtOnceDespiteARecentNoBoardAnswer() async {
        let room = MatchaRoomFixture(roomID: "!created:x")
        room.serverPointer = { .success(nil) }
        let tab = TasksTab(rooms: [room])
        #expect(await tab.check(tab.tasksTabRooms()).boards.isEmpty)
        
        _ = await room.store(noBoardAnswers: tab.noBoardAnswers).sendState(type: MatchaConfig.stateKanban, stateKey: "", contentJSON: pointer)
        room.serverPointer = { .success("$board-root") }
        #expect(await tab.check(tab.tasksTabRooms()).boards.map(\.roomID) == ["!created:x"])
    }
    
    @Test
    func aClockMovedBackDoesntStretchANoBoardAnswer() async {
        let room = MatchaRoomFixture(roomID: "!clock:x")
        room.serverPointer = { .success(nil) }
        let tab = TasksTab(rooms: [room])
        
        tab.now = .seconds(1000)
        await tab.check(tab.tasksTabRooms())
        tab.now = .zero
        await tab.check(tab.tasksTabRooms())
        #expect(room.serverPointerReads == 2)
    }
    
    @Test
    func aRecentNoBoardAnswerIsReusedAndAskedAgainOnceItIsOld() async {
        let room = MatchaRoomFixture(roomID: "!cached:x")
        room.serverPointer = { .success(nil) }
        let tab = TasksTab(rooms: [room])
        
        await tab.check(tab.tasksTabRooms())
        await tab.check(tab.tasksTabRooms())
        #expect(room.serverPointerReads == 1)
        
        tab.now += .seconds(11 * 60)
        await tab.check(tab.tasksTabRooms())
        #expect(room.serverPointerReads == 2)
    }
    
    @Test
    func comingBackWithinAWhileFindsTheBoardsReadWithoutCheckingAgainAndALongerAbsenceLetsThemGo() async {
        let room = MatchaRoomFixture(roomID: "!kept:x")
        room.serverPointer = { .success("$board-root") }
        let tab = TasksTab(rooms: [room])
        let rooms = tab.tasksTabRooms(clock: tab.clock)
        
        let shown = Task { await rooms.run() }
        let store = await tab.waitForChats(rooms) { !$0.boards.isEmpty && $0.checking.isEmpty }?.boards.first?.room.store
        shown.cancel()
        await tab.clock.waitForScheduledSleep()
        tab.clock.advance(by: MatchaConfig.tasksTabKeepAlive - .seconds(1))
        #expect(store?.isStopped == false)
        
        let shownAgain = Task { await rooms.run() }
        // The new run cancels the pending close.
        await eventually { !tab.clock.hasPendingSleep }
        tab.clock.advance(by: .seconds(1))
        #expect(rooms.chatsPublisher.value.boards.map(\.roomID) == ["!kept:x"])
        #expect(room.serverPointerReads == 1)
        #expect(room.timelinesOpened == 1)
        
        shownAgain.cancel()
        await tab.clock.waitForScheduledSleep()
        tab.clock.advance(by: MatchaConfig.tasksTabKeepAlive + .seconds(1))
        await eventually { store?.isStopped == true }
        // Everything was let go, so the next time every chat is checked again.
        #expect(await tab.check(rooms).boards.map(\.roomID) == ["!kept:x"])
        #expect(room.serverPointerReads == 2)
    }
    
    @Test
    func comingBackWithinAWhileChecksAgainAChatThisDeviceHasGivenABoardSinceAndAChatThatFailed() async {
        let created = MatchaRoomFixture(roomID: "!created-meanwhile:x")
        created.serverPointer = { .success(nil) }
        let failed = MatchaRoomFixture(roomID: "!failed-meanwhile:x")
        failed.serverPointer = { .failure(.sdkError(RoomProxyMockError.generic)) }
        let tab = TasksTab(rooms: [created, failed])
        let rooms = tab.tasksTabRooms(clock: tab.clock)
        
        let shown = Task { await rooms.run() }
        let first = await tab.waitForChats(rooms) { $0.isRoomListLoaded && $0.checking.isEmpty }
        #expect(first?.boards.isEmpty == true)
        #expect(first?.failed == ["!failed-meanwhile:x"])
        shown.cancel()
        await shown.value
        
        _ = await created.store(noBoardAnswers: tab.noBoardAnswers).sendState(type: MatchaConfig.stateKanban, stateKey: "", contentJSON: pointer)
        created.serverPointer = { .success("$board-root") }
        failed.serverPointer = { .success(nil) }
        let shownAgain = Task { await rooms.run() }
        let again = await tab.waitForChats(rooms) { $0.boards.map(\.roomID) == ["!created-meanwhile:x"] && $0.checking.isEmpty }
        #expect(again?.failed.isEmpty == true)
        shownAgain.cancel()
    }
    
    @Test
    func aCheckCutShortByLeavingTheTabIsDoneAgainNextTime() async {
        let room = MatchaRoomFixture(roomID: "!slow:x")
        let tab = TasksTab(rooms: [room])
        // The homeserver doesn't answer before the tab goes.
        let gate = Gate()
        tab.serverReadGate = gate
        let rooms = tab.tasksTabRooms(clock: tab.clock)
        
        let shown = Task { await rooms.run() }
        await eventually { tab.client.fetchStateEventContentJSONRoomIDTypeStateKeyCallsCount == 1 }
        shown.cancel()
        await shown.value
        
        let shownAgain = Task { await rooms.run() }
        await eventually { tab.client.fetchStateEventContentJSONRoomIDTypeStateKeyCallsCount == 2 }
        room.serverPointer = { .success("$board-root") }
        gate.open()
        // Only the second run's check records what it found.
        let store = await tab.waitForChats(rooms) { $0.boards.map(\.roomID) == ["!slow:x"] && $0.checking.isEmpty }?.boards.first?.room.store
        await store?.settle()
        #expect(room.timelinesOpened == 1)
        shownAgain.cancel()
    }
    
    @Test
    func aWriteStartedFromTheTabStillFinishesAfterTheTabHasBeenGoneAWhileAndItsChatGoesOnceItIsDone() async {
        let room = MatchaRoomFixture(roomID: "!writing:x")
        room.serverPointer = { .success("$board-root") }
        let tab = TasksTab(rooms: [room])
        let rooms = tab.tasksTabRooms(clock: tab.clock)
        
        let shown = Task { await rooms.run() }
        guard let board = await tab.waitForChats(rooms, where: { !$0.boards.isEmpty })?.boards.first else { return }
        let write = Gate()
        board.room.write { await write.wait() }
        shown.cancel()
        await tab.clock.waitForScheduledSleep()
        tab.clock.advance(by: MatchaConfig.tasksTabKeepAlive + .seconds(1))
        await eventually { rooms.chatsPublisher.value.boards.isEmpty }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!board.room.store.isStopped)
        
        write.open()
        await eventually { board.room.store.isStopped }
    }
    
    @Test
    func aChatScreenReadsThroughTheStoreOfABoardTheTabHasOpenWhichOutlivesTheTabUntilTheScreenLetsItGo() async throws {
        let room = MatchaRoomFixture(roomID: "!held:x")
        room.serverPointer = { .success("$board-root") }
        let tab = TasksTab(rooms: [room])
        let rooms = tab.tasksTabRooms(clock: tab.clock)
        
        let shown = Task { await rooms.run() }
        guard let board = await tab.waitForChats(rooms, where: { !$0.boards.isEmpty })?.boards.first else { return }
        let held = try #require(rooms.acquire(roomID: "!held:x"))
        #expect(held.store === board.room.store)
        shown.cancel()
        await tab.clock.waitForScheduledSleep()
        tab.clock.advance(by: MatchaConfig.tasksTabKeepAlive + .seconds(1))
        await eventually { rooms.chatsPublisher.value.boards.isEmpty }
        
        // The tab has let the board go, so it isn't handed out again, but it keeps working for the screen holding it.
        #expect(rooms.acquire(roomID: "!held:x") == nil)
        #expect(!held.store.isStopped)
        _ = await held.store.send(type: MatchaConfig.eventThreadMetadata, contentJSON: "{}")
        await waitForSnapshot(held.store) { $0.events.contains { $0.eventID == "$sent" } }
        rooms.release(held)
        await eventually { held.store.isStopped }
    }
    
    @Test
    func aChatThatLeavesTheListGoesOnceTheLastScreenHoldingItAndTheTabsWritesAreDone() async throws {
        let room = MatchaRoomFixture(roomID: "!left:x")
        room.serverPointer = { .success("$board-root") }
        let tab = TasksTab(rooms: [room])
        let rooms = tab.tasksTabRooms(clock: tab.clock)
        
        let shown = Task { await rooms.run() }
        guard let board = await tab.waitForChats(rooms, where: { !$0.boards.isEmpty })?.boards.first else { return }
        let first = try #require(rooms.acquire(roomID: "!left:x"))
        let second = try #require(rooms.acquire(roomID: "!left:x"))
        let write = Gate()
        board.room.write { await write.wait() }
        tab.summaries.send([])
        #expect(rooms.chatsPublisher.value.boards.isEmpty)
        
        rooms.release(first)
        write.open()
        try? await Task.sleep(for: .milliseconds(100))
        // The tab's write is done and one screen has let go, but the other still holds the room.
        #expect(!board.room.store.isStopped)
        // An Undo tapped while the screen still held the room is still written.
        let undo = Gate()
        board.room.write { await undo.wait() }
        rooms.release(second)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!board.room.store.isStopped)
        undo.open()
        await eventually { board.room.store.isStopped }
        shown.cancel()
    }
    
    @Test
    func onceTheTabHasLetABoardGoAChatScreenOpenedLaterDoesntGetTheOldStore() async throws {
        let room = MatchaRoomFixture(roomID: "!fresh:x")
        room.serverPointer = { .success("$board-root") }
        let tab = TasksTab(rooms: [room])
        let rooms = tab.tasksTabRooms(clock: tab.clock)
        
        let shown = Task { await rooms.run() }
        await tab.waitForChats(rooms) { !$0.boards.isEmpty }
        let old = try #require(rooms.acquire(roomID: "!fresh:x"))
        rooms.release(old)
        shown.cancel()
        await tab.clock.waitForScheduledSleep()
        tab.clock.advance(by: MatchaConfig.tasksTabKeepAlive + .seconds(1))
        await eventually { old.store.isStopped }
        #expect(rooms.acquire(roomID: "!fresh:x") == nil)
        
        #expect(await tab.check(rooms).boards.map(\.roomID) == ["!fresh:x"])
        #expect(try #require(rooms.acquire(roomID: "!fresh:x")).store !== old.store)
    }
    
    @Test
    func aCheckCutShortByTheChatLeavingRecordsNothingOverTheCheckOfItsReturn() async {
        let room = MatchaRoomFixture(roomID: "!back:x")
        let tab = TasksTab(rooms: [room])
        // The homeserver answers each read when its gate opens: the first read hears of no board, the second of one.
        var answers = [Gate]()
        var pointers: [String?] = [nil, "$board-root"]
        tab.client.fetchStateEventContentJSONRoomIDTypeStateKeyClosure = { _, _, _ in
            let answer = Gate()
            answers.append(answer)
            let pointer = pointers.removeFirst()
            await answer.wait()
            return .success(pointer.map { KanbanProtocol.boardPointerContent(rootID: $0) })
        }
        let rooms = tab.tasksTabRooms()
        let shown = Task { await rooms.run() }
        await eventually { answers.count == 1 }
        
        // The chat leaves the list while its check waits for the homeserver, and comes back.
        tab.summaries.send([])
        tab.summaries.send([RoomSummary.mock(id: "!back:x", name: "!back:x")])
        await eventually { answers.count == 2 }
        answers[1].open()
        await tab.waitForChats(rooms) { $0.boards.map(\.roomID) == ["!back:x"] }
        // The first check's answer, from before the chat left, comes last.
        answers[0].open()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(rooms.chatsPublisher.value.boards.map(\.roomID) == ["!back:x"])
        #expect(!tab.noBoardAnswers.isRecent(roomID: "!back:x"))
        shown.cancel()
    }
    
    @Test
    func stoppingLetsGoOfEverythingWithoutWaitingToLetGoAgainLater() async {
        let room = MatchaRoomFixture(roomID: "!stopped:x")
        room.serverPointer = { .success("$board-root") }
        let tab = TasksTab(rooms: [room])
        let rooms = tab.tasksTabRooms(clock: tab.clock)
        let shown = Task { await rooms.run() }
        let store = await tab.waitForChats(rooms) { !$0.boards.isEmpty && $0.checking.isEmpty }?.boards.first?.room.store
        
        rooms.stop()
        await shown.value
        try? await Task.sleep(for: .milliseconds(100))
        #expect(store?.isStopped == true)
        #expect(!tab.clock.hasPendingSleep, "Nothing is left to let go once the keep-alive passes.")
    }
    
    @Test
    func theChatsGivenFirstAreCheckedFirst() async {
        let rooms = (1...6).map { MatchaRoomFixture(roomID: "!r\($0):x") }
        let tab = TasksTab(rooms: rooms)
        
        _ = await tab.check(tab.tasksTabRooms(), first: ["!r6:x"])
        // Four chats are checked at once.
        let firstTurn = tab.client.stateEventsJSONRoomIDTypeReceivedInvocations.prefix(MatchaConfig.tasksTabMaxConcurrentChecks).map(\.roomID)
        #expect(Set(firstTurn) == ["!r6:x", "!r1:x", "!r2:x", "!r3:x"])
    }
}

/// The session the Tasks tab runs in: a client over the rooms of `MatchaRoomFixture`s, its room list, and the clocks.
@MainActor
final class TasksTab {
    let client = ClientProxyMock(.init(userID: matchaUser))
    let summaries: CurrentValueSubject<[RoomSummary], Never>
    let clock = ManualClock()
    /// Monotonic time, for how long a "no board" answer is reused.
    var now: Duration = .zero
    /// Holds the homeserver's answers to board pointer reads until opened.
    var serverReadGate: Gate?
    private(set) lazy var noBoardAnswers = NoBoardAnswers { [unowned self] in now }
    private var runs = [Task<Void, Never>]()
    
    init(rooms: [MatchaRoomFixture]) {
        let rooms = Dictionary(uniqueKeysWithValues: rooms.map { ($0.room.id, $0) })
        summaries = .init(rooms.keys.sorted().map { RoomSummary.mock(id: $0, name: $0, isDirect: rooms[$0]?.roomInfo.isDirect == true) })
        let roomList = StaticRoomSummaryProviderMock()
        roomList.statePublisher = CurrentValueSubject(.loaded(totalNumberOfRooms: UInt(rooms.count))).asCurrentValuePublisher()
        roomList.roomListPublisher = summaries.asCurrentValuePublisher()
        client.staticRoomSummaryProvider = roomList
        client.stateEventsJSONRoomIDTypeClosure = { roomID, type in
            guard let room = rooms[roomID] else { return .failure(.roomNotInLocalStore) }
            return await room.room.stateEventsJSON(type: type).mapError { .sdkError($0) }
        }
        client.fetchStateEventContentJSONRoomIDTypeStateKeyClosure = { [weak self] roomID, type, stateKey in
            await self?.serverReadGate?.wait()
            guard let room = rooms[roomID] else { return .failure(.roomNotInLocalStore) }
            return await room.room.fetchStateEventContentJSON(type: type, stateKey: stateKey).mapError { .sdkError($0) }
        }
        client.roomForIdentifierClosure = { roomID in
            rooms[roomID].map { .joined($0.room) }
        }
    }
    
    isolated deinit {
        runs.forEach { $0.cancel() }
    }
    
    /// The Tasks tab's rooms on their own clock, or on `clock` for the tests that move it; it takes one sleep at a time.
    func tasksTabRooms(clock: ManualClock = ManualClock()) -> TasksTabRooms {
        TasksTabRooms(clientProxy: client, noBoardAnswers: noBoardAnswers, clock: clock)
    }
    
    /// Runs `rooms` until every chat is checked and returns what it found; the run goes on until the test ends.
    @discardableResult
    func check(_ rooms: TasksTabRooms, first: Set<String> = []) async -> TabChats {
        let run = Task { await rooms.run(first: first) }
        runs.append(run)
        return await waitForChats(rooms) { $0.isRoomListLoaded && $0.checking.isEmpty } ?? .init()
    }
    
    @discardableResult
    func waitForChats(_ rooms: TasksTabRooms,
                      sourceLocation: SourceLocation = #_sourceLocation,
                      where condition: @escaping @Sendable (TabChats) -> Bool) async -> TabChats? {
        let chats = await firstValue(of: rooms.chatsPublisher, timeout: .seconds(10), where: condition)
        if chats == nil {
            Issue.record("The Tasks tab never got there", sourceLocation: sourceLocation)
        }
        return chats
    }
}
