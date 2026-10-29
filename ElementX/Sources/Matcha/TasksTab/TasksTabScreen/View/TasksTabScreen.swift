//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import MatchaProtocol
import SwiftUI

/// The Tasks tab, or a space's boards: the chips, the tasks grouped by deadline or in a table, the list's footer, New task in the
/// toolbar, and the sheets.
struct TasksTabScreen: View {
    @Bindable var context: TasksTabScreenViewModel.Context
    
    private var isSpace: Bool {
        context.viewState.spaceName != nil
    }
    
    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.compound.bgCanvasDefault.ignoresSafeArea())
            .navigationTitle(isSpace ? UntranslatedL10n.screenMatchaSpaceBoardsTitle : UntranslatedL10n.commonMatchaTasks)
            .matchaNavigationSubtitle(context.viewState.spaceName)
            .navigationBarTitleDisplayMode(isSpace ? .inline : .large)
            .toolbar { toolbar }
            .overlay(alignment: .bottom) {
                if let banner = context.viewState.banner {
                    TaskBannerView(banner: banner) {
                        context.send(viewAction: .bannerAction)
                    } dismiss: {
                        context.send(viewAction: .dismissBanner)
                    }
                }
            }
            .animation(.elementDefault, value: context.viewState.banner)
            .sheet(item: $context.sheet) { sheet in
                switch sheet {
                case .chooseChat(let purpose):
                    ChooseChatSheet(context: context, purpose: purpose)
                case .choosePerson:
                    ChoosePersonSheet(context: context)
                }
            }
            .confirmationDialog(context.viewState.actionsTask?.task.title ?? UntranslatedL10n.commonMatchaThreadUntitled,
                                isPresented: Binding { context.actionsTaskID != nil } set: {
                                    if !$0 {
                                        context.actionsTaskID = nil
                                    }
                                },
                                titleVisibility: .visible,
                                presenting: context.viewState.actionsTask) { task in
                if task.canEdit, !task.task.isArchived {
                    ForEach(TaskStatus.allCases.filter { $0 != task.task.status }, id: \.self) { status in
                        Button(status.label) { context.send(viewAction: .move(task.id, status: status)) }
                    }
                }
                TabTaskActionButtons(task: task, context: context)
            } message: { task in
                Text(UntranslatedL10n.screenMatchaTasksInChat(task.chat.name))
            }
            .onAppear { context.send(viewAction: .appeared) }
            .onDisappear { context.send(viewAction: .disappeared) }
    }
    
    @ViewBuilder
    private var content: some View {
        switch context.viewState.content {
        case .table(let rows, let sort):
            ScrollView {
                // Lazy and pinning section headers, so the table's header stays on screen while its rows scroll.
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                    TasksTabChips(context: context)
                    if rows.isEmpty {
                        NoMatchingTasks(filter: context.viewState.filter)
                    } else {
                        TasksTable(rows: rows, sort: sort, context: context)
                    }
                    TasksTabFooter(context: context)
                }
            }
        case .loading, .empty, .tasks:
            CanvasList {
                TasksTabChips(context: context)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                listContent
                if TasksTabFooter.isShown(context.viewState) {
                    TasksTabFooter(context: context)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                }
            }
        }
    }
    
    @ViewBuilder
    private var listContent: some View {
        switch context.viewState.content {
        case .loading:
            TaskPlaceholderRows()
        case .empty:
            EmptyTasksTab(isSpace: isSpace)
                .listRowSeparator(.hidden)
        case .tasks(let groups, let done, let isDoneExpanded):
            if groups.isEmpty, done.isEmpty {
                NoMatchingTasks(filter: context.viewState.filter)
                    .listRowSeparator(.hidden)
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.tasks) { task in
                        TabTaskRow(task: task, context: context)
                    }
                } header: {
                    if let section = group.section {
                        Text(section.label)
                            .font(.compound.bodyMDSemibold)
                            .foregroundStyle(.compound.textSecondary)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
            }
            if !done.isEmpty {
                Button { context.send(viewAction: .toggleDone) } label: {
                    HStack(spacing: 4) {
                        Text(UntranslatedL10n.screenMatchaTasksDoneSection(done.count))
                        CompoundIcon(isDoneExpanded ? \.chevronDown : \.chevronRight, size: .small, relativeTo: .compound.bodyMD)
                            .foregroundStyle(.compound.iconSecondary)
                            .accessibilityHidden(true)
                    }
                    .font(.compound.bodyMDSemibold)
                    .foregroundStyle(.compound.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isHeader)
                .accessibilityValue(isDoneExpanded ? UntranslatedL10n.a11yStateExpanded : UntranslatedL10n.a11yStateCollapsed)
                if isDoneExpanded {
                    ForEach(done) { task in
                        TabTaskRow(task: task, context: context)
                    }
                }
            }
        case .table:
            EmptyView()
        }
    }
    
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let userProfile = context.viewState.userProfile {
            MatchaSettingsToolbarItem(userProfile: userProfile, mediaProvider: context.mediaProvider) {
                context.send(viewAction: .showSettings)
            }
        }
        
        ToolbarItem(placement: .primaryAction) {
            Button { context.send(viewAction: .newTask) } label: {
                CompoundIcon(\.plus)
                    .accessibilityHidden(true)
            }
            .matchaProminentToolbarButton()
            .accessibilityLabel(UntranslatedL10n.screenMatchaTasksNew)
        }
    }
}

