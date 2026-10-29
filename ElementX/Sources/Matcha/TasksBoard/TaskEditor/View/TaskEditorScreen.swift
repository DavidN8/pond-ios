//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import MatchaProtocol
import SwiftUI

/// The task editor: the name and description, then status, deadline, sharing and the task's thread.
struct TaskEditorScreen: View {
    @Bindable var context: TaskEditorScreenViewModel.Context
    @FocusState private var focus: Field?
    
    private enum Field {
        case title
        case description
    }
    
    private var state: TaskEditorScreenViewState {
        context.viewState
    }
    
    var body: some View {
        Form {
            textSections
            detailsSection
            if state.canShare {
                Section {
                    ListRow(label: .default(title: UntranslatedL10n.screenMatchaTasksShowToRoom, icon: \.group),
                            kind: .toggle($context.showToRoom))
                        .disabled(state.isSaving)
                } footer: {
                    Text(UntranslatedL10n.screenMatchaTasksShowToRoomHint)
                        .compoundListSectionFooter()
                }
            }
            threadSection
        }
        .compoundList()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(state.isNew ? UntranslatedL10n.screenMatchaTasksNew : UntranslatedL10n.screenMatchaTasksEdit)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        // A swipe can't ask first, and a save that ends after it would close whatever is shown by then.
        .interactiveDismissDisabled(state.hasChanges || state.isSaving)
        .confirmationDialog(UntranslatedL10n.screenMatchaTasksDiscardTitle, isPresented: $context.isDiscardConfirmationPresented, titleVisibility: .visible) {
            Button(L10n.actionDiscard, role: .destructive) { context.send(viewAction: .discard) }
            Button(UntranslatedL10n.actionMatchaKeepEditing, role: .cancel) { }
        }
    }
    
    // MARK: - Private
    
    @ViewBuilder
    private var textSections: some View {
        Section {
            // ListRow's text field, with its hint too in headingMD (WHATSAPP_DESIGN §4b): the name reads as the sheet's heading.
            ListRow(kind: .custom {
                TextField(text: $context.title, axis: .vertical) {
                    Text(UntranslatedL10n.screenMatchaTasksNameHint)
                        .foregroundColor(.compound.textSecondary)
                }
                .font(.compound.headingMD)
                .lineLimit(1...2)
                .tint(.compound.iconAccentTertiary)
                .foregroundStyle(state.canRename && !state.isSaving ? Color.compound.textPrimary : .compound.textDisabled)
                .listRowInsets(ListRowPadding.textFieldInsets)
                .accessibilityLabel(UntranslatedL10n.screenMatchaTasksNameHint)
            })
            .focused($focus, equals: .title)
            .disabled(!state.canRename || state.isSaving)
        } footer: {
            if let error = state.titleError {
                Text(error.message)
                    .compoundListSectionFooter()
                    .foregroundStyle(.compound.textCriticalPrimary)
            } else if let note = titleNote {
                Text(note)
                    .compoundListSectionFooter()
            }
        }
        
        Section {
            ListRow(label: .plain(title: UntranslatedL10n.screenMatchaTasksDescriptionHint),
                    kind: .textField(text: $context.description, axis: .vertical))
                .lineLimit(3...12)
                .focused($focus, equals: .description)
                .disabled(state.isSaving)
        } footer: {
            if let error = state.descriptionError {
                Text(error.message)
                    .compoundListSectionFooter()
                    .foregroundStyle(.compound.textCriticalPrimary)
            }
        }
    }
    
    private var titleNote: String? {
        if !state.canRename {
            UntranslatedL10n.screenMatchaTasksRenameNotAllowed
        } else if state.isNew {
            UntranslatedL10n.screenMatchaTasksThreadNoteNew
        } else if state.isLinked {
            UntranslatedL10n.screenMatchaTasksThreadNoteLinked
        } else {
            nil
        }
    }
    
