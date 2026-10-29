//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import MatchaProtocol
import SwiftUI

/// A note of a list, as its rows show it.
struct NoteRowItem: Equatable, Identifiable {
    let id: String
    /// Nil for Space notes before anyone names it.
    let title: String?
    /// When the note was last edited, already formatted, if known.
    let editedAt: String?
    
    var displayTitle: String {
        title ?? UntranslatedL10n.screenMatchaDocsMainName
    }
    
    var subtitle: String? {
        editedAt.map(UntranslatedL10n.screenMatchaDocsEdited)
    }
    
    /// A space's notes as lists show them: Space notes first, then the others by last edit, each with when it was last edited.
    static func rows(_ documents: [SpaceDocument], lastEdits: [String: Int64]) -> [NoteRowItem] {
        func editedAt(_ document: SpaceDocument) -> Int64? {
            lastEdits[document.id] ?? (document.createdAt > 0 ? document.createdAt : nil)
        }
        let main = documents.filter { $0.id == DocsProtocol.mainDocumentID }
        let others = documents.filter { $0.id != DocsProtocol.mainDocumentID }.sorted { (editedAt($0) ?? 0) > (editedAt($1) ?? 0) }
        return (main + others).map { document in
            NoteRowItem(id: document.id,
                        title: document.title,
                        editedAt: editedAt(document).map { Date(timeIntervalSince1970: TimeInterval($0) / 1000).formattedMinimal() })
        }
    }
    
    /// The newest frame time of each note; the store's events are newest first.
    static func lastEdits(_ events: [RawEvent]) -> [String: Int64] {
        var edits = [String: Int64]()
        for event in events where event.type == MatchaConfig.eventDocsUpdate {
            if let documentID = event.content.string("doc"), let timestamp = event.timestamp, edits[documentID] == nil {
                edits[documentID] = timestamp
            }
        }
        return edits
    }
}

/// A note row: a rounded tile, the title and one grey line.
struct NoteRow: View {
    let title: String
    let subtitle: String?
    /// Nil for the Matcha notes icon.
    var icon: KeyPath<CompoundIcons, Image>?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    
    /// At accessibility sizes one line kept "Space not…": the lines wrap there.
    private var lineLimit: Int? {
        dynamicTypeSize.isAccessibilitySize ? nil : 1
    }
    
    var body: some View {
        HStack(spacing: 16) {
            NoteTile(icon: icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.compound.bodyLGSemibold)
                    .foregroundStyle(.compound.textPrimary)
                    .lineLimit(lineLimit)
                if let subtitle {
                    Text(subtitle)
                        .font(.compound.bodyMD)
                        .foregroundStyle(.compound.textSecondary)
                        .lineLimit(lineLimit)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 48)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The 48 pt rounded-square tile of a note row.
struct NoteTile: View {
    /// Nil for the Matcha notes icon (WHATSAPP_DESIGN §2.8).
    var icon: KeyPath<CompoundIcons, Image>?
    
    var body: some View {
        Group {
            if let icon {
                CompoundIcon(icon)
            } else {
                CompoundIcon(asset: Asset.Images.matchaNotes)
            }
        }
        .foregroundStyle(.compound.iconSecondary)
        .frame(width: 48, height: 48)
        .background(.compound.bgSubtleSecondary, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)
    }
}

/// A skeleton note row, shown while a list loads.
struct NoteRowPlaceholder: View {
    var body: some View {
        NoteRow(title: "Space notes", subtitle: "Edited yesterday")
            .redacted(reason: .placeholder)
            .shimmer()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.commonLoading)
    }
}

/// A list of skeleton note rows, one Loading element for VoiceOver.
struct NoteRowsPlaceholder: View {
    var body: some View {
        List {
            ForEach(0..<3, id: \.self) { _ in
                NoteRowPlaceholder()
                    .listRowBackground(Color.compound.bgCanvasDefault)
            }
        }
        .notesListStyle()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.commonLoading)
    }
}

extension View {
    /// A plain list on the canvas, whose rows also need `listRowBackground(Color.compound.bgCanvasDefault)`: a plain list's rows are
    /// black in dark mode, darker than the canvas.
    func notesListStyle() -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
    }
}

/// A notice under the navigation bar.
struct NotesNoticeStrip: View {
    let icon: KeyPath<CompoundIcons, Image>
    let text: String
    
    var body: some View {
        HStack(spacing: 8) {
            CompoundIcon(icon, size: .small, relativeTo: .compound.bodyMD)
                .accessibilityHidden(true)
            Text(text)
                .font(.compound.bodyMD)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.compound.textPrimary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 32)
        .background(.compound.bgSubtlePrimary)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// A centred page with a big icon, a message and an optional button, for empty, error and setup states.
struct NotesMessagePage: View {
    let icon: KeyPath<CompoundIcons, Image>
    var title: String?
    let message: String
    var actionTitle: String?
    var action: () -> Void = { }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                BigIcon(icon: icon)
                if let title {
                    Text(title)
                        .font(.compound.headingSMSemibold)
                        .foregroundStyle(.compound.textPrimary)
                        .multilineTextAlignment(.center)
                }
                Text(message)
                    .font(.compound.bodyMD)
                    .foregroundStyle(.compound.textSecondary)
                    .multilineTextAlignment(.center)
                if let actionTitle {
                    Button(actionTitle, action: action)
                        .buttonStyle(.compound(.primary))
                        .padding(.top, 8)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center)
    }
}

// MARK: - Previews

struct NotesComponents_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        VStack(spacing: 0) {
            NotesNoticeStrip(icon: \.offline, text: UntranslatedL10n.screenMatchaDocsOfflineStrip)
            NoteRow(title: UntranslatedL10n.screenMatchaDocsMainName, subtitle: UntranslatedL10n.screenMatchaDocsEdited("Yesterday"))
                .padding(16)
            NoteRowPlaceholder()
                .padding(16)
            NotesMessagePage(icon: \.warning,
                             title: UntranslatedL10n.screenMatchaDocsLoadErrorTitle,
                             message: UntranslatedL10n.screenMatchaDocsLoadErrorBody,
                             actionTitle: L10n.actionRetry)
        }
    }
}