// MARK: - Parts

/// All · To do · In progress · Done · Archived, then Chat ▾ and People ▾, and the list or table switch at the end.
private struct TasksTabChips: View {
    let context: TasksTabScreenViewModel.Context
    
    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(TasksTabFilter.allCases, id: \.self) { filter in
                        let isSelected = context.viewState.filter == filter
                        Button(filter.label) { context.send(viewAction: .setFilter(filter)) }
                            .buttonStyle(ChatBarChipStyle(isSelected: isSelected))
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                    // Tapping a chosen chat or person shows everyone's tasks again, like the other chips.
                    dropDownChip(title: context.viewState.chatFilter?.name ?? UntranslatedL10n.screenMatchaTasksFilterChat,
                                 isSelected: context.viewState.chatFilter != nil) {
                        context.send(viewAction: .toggleChatFilter)
                    }
                    if !context.viewState.people.isEmpty || context.viewState.personFilter != nil {
                        dropDownChip(title: context.viewState.personFilter?.name ?? UntranslatedL10n.screenMatchaTasksFilterPeople,
                                     isSelected: context.viewState.personFilter != nil) {
                            context.send(viewAction: .togglePersonFilter)
                        }
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, 8)
            }
            .sensoryFeedback(.selection, trigger: context.viewState.filter)
            
            Button { context.send(viewAction: .toggleTable) } label: {
                CompoundIcon(context.viewState.isTable ? \.listView : \.grid)
                    .foregroundStyle(.compound.iconSecondary)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.borderless)
            .padding(.trailing, 8)
            .accessibilityLabel(context.viewState.isTable ? UntranslatedL10n.a11yMatchaTasksShowList : UntranslatedL10n.a11yMatchaTasksShowTable)
        }
        .padding(.vertical, 8)
    }
    
    private func dropDownChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .lineLimit(1)
                    .frame(maxWidth: 160, alignment: .leading)
                    .fixedSize()
                CompoundIcon(\.chevronDown, size: .xSmall, relativeTo: .compound.bodyMD)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(ChatBarChipStyle(isSelected: isSelected))
        .accessibilityHint(isSelected ? L10n.actionClear : "")
    }
}

/// A task's row: tap opens it, swipes mark it done or archive it, and a long press offers its other actions.
private struct TabTaskRow: View {
    let task: TabTask
    let context: TasksTabScreenViewModel.Context
    
    var body: some View {
        Button { context.send(viewAction: .openTask(task.id)) } label: {
            TaskRow(task: task.task,
                    chat: TaskRowChat(name: task.chat.name, avatar: task.chat.avatar),
                    people: task.peopleLine,
                    mediaProvider: context.mediaProvider)
        }
        .swipeActions(edge: .leading) {
            if task.canEdit, !task.task.isArchived, task.task.status != .done {
                Button { context.send(viewAction: .move(task.id, status: .done)) } label: {
                    Label(TaskStatus.done.label, systemImage: "checkmark.circle")
                }
                .tint(.compound.iconAccentPrimary)
            }
        }
        .swipeActions(edge: .trailing) {
            if task.canArchive {
                Button { context.send(viewAction: .setArchived(task.id, archived: !task.task.isArchived)) } label: {
                    task.task.isArchived
                        ? Label(UntranslatedL10n.actionMatchaUnarchive, systemImage: "tray.and.arrow.up")
                        : Label { Text(UntranslatedL10n.actionMatchaArchive) } icon: { Asset.Images.matchaArchive.swiftUIImage }
                }
            }
        }
        .contextMenu { TabTaskMenu(task: task, context: context) }
    }
}

