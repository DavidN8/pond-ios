//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import MatchaProtocol
import SwiftUI

typealias TasksTabScreenViewModelType = StateStoreViewModelV2<TasksTabScreenViewState, TasksTabScreenViewAction>

/// The Tasks tab, as Android's `TasksTabPresenter`: the user's tasks from every joined chat with a board, narrowed by status, chat
/// and person, grouped by deadline or in a table. Like the web client's personal board, it only holds the tasks that involve the
/// user: their threads and the tasks of their direct chats. A task is changed through its chat's store, which `TasksTabRooms` holds
/// while the tab is on screen, so no chat has to be opened.
///
/// With a space, it is the space's All boards instead: the boards of the chats the space holds, each with what the chat's own board
/// shows, the space's chats checked first.
class TasksTabScreenViewModel: TasksTabScreenViewModelType, TasksTabScreenViewModelProtocol {
    private let rooms: TasksTabRooms
    private let userID: String
    private let spaceID: String?
    private let formatDeadline: (Int64) -> String
    private let now: () -> Date
    private let calendar: Calendar
    private let bannerDuration: Duration
    private let isVoiceOverRunning: () -> Bool
    private let announce: (String) -> Void
    
    private var chats = TabChats()
    /// Nil until the space's filters are known; always nil on the Tasks tab.
    private var scope: SpaceScope?
    private var chatFilterID: String?
    private var personFilterID: String?
    private var tableSort = TaskTableSort()
    private var isDoneExpanded = false
    /// Display names by user id, each read once from a chat it appears in; until then the user id stands in.
    private var names = [String: String]()
    private var requestedNames = Set<String>()
    /// The boards on screen by room id, and their tasks, as of the last update.
    private var boards = [String: TabChat]()
    private var tasks = [TabTask]()
    private var isOnScreen = false
    /// Reads the chats while the tab is on screen; the rooms it opened stay open a while after, in case it comes back.
    private var runTask: Task<Void, Never>?
    private var bannerAction: (() -> Void)?
    private var bannerTimeout: Task<Void, Never>?
    
