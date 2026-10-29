//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import MatchaProtocol
import SwiftUI

/// A chat's task board: a status picker over one list on compact width, three columns on regular width.
struct TasksBoardScreen: View {
    @Bindable var context: TasksBoardScreenViewModel.Context
    /// The chat's chip bar, with the board selected.
    var chatBarContext: ChatBarViewModel.Context?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    
    private var isWide: Bool {
        horizontalSizeClass == .regular
    }
    
    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .matchaChatBar(chatBarContext)
            .background(.compound.bgCanvasDefault)
            .navigationTitle(UntranslatedL10n.commonMatchaTasks)
            .navigationSubtitle(context.viewState.roomName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .modifier(TasksBoardOverlays(context: context))
    }
    
    @ViewBuilder
    private var content: some View {
        switch context.viewState.content {
        case .lookingForBoard:
            CanvasList {
                TaskPlaceholderRows()
                Text(UntranslatedL10n.screenMatchaTasksLooking)
                    .font(.compound.bodyMD)
                    .foregroundStyle(.compound.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
            }
        case .loadFailed:
            BoardMessage(title: UntranslatedL10n.commonMatchaWriteFailed, subtitle: nil, icon: \.warning, iconStyle: .alertSolid,
                         actionTitle: L10n.actionRetry) {
                context.send(viewAction: .retryLoad)
            }
        case .setup(let canCreate, let isCreating, let createFailed):
            BoardMessage(title: UntranslatedL10n.screenMatchaTasksSetupTitle,
                         subtitle: canCreate ? UntranslatedL10n.screenMatchaTasksSetupBody : UntranslatedL10n.screenMatchaTasksSetupNoPermission,
                         icon: \.checkCircle,
                         iconStyle: .defaultSolid,
                         actionTitle: canCreate ? UntranslatedL10n.screenMatchaTasksSetupAction : nil,
                         isBusy: isCreating,
                         error: createFailed ? UntranslatedL10n.screenMatchaTasksSetupFailed : nil) {
                context.send(viewAction: .createBoard)
            }
        case .board(let board):
            if isWide {
                wideBoard(board)
            } else {
                compactBoard(board)
            }
        }
    }
    
    // MARK: Compact
    
    private func compactBoard(_ board: TasksBoard) -> some View {
        let tasks = board.tasks(context.selectedStatus)
        return VStack(spacing: 0) {
            statusPicker(board)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            BoardNotices(board: board)
            CanvasList {
                if !board.archived.isEmpty {
                    archivedRow(count: board.archived.count)
                }
                if board.isLoading {
                    TaskPlaceholderRows()
                } else if tasks.isEmpty {
                    EmptyBoardMessage(canAdd: board.canAdd)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(tasks, id: \.listID) { task in
                        TaskListRow(task: task, board: board, context: context)
                    }
                }
                if board.hasMore {
                    LoadOlderTasksRow(isLoading: board.isLoadingMore) { context.send(viewAction: .loadMore) }
                        .id("load-older")
                }
            }
        }
    }
    
    /// A segmented picker, or a scrolling row of tabs when the text is too large for one.
    @ViewBuilder
    private func statusPicker(_ board: TasksBoard) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(TaskStatus.allCases, id: \.self) { status in
                        let isSelected = context.selectedStatus == status
                        Button { context.selectedStatus = status } label: {
                            HStack(spacing: 6) {
                                Text(status.label)
                                    .font(.compound.bodyMDSemibold)
                                    .foregroundStyle(isSelected ? Color.compound.textActionAccent : .compound.textSecondary)
                                Text(board.tasks(status).count.formatted())
                                    .font(.compound.bodyMD)
                                    .foregroundStyle(.compound.textSecondary)
                            }
                            .frame(minHeight: 44)
                        }
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
        } else {
            Picker(UntranslatedL10n.screenMatchaTasksStatusLabel, selection: $context.selectedStatus) {
                ForEach(TaskStatus.allCases, id: \.self) { status in
                    Text(verbatim: "\(status.label) \(board.tasks(status).count.formatted())")
                        .tag(status)
                }
            }
            .pickerStyle(.segmented)
        }
    }
    
    // MARK: Wide
    
    private func wideBoard(_ board: TasksBoard) -> some View {
        VStack(spacing: 0) {
            BoardNotices(board: board)
            if !board.archived.isEmpty {
                Button { context.send(viewAction: .showArchived) } label: {
                    ArchivedTasksRow(count: board.archived.count)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            if board.isLoading {
                CanvasList { TaskPlaceholderRows() }
            } else if board.todo.isEmpty, board.doing.isEmpty, board.done.isEmpty {
                EmptyBoardMessage(canAdd: board.canAdd)
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(TaskStatus.allCases, id: \.self) { status in
                            column(status, board: board)
                                .containerRelativeFrame(.horizontal, count: TaskStatus.allCases.count, spacing: 8)
                                .frame(minWidth: 240)
                        }
                    }
                    .padding(16)
                }
            }
            if board.hasMore {
                LoadOlderTasksRow(isLoading: board.isLoadingMore) { context.send(viewAction: .loadMore) }
            }
        }
    }
    
