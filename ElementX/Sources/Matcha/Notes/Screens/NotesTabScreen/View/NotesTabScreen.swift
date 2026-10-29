//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

/// The root of the Notes tab: a section per space with its notes, New note in the toolbar, and its sheet.
struct NotesTabScreen: View {
    @Bindable var context: NotesTabScreenViewModel.Context
    
    var body: some View {
        mainContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.compound.bgCanvasDefault.ignoresSafeArea())
            .navigationTitle(UntranslatedL10n.commonMatchaDocs)
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbar }
            .sheet(item: $context.sheet, onDismiss: { context.send(viewAction: .dismissSheet) }, content: sheet)
            .onAppear { context.send(viewAction: .appeared) }
            .onDisappear { context.send(viewAction: .disappeared) }
    }
    
    @ViewBuilder
    private var mainContent: some View {
        switch context.viewState.content {
        case .loading:
            NoteRowsPlaceholder()
        case .empty(let hasSpaces):
            NotesMessagePage(icon: \.document,
                             title: UntranslatedL10n.screenMatchaNotesTabEmptyTitle,
                             message: hasSpaces ? UntranslatedL10n.screenMatchaNotesTabNoneOnBody : UntranslatedL10n.screenMatchaNotesTabEmptyBody)
        case .spaces(let sections):
            List {
                ForEach(sections) { section in
                    Section {
                        sectionRows(section)
                            .listRowBackground(Color.compound.bgCanvasDefault)
                    }
                }
            }
            .notesListStyle()
        }
    }
    
    @ViewBuilder
    private func sectionRows(_ section: NotesSection) -> some View {
        let spaceID = section.space.id
        // The header opens the space's own list, which can also rename notes.
        Button {
            context.send(viewAction: .openNote(spaceID: spaceID, documentID: nil))
        } label: {
            NotesTabSpaceLabel(space: section.space, mediaProvider: context.mediaProvider, showsChevron: true)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
        .reportsVisibility(of: spaceID, row: "header", to: context)
        switch section.content {
        case .loading:
            NoteRowPlaceholder()
                .reportsVisibility(of: spaceID, row: "loading", to: context)
        case .loadError:
            HStack(spacing: 16) {
                NoteTile(icon: \.warning)
                Text(UntranslatedL10n.screenMatchaDocsListLoadError)
                    .font(.compound.bodyMD)
                    .foregroundStyle(.compound.textSecondary)
                Spacer(minLength: 0)
                Button(L10n.actionRetry) {
                    context.send(viewAction: .retry(spaceID: spaceID))
                }
                .buttonStyle(.compound(.textLink, size: .small))
            }
            .reportsVisibility(of: spaceID, row: "error", to: context)
        case .turnOn:
            // The space's notes screen turns them on.
            Button {
                context.send(viewAction: .openNote(spaceID: spaceID, documentID: nil))
            } label: {
                HStack(spacing: 16) {
                    NoteTile(icon: \.plus)
                    Text(UntranslatedL10n.screenMatchaDocsSetupAction)
                        .font(.compound.bodyLG)
                        .foregroundStyle(.compound.textSecondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .reportsVisibility(of: spaceID, row: "turn-on", to: context)
        case .notes(let notes):
            ForEach(notes) { note in
                Button {
                    context.send(viewAction: .openNote(spaceID: spaceID, documentID: note.id))
                } label: {
                    NoteRow(title: note.displayTitle, subtitle: note.subtitle)
                }
                .buttonStyle(.plain)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 64 }
                .reportsVisibility(of: spaceID, row: note.id, to: context)
            }
        }
    }
    
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let userProfile = context.viewState.userProfile {
            MatchaSettingsToolbarItem(userProfile: userProfile, mediaProvider: context.mediaProvider) {
                context.send(viewAction: .showSettings)
            }
        }
        
        if context.viewState.canCreate {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    context.send(viewAction: .newNote)
                } label: {
                    CompoundIcon(\.plus)
                        .accessibilityHidden(true)
                }
                .matchaProminentToolbarButton()
                .accessibilityLabel(UntranslatedL10n.screenMatchaDocsNew)
            }
        }
    }
    
    @ViewBuilder
    private func sheet(_ sheet: NotesTabSheet) -> some View {
        switch sheet {
        case .chooseSpace(let spaces):
            NotesTabSpacePicker(spaces: spaces,
                                mediaProvider: context.mediaProvider,
                                onChoose: { context.send(viewAction: .chooseSpace(spaceID: $0)) },
                                onCancel: { context.send(viewAction: .dismissSheet) })
        case .name(let state):
            NoteNameSheet(state: state,
                          onNameChange: { context.send(viewAction: .updateName($0)) },
                          onSubmit: { context.send(viewAction: .submitName) },
                          onCancel: { context.send(viewAction: .dismissSheet) })
        }
    }
}