    private let actionsSubject: PassthroughSubject<TasksTabScreenViewModelAction, Never> = .init()
    var actionsPublisher: AnyPublisher<TasksTabScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    /// - Parameter spaceID: the space whose boards are shown, or nil for the Tasks tab.
    init(rooms: TasksTabRooms,
         clientProxy: ClientProxyProtocol,
         spaceID: String? = nil,
         mediaProvider: MediaProviderProtocol? = nil,
         userProfilePublisher: CurrentValuePublisher<UserProfile, Never>? = nil,
         formatDeadline: ((Int64) -> String)? = nil,
         now: @escaping () -> Date = { .now },
         calendar: Calendar = .current,
         bannerDuration: Duration = .seconds(10),
         isVoiceOverRunning: @escaping () -> Bool = { UIAccessibility.isVoiceOverRunning },
         announce: @escaping (String) -> Void = { AccessibilityNotification.Announcement($0).post() }) {
        self.rooms = rooms
        userID = clientProxy.userID
        self.spaceID = spaceID
        self.formatDeadline = formatDeadline ?? { DeadlineFormatter.format($0, now: now(), calendar: calendar) }
        self.now = now
        self.calendar = calendar
        self.bannerDuration = bannerDuration
        self.isVoiceOverRunning = isVoiceOverRunning
        self.announce = announce
        super.init(initialViewState: .init(spaceName: spaceID.map { _ in "" }, userProfile: userProfilePublisher?.value), mediaProvider: mediaProvider)
        
        userProfilePublisher?
            .map(Optional.some)
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.state.userProfile, on: self)
            .store(in: &cancellables)
        rooms.chatsPublisher
            .sink { [weak self] chats in
                self?.chats = chats
                self?.update()
            }
            .store(in: &cancellables)
        // Overdue, Today and Tomorrow change with the day, the time zone and the clock.
        NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)
            .sink { [weak self] _ in self?.update() }
            .store(in: &cancellables)
        if let spaceID {
            clientProxy.spaceService.spaceFilterPublisher
                // The filters start empty; once a space was listed, none means the user left the last one.
                .drop(while: \.isEmpty)
                .map { SpaceScope(spaceID: spaceID, filters: $0) }
                .removeDuplicates()
                .sink { [weak self] scope in
                    self?.scope = scope
                    self?.startReadingIfShown()
                    self?.update()
                }
                .store(in: &cancellables)
        }
    }
    
    isolated deinit {
        runTask?.cancel()
    }
    
    // MARK: - Public
    
    override func process(viewAction: TasksTabScreenViewAction) {
        switch viewAction {
        case .appeared:
            isOnScreen = true
            startReadingIfShown()
        case .disappeared:
            isOnScreen = false
            runTask?.cancel()
            runTask = nil
            // Nothing is recomputed until the tab shows again, so let go of its chats now rather than holding them for the session.
            boards = [:]
        case .setFilter(let filter):
            state.filter = filter
        case .toggleChatFilter:
            if state.chatFilter != nil {
                chatFilterID = nil
            } else {
                showSheet(.chooseChat(.filter))
            }
        case .chooseChat(let roomID):
            chooseChat(roomID)
        case .toggleDone:
            isDoneExpanded.toggle()
        case .togglePersonFilter:
            if state.personFilter != nil {
                personFilterID = nil
            } else {
                showSheet(.choosePerson)
            }
        case .choosePerson(let userID):
            state.bindings.sheet = nil
            personFilterID = userID
        case .toggleTable:
            state.isTable.toggle()
        case .sortTable(let column):
            tableSort = tableSort.column == column ? TaskTableSort(column: column, isAscending: !tableSort.isAscending) : TaskTableSort(column: column)
        case .openTask(let id):
            state.bindings.actionsTaskID = nil
            openTask(id)
        case .showActions(let id):
            state.bindings.actionsTaskID = id
        case .move(let id, let status):
            state.bindings.actionsTaskID = nil
            if let board = boards[id.roomID], board.snapshot.permissions.canWriteCards {
                listActions(board).move(id.taskID, to: status)
            }
        case .setArchived(let id, let archived):
            state.bindings.actionsTaskID = nil
            if let task = find(id), task.canArchive, let board = boards[id.roomID] {
                listActions(board).setArchived(id.taskID, archived: archived)
            }
        case .editTask(let id):
            state.bindings.actionsTaskID = nil
            if boards[id.roomID]?.snapshot.permissions.canWriteCards == true {
                actionsSubject.send(.presentEditor(roomID: id.roomID, target: .edit(taskID: id.taskID)))
            }
        case .openChat(let roomID):
            state.bindings.actionsTaskID = nil
            actionsSubject.send(.presentRoom(roomID: roomID))
        case .newTask:
            newTask()
        case .dismissSheet:
            state.bindings.sheet = nil
        case .retry:
            rooms.retry()
        case .loadMore:
            loadMore()
        case .bannerAction:
            let action = bannerAction
            dismissBanner()
            action?()
        case .dismissBanner:
            dismissBanner()
        case .showSettings:
            actionsSubject.send(.showSettings)
        }
        update()
    }
    
    // MARK: - Private
    
    /// Reads the chats while the tab is on screen; a space's boards wait until the space's chats are known, so they go first.
    private func startReadingIfShown() {
        guard isOnScreen, runTask == nil, spaceID == nil || scope != nil else { return }
        let first = scope?.chatIDs ?? []
        runTask = Task { [rooms] in await rooms.run(first: first) }
    }
    
    private func chooseChat(_ roomID: String) {
        guard case .chooseChat(let purpose) = state.bindings.sheet else { return }
        state.bindings.sheet = nil
        switch purpose {
        case .filter:
            chatFilterID = roomID
        case .newTask:
            if boards[roomID]?.canAddTasks == true {
                actionsSubject.send(.presentEditor(roomID: roomID, target: .new(status: state.filter.newTaskStatus)))
            }
        }
    }
    
    private func openTask(_ id: TabTaskID) {
        guard let task = find(id) else { return }
        if let threadID = task.task.threadID {
            actionsSubject.send(.presentThread(roomID: id.roomID, threadRootEventID: threadID))
        } else {
            actionsSubject.send(.presentRoom(roomID: id.roomID))
        }
    }
    
    private func newTask() {
        // With a chat chosen, the new task goes there without asking.
        if let chosen = chatFilterID.flatMap({ boards[$0] }), chosen.canAddTasks {
            actionsSubject.send(.presentEditor(roomID: chosen.roomID, target: .new(status: state.filter.newTaskStatus)))
        } else {
            showSheet(.chooseChat(.newTask))
        }
    }
    
    private func loadMore() {
        let visible = chatFilterID.flatMap { boards[$0] }.map { [$0] } ?? Array(boards.values)
        for board in visible where board.snapshot.hasMoreHistory && !board.snapshot.isLoadingMore {
            Task { _ = await board.room.store.loadMore() }
        }
    }
    
    private func showSheet(_ sheet: TasksTabSheet) {
        state.bindings.chatSearchQuery = ""
        state.bindings.sheet = sheet
    }
    
    private func find(_ id: TabTaskID) -> TabTask? {
        tasks.first { $0.id == id }
    }
    
    /// Recomputes the screen while it is shown, and once it is shown again: the view model lives as long as the session.
    private func update() {
        guard isOnScreen else { return }
        let me = userID
        let spaceID = spaceID
        let scope = scope
        let chats = chats
        // As on the Channels tab, a direct chat in a space is left out, so it is neither listed nor waited for.
        func isInScope(_ roomID: String) -> Bool {
            spaceID == nil || scope?.chatIDs.contains(roomID) == true && !chats.dms.contains(roomID)
        }
        let shown = spaceID == nil ? chats.boards : chats.boards.filter { isInScope($0.roomID) }
        // The Tasks tab holds the user's own tasks; a space's boards hold what each chat's own board shows.
        let isShown: (ProjectedCard) -> Bool = if spaceID == nil {
            { $0.participants.contains(me) }
        } else {
            { $0.isShownOnBoard(userID: me) }
        }
        requestNames(of: shown, isShown: isShown)
        tasks = tabTasks(shown, isShown: isShown)
        let people = Self.people(of: tasks, names: names, me: me)
        boards = Dictionary(shown.map { ($0.roomID, $0) }) { first, _ in first }
        // A chosen chat that the user has left, or a person no task involves any more, no longer narrows the list.
        let chatFilter = chatFilterID.flatMap { boards[$0] }
        let personFilter = personFilterID.flatMap { id in people.first { $0.userID == id } }
        let visibleBoards = chatFilter.map { [$0] } ?? shown
        let visibleTasks = tasks.filter { task in
            (chatFilter == nil || task.chat.roomID == chatFilter?.roomID) && (personFilter.map { task.task.participants.contains($0.userID) } ?? true)
        }
        // A space's boards only wait for its own chats.
        let loadingCount = chats.checking.count(where: isInScope) + shown.count(where: \.isLoading)
        
        state.content = if tasks.isEmpty, !chats.isRoomListLoaded || (spaceID != nil && scope == nil) || loadingCount > 0 {
            .loading
        } else if tasks.isEmpty {
            .empty
        } else if state.isTable {
            tableContent(visibleTasks)
        } else {
            tasksContent(visibleTasks)
        }
        state.chatFilter = chatFilter?.tabChat
        state.personFilter = personFilter
        state.people = people
        state.checkingCount = loadingCount
        state.failedCount = chats.failed.count(where: isInScope) + shown.count { $0.snapshot.loadFailed }
        state.isUnreadable = visibleBoards.contains { $0.snapshot.unreadable }
        state.hasMore = visibleBoards.contains { $0.snapshot.hasMoreHistory }
        state.isLoadingMore = visibleBoards.contains { $0.snapshot.isLoadingMore }
        state.spaceName = spaceID.map { _ in scope?.name ?? "" }
        state.chatChoices = (state.bindings.sheet == .chooseChat(.newTask) ? shown.filter(\.canAddTasks) : shown).map(\.tabChat)
    }
    
    /// Every task of every chat that `isShown` keeps, soonest deadline first (none last), then newest.
    private func tabTasks(_ boards: [TabChat], isShown: (ProjectedCard) -> Bool) -> [TabTask] {
        let now = now()
        return boards.flatMap { board in
            let chat = board.tabChat
            let rootTimestamps = Dictionary(board.snapshot.threads.map { ($0.id, $0.rootTimestamp) }) { first, _ in first }
            let permissions = board.snapshot.permissions
            return board.snapshot.taskItems(formatDeadline: formatDeadline, now: now, isShown: isShown).map { task in
                TabTask(chat: chat,
                        task: task,
                        createdAt: task.threadID.flatMap { rootTimestamps[$0] } ?? 0,
                        people: task.participants.filter { $0 != userID }.map { names[$0] ?? $0 },
                        canEdit: permissions.canWriteCards,
                        canArchive: permissions.canArchive(threadID: task.threadID))
            }
        }
        .stableSorted { lhs, rhs in
            let (lhsDue, rhsDue) = (lhs.task.dueAt ?? .max, rhs.task.dueAt ?? .max)
            return lhsDue != rhsDue ? lhsDue < rhsDue : lhs.createdAt > rhs.createdAt
        }
    }
    
    /// The table's rows: the active tasks of the chosen status (any with All), or the archived ones.
    private func tableContent(_ tasks: [TabTask]) -> TasksTabContent {
        let filter = state.filter
        let rows = tasks.filter { tabTask in
            switch filter {
            case .all: !tabTask.task.isArchived
            case .todo: !tabTask.task.isArchived && tabTask.task.status == .todo
            case .doing: !tabTask.task.isArchived && tabTask.task.status == .doing
            case .done: !tabTask.task.isArchived && tabTask.task.status == .done
            case .archived: tabTask.task.isArchived
            }
        }
        return .table(rows: rows.sorted(for: tableSort), sort: tableSort)
    }
    
    private func tasksContent(_ tasks: [TabTask]) -> TasksTabContent {
        let archived = tasks.filter(\.task.isArchived)
        let active = tasks.filter { !$0.task.isArchived }
        let newestFirst: (TabTask, TabTask) -> Bool = { $0.createdAt > $1.createdAt }
        let done = active.filter { $0.task.status == .done }.stableSorted(by: newestFirst)
        let groups = switch state.filter {
        case .all: byDeadline(active.filter { $0.task.status != .done })
        case .todo: byDeadline(active.filter { $0.task.status == .todo })
        case .doing: byDeadline(active.filter { $0.task.status == .doing })
        case .done: [TaskGroup(section: nil, tasks: done)]
        case .archived: [TaskGroup(section: nil, tasks: archived.stableSorted(by: newestFirst))]
        }
        return .tasks(groups: groups.filter { !$0.tasks.isEmpty }, done: state.filter == .all ? done : [], isDoneExpanded: isDoneExpanded)
    }
    
    /// Groups tasks already in deadline order under Overdue, Today, Tomorrow, Upcoming and No deadline, leaving out empty groups.
    private func byDeadline(_ tasks: [TabTask]) -> [TaskGroup] {
        let today = calendar.startOfDay(for: now())
        let grouped = Dictionary(grouping: tasks) { tabTask -> TaskSection in
            guard let dueAt = tabTask.task.dueAt else { return .noDeadline }
            if tabTask.task.isOverdue {
                return .overdue
            }
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(dueAt) / 1000))
            return switch calendar.dateComponents([.day], from: today, to: day).day {
            case 0: .today
            case 1: .tomorrow
            default: .upcoming
            }
        }
        return TaskSection.allCases.compactMap { section in grouped[section].map { TaskGroup(section: section, tasks: $0) } }
    }
    
    /// Reads the display names of the people the tasks `isShown` keeps involve, each once while the tab lives.
    ///
    /// ponytail: a name is read once, so a rename shows the next time the tab is made.
    private func requestNames(of boards: [TabChat], isShown: (ProjectedCard) -> Bool) {
        for board in boards {
            let userIDs = Set(board.snapshot.board?.cards.filter(isShown).flatMap(\.participants) ?? []).subtracting([userID])
            for userID in userIDs where requestedNames.insert(userID).inserted {
                let room = board.room.room
                Task { [weak self] in
                    guard case .success(let member) = await room.getMember(userID: userID), let name = member.displayName, let self else { return }
                    names[userID] = name
                    update()
                }
            }
        }
    }
    
    /// Everyone but `me` that the tasks involve, by name then user id.
    private static func people(of tasks: [TabTask], names: [String: String], me: String) -> [TasksTabPerson] {
        Set(tasks.flatMap(\.task.participants))
            .subtracting([me])
            .map { TasksTabPerson(userID: $0, name: names[$0] ?? $0) }
            .sorted { lhs, rhs in
                let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                return order == .orderedSame ? lhs.userID < rhs.userID : order == .orderedAscending
            }
    }
    
    private func listActions(_ board: TabChat) -> TaskListActions {
        TaskListActions(writer: TaskWriter(store: board.room.store), run: board.room.write) { [weak self] message, actionTitle, action in
            self?.showBanner(message: message, actionTitle: actionTitle, action: action)
        }
    }
    
    private func showBanner(message: String, actionTitle: String, action: @escaping () -> Void) {
        let banner = TaskBanner(message: message, actionTitle: actionTitle)
        state.banner = banner
        bannerAction = action
        announce(message)
        bannerTimeout?.cancel()
        // Reaching Undo takes a VoiceOver user longer: the banner stays until it is used, dismissed or replaced.
        guard !isVoiceOverRunning() else { return }
        bannerTimeout = Task { [weak self, bannerDuration] in
            try? await Task.sleep(for: bannerDuration)
            guard !Task.isCancelled, let self, state.banner?.id == banner.id else { return }
            dismissBanner()
        }
    }
    
    private func dismissBanner() {
        state.banner = nil
        bannerAction = nil
        bannerTimeout?.cancel()
    }
}