    private func column(_ status: TaskStatus, board: TasksBoard) -> some View {
        let tasks = board.tasks(status)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(status.label)
                Text(tasks.count.formatted())
            }
            .font(.compound.bodyMDSemibold)
            .foregroundStyle(.compound.textSecondary)
            .frame(minHeight: 44)
            .padding(.horizontal, 12)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(tasks, id: \.listID) { task in
                        Button { context.send(viewAction: .openTask(id: task.id)) } label: {
                            TaskCard(task: task)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { TaskMenu(task: task, board: board, context: context) }
                    }
                }
                .padding([.horizontal, .bottom], 8)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // A grouped surface, its cards raised on it (WHATSAPP_DESIGN §4b).
        .background(.compound.bgSubtleSecondaryLevel0, in: RoundedRectangle(cornerRadius: 16))
    }
    
    // MARK: Shared
    
    private func archivedRow(count: Int) -> some View {
        Button { context.send(viewAction: .showArchived) } label: {
            ArchivedTasksRow(count: count)
        }
        .id("archived")
    }
    
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if case .board(let board) = context.viewState.content, board.canAdd {
            ToolbarItem(placement: .primaryAction) {
                Button { context.send(viewAction: .newTask(status: isWide ? .todo : context.selectedStatus)) } label: {
                    CompoundIcon(\.plus)
                }
                .accessibilityLabel(UntranslatedL10n.screenMatchaTasksNew)
            }
        }
    }
}

/// The archived tasks of a chat's board, from the board's view model.
struct ArchivedTasksScreen: View {
    @Bindable var context: TasksBoardScreenViewModel.Context
    
    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.compound.bgCanvasDefault)
            .navigationTitle(UntranslatedL10n.screenMatchaTasksArchivedTitle)
            .navigationSubtitle(context.viewState.roomName)
            .navigationBarTitleDisplayMode(.inline)
            .modifier(TasksBoardOverlays(context: context))
    }
    
    @ViewBuilder
    private var content: some View {
        if case .board(let board) = context.viewState.content, !board.isLoading {
            if board.archived.isEmpty {
                Text(UntranslatedL10n.screenMatchaTasksArchivedEmpty)
                    .font(.compound.bodyLGSemibold)
                    .foregroundStyle(.compound.textPrimary)
            } else {
                CanvasList {
                    ForEach(board.archived, id: \.listID) { task in
                        TaskListRow(task: task, board: board, context: context)
                    }
                    if board.hasMore {
                        LoadOlderTasksRow(isLoading: board.isLoadingMore) { context.send(viewAction: .loadMore) }
                            .id("load-older")
                    }
                }
            }
        } else {
            CanvasList { TaskPlaceholderRows() }
        }
    }
}

// MARK: - Parts

/// A task's row in a list: tap opens it, swipes mark it done or archive it, and a long press offers its other actions.
private struct TaskListRow: View {
    let task: TaskItem
    let board: TasksBoard
    let context: TasksBoardScreenViewModel.Context
    
    var body: some View {
        Button { context.send(viewAction: .openTask(id: task.id)) } label: {
            TaskRow(task: task)
        }
        .swipeActions(edge: .leading) {
            if board.canEdit, !task.isArchived, task.status != .done {
                Button { context.send(viewAction: .move(id: task.id, status: .done)) } label: {
                    Label(TaskStatus.done.label, systemImage: "checkmark.circle")
                }
                .tint(.compound.iconAccentPrimary)
            }
        }
        .swipeActions(edge: .trailing) {
            if board.canArchive(task) {
                Button { context.send(viewAction: .setArchived(id: task.id, archived: !task.isArchived)) } label: {
                    task.isArchived
                        ? Label(UntranslatedL10n.actionMatchaUnarchive, systemImage: "tray.and.arrow.up")
                        : Label { Text(UntranslatedL10n.actionMatchaArchive) } icon: { Asset.Images.matchaArchive.swiftUIImage }
                }
            }
        }
        .contextMenu { TaskMenu(task: task, board: board, context: context) }
    }
}

/// A task's actions: an active task can be moved, opened, edited and archived; an archived one unarchived, opened and edited.
/// Without `canEdit` only Open thread is offered.
private struct TaskMenu: View {
    let task: TaskItem
    let board: TasksBoard
    let context: TasksBoardScreenViewModel.Context
    