/// A task's long-press menu: Move to, then the other actions.
struct TabTaskMenu: View {
    let task: TabTask
    let context: TasksTabScreenViewModel.Context
    
    var body: some View {
        if task.canEdit, !task.task.isArchived {
            Menu(UntranslatedL10n.screenMatchaTasksMoveTo) {
                ForEach(TaskStatus.allCases, id: \.self) { status in
                    Button { context.send(viewAction: .move(task.id, status: status)) } label: {
                        if task.task.status == status {
                            Label(status.label, systemImage: "checkmark")
                        } else {
                            Text(status.label)
                        }
                    }
                }
            }
        }
        TabTaskActionButtons(task: task, context: context)
    }
}

/// The actions besides moving, shared by the long-press menu and the action sheet, in the order of Android's `TaskActionsSheet`. The
/// reminder sheet belongs to the chat, so the tab offers Open chat instead of Remind me, as Android does.
private struct TabTaskActionButtons: View {
    let task: TabTask
    let context: TasksTabScreenViewModel.Context
    
    var body: some View {
        if task.canArchive, task.task.isArchived {
            Button { context.send(viewAction: .setArchived(task.id, archived: false)) } label: {
                Label(UntranslatedL10n.actionMatchaUnarchive, systemImage: "tray.and.arrow.up")
            }
        }
        if task.task.threadID != nil {
            Button { context.send(viewAction: .openTask(task.id)) } label: {
                Label(UntranslatedL10n.screenMatchaTasksOpenThread, icon: \.threads)
            }
        }
        Button { context.send(viewAction: .openChat(roomID: task.chat.roomID)) } label: {
            Label(UntranslatedL10n.screenMatchaTasksOpenChat, icon: \.chat)
        }
        if task.canEdit {
            Button { context.send(viewAction: .editTask(task.id)) } label: {
                Label(UntranslatedL10n.screenMatchaTasksEdit, icon: \.edit)
            }
        }
        if task.canArchive, !task.task.isArchived {
            Button { context.send(viewAction: .setArchived(task.id, archived: true)) } label: {
                Label { Text(UntranslatedL10n.actionMatchaArchive) } icon: { Asset.Images.matchaArchive.swiftUIImage }
            }
        }
    }
}

/// Load older tasks, the chats still being checked, those that couldn't be with Retry, and the unreadable note.
private struct TasksTabFooter: View {
    let context: TasksTabScreenViewModel.Context
    
    static func isShown(_ state: TasksTabScreenViewState) -> Bool {
        let isLoading = state.content == .loading
        return state.hasMore && !isLoading || state.checkingCount > 0 && !isLoading || state.failedCount > 0 || state.isUnreadable
    }
    
