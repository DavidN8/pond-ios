//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import MatchaProtocol
import SwiftUI

struct NoteEditorScreen: View {
    @Bindable var context: NoteEditorScreenViewModel.Context
    @Environment(\.scenePhase) private var scenePhase
    @State private var editorModel = NoteTextEditorModel()
    
    private var state: NoteEditorScreenViewState {
        context.viewState
    }
    
    var body: some View {
        mainContent
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .safeAreaInset(edge: .top, spacing: 0) {
                if let notice = state.notice {
                    NotesNoticeStrip(icon: notice == .offline ? \.offline : \.warning, text: noticeText(notice))
                }
            }
            .background(Color.compound.bgCanvasDefault.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(state.isEditing || state.hasUnsavedChanges)
            .toolbar { toolbar }
            .alert(UntranslatedL10n.screenMatchaDocsUnsavedTitle, isPresented: $context.isShowingLeaveAlert) {
                Button(L10n.actionLeave, role: .destructive) { context.send(viewAction: .confirmLeave) }
                Button(UntranslatedL10n.screenMatchaDocsShareText) { context.send(viewAction: .shareFromLeaveAlert) }
                Button(UntranslatedL10n.screenMatchaDocsStay, role: .cancel) { }
            } message: {
                Text(UntranslatedL10n.screenMatchaDocsUnsavedBody)
            }
            .sheet(item: $context.nameSheet, onDismiss: { context.send(viewAction: .dismissNameSheet) }, content: { sheet in
                NoteNameSheet(state: sheet,
                              onNameChange: { context.send(viewAction: .updateName($0)) },
                              onSubmit: { context.send(viewAction: .submitName) },
                              onCancel: { context.send(viewAction: .dismissNameSheet) })
            })
            .sheet(isPresented: $context.isSharingText) {
                AppActivityView(activityItems: [state.text])
                    .presentationDetents([.medium, .large])
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    context.send(viewAction: .enteredBackground)
                }
            }
    }
    
    @ViewBuilder
    private var mainContent: some View {
        if state.isLoadError {
            NotesMessagePage(icon: \.warning,
                             title: UntranslatedL10n.screenMatchaDocsLoadErrorTitle,
                             message: UntranslatedL10n.screenMatchaDocsLoadErrorBody,
                             actionTitle: L10n.actionRetry) {
                context.send(viewAction: .retry)
            }
        } else if state.status == .loading, state.text.isEmpty {
            skeleton
        } else if state.isEditing {
            NoteTextEditor(text: state.text, isApplyingEdits: state.isApplyingEdits, model: editorModel) { before, after in
                context.send(viewAction: .edit(before: before, after: after))
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                NoteFormattingBar(model: editorModel)
            }
        } else if state.text.isKotlinBlank {
            Text(state.canEdit ? UntranslatedL10n.screenMatchaDocsDocEmpty : UntranslatedL10n.screenMatchaDocsDocEmptyReadOnly)
                .font(.compound.bodyMD)
                .foregroundStyle(.compound.textSecondary)
                .padding(16)
        } else {
            MarkdownPreview(blocks: state.blocks)
        }
    }
    
    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trip plans for the weekend")
                .font(.compound.headingSMSemibold)
            ForEach(0..<4, id: \.self) { _ in
                Text("We leave on Friday at nine and meet at the station.")
                    .font(.compound.bodyLG)
            }
        }
        .padding(16)
        .redacted(reason: .placeholder)
        .shimmer()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.commonLoading)
    }
    
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if state.isEditing || state.hasUnsavedChanges {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    context.send(viewAction: .back)
                } label: {
                    CompoundIcon(\.chevronLeft)
                        .accessibilityHidden(true)
                }
                .accessibilityLabel(L10n.actionBack)
            }
        }
        ToolbarItem(placement: .principal) {
            title
        }
        if !state.isLoadError {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if state.canRename {
                        Button {
                            context.send(viewAction: .rename)
                        } label: {
                            Label(UntranslatedL10n.actionMatchaRename, icon: \.edit)
                        }
                    }
                    ShareLink(item: state.text) {
                        Label(UntranslatedL10n.screenMatchaDocsShareText, icon: \.shareIos)
                    }
                } label: {
                    CompoundIcon(\.overflowHorizontal)
                        .accessibilityHidden(true)
                }
                .accessibilityLabel(UntranslatedL10n.a11yMatchaDocsMore)
            }
        }
        if state.isEditing {
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.actionDone) {
                    context.send(viewAction: .stopEditing)
                }
            }
        } else if state.canEdit, !state.isLoadError {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    context.send(viewAction: .startEditing)
                } label: {
                    CompoundIcon(\.edit)
                        .accessibilityHidden(true)
                }
                .accessibilityLabel(UntranslatedL10n.a11yMatchaDocEdit)
            }
        }
    }
    
    /// The note's name and its save state; when a save failed the whole title retries, so the target is large enough to tap.
    @ViewBuilder
    private var title: some View {
        let isFailed = state.status == .failed
        let label = VStack(spacing: 0) {
            Text(state.displayTitle)
                .font(.compound.bodyLGSemibold)
                .foregroundStyle(.compound.textPrimary)
                .lineLimit(1)
            Text(statusText)
                .font(.compound.bodySM)
                .foregroundStyle(isFailed ? .compound.textCriticalPrimary : .compound.textSecondary)
                .lineLimit(1)
        }
        if isFailed {
            Button {
                context.send(viewAction: .retry)
            } label: {
                label
            }
            .accessibilityHint(L10n.actionRetry)
        } else {
            label
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
        }
    }
    
    private var statusText: String {
        switch state.status {
        case .loading: L10n.commonLoading
        case .saving: L10n.commonSaving
        case .saved: UntranslatedL10n.screenMatchaDocsStatusSaved
        case .offline: UntranslatedL10n.screenMatchaDocsStatusOffline
        case .failed: UntranslatedL10n.screenMatchaDocsStatusFailed
        case .viewOnly: UntranslatedL10n.screenMatchaDocsStatusViewOnly
        case .earlierChat: UntranslatedL10n.screenMatchaDocsStatusEarlier
        }
    }
    
    private func noticeText(_ notice: NoteNotice) -> String {
        switch notice {
        case .offline: UntranslatedL10n.screenMatchaDocsOfflineStrip
        case .decryptError: UntranslatedL10n.screenMatchaDocsDecryptError
        case .incomplete: UntranslatedL10n.screenMatchaDocsIncomplete
        case .invalid: UntranslatedL10n.screenMatchaDocsInvalidUpdate
        case .permissionError: UntranslatedL10n.screenMatchaDocsPermissionError
        case .tooLarge: UntranslatedL10n.screenMatchaDocsTooLarge
        }
    }
}