/// All boards of a space: its name and the chats in its tree.
private struct SpaceScope: Equatable {
    let name: String
    let chatIDs: Set<String>
    
    init(spaceID: String, filters: [SpaceServiceFilter]) {
        // A top-level filter holds its space's children, and the deeper filters after it the rest of its tree.
        var topLevelID: String?
        var chatIDs = Set<String>()
        for filter in filters {
            if filter.level == 0 {
                topLevelID = filter.room.id
            }
            if topLevelID == spaceID {
                chatIDs.formUnion(filter.descendants)
            }
        }
        name = filters.first { $0.level == 0 && $0.room.id == spaceID }?.room.name ?? ""
        self.chatIDs = chatIDs
    }
}

private extension TabChat {
    /// The chat's store is still reading; one whose read failed offers "Load older tasks" instead of checking for ever.
    var isLoading: Bool {
        !snapshot.isLoaded && !snapshot.loadFailed && snapshot.warning != .network
    }
    
    var canAddTasks: Bool {
        snapshot.board != nil && snapshot.permissions.canAddTasks
    }
    
    var tabChat: TasksTabChat {
        TasksTabChat(roomID: roomID, name: name, avatarURL: avatarURL)
    }
}

private extension TasksTabFilter {
    /// A new task starts in the status the chips show, and in To do anywhere else.
    var newTaskStatus: TaskStatus {
        switch self {
        case .doing: .doing
        case .done: .done
        case .all, .todo, .archived: .todo
        }
    }
}