    var body: some View {
        let state = context.viewState
        let isLoading = state.content == .loading
        VStack(spacing: 0) {
            if state.hasMore, !isLoading {
                LoadOlderTasksRow(isLoading: state.isLoadingMore) { context.send(viewAction: .loadMore) }
            }
            if state.checkingCount > 0, !isLoading {
                note(UntranslatedL10n.screenMatchaTasksCheckingChats(state.checkingCount))
            }
            if state.failedCount > 0 {
                HStack(spacing: 8) {
                    Text(UntranslatedL10n.screenMatchaTasksCheckFailed(state.failedCount))
                        .font(.compound.bodyMD)
                        .foregroundStyle(.compound.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(L10n.actionRetry) { context.send(viewAction: .retry) }
                        .buttonStyle(.compound(.textLink, size: .small))
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 56)
            }
            if state.isUnreadable {
                note(UntranslatedL10n.screenMatchaTasksTabUnreadable)
            }
        }
        .padding(.bottom, 16)
    }
    
    private func note(_ text: String) -> some View {
        Text(text)
            .font(.compound.bodyMD)
            .foregroundStyle(.compound.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
    }
}

/// No task yet, on the Tasks tab or in a space's boards.
private struct EmptyTasksTab: View {
    let isSpace: Bool
    
    var body: some View {
        VStack(spacing: 16) {
            Asset.Images.matchaBoard.swiftUIImage
                .bigIcon()
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(UntranslatedL10n.screenMatchaTasksTabEmptyTitle)
                    .font(.compound.headingMDBold)
                    .foregroundStyle(.compound.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(isSpace ? UntranslatedL10n.screenMatchaSpaceBoardsEmptyBody : UntranslatedL10n.screenMatchaTasksTabEmptyBody)
                    .font(.compound.bodyMD)
                    .foregroundStyle(.compound.textSecondary)
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 64)
    }
}

/// The chips select no task.
struct NoMatchingTasks: View {
    let filter: TasksTabFilter
    
    var body: some View {
        Text(filter == .archived ? UntranslatedL10n.screenMatchaTasksArchivedEmpty : UntranslatedL10n.screenMatchaTasksBoardEmptyTitle)
            .font(.compound.bodyLGSemibold)
            .foregroundStyle(.compound.textPrimary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 64)
    }
}

/// Chat ▾ and New task's Choose a chat: a searchable list of chats.
private struct ChooseChatSheet: View {
    @Bindable var context: TasksTabScreenViewModel.Context
    let purpose: ChooseChatPurpose
    
    var body: some View {
        ElementNavigationStack {
            content
                .navigationTitle(purpose == .filter ? UntranslatedL10n.screenMatchaTasksFilterChat : UntranslatedL10n.screenMatchaTasksPickChatTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.actionCancel) { context.send(viewAction: .dismissSheet) }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
    
    @ViewBuilder
    private var content: some View {
        if context.viewState.chatChoices.isEmpty {
            SheetNote(text: UntranslatedL10n.screenMatchaTasksPickChatEmpty)
        } else {
            let chats = context.viewState.visibleChatChoices
            List {
                if chats.isEmpty {
                    SheetNote(text: L10n.commonNoResults)
                        .listRowSeparator(.hidden)
                }
                ForEach(chats) { chat in
                    Button { context.send(viewAction: .chooseChat(roomID: chat.roomID)) } label: {
                        HStack(spacing: 16) {
                            RoomAvatarImage(avatar: chat.avatar, avatarSize: .room(on: .chats), mediaProvider: context.mediaProvider)
                                .accessibilityHidden(true)
                            Text(chat.name)
                                .font(.compound.bodyLGSemibold)
                                .foregroundStyle(.compound.textPrimary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .searchable(text: $context.chatSearchQuery, placement: .navigationBarDrawer(displayMode: .always), prompt: L10n.actionSearch)
        }
    }
}

/// People ▾: everyone the user works with, then each of them; the chosen one is ticked.
private struct ChoosePersonSheet: View {
    let context: TasksTabScreenViewModel.Context
    @ScaledMetric private var avatarSize = Avatars.Size.user(on: .startChat).value
    
    var body: some View {
        ElementNavigationStack {
            List {
                row(name: UntranslatedL10n.screenMatchaTasksAllPeople, userID: nil) {
                    CompoundIcon(\.group)
                        .foregroundStyle(.compound.iconSecondary)
                        .frame(width: avatarSize, height: avatarSize)
                        .background(.compound.bgSubtleSecondary, in: Circle())
                }
                ForEach(context.viewState.people) { person in
                    row(name: person.name, userID: person.userID) {
                        LoadableAvatarImage(url: nil, name: person.name, contentID: person.userID, avatarSize: .user(on: .startChat), mediaProvider: context.mediaProvider)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle(UntranslatedL10n.screenMatchaTasksFilterPeopleTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.actionCancel) { context.send(viewAction: .dismissSheet) }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
    
    private func row(name: String, userID: String?, @ViewBuilder avatar: () -> some View) -> some View {
        let isSelected = context.viewState.personFilter?.userID == userID
        return Button { context.send(viewAction: .choosePerson(userID: userID)) } label: {
            HStack(spacing: 16) {
                avatar()
                    .accessibilityHidden(true)
                Text(name)
                    .font(.compound.bodyLGSemibold)
                    .foregroundStyle(.compound.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isSelected {
                    CompoundIcon(\.check)
                        .foregroundStyle(.compound.iconAccentPrimary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SheetNote: View {
    let text: String
    
    var body: some View {
        Text(text)
            .font(.compound.bodyMD)
            .foregroundStyle(.compound.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
    }
}

extension TasksTabFilter {
    var label: String {
        switch self {
        case .all: UntranslatedL10n.commonMatchaAll
        case .todo: TaskStatus.todo.label
        case .doing: TaskStatus.doing.label
        case .done: TaskStatus.done.label
        case .archived: UntranslatedL10n.commonMatchaArchived
        }
    }
}

private extension TaskSection {
    var label: String {
        switch self {
        case .overdue: UntranslatedL10n.screenMatchaTasksOverdue
        case .today: UntranslatedL10n.screenMatchaTasksSectionToday
        case .tomorrow: UntranslatedL10n.screenMatchaTasksSectionTomorrow
        case .upcoming: UntranslatedL10n.screenMatchaTasksSectionUpcoming
        case .noDeadline: UntranslatedL10n.screenMatchaTasksSectionNoDeadline
        }
    }
}

private extension View {
    /// The space's name under the title of its boards, once known.
    @ViewBuilder
    func matchaNavigationSubtitle(_ subtitle: String?) -> some View {
        if let subtitle, !subtitle.isEmpty {
            navigationSubtitle(subtitle)
        } else {
            self
        }
    }
}

// MARK: - Previews

struct TasksTabScreen_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        preview(state())
            .previewDisplayName("Tasks")
        preview(state(content: .loading, checkingCount: 12))
            .previewDisplayName("Loading")
        preview(state(content: .empty))
            .previewDisplayName("Empty")
        preview(state(content: tasksContent(isDoneExpanded: true)))
            .previewDisplayName("Done expanded")
        preview(state(filter: .archived, chatFilter: design, content: .tasks(groups: [], done: [], isDoneExpanded: false)))
            .previewDisplayName("No archived tasks in a chat")
        preview(state(checkingCount: 3, failedCount: 2, isUnreadable: true, hasMore: true))
            .previewDisplayName("Footer")
        preview(state(hasMore: true, isLoadingMore: true))
            .previewDisplayName("Loading older tasks")
        preview(state(personFilter: bob))
            .previewDisplayName("One person")
        preview(state(chatChoices: [design, launch], bindings: .init(sheet: .chooseChat(.newTask))))
            .previewDisplayName("Choose a chat")
        preview(state(bindings: .init(sheet: .chooseChat(.newTask))))
            .previewDisplayName("Choose a chat without any")
        preview(state(chatChoices: [design, launch], bindings: .init(sheet: .chooseChat(.filter), chatSearchQuery: "zzz")))
            .previewDisplayName("Chat filter without a match")
        preview(state(personFilter: carol, bindings: .init(sheet: .choosePerson)))
            .previewDisplayName("Filter by person")
        preview(state(isTable: true, content: tableContent()))
            .previewDisplayName("Table")
        preview(state(isTable: true, content: tableContent(sort: TaskTableSort(column: .task, isAscending: false))))
            .previewDisplayName("Table sorted by task")
        preview(state(filter: .archived, isTable: true, content: .table(rows: [], sort: TaskTableSort())))
            .previewDisplayName("Table without archived tasks")
        preview(state(spaceName: "Acme"))
            .previewDisplayName("Space boards")
        preview(state(content: .empty, spaceName: "Acme"))
            .previewDisplayName("Space boards empty")
        preview(state(content: .loading, checkingCount: 3, spaceName: ""))
            .previewDisplayName("Space boards loading")
        preview(state(filter: .done, content: .tasks(groups: [TaskGroup(section: nil, tasks: doneTasks)], done: [], isDoneExpanded: false)))
            .previewDisplayName("Done")
        preview(state(bindings: .init(sheet: .choosePerson)))
            .previewDisplayName("Filter by person, everyone")
        preview(state(userProfile: UserProfile(userID: "@alice:matrix.org", displayName: "Alice")))
            .previewDisplayName("Tasks tab with its settings avatar")
    }
    
    static let design = TasksTabChat(roomID: "!design:matrix.org", name: "Design team", avatarURL: nil)
    static let launch = TasksTabChat(roomID: "!launch:matrix.org", name: "Launch", avatarURL: nil)
    static let bob = TasksTabPerson(userID: "@bob:matrix.org", name: "Bob")
    static let carol = TasksTabPerson(userID: "@carol:matrix.org", name: "Carol")
    
    static func preview(_ state: TasksTabScreenViewState) -> some View {
        ElementNavigationStack {
            TasksTabScreen(context: TasksTabScreenPreviewViewModel(state: state).context)
        }
    }
    
    /// Tasks grouped by deadline on the Tasks tab, unless told otherwise.
    static func state(filter: TasksTabFilter = .all,
                      chatFilter: TasksTabChat? = nil,
                      personFilter: TasksTabPerson? = nil,
                      isTable: Bool = false,
                      content: TasksTabContent = tasksContent(),
                      checkingCount: Int = 0,
                      failedCount: Int = 0,
                      isUnreadable: Bool = false,
                      hasMore: Bool = false,
                      isLoadingMore: Bool = false,
                      spaceName: String? = nil,
                      chatChoices: [TasksTabChat] = [],
                      userProfile: UserProfile? = nil,
                      bindings: TasksTabScreenViewStateBindings = .init()) -> TasksTabScreenViewState {
        TasksTabScreenViewState(filter: filter,
                                chatFilter: chatFilter,
                                personFilter: personFilter,
                                people: [bob, carol],
                                isTable: isTable,
                                content: content,
                                checkingCount: checkingCount,
                                failedCount: failedCount,
                                isUnreadable: isUnreadable,
                                hasMore: hasMore,
                                isLoadingMore: isLoadingMore,
                                spaceName: spaceName,
                                chatChoices: chatChoices,
                                userProfile: userProfile,
                                bindings: bindings)
    }
    
    static func tabTask(_ id: String,
                        _ title: String?,
                        chat: TasksTabChat = design,
                        status: TaskStatus = .todo,
                        deadline: String? = nil,
                        isOverdue: Bool = false,
                        isSharedWithChat: Bool = false,
                        threadID: String? = "$thread",
                        people: [String] = []) -> TabTask {
        TabTask(chat: chat,
                task: TaskItem(id: id, title: title, summary: "", status: status, isArchived: false, threadID: threadID, dueAt: deadline == nil ? nil : 1,
                               deadline: deadline, isOverdue: isOverdue, replyCount: 2, hasReminder: false, isSharedWithChat: isSharedWithChat, participants: []),
                createdAt: 0,
                people: people,
                canEdit: true,
                canArchive: true)
    }
    
    static func tasksContent(isDoneExpanded: Bool = false) -> TasksTabContent {
        .tasks(groups: [TaskGroup(section: .overdue, tasks: [tabTask("t1", "Book the venue", deadline: "Yesterday", isOverdue: true, isSharedWithChat: true, people: ["Bob", "Carol"])]),
                        TaskGroup(section: .today, tasks: [tabTask("t2", "Draft the press release", chat: launch, deadline: "Today 17:00")]),
                        TaskGroup(section: .upcoming, tasks: [tabTask("t3", "Order the banners", status: .doing, deadline: "Tue 17:00", people: ["Bob"])]),
                        TaskGroup(section: .noDeadline, tasks: [tabTask("t4", nil),
                                                                tabTask("legacy", "An older card without a thread", chat: launch, threadID: nil)])],
               done: doneTasks,
               isDoneExpanded: isDoneExpanded)
    }
    
    static var doneTasks: [TabTask] {
        [tabTask("d1", "Pick the date", status: .done), tabTask("d2", "Send the invites", chat: launch, status: .done)]
    }
    
    static func tableContent(sort: TaskTableSort = TaskTableSort()) -> TasksTabContent {
        .table(rows: [tabTask("t1", "Book the venue", deadline: "Yesterday", isOverdue: true, isSharedWithChat: true, people: ["Bob", "Carol"]),
                      tabTask("t2", "Draft the press release", chat: launch, deadline: "Today 17:00"),
                      tabTask("t3", "Order the banners", status: .doing, deadline: "Tue 17:00", people: ["Bob"]),
                      tabTask("t4", nil, people: ["Carol"]),
                      tabTask("d1", "Pick the date", chat: launch, status: .done, people: ["Bob", "Carol", "Dan"])],
               sort: sort)
    }
}

/// A Tasks tab showing a fixed state, for previews.
private final class TasksTabScreenPreviewViewModel: TasksTabScreenViewModelType {
    init(state: TasksTabScreenViewState) {
        super.init(initialViewState: state, mediaProvider: MediaProviderMock(.init()))
    }
}
