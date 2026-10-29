//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

/// A note's Markdown as blocks of styled text: body text with 16 pt gutters, links in the link colour, code on a grey fill.
struct MarkdownPreview: View {
    let blocks: [MarkdownBlock]
    
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
        .tint(.compound.textLinkExternal)
    }
    
    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownParser.inline(text))
                .font(level == 1 ? .compound.headingMDBold : level == 2 ? .compound.headingSMSemibold : .compound.bodyLGSemibold)
                .foregroundStyle(.compound.textPrimary)
                .padding(.top, 8)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            bodyText(text)
        case .listItem(let depth, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(marker)
                    .font(.compound.bodyLG)
                    .foregroundStyle(.compound.textPrimary)
                    .frame(minWidth: 24, alignment: .leading)
                    .accessibilityLabel(markerLabel(marker))
                bodyText(text)
            }
            .padding(.leading, CGFloat(depth * 24))
            // One element, so the marker is read with its item.
            .accessibilityElement(children: .combine)
        case .quote(let text):
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.compound.borderInteractiveSecondary)
                    .frame(width: 4)
                Text(MarkdownParser.inline(text))
                    .font(.compound.bodyLG)
                    .foregroundStyle(.compound.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let text):
            ScrollView(.horizontal) {
                Text(text)
                    .font(.compound.bodyMD.monospaced())
                    .foregroundStyle(.compound.textPrimary)
                    .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.compound.bgSubtleSecondary, in: RoundedRectangle(cornerRadius: 8))
        case .rule:
            Divider()
                .padding(.vertical, 8)
        case .table(let rows):
            table(rows)
        }
    }
    
    /// Checkboxes are read as their state rather than as the symbols' names.
    private func markerLabel(_ marker: String) -> String {
        switch marker {
        case MarkdownParser.uncheckedMarker: UntranslatedL10n.a11yMatchaChecklistUnchecked
        case MarkdownParser.checkedMarker: UntranslatedL10n.a11yMatchaChecklistChecked
        default: marker
        }
    }
    
    private func bodyText(_ text: String) -> some View {
        Text(MarkdownParser.inline(text))
            .font(.compound.bodyLG)
            .foregroundStyle(.compound.textPrimary)
            .lineSpacing(4)
    }
    
    private func table(_ rows: [[String]]) -> some View {
        let columns = rows.map(\.count).max() ?? 0
        return Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    Divider()
                }
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        Text(MarkdownParser.inline(column < row.count ? row[column] : ""))
                            .font(index == 0 ? .compound.bodyLGSemibold : .compound.bodyLG)
                            .foregroundStyle(.compound.textPrimary)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.compound.borderDisabled))
    }
}

// MARK: - Previews

struct MarkdownPreview_Previews: PreviewProvider, TestablePreview {
    static let markdown = """
    # Trip plans
    We leave on **Friday** at 9 and meet at the *station*. See https://example.org for the ~~old~~ new times.
    
    ## Packing
    - Tickets
    - [ ] Snacks
    - [x] Charger
    1. Book the hotel
    2. Tell `Ana`
    
    > Bring a coat, it gets cold at night.
    
    ```
    Platform 4, coach B
    ```
    
    | Day | Plan |
    | --- | --- |
    | Fri | Travel |
    | Sat | Hike |
    """
    
    static var previews: some View {
        MarkdownPreview(blocks: MarkdownParser.parse(markdown))
    }
}
