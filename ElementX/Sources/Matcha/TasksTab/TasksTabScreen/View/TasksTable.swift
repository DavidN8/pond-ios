//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import MatchaProtocol
import SwiftUI

/// The tasks as a table, Task · Chat · Status · Due · People, under a header that sorts by the tapped column. A row opens its task
/// like a list row; its Status cell, like a long press, offers the task's actions. The columns share the width when they fit, and
/// otherwise scroll sideways with the Task column kept in place.
///
/// A section, so that in a `LazyVStack` pinning its section headers the header stays on screen while the rows scroll under it, as
/// Android's sticky header does. The header follows the rows sideways; only the rows' scroll view scrolls by a swipe.
struct TasksTable: View {
    let rows: [TabTask]
    let sort: TaskTableSort
    let context: TasksTabScreenViewModel.Context
    @State private var width: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0
    /// The column widths grow with the text.
    @ScaledMetric(relativeTo: .compound.bodySM) private var unit: CGFloat = 1
    
    var body: some View {
        let widths = Dictionary(uniqueKeysWithValues: TaskTableColumn.allCases.map { ($0, width(of: $0)) })
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        TasksTableRow(task: row, context: context, widths: widths)
                    }
                }
                .padding(.horizontal, 16)
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.x + geometry.contentInsets.leading
            } action: { _, offset in
                scrollOffset = max(0, offset)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        } header: {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 16)
                    .offset(x: -scrollOffset)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .clipped()
                Divider()
            }
            .background(Color.compound.bgCanvasDefault)
        }
    }
    
    private var header: some View {
        HStack(spacing: 0) {
            ForEach(TaskTableColumn.allCases, id: \.self) { column in
                let isSorted = sort.column == column
                let cell = Button { context.send(viewAction: .sortTable(column)) } label: {
                    HStack(spacing: 4) {
                        Text(column.label)
                            .font(.compound.bodySMSemibold)
                            .foregroundStyle(isSorted ? Color.compound.textPrimary : .compound.textSecondary)
                            .lineLimit(1)
                        if isSorted {
                            CompoundIcon(sort.isAscending ? \.arrowUp : \.arrowDown, size: .xSmall, relativeTo: .compound.bodySM)
                                .foregroundStyle(.compound.iconPrimary)
                        }
                    }
                    .padding(.trailing, 12)
                    .frame(width: width(of: column), alignment: .leading)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(isSorted ? (sort.isAscending ? UntranslatedL10n.a11yMatchaTasksSortedAscending : UntranslatedL10n.a11yMatchaTasksSortedDescending) : "")
                
                if column == .task {
                    cell.pinned(by: scrollOffset)
                } else {
                    cell
                }
            }
        }
    }
    
    /// A column's share of the width when the table fits, or its own width when it scrolls sideways.
    private func width(of column: TaskTableColumn) -> CGFloat {
        let total = TaskTableColumn.allCases.map(\.width).reduce(0, +) * unit
        return column.width * unit * max(1, (width - 32) / total)
    }
}

private struct TasksTableRow: View {
    let task: TabTask
    let context: TasksTabScreenViewModel.Context
    let widths: [TaskTableColumn: CGFloat]
    
    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(task.task.title ?? UntranslatedL10n.commonMatchaThreadUntitled)
                    .font(.compound.bodyMDSemibold)
                    .foregroundStyle(task.task.title == nil ? Color.compound.textSecondary : .compound.textPrimary)
                    .lineLimit(2)
                if task.task.isSharedWithChat {
                    CompoundIcon(\.group, size: .xSmall, relativeTo: .compound.bodySM)
                        .foregroundStyle(.compound.iconSecondary)
                        .accessibilityLabel(UntranslatedL10n.a11yMatchaTaskShownToRoom)
                }
            }
            .cell(widths[.task] ?? 0)
            .pinnedInScrollView()
            
            CellText(text: task.chat.name)
                .cell(widths[.chat] ?? 0)
            
            // A tap here offers the actions; screen readers reach them with the row's long press.
            Button { context.send(viewAction: .showActions(task.id)) } label: {
                HStack(spacing: 4) {
                    CompoundIcon(task.task.status.icon, size: .xSmall, relativeTo: .compound.bodySM)
                        .foregroundStyle(task.task.status == .todo ? Color.compound.iconSecondary : .compound.iconAccentPrimary)
                    CellText(text: task.task.status.label)
                    CompoundIcon(\.chevronDown, size: .xSmall, relativeTo: .compound.bodySM)
                        .foregroundStyle(.compound.iconSecondary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cell(widths[.status] ?? 0)
            
            CellText(text: task.task.deadline ?? "", isCritical: task.task.isOverdue)
                .accessibilityLabel(task.task.deadline.map(UntranslatedL10n.a11yMatchaTaskDue) ?? "")
                .cell(widths[.due] ?? 0)
            
            CellText(text: task.peopleCell)
                .cell(widths[.people] ?? 0)
        }
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .onTapGesture { context.send(viewAction: .openTask(task.id)) }
        .contextMenu { TabTaskMenu(task: task, context: context) }
        // One element for screen readers: the cells in order, opening the task, with the actions on a long press.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { context.send(viewAction: .openTask(task.id)) }
    }
}

private struct CellText: View {
    let text: String
    var isCritical = false
    
    var body: some View {
        Text(text)
            .font(.compound.bodySM)
            .foregroundStyle(isCritical ? Color.compound.textCriticalPrimary : .compound.textSecondary)
            .lineLimit(2)
    }
}

private extension View {
    func cell(_ width: CGFloat) -> some View {
        padding(.trailing, 12)
            .frame(width: width, alignment: .leading)
    }
    
    /// Kept at the leading edge while the table scrolls sideways under it.
    func pinned(by offset: CGFloat) -> some View {
        background(Color.compound.bgCanvasDefault.padding(.leading, -16))
            .offset(x: offset)
            .zIndex(1)
    }
    
    /// Kept at the leading edge of the scroll view while the row scrolls sideways under it, without redrawing the row: the offset
    /// is read where it is drawn.
    func pinnedInScrollView() -> some View {
        background(Color.compound.bgCanvasDefault.padding(.leading, -16))
            .visualEffect { content, geometry in
                content.offset(x: max(0, 16 - geometry.frame(in: .scrollView(axis: .horizontal)).minX))
            }
            .zIndex(1)
    }
}

private extension TaskTableColumn {
    /// The column's width when the table scrolls sideways, and its share of the width when it fits.
    var width: CGFloat {
        switch self {
        case .task: 168
        case .chat: 136
        case .status: 128
        case .due: 128
        case .people: 160
        }
    }
    
    var label: String {
        switch self {
        case .task: UntranslatedL10n.screenMatchaTasksTableTask
        case .chat: UntranslatedL10n.screenMatchaTasksTableChat
        case .status: UntranslatedL10n.screenMatchaTasksStatusLabel
        case .due: UntranslatedL10n.screenMatchaTasksTableDue
        case .people: UntranslatedL10n.screenMatchaTasksTablePeople
        }
    }
}
