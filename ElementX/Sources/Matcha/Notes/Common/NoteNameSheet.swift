//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import MatchaProtocol
import SwiftUI

enum NoteNameError: Equatable {
    case empty
    case tooLong
    case saveFailed
}

/// The New note and Rename note sheet.
struct NoteNameSheetState: Equatable, Identifiable {
    /// Nil for a new note.
    var documentID: String?
    var name: String
    var error: NoteNameError?
    var isSaving = false
    /// A new note whose first save failed: submitting again saves it rather than adding another.
    var unsavedDocumentID: String?
    
    var id: String {
        documentID ?? "new-note"
    }
    
    var isNew: Bool {
        documentID == nil
    }
    
    static func new() -> Self {
        .init(documentID: nil, name: "")
    }
    
    static func rename(documentID: String, name: String) -> Self {
        .init(documentID: documentID, name: name)
    }
    
    /// The sheet after typing `name`; an empty name is only reported on submit.
    func updating(name: String) -> Self {
        var sheet = self
        sheet.name = name
        sheet.error = name.kotlinTrimmed.utf16.count > MatchaConfig.documentNameMaxLength ? .tooLong : nil
        return sheet
    }
    
    /// The sheet showing why its name can't be saved, or nil when it can.
    func withNameError() -> Self? {
        var sheet = updating(name: name)
        if name.isKotlinBlank {
            sheet.error = .empty
        }
        return sheet.error == nil ? nil : sheet
    }
    
    /// Saves the name in `catalog`: renames its note, or creates a new one. Returns the note's id.
    func save(in catalog: DocumentCatalog) async -> Result<String, CatalogError> {
        if let existingID = documentID ?? unsavedDocumentID {
            return await catalog.rename(documentID: existingID, title: name).map { existingID }
        }
        return await catalog.create(title: name)
    }
    
    /// The sheet after a failed save: kept open, and a new note whose entry was kept locally is saved again rather than added twice.
    func saveFailed(_ error: CatalogError) -> Self {
        var sheet = self
        sheet.isSaving = false
        sheet.error = .saveFailed
        sheet.unsavedDocumentID = error.documentID ?? documentID ?? unsavedDocumentID
        return sheet
    }
}

/// The sheet's content: a name field with Cancel and Create (or Save) in the navigation bar, as iOS sheets confirm top right.
struct NoteNameSheet: View {
    let state: NoteNameSheetState
    let onNameChange: @MainActor (String) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
    
    @FocusState private var isFocused: Bool
    
    var body: some View {
        ElementNavigationStack {
            Form {
                Section {
                    TextField(UntranslatedL10n.screenMatchaDocsNameHint, text: Binding(get: { state.name }, set: onNameChange))
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.done)
                        .onSubmit(onSubmit)
                        .focused($isFocused)
                        .disabled(state.isSaving)
                } footer: {
                    if let error = errorText {
                        Text(error)
                            .foregroundStyle(.compound.textCriticalPrimary)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                }
            }
            .compoundList()
            .navigationTitle(state.isNew ? UntranslatedL10n.screenMatchaDocsNew : UntranslatedL10n.screenMatchaDocsRenameTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.actionCancel, action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if state.isSaving {
                        ProgressView()
                    } else {
                        Button(state.isNew ? L10n.actionCreate : L10n.actionSave, action: onSubmit)
                            .disabled(state.error == .tooLong)
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear { isFocused = true }
    }
    
    private var errorText: String? {
        switch state.error {
        case .empty: UntranslatedL10n.commonMatchaErrorNameEmpty
        case .tooLong: UntranslatedL10n.commonMatchaErrorMaxChars(MatchaConfig.documentNameMaxLength)
        case .saveFailed: UntranslatedL10n.commonMatchaWriteFailed
        case nil: nil
        }
    }
}

// MARK: - Previews

struct NoteNameSheet_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        sheet(.new())
            .previewDisplayName("New")
        sheet(.rename(documentID: "main", name: "Space notes"))
            .previewDisplayName("Rename")
        sheet(NoteNameSheetState.new().withNameError() ?? .new())
            .previewDisplayName("Empty name")
        sheet(NoteNameSheetState.new().updating(name: String(repeating: "A", count: 101)))
            .previewDisplayName("Too long")
        sheet(.init(documentID: nil, name: "Trip plans", isSaving: true))
            .previewDisplayName("Saving")
        sheet(.init(documentID: nil, name: "Trip plans", error: .saveFailed))
            .previewDisplayName("Save failed")
    }
    
    static func sheet(_ state: NoteNameSheetState) -> some View {
        NoteNameSheet(state: state, onNameChange: { _ in }, onSubmit: { }, onCancel: { })
    }
}
