//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import MatchaProtocol
import SwiftUI

/// A task as a chat-style row: status icon, name and deadline, then the description or the replies. Across chats (the Tasks tab),
/// the icon is the chat's avatar with a status badge, the second line starts with the chat's name, and `people` adds a third line.
struct TaskRow: View {
    let task: TaskItem
    /// The task's chat, across chats.
    var chat: TaskRowChat?
    /// Who else the task involves, e.g. "With Bob, Carol".
    var people: String?
    var mediaProvider: MediaProviderProtocol?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    
    /// At accessibility sizes the lines wrap: cut to one, the chat's name and the replies are lost, and tasks look alike.
    private var lineLimit: Int {
        dynamicTypeSize.isAccessibilitySize ? 3 : 1
    }
    
    var body: some View {
        HStack(spacing: 12) {
            if let chat {
                ChatAvatarWithStatus(avatar: chat.avatar, status: task.status, mediaProvider: mediaProvider)
            } else {
                TaskStatusIcon(status: task.status)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TaskTitle(task: task, lineLimit: lineLimit)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let deadline = task.deadline {
                        TaskDeadline(deadline: deadline, isOverdue: task.isOverdue)
                    }
                }
                
                HStack(spacing: 6) {
                    Text(secondLine)
                        .font(.compound.bodyMD)
                        .foregroundStyle(.compound.textSecondary)
                        .lineLimit(lineLimit)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TaskMarks(task: task)
                }
                
                if let people {
                    Text(people)
                        .font(.compound.bodySM)
                        .foregroundStyle(.compound.textSecondary)
                        .lineLimit(lineLimit)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
    
    private var secondLine: String {
        guard let chat else { return task.secondLine }
        return task.secondLine.isEmpty ? chat.name : UntranslatedL10n.screenMatchaTasksChatAndSummary(chat.name, task.secondLine)
    }
}

/// The chat a task row names, across chats.
struct TaskRowChat: Equatable {
    let name: String
    let avatar: RoomAvatar
}

/// The source chat's avatar with the task's status as a badge at its bottom trailing corner, on a ring of the canvas colour.
private struct ChatAvatarWithStatus: View {
    let avatar: RoomAvatar
    let status: TaskStatus
    let mediaProvider: MediaProviderProtocol?
    @ScaledMetric(relativeTo: .compound.bodyLG) private var badgeSize = 18
    
    var body: some View {
        RoomAvatarImage(avatar: avatar, avatarSize: .room(on: .chats), mediaProvider: mediaProvider)
            .overlay(alignment: .bottomTrailing) {
                CompoundIcon(status.icon, size: .custom(14), relativeTo: .compound.bodyLG)
                    .foregroundStyle(status == .todo ? Color.compound.iconSecondary : .compound.iconAccentPrimary)
                    .frame(width: badgeSize, height: badgeSize)
                    .background(.compound.bgCanvasDefault, in: Circle())
            }
            .accessibilityElement()
            .accessibilityLabel(UntranslatedL10n.a11yMatchaTaskStatus(status.label))
    }
}

/// A task as a card in a board column (regular width).
struct TaskCard: View {
    let task: TaskItem
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TaskTitle(task: task, lineLimit: 2)
            
            HStack(spacing: 8) {
                if let deadline = task.deadline {
                    TaskDeadline(deadline: deadline, isOverdue: task.isOverdue)
                }
                TaskMarks(task: task)
                if let replyCount = task.replyCount {
                    Label {
                        Text(replyCount.formatted())
                    } icon: {
                        CompoundIcon(\.threads, size: .xSmall, relativeTo: .compound.bodySM)
                    }
                    .labelStyle(.titleAndIcon)
                    .font(.compound.bodySM)
                    .foregroundStyle(.compound.textSecondary)
                    .accessibilityLabel(L10n.commonReplies(replyCount))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.compound.bgCanvasDefaultLevel1, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityValue(UntranslatedL10n.a11yMatchaTaskStatus(task.status.label))
    }
}

/// The row that opens a board's archived tasks.
struct ArchivedTasksRow: View {
    let count: Int
    @ScaledMetric(relativeTo: .compound.bodyLG) private var circleSize = TaskStatusIcon.size
    
    var body: some View {
        HStack(spacing: 12) {
            CompoundIcon(asset: Asset.Images.matchaArchive, size: .medium, relativeTo: .compound.bodyLG)
                .foregroundStyle(.compound.iconSecondary)
                .frame(width: circleSize, height: circleSize)
                .background(.compound.bgSubtleSecondary, in: Circle())
            Text(UntranslatedL10n.commonMatchaArchived)
                .font(.compound.bodyLGSemibold)
                .foregroundStyle(.compound.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(count.formatted())
                .font(.compound.bodySMSemibold)
                .foregroundStyle(.compound.textActionAccent)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// "Load older tasks", or a spinner while they load.
struct LoadOlderTasksRow: View {
    let isLoading: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            ZStack {
                if isLoading {
                    ProgressView()
                } else {
                    Text(UntranslatedL10n.screenMatchaTasksLoadOlder)
                        .font(.compound.bodyMDSemibold)
                        .foregroundStyle(.compound.textActionAccent)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .disabled(isLoading)
    }
}

/// A plain list on the canvas, rows included: plain rows draw the system background, a black block on the canvas in dark mode.
struct CanvasList<Content: View>: View {
    @ViewBuilder let content: Content
    
    var body: some View {
        List {
            Group { content }
                .listRowBackground(Color.compound.bgCanvasDefault)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

/// Rows standing in for tasks still being read.
struct TaskPlaceholderRows: View {
    var body: some View {
        ForEach(0..<3, id: \.self) { index in
            TaskRow(task: .placeholder(index))
                .redacted(reason: .placeholder)
                .shimmer()
        }
    }
}

/// The circle carrying a task's status icon.
struct TaskStatusIcon: View {
    static let size: CGFloat = 44
    let status: TaskStatus
    /// Grows with the icon, which scales with the text: a fixed circle clips it at accessibility sizes.
    @ScaledMetric(relativeTo: .compound.bodyLG) private var circleSize = TaskStatusIcon.size
    
    var body: some View {
        CompoundIcon(status.icon, size: .medium, relativeTo: .compound.bodyLG)
            .foregroundStyle(status == .todo ? Color.compound.iconSecondary : .compound.iconAccentPrimary)
            .frame(width: circleSize, height: circleSize)
            .background(.compound.bgSubtleSecondary, in: Circle())
            .accessibilityLabel(UntranslatedL10n.a11yMatchaTaskStatus(status.label))
    }
}

/// The banner over the bottom of the board: a message and an optional action, such as Undo or Retry. VoiceOver moves to it, and
/// while VoiceOver runs it stays until it is used or dismissed.
struct TaskBannerView: View {
    let banner: TaskBanner
    let action: () -> Void
    let dismiss: () -> Void
    @AccessibilityFocusState private var isFocused: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            Text(banner.message)
                .font(.compound.bodyMD)
                .foregroundStyle(.compound.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle = banner.actionTitle {
                Button(actionTitle, action: action)
                    .font(.compound.bodyMDSemibold)
                    .foregroundStyle(.compound.textActionAccent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.compound.bgSubtleSecondary, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            if let actionTitle = banner.actionTitle {
                Button(actionTitle, action: action)
            }
            Button(L10n.actionDismiss, action: dismiss)
        }
        .accessibilityFocused($isFocused)
        .onChange(of: banner.id, initial: true) { isFocused = true }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .onTapGesture(perform: dismiss)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Parts

private struct TaskTitle: View {
    let task: TaskItem
    let lineLimit: Int
    
    var body: some View {
        Text(task.title ?? UntranslatedL10n.commonMatchaThreadUntitled)
            .font(.compound.bodyLGSemibold)
            // An unnamed thread reads as untidy rather than broken.
            .foregroundStyle(task.title == nil ? Color.compound.textSecondary : .compound.textPrimary)
            .lineLimit(lineLimit)
    }
}

/// The deadline, red and after the word "Overdue" once it has passed; announced as "Due …".
private struct TaskDeadline: View {
    let deadline: String
    let isOverdue: Bool
    
    var body: some View {
        HStack(spacing: 4) {
            if isOverdue {
                Text(UntranslatedL10n.screenMatchaTasksOverdue)
                    .font(.compound.bodySMSemibold)
            }
            Text(deadline)
        }
        .font(.compound.bodySM)
        .foregroundStyle(isOverdue ? Color.compound.textCriticalPrimary : .compound.textSecondary)
        .lineLimit(1)
        .accessibilityLabel(isOverdue ? "\(UntranslatedL10n.screenMatchaTasksOverdue), \(UntranslatedL10n.a11yMatchaTaskDue(deadline))" : UntranslatedL10n.a11yMatchaTaskDue(deadline))
    }
}

/// The quiet marks of a requested reminder and of a task shown to everyone in the chat.
private struct TaskMarks: View {
    let task: TaskItem
    
    var body: some View {
        if task.hasReminder {
            CompoundIcon(\.notificationsSolid, size: .xSmall, relativeTo: .compound.bodySM)
                .foregroundStyle(.compound.iconSecondary)
                .accessibilityLabel(UntranslatedL10n.a11yMatchaTaskReminder)
        }
        if task.isSharedWithChat {
            CompoundIcon(\.group, size: .xSmall, relativeTo: .compound.bodySM)
                .foregroundStyle(.compound.iconSecondary)
                .accessibilityLabel(UntranslatedL10n.a11yMatchaTaskShownToRoom)
        }
    }
}

extension TaskStatus {
    var label: String {
        switch self {
        case .todo: UntranslatedL10n.screenMatchaTasksStatusTodo
        case .doing: UntranslatedL10n.screenMatchaTasksStatusDoing
        case .done: UntranslatedL10n.screenMatchaTasksStatusDone
        }
    }
    
    var icon: KeyPath<CompoundIcons, Image> {
        switch self {
        case .todo: \.circle
        case .doing: \.time
        case .done: \.checkCircleSolid
        }
    }
}

private extension TaskItem {
    /// The description's first line, or the replies when there is no description.
    var secondLine: String {
        if !summary.isEmpty {
            return summary
        }
        guard let replyCount else { return "" }
        return replyCount > 0 ? L10n.commonReplies(replyCount) : UntranslatedL10n.screenMatchaTasksNoReplies
    }
    
    static func placeholder(_ index: Int) -> TaskItem {
        TaskItem(id: "placeholder-\(index)", title: "Placeholder task", summary: "A line of the description", status: .todo, isArchived: false,
                 threadID: nil, dueAt: nil, deadline: nil, isOverdue: false, replyCount: nil, hasReminder: false, isSharedWithChat: false,
                 participants: [])
    }
}

// MARK: - Previews

struct TaskRow_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        List {
            ForEach(TaskItem.previewTasks) { task in
                TaskRow(task: task)
            }
            ArchivedTasksRow(count: 3)
            LoadOlderTasksRow(isLoading: false) { }
            LoadOlderTasksRow(isLoading: true) { }
            TaskPlaceholderRows()
        }
        .listStyle(.plain)
        .previewDisplayName("Rows")
        
        VStack(spacing: 8) {
            ForEach(TaskItem.previewTasks) { task in
                TaskCard(task: task)
            }
            TaskBannerView(banner: .init(message: UntranslatedL10n.screenMatchaTasksArchivedSnackbar, actionTitle: UntranslatedL10n.actionMatchaUndo)) { } dismiss: { }
        }
        .padding(8)
        .background(.compound.bgSubtleSecondary)
        .previewDisplayName("Cards")
    }
}

extension TaskItem {
    /// Tasks of every kind, for previews.
    static let previewTasks: [TaskItem] = [
        TaskItem(id: "1", title: "Book the venue", summary: "Near the station", status: .todo, isArchived: false, threadID: "$1", dueAt: 1,
                 deadline: "Mon 17:00", isOverdue: true, replyCount: 2, hasReminder: false, isSharedWithChat: false, participants: []),
        TaskItem(id: "2", title: "Plan the offsite", summary: "", status: .doing, isArchived: false, threadID: "$2", dueAt: 2,
                 deadline: "Fri 10:00", isOverdue: false, replyCount: 0, hasReminder: true, isSharedWithChat: true, participants: []),
        TaskItem(id: "3", title: nil, summary: "", status: .todo, isArchived: false, threadID: "$3", dueAt: nil,
                 deadline: nil, isOverdue: false, replyCount: 4, hasReminder: false, isSharedWithChat: true, participants: []),
        TaskItem(id: "4", title: "Send the invoices", summary: "", status: .done, isArchived: false, threadID: nil, dueAt: nil,
                 deadline: nil, isOverdue: false, replyCount: nil, hasReminder: false, isSharedWithChat: false, participants: [])
    ]
}