extension [TabTask] {
    /// Sorted by the column of `sort`, keeping the current order between equal rows; rows without a value in that column (no
    /// deadline, an untitled thread, "Just you") come last either way.
    func sorted(for sort: TaskTableSort) -> [TabTask] {
        func by<Key>(_ key: @escaping (TabTask) -> Key?, _ compare: @escaping (Key, Key) -> ComparisonResult) -> (TabTask, TabTask) -> ComparisonResult {
            { lhs, rhs in
                switch (key(lhs), key(rhs)) {
                case (nil, nil): .orderedSame
                case (nil, _): .orderedDescending
                case (_, nil): .orderedAscending
                case (let lhs?, let rhs?): sort.isAscending ? compare(lhs, rhs) : compare(rhs, lhs)
                }
            }
        }
        func natural<Key: Comparable>(_ lhs: Key, _ rhs: Key) -> ComparisonResult {
            lhs < rhs ? .orderedAscending : lhs > rhs ? .orderedDescending : .orderedSame
        }
        let text: (String, String) -> ComparisonResult = { $0.localizedCaseInsensitiveCompare($1) }
        let compare = switch sort.column {
        case .task: by({ $0.task.title }, text)
        case .chat: by({ $0.chat.name }, text)
        case .status: by({ TaskStatus.allCases.firstIndex(of: $0.task.status) }, natural)
        case .due: by({ $0.task.dueAt }, natural)
        case .people: by({ $0.people.isEmpty ? nil : $0.peopleCell }, text)
        }
        return stableSorted { compare($0, $1) == .orderedAscending }
    }
}

private extension Array {
    /// Sorted by `areInIncreasingOrder`, keeping the current order between equal elements, which `sorted(by:)` doesn't promise.
    func stableSorted(by areInIncreasingOrder: (Element, Element) -> Bool) -> [Element] {
        enumerated()
            .sorted { lhs, rhs in
                if areInIncreasingOrder(lhs.element, rhs.element) {
                    return true
                }
                return !areInIncreasingOrder(rhs.element, lhs.element) && lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