/// A space's avatar and name and, for a subspace, the space it is listed under.
struct NotesTabSpaceLabel: View {
    let space: NotesTabSpace
    let mediaProvider: MediaProviderProtocol?
    var showsChevron = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    
    /// The avatar grows with the text: beside it, a name at an accessibility size kept a few letters, so it goes above the name, which
    /// wraps rather than being cut.
    private var avatarAndNames: AnyLayout {
        dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 16))
    }
    
    var body: some View {
        HStack(spacing: 16) {
            avatarAndNames {
                RoomAvatarImage(avatar: space.avatar, avatarSize: .room(on: .spaces), mediaProvider: mediaProvider)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(space.name)
                        .font(.compound.bodyLGSemibold)
                        .foregroundStyle(.compound.textPrimary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    if let parentName = space.parentName {
                        Text(parentName)
                            .font(.compound.bodyMD)
                            .foregroundStyle(.compound.textSecondary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    }
                }
            }
            Spacer(minLength: 0)
            if showsChevron {
                CompoundIcon(\.chevronRight)
                    .foregroundStyle(.compound.iconTertiaryAlpha)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// New note's Choose a space: the spaces that can take the note.
struct NotesTabSpacePicker: View {
    let spaces: [NotesTabSpace]
    let mediaProvider: MediaProviderProtocol?
    let onChoose: (String) -> Void
    let onCancel: () -> Void
    
    var body: some View {
        ElementNavigationStack {
            List(spaces) { space in
                Button {
                    onChoose(space.id)
                } label: {
                    NotesTabSpaceLabel(space: space, mediaProvider: mediaProvider)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .navigationTitle(UntranslatedL10n.commonMatchaChooseSpace)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.actionCancel, action: onCancel)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private extension View {
    /// Tells the tab while this row is on screen, so its space's notes are read. Note ids never clash with the other rows' names.
    func reportsVisibility(of spaceID: String, row rowID: String, to context: NotesTabScreenViewModel.Context) -> some View {
        onAppear { context.send(viewAction: .rowAppeared(spaceID: spaceID, rowID: rowID)) }
            .onDisappear { context.send(viewAction: .rowDisappeared(spaceID: spaceID, rowID: rowID)) }
    }
}

// MARK: - Previews

struct NotesTabScreen_Previews: PreviewProvider, TestablePreview {
    static let design = NotesTabSpace(id: "!design:matrix.org", name: "Design team", parentName: nil, avatarURL: nil)
    static let research = NotesTabSpace(id: "!research:matrix.org", name: "Research", parentName: "Design team", avatarURL: nil)
    static let launch = NotesTabSpace(id: "!launch:matrix.org", name: "Launch", parentName: nil, avatarURL: nil)
    static let company = NotesTabSpace(id: "!company:matrix.org", name: "Company", parentName: nil, avatarURL: nil)
    static let notes = [NoteRowItem(id: "main", title: nil, editedAt: "Yesterday"),
                        NoteRowItem(id: "11111111-1111-4111-8111-111111111111", title: "Trip plans", editedAt: "14:05"),
                        NoteRowItem(id: "22222222-2222-4222-8222-222222222222", title: "A guide with a name long enough to be cut at the end of the row", editedAt: "Mon")]
    static let spaces = NotesTabContent.spaces([NotesSection(space: design, content: .notes(notes)),
                                                NotesSection(space: launch, content: .loading),
                                                NotesSection(space: company, content: .turnOn)])
    
    static var previews: some View {
        preview(.init(content: spaces, canCreate: true))
            .previewDisplayName("Spaces")
        preview(.init(content: .loading))
            .previewDisplayName("Loading")
        preview(.init(content: .empty(hasSpaces: false)))
            .previewDisplayName("No spaces")
        preview(.init(content: .empty(hasSpaces: true)))
            .previewDisplayName("No space has notes")
        preview(.init(content: .spaces([NotesSection(space: launch, content: .notes([NoteRowItem(id: "main", title: nil, editedAt: nil)])),
                                        NotesSection(space: design, content: .loadError),
                                        NotesSection(space: company, content: .turnOn)])))
            .previewDisplayName("Errors and turn on")
        preview(.init(content: .spaces([NotesSection(space: design, content: .notes([NoteRowItem(id: "main", title: nil, editedAt: "Yesterday")])),
                                        NotesSection(space: research, content: .notes([NoteRowItem(id: "main", title: nil, editedAt: "14:05")])),
                                        NotesSection(space: launch, content: .loading)]),
                      canCreate: true))
            .previewDisplayName("Subspaces")
        preview(.init(content: spaces, canCreate: true, bindings: .init(sheet: .chooseSpace([design, research, launch]))))
            .previewDisplayName("Choose a space")
        preview(.init(content: spaces, canCreate: true, bindings: .init(sheet: .name(.new()))))
            .previewDisplayName("New note")
        preview(.init(content: spaces, canCreate: true, bindings: .init(sheet: .name(.init(documentID: nil, name: "Trip plans", error: .saveFailed)))))
            .previewDisplayName("New note failed")
    }
    
    static func preview(_ state: NotesTabScreenViewState) -> some View {
        ElementNavigationStack {
            NotesTabScreen(context: NotesTabScreenPreviewViewModel(state: state).context)
        }
    }
}

/// A Notes tab showing a fixed state, for previews.
private final class NotesTabScreenPreviewViewModel: NotesTabScreenViewModelType {
    init(state: NotesTabScreenViewState) {
        super.init(initialViewState: state, mediaProvider: MediaProviderMock(.init()))
    }
}