    private var detailsSection: some View {
        Section {
            ListRow(label: .default(title: UntranslatedL10n.screenMatchaTasksStatusLabel, icon: \.checkCircle),
                    kind: .picker(selection: $context.status, items: TaskStatus.allCases.map { (title: $0.label, tag: $0) }))
                .disabled(state.isSaving)
            ListRow(label: .default(title: UntranslatedL10n.screenMatchaTasksDeadlineLabel, icon: \.calendar),
                    kind: .toggle(Binding { state.dueAt != nil } set: { context.send(viewAction: $0 ? .addDeadline : .clearDeadline) }))
                .disabled(state.isSaving)
            if let dueAt = state.dueAt {
                ListRow(kind: .custom {
                    DatePicker(UntranslatedL10n.screenMatchaTasksDeadlineLabel,
                               selection: Binding { Date(timeIntervalSince1970: TimeInterval(dueAt) / 1000) } set: { context.send(viewAction: .setDeadline($0)) },
                               displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .disabled(state.isSaving)
                })
            }
        } footer: {
            if let warning = state.deadlineWarning {
                Text(warning.message)
                    .compoundListSectionFooter()
                    .foregroundStyle(warning == .past ? Color.compound.textSecondary : .compound.textCriticalPrimary)
            }
        }
    }
    
    @ViewBuilder
    private var threadSection: some View {
        if !state.isNew, state.isLinked || state.canRemind {
            Section {
                if state.isLinked {
                    ListRow(label: .default(title: UntranslatedL10n.screenMatchaTasksOpenThread, icon: \.threads),
                            kind: .navigationLink { context.send(viewAction: .openThread) })
                }
                if state.canRemind {
                    // Like Android, the request is told under the row, with when it's due.
                    ListRow(label: .default(title: UntranslatedL10n.actionMatchaRemindMe,
                                            description: state.reminderRequestedAt.map(UntranslatedL10n.screenMatchaTasksReminderRequested),
                                            icon: \.notifications),
                            kind: .button { context.send(viewAction: .remindMe) })
                        .disabled(state.isSaving)
                }
            }
        }
        if !state.earlierCards.isEmpty {
            Section {
                ListRow(kind: .custom {
                    DisclosureGroup(UntranslatedL10n.screenMatchaTasksEarlierCards(state.earlierCards.count)) {
                        ForEach(Array(state.earlierCards.enumerated()), id: \.offset) { _, name in
                            Text(name)
                                .font(.compound.bodyMD)
                                .foregroundStyle(.compound.textSecondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                })
            }
        }
        if let error = state.saveError {
            Section {
                ListRow(label: .plain(title: error.message, role: .error), kind: .label)
            }
        }
    }
    
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(L10n.actionCancel) { context.send(viewAction: .cancel) }
        }
        ToolbarItem(placement: .confirmationAction) {
            if state.isSaving {
                ProgressView()
            } else {
                Button(state.isNew ? UntranslatedL10n.screenMatchaTasksAdd : L10n.actionSave) {
                    context.send(viewAction: .save)
                    // Saving with errors moves the focus to the first one.
                    if context.viewState.titleError != nil {
                        focus = .title
                    } else if context.viewState.descriptionError != nil {
                        focus = .description
                    }
                }
            }
        }
    }
}

// MARK: - Previews

struct TaskEditorScreen_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        ElementNavigationStack {
            TaskEditorScreen(context: makeViewModel().context)
        }
        .previewDisplayName("New")
        
        ElementNavigationStack {
            TaskEditorScreen(context: makeViewModel { state in
                state.bindings.title = ""
                state.showsEmptyTitleError = true
                state.bindings.description = String(repeating: "a", count: MatchaConfig.cardDescriptionMaxLength + 1)
            }.context)
        }
        .previewDisplayName("New with errors")
        
        ElementNavigationStack {
            TaskEditorScreen(context: makeViewModel { state in
                state.isNew = false
                state.bindings.title = "Book the venue"
                state.bindings.description = "Near the station"
                state.bindings.status = .doing
                state.bindings.showToRoom = true
                state.dueAt = 1_767_200_400_000
                state.isDeadlinePast = true
                state.earlierCards = ["Venue", "Find a venue"]
                state.canRemind = true
                state.reminderRequestedAt = "Fri 09:00"
            }.context)
        }
        .previewDisplayName("Edit")
        
        ElementNavigationStack {
            TaskEditorScreen(context: makeViewModel { state in
                state.isNew = false
                state.canRename = false
                state.canShare = false
                state.bindings.title = "Plan the offsite"
                state.saveError = .failed
            }.context)
        }
        .previewDisplayName("Edit, can't rename, in a DM, save failed")
        
        ElementNavigationStack {
            TaskEditorScreen(context: makeViewModel { state in
                state.bindings.title = "Book the venue"
                state.isSaving = true
            }.context)
        }
        .previewDisplayName("Saving")
    }
    
    /// A view model for a new task over a stopped store, changed by `change`.
    static func makeViewModel(_ change: (inout TaskEditorScreenViewState) -> Void = { _ in }) -> TaskEditorScreenViewModel {
        let store = MatchaRoomStore(room: JoinedRoomProxyMock(.init(name: "Design team")), noBoardAnswers: NoBoardAnswers())
        store.stop()
        let viewModel = TaskEditorScreenViewModel(store: store, target: .new(status: .todo))
        change(&viewModel.state)
        return viewModel
    }
}