    var body: some View {
        if board.canEdit, !task.isArchived {
            Menu(UntranslatedL10n.screenMatchaTasksMoveTo) {
                ForEach(TaskStatus.allCases, id: \.self) { status in
                    Button { context.send(viewAction: .move(id: task.id, status: status)) } label: {
                        if task.status == status {
                            Label(status.label, systemImage: "checkmark")
                        } else {
                            Text(status.label)
                        }
                    }
                }
            }
        }
        TaskActionButtons(task: task, board: board, context: context)
    }
}

/// The actions besides moving, shared by the context menu and the action sheet, in the order of Android's `TaskActionsSheet`.
private struct TaskActionButtons: View {
    let task: TaskItem
    let board: TasksBoard
    let context: TasksBoardScreenViewModel.Context
    
    var body: some View {
        if board.canArchive(task), task.isArchived {
            Button { context.send(viewAction: .setArchived(id: task.id, archived: false)) } label: {
                Label(UntranslatedL10n.actionMatchaUnarchive, systemImage: "tray.and.arrow.up")
            }
        }
        if task.threadID != nil {
            Button { context.send(viewAction: .openTask(id: task.id)) } label: {
                Label(UntranslatedL10n.screenMatchaTasksOpenThread, icon: \.threads)
            }
        }
        if board.canRemind, !task.isArchived {
            Button { context.send(viewAction: .remindMe(id: task.id)) } label: {
                Label(UntranslatedL10n.actionMatchaRemindMe, icon: \.notifications)
            }
        }
        if board.canEdit {
            Button { context.send(viewAction: .editTask(id: task.id)) } label: {
                Label(UntranslatedL10n.screenMatchaTasksEdit, icon: \.edit)
            }
        }
        if board.canArchive(task), !task.isArchived {
            Button { context.send(viewAction: .setArchived(id: task.id, archived: true)) } label: {
                Label { Text(UntranslatedL10n.actionMatchaArchive) } icon: { Asset.Images.matchaArchive.swiftUIImage }
            }
        }
    }
}

/// The banner and the action sheet, under the board and its archived tasks.
private struct TasksBoardOverlays: ViewModifier {
    @Bindable var context: TasksBoardScreenViewModel.Context
    /// Both screens share one view model, so only the one on top presents the action sheet: with the archived tasks pushed above
    /// the board, both would try to present it and it might not show.
    @State private var isOnTop = false
    
    func body(content: Content) -> some View {
        content
            .onAppear { isOnTop = true }
            .onDisappear { isOnTop = false }
            // An inset rather than an overlay, so the chat's own banner, at the bottom of the board under the chat's bar, stacks
            // above this one instead of under it.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let banner = context.viewState.banner {
                    TaskBannerView(banner: banner) {
                        context.send(viewAction: .bannerAction)
                    } dismiss: {
                        context.send(viewAction: .dismissBanner)
                    }
                }
            }
            .animation(.elementDefault, value: context.viewState.banner)
            .confirmationDialog(context.viewState.actionsTask?.title ?? UntranslatedL10n.commonMatchaThreadUntitled,
                                isPresented: Binding { isOnTop && context.actionsTaskID != nil } set: {
                                    if !$0 {
                                        context.actionsTaskID = nil
                                    }
                                },
                                titleVisibility: .visible,
                                presenting: context.viewState.actionsTask) { task in
                if case .board(let board) = context.viewState.content {
                    if board.canEdit, !task.isArchived {
                        ForEach(TaskStatus.allCases.filter { $0 != task.status }, id: \.self) { status in
                            Button(status.label) { context.send(viewAction: .move(id: task.id, status: status)) }
                        }
                    }
                    TaskActionButtons(task: task, board: board, context: context)
                }
            }
    }
}

private struct BoardNotices: View {
    let board: TasksBoard
    
    var body: some View {
        if board.isUnreadable {
            MatchaWarningStrip(text: UntranslatedL10n.screenMatchaTasksUnreadable, lineLimit: 3)
        }
        if !board.canEdit {
            MatchaWarningStrip(text: UntranslatedL10n.screenMatchaTasksReadOnly, lineLimit: 3)
        }
    }
}

private struct EmptyBoardMessage: View {
    let canAdd: Bool
    
