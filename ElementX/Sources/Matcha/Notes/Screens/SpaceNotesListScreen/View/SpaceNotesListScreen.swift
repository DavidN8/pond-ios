//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct SpaceNotesListScreen: View {
    @Bindable var context: SpaceNotesListScreenViewModel.Context
    
    var body: some View {
        mainContent
            .safeAreaInset(edge: .top, spacing: 0) {
                if context.viewState.hasUnreadableNames {
                    NotesNoticeStrip(icon: \.warning, text: UntranslatedL10n.screenMatchaDocsListDecryptError)
                }
            }
            .background(Color.compound.bgCanvasDefault.ignoresSafeArea())
            .navigationTitle(UntranslatedL10n.commonMatchaDocs)
            .navigationSubtitle(context.viewState.spaceName ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .sheet(item: $context.nameSheet, onDismiss: { context.send(viewAction: .dismissNameSheet) }, content: { sheet in
                NoteNameSheet(state: sheet,
                              onNameChange: { context.send(viewAction: .updateName($0)) },
                              onSubmit: { context.send(viewAction: .submitName) },
                              onCancel: { context.send(viewAction: .dismissNameSheet) })
            })
            .onAppear { context.send(viewAction: .appeared) }
    }
    
    @ViewBuilder
    private var mainContent: some View {
        switch context.viewState.content {
        case .loading:
            NoteRowsPlaceholder()
        case .loadError:
            NotesMessagePage(icon: \.warning,
                             message: UntranslatedL10n.screenMatchaDocsListLoadError,
                             actionTitle: L10n.actionRetry) {
                context.send(viewAction: .retry)
            }
        case .notSetUp(let canSetUp):
            NotesMessagePage(icon: \.document,
                             message: canSetUp ? UntranslatedL10n.screenMatchaDocsTip : UntranslatedL10n.screenMatchaDocsNotEnabled,
                             actionTitle: canSetUp ? UntranslatedL10n.screenMatchaDocsTipAction : nil) {
                context.send(viewAction: .openSetup)
            }
        case .notes(let notes):
            List {
                ForEach(notes) { note in
                    noteRow(note)
                }
                if notes.count == 1 {
                    Text(UntranslatedL10n.screenMatchaDocsListEmpty)
                        .font(.compound.bodyMD)
                        .foregroundStyle(.compound.textSecondary)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.compound.bgCanvasDefault)
                }
            }
            .notesListStyle()
        }
    }
    
    private func noteRow(_ note: NoteRowItem) -> some View {
        Button {
            context.send(viewAction: .openNote(documentID: note.id))
        } label: {
            NoteRow(title: note.displayTitle, subtitle: note.subtitle)
        }
        .buttonStyle(.plain)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 64 }
        .listRowBackground(Color.compound.bgCanvasDefault)
        // Renaming writes the catalog, so it needs the same right as creating.
        .contextMenu {
            if context.viewState.canCreate {
                renameButton(note)
            }
        }
        .swipeActions(edge: .trailing) {
            if context.viewState.canCreate {
                renameButton(note)
            }
        }
    }
    
    private func renameButton(_ note: NoteRowItem) -> some View {
        Button {
            context.send(viewAction: .rename(documentID: note.id))
        } label: {
            Label(UntranslatedL10n.actionMatchaRename, icon: \.edit)
        }
    }
    
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if context.viewState.canCreate {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    context.send(viewAction: .newNote)
                } label: {
                    CompoundIcon(\.plus)
                        .accessibilityHidden(true)
                }
                .accessibilityLabel(UntranslatedL10n.screenMatchaDocsNew)
            }
        }
    }
}

// MARK: - Previews

struct SpaceNotesListScreen_Previews: PreviewProvider, TestablePreview {
    static let notes = [NoteRowItem(id: "main", title: nil, editedAt: "Yesterday"),
                        NoteRowItem(id: "11111111-1111-4111-8111-111111111111", title: "Trip plans", editedAt: "14:05"),
                        NoteRowItem(id: "22222222-2222-4222-8222-222222222222", title: "A guide with a name long enough to be cut at the end of the row", editedAt: "Mon")]
    
    static var previews: some View {
        preview(.init(content: .notes(notes), canCreate: true))
            .previewDisplayName("Notes")
        preview(.init(content: .loading))
            .previewDisplayName("Loading")
        preview(.init(content: .notes([NoteRowItem(id: "main", title: nil, editedAt: nil)]), canCreate: true))
            .previewDisplayName("Only Space notes")
        preview(.init(content: .loadError))
            .previewDisplayName("Load error")
        preview(.init(content: .notes(notes), hasUnreadableNames: true))
            .previewDisplayName("Unreadable names")
        preview(.init(content: .notSetUp(canSetUp: true)))
            .previewDisplayName("Can turn on")
        preview(.init(content: .notSetUp(canSetUp: false)))
            .previewDisplayName("Not turned on")
        preview(.init(content: .notes(notes)))
            .previewDisplayName("View only")
    }
    
    static func preview(_ state: SpaceNotesListScreenViewState) -> some View {
        var state = state
        state.spaceName = "Matcha team"
        return ElementNavigationStack {
            SpaceNotesListScreen(context: SpaceNotesListScreenFixedViewModel(state: state).context)
        }
    }
}

/// A list screen showing a fixed state: the previews, and the skeleton shown while a space opens.
final class SpaceNotesListScreenFixedViewModel: SpaceNotesListScreenViewModelType {
    init(state: SpaceNotesListScreenViewState) {
        super.init(initialViewState: state)
    }
}
