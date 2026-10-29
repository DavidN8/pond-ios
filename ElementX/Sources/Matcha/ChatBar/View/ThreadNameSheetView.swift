//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import MatchaProtocol
import SwiftUI

/// New thread, or Rename thread when the sheet has a thread: Cancel on the left, Create or Save on the right.
struct ThreadNameSheetView: View {
    @Bindable var context: ChatBarViewModel.Context
    @FocusState private var isFocused: Bool
    
    /// The counter appears once a name gets close to the limit.
    private static let counterFrom = 80
    
    private var sheet: ThreadNameSheet {
        context.threadNameSheet ?? ThreadNameSheet(threadID: nil, name: "")
    }
    
    private var isRename: Bool {
        sheet.threadID != nil
    }
    
    var body: some View {
        ElementNavigationStack {
            Form {
                Section {
                    ListRow(label: .plain(title: UntranslatedL10n.screenMatchaThreadsNameHint),
                            kind: .textField(text: name, axis: .horizontal))
                        .focused($isFocused)
                        .submitLabel(.done)
                        .onSubmit { context.send(viewAction: .submitThreadName) }
                        .disabled(sheet.isSending)
                } footer: {
                    footer
                }
            }
            .compoundList()
            .navigationTitle(isRename ? UntranslatedL10n.screenMatchaThreadsRenameTitle : UntranslatedL10n.commonMatchaNewThread)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .presentationDetents([.medium])
        .onAppear { isFocused = true }
    }
    
    private var name: Binding<String> {
        Binding { sheet.name } set: { context.send(viewAction: .updateThreadName($0)) }
    }
    
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(fieldMessage)
                    .foregroundStyle(isFieldError ? .compound.textCriticalPrimary : .compound.textSecondary)
                Spacer()
                if sheet.name.utf16.count >= Self.counterFrom {
                    Text("\(sheet.name.utf16.count)/\(MatchaConfig.threadNameMaxLength)")
                        .foregroundStyle(sheet.error == .tooLong ? .compound.textCriticalPrimary : .compound.textSecondary)
                }
            }
            // A failed send sits under the field, and the sheet stays open.
            if let sendError {
                Text(sendError)
                    .foregroundStyle(.compound.textCriticalPrimary)
            }
        }
        .compoundListSectionFooter()
    }
    
    private var isFieldError: Bool {
        sheet.error == .empty || sheet.error == .tooLong
    }
    
    private var fieldMessage: String {
        switch sheet.error {
        case .empty: UntranslatedL10n.commonMatchaErrorNameEmpty
        case .tooLong: UntranslatedL10n.commonMatchaErrorMaxChars(String(MatchaConfig.threadNameMaxLength))
        default: UntranslatedL10n.screenMatchaThreadsNameHelper
        }
    }
    
    private var sendError: String? {
        switch sheet.error {
        case .createFailed: UntranslatedL10n.screenMatchaThreadsCreateFailed
        case .renameFailed: UntranslatedL10n.commonMatchaWriteFailed
        default: nil
        }
    }
    
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(L10n.actionCancel) { context.threadNameSheet = nil }
        }
        ToolbarItem(placement: .confirmationAction) {
            if sheet.isSending {
                ProgressView()
            } else {
                Button(isRename ? L10n.actionSave : L10n.actionCreate) {
                    context.send(viewAction: .submitThreadName)
                }
            }
        }
    }
}

// MARK: - Previews

struct ThreadNameSheetView_Previews: PreviewProvider, TestablePreview {
    static let newThread = makeViewModel(ThreadNameSheet(threadID: nil, name: ""))
    static let empty = makeViewModel(ThreadNameSheet(threadID: nil, name: "", error: .empty))
    static let tooLong = makeViewModel(ThreadNameSheet(threadID: nil, name: String(repeating: "A", count: 104), error: .tooLong))
    static let createFailed = makeViewModel(ThreadNameSheet(threadID: nil, name: "Budget review", error: .createFailed))
    static let renaming = makeViewModel(ThreadNameSheet(threadID: "$t1", name: "Launch plan v2", isSending: true))
    static let renameFailed = makeViewModel(ThreadNameSheet(threadID: "$t1", name: "Launch plan v2", error: .renameFailed))
    
    static var previews: some View {
        ThreadNameSheetView(context: newThread.context)
            .previewDisplayName("New thread")
        ThreadNameSheetView(context: empty.context)
            .previewDisplayName("Empty name")
        ThreadNameSheetView(context: tooLong.context)
            .previewDisplayName("Name too long")
        ThreadNameSheetView(context: createFailed.context)
            .previewDisplayName("Create failed")
        ThreadNameSheetView(context: renaming.context)
            .previewDisplayName("Renaming")
        ThreadNameSheetView(context: renameFailed.context)
            .previewDisplayName("Rename failed")
    }
    
    static func makeViewModel(_ sheet: ThreadNameSheet) -> ChatBarViewModel {
        ChatBarViewModel.mock(threadNameSheet: sheet)
    }
}