// MARK: - Previews

struct NoteEditorScreen_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        preview()
            .previewDisplayName("Saved")
        preview(status: .loading, text: "", canEdit: false)
            .previewDisplayName("Loading")
        preview(status: .saving, isEditing: true, hasUnsavedChanges: true)
            .previewDisplayName("Editing")
        preview(status: .offline, notice: .offline, hasUnsavedChanges: true)
            .previewDisplayName("Offline")
        preview(status: .failed, hasUnsavedChanges: true)
            .previewDisplayName("Save failed")
        preview(status: .viewOnly, canEdit: false, canRename: false)
            .previewDisplayName("View only")
        preview(title: "Weekend trip", status: .earlierChat, canEdit: false, canRename: false)
            .previewDisplayName("Earlier chat document")
        preview(status: .viewOnly, notice: .decryptError, canEdit: false)
            .previewDisplayName("Can't decrypt")
        preview(status: .viewOnly, notice: .incomplete, canEdit: false)
            .previewDisplayName("Incomplete")
        preview(status: .viewOnly, notice: .invalid, canEdit: false)
            .previewDisplayName("Invalid")
        preview(status: .viewOnly, isLoadError: true, text: "", canEdit: false)
            .previewDisplayName("Load error")
        preview(title: nil, text: "")
            .previewDisplayName("Empty Space notes")
        preview(title: nil, status: .viewOnly, text: "", canEdit: false)
            .previewDisplayName("Empty Space notes, view only")
        preview(status: .failed, hasUnsavedChanges: true, isShowingLeaveAlert: true)
            .previewDisplayName("Leave with unsaved changes")
        preview(status: .failed, notice: .permissionError, canEdit: false, hasUnsavedChanges: true)
            .previewDisplayName("Permission lost")
        preview(status: .failed, notice: .tooLarge, canEdit: false, hasUnsavedChanges: true)
            .previewDisplayName("Too large")
    }
    
    static func preview(title: String? = "Trip plans",
                        status: NoteStatus = .saved,
                        notice: NoteNotice? = nil,
                        isLoadError: Bool = false,
                        text: String = "# Trip plans\nWe leave on **Friday**.\n\n- [ ] Tickets\n- [x] Charger",
                        isEditing: Bool = false,
                        canEdit: Bool = true,
                        canRename: Bool = true,
                        hasUnsavedChanges: Bool = false,
                        isShowingLeaveAlert: Bool = false) -> some View {
        let state = NoteEditorScreenViewState(title: title,
                                              status: status,
                                              notice: notice,
                                              isLoadError: isLoadError,
                                              text: text,
                                              blocks: MarkdownParser.parse(text),
                                              isEditing: isEditing,
                                              canEdit: canEdit,
                                              canRename: canRename,
                                              hasUnsavedChanges: hasUnsavedChanges,
                                              bindings: .init(isShowingLeaveAlert: isShowingLeaveAlert))
        return ElementNavigationStack {
            NoteEditorScreen(context: NoteEditorScreenPreviewViewModel(state: state).context)
        }
    }
}

/// An editor showing a fixed state, for previews.
private final class NoteEditorScreenPreviewViewModel: NoteEditorScreenViewModelType {
    init(state: NoteEditorScreenViewState) {
        super.init(initialViewState: state)
    }
}