    var body: some View {
        VStack(spacing: 8) {
            Text(UntranslatedL10n.screenMatchaTasksBoardEmptyTitle)
                .font(.compound.bodyLGSemibold)
                .foregroundStyle(.compound.textPrimary)
                .accessibilityAddTraits(.isHeader)
            if canAdd {
                Text(UntranslatedL10n.screenMatchaTasksBoardEmptyBody)
                    .font(.compound.bodyMD)
                    .foregroundStyle(.compound.textSecondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    }
}

/// A centred state: a big icon, a title and a body, an optional error, and an optional button.
private struct BoardMessage: View {
    let title: String
    let subtitle: String?
    let icon: KeyPath<CompoundIcons, Image>
    let iconStyle: BigIcon.Style
    let actionTitle: String?
    var isBusy = false
    var error: String?
    let action: () -> Void
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                TitleAndIcon(title: title, subtitle: subtitle, icon: icon, iconStyle: iconStyle)
                if let actionTitle {
                    VStack(spacing: 8) {
                        if let error {
                            Text(error)
                                .font(.compound.bodyMD)
                                .foregroundStyle(.compound.textCriticalPrimary)
                                .multilineTextAlignment(.center)
                        }
                        Button(action: action) {
                            if isBusy {
                                ProgressView()
                            } else {
                                Text(actionTitle)
                            }
                        }
                        .buttonStyle(.compound(.primary))
                        .disabled(isBusy)
                    }
                }
            }
            .padding(24)
            .padding(.top, 40)
        }
    }
}

private extension TaskItem {
    /// Namespaced, so a card id like "archived" can't collide with the list's own rows.
    var listID: String {
        "task:" + id
    }
}

// MARK: - Previews

struct TasksBoardScreen_Previews: PreviewProvider, TestablePreview {
    static let board = TasksBoard(todo: [TaskItem.previewTasks[0], TaskItem.previewTasks[2]],
                                  doing: [TaskItem.previewTasks[1]],
                                  done: [TaskItem.previewTasks[3]],
                                  archived: [TaskItem.previewTasks[0]],
                                  hasMore: true)
    
    static var previews: some View {
        ElementNavigationStack {
            TasksBoardScreen(context: makeViewModel(.board(board)).context)
        }
        .previewDisplayName("Board")
        
        ElementNavigationStack {
            TasksBoardScreen(context: makeViewModel(.board(TasksBoard(todo: [TaskItem.previewTasks[0]], canEdit: false, canAdd: false, isUnreadable: true))).context)
        }
        .previewDisplayName("Read-only")
        
        ElementNavigationStack {
            TasksBoardScreen(context: makeViewModel(.board(TasksBoard()), banner: .init(message: UntranslatedL10n.commonMatchaWriteFailed, actionTitle: L10n.actionRetry)).context)
        }
        .previewDisplayName("Empty")
        
        ElementNavigationStack {
            TasksBoardScreen(context: makeViewModel(.board(TasksBoard(isLoading: true))).context)
        }
        .previewDisplayName("Loading")
        
        ElementNavigationStack {
            TasksBoardScreen(context: makeViewModel(.lookingForBoard).context)
        }
        .previewDisplayName("Looking for the board")
        
        ElementNavigationStack {
            TasksBoardScreen(context: makeViewModel(.setup(canCreate: true, isCreating: false, createFailed: true)).context)
        }
        .previewDisplayName("Setup")
        
        ElementNavigationStack {
            TasksBoardScreen(context: makeViewModel(.setup(canCreate: false, isCreating: false, createFailed: false)).context)
        }
        .previewDisplayName("Setup without permission")
        
        ElementNavigationStack {
            TasksBoardScreen(context: makeViewModel(.loadFailed).context)
        }
        .previewDisplayName("Load failed")
        
        ElementNavigationStack {
            TasksBoardScreen(context: makeViewModel(.board(board)).context)
        }
        .environment(\.horizontalSizeClass, .regular)
        .previewDisplayName("Wide")
        
        ElementNavigationStack {
            ArchivedTasksScreen(context: makeViewModel(.board(board)).context)
        }
        .previewDisplayName("Archived")
        
        ElementNavigationStack {
            ArchivedTasksScreen(context: makeViewModel(.board(TasksBoard())).context)
        }
        .previewDisplayName("Archived empty")
        
        ElementNavigationStack {
            TasksBoardScreen(context: makeViewModel(.board(board)).context,
                             chatBarContext: ChatBarViewModel.mock(selection: .board, threads: [ChatBarThread(id: "$t1", name: "Launch plan", isArchived: false)]).context)
        }
        .previewDisplayName("In a chat")
    }
    
    /// A view model over a stopped store, showing `content`.
    static func makeViewModel(_ content: TasksBoardContent, banner: TaskBanner? = nil) -> TasksBoardScreenViewModel {
        let store = MatchaRoomStore(room: JoinedRoomProxyMock(.init(name: "Design team")), noBoardAnswers: NoBoardAnswers())
        store.stop()
        let viewModel = TasksBoardScreenViewModel(store: store)
        viewModel.state.content = content
        viewModel.state.banner = banner
        return viewModel
    }
}
