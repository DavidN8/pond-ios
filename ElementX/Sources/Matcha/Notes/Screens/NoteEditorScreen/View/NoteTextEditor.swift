//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

/// What the formatting row needs from the text view: its text and selection, and a way to format them.
@Observable
final class NoteTextEditorModel {
    fileprivate(set) var value = FormattedText("", 0)
    @ObservationIgnored fileprivate weak var coordinator: NoteTextEditor.Coordinator?
    
    func apply(_ command: FormatCommand) {
        coordinator?.apply(command)
    }
    
    func isActive(_ command: FormatCommand) -> Bool {
        MarkdownFormatting.isActive(command, in: value)
    }
}

/// The plain text view of edit mode, a `UITextView` for its exact selection and marked text. Edits go out as `onEdit(before:after:)`;
/// edits from others are merged in between keystrokes, keeping the cursor on its character, and never while the keyboard is
/// composing a word (marked text) or while the field's own edits are still on their way into the document.
struct NoteTextEditor: UIViewRepresentable {
    /// The document's text.
    let text: String
    let isApplyingEdits: Bool
    let model: NoteTextEditorModel
    let onEdit: (_ before: String, _ after: String) -> Void
    
    func makeCoordinator() -> Coordinator {
        Coordinator(text: text, onEdit: onEdit)
    }
    
    func makeUIView(context: Context) -> NoteUITextView {
        let textView = NoteUITextView()
        textView.text = text
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = .compound.textPrimary
        textView.tintColor = .compound.textActionAccent
        textView.backgroundColor = .clear
        textView.autocapitalizationType = .sentences
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        textView.keyboardDismissMode = .interactive
        textView.delegate = context.coordinator
        textView.onFormat = { [weak coordinator = context.coordinator] in coordinator?.apply($0) }
        textView.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        context.coordinator.textView = textView
        model.coordinator = context.coordinator
        context.coordinator.model = model
        context.coordinator.selectionChanged()
        DispatchQueue.main.async { textView.becomeFirstResponder() }
        return textView
    }
    
    func updateUIView(_ textView: NoteUITextView, context: Context) {
        context.coordinator.onEdit = onEdit
        context.coordinator.documentChanged(text, isApplyingEdits: isApplyingEdits)
    }
    
    final class Coordinator: NSObject, UITextViewDelegate {
        weak var textView: UITextView?
        weak var model: NoteTextEditorModel?
        var onEdit: (_ before: String, _ after: String) -> Void
        /// What the field showed after its last edit.
        private var fieldText: String
        private var echoes: EditEchoes
        private var documentText: String
        private var isApplyingEdits = false
        
        init(text: String, onEdit: @escaping (_ before: String, _ after: String) -> Void) {
            fieldText = text
            documentText = text
            echoes = EditEchoes(text)
            self.onEdit = onEdit
        }
        
        func documentChanged(_ text: String, isApplyingEdits: Bool) {
            documentText = text
            self.isApplyingEdits = isApplyingEdits
            mergeDocumentText()
        }
        
        func apply(_ command: FormatCommand) {
            guard let textView else { return }
            let text = textView.text ?? ""
            let formatted = MarkdownFormatting.apply(command, to: FormattedText(text, selection: textView.selectedRange))
            // Replaced in place rather than assigned, which would clear the undo history: the formatting and the typing before it can be undone.
            let changes = TextDiff.changes(from: text, to: formatted.text)
            if let first = changes.first, let last = changes.last,
               let start = textView.position(from: textView.beginningOfDocument, offset: first.index),
               let end = textView.position(from: textView.beginningOfDocument, offset: last.index + last.remove),
               let range = textView.textRange(from: start, to: end) {
                let length = last.index + last.remove - first.index + (formatted.text as NSString).length - (text as NSString).length
                textView.replace(range, withText: (formatted.text as NSString).substring(with: NSRange(location: first.index, length: length)))
            }
            textView.selectedRange = formatted.selection
            fieldEdited()
        }
        
        // MARK: UITextViewDelegate
        
        func textViewDidChange(_ textView: UITextView) {
            fieldEdited()
        }
        
        func textViewDidChangeSelection(_ textView: UITextView) {
            selectionChanged()
        }
        
        // MARK: Private
        
        fileprivate func selectionChanged() {
            guard let textView else { return }
            model?.value = FormattedText(textView.text, selection: textView.selectedRange)
        }
        
        private func fieldEdited() {
            guard let textView else { return }
            let text = textView.text ?? ""
            if text != fieldText {
                let before = fieldText
                fieldText = text
                echoes.sent(text)
                onEdit(before, text)
            }
            selectionChanged()
            // A word the keyboard was composing may have just been committed: a waiting remote change can go in now.
            mergeDocumentText()
        }
        
        /// Edits from others arrive between keystrokes; the cursor keeps its place in the text around it.
        private func mergeDocumentText() {
            guard let textView, textView.markedTextRange == nil, !echoes.isBehindField(documentText), !isApplyingEdits, documentText != fieldText else { return }
            echoes.reset(documentText)
            let changes = TextDiff.changes(from: fieldText, to: documentText)
            let selection = textView.selectedRange
            let start = TextDiff.mapOffset(selection.lowerBound, through: changes)
            let end = TextDiff.mapOffset(selection.upperBound, through: changes)
            fieldText = documentText
            let offset = textView.contentOffset
            // ponytail: assigning clears the undo history, which would otherwise undo others' edits; transform it if undo across them matters.
            textView.text = documentText
            textView.selectedRange = NSRange(location: start, length: max(end - start, 0))
            textView.setContentOffset(offset, animated: false)
            selectionChanged()
        }
    }
}

/// A text view with ⌘B and ⌘I for the Markdown it holds.
final class NoteUITextView: UITextView {
    var onFormat: ((FormatCommand) -> Void)?
    
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(title: L10n.richTextEditorFormatBold, action: #selector(formatBold), input: "b", modifierFlags: .command),
         UIKeyCommand(title: L10n.richTextEditorFormatItalic, action: #selector(formatItalic), input: "i", modifierFlags: .command)]
    }
    
    @objc private func formatBold() {
        onFormat?(.bold)
    }
    
    @objc private func formatItalic() {
        onFormat?(.italic)
    }
}

/// The formatting buttons, above the keyboard in edit mode.
struct NoteFormattingBar: View {
    let model: NoteTextEditorModel
    /// Grows with Dynamic Type, as the icons do.
    @ScaledMetric private var buttonSize = 40.0
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(FormatCommand.allCases, id: \.self) { command in
                    Button {
                        model.apply(command)
                    } label: {
                        icon(command)
                            .foregroundStyle(.compound.iconSecondary)
                            .frame(width: buttonSize, height: buttonSize)
                            .background(model.isActive(command) ? .compound.bgSubtlePrimary : Color.clear, in: Circle())
                    }
                    .accessibilityLabel(label(command))
                    .accessibilityAddTraits(model.isActive(command) ? .isSelected : [])
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: buttonSize + 8)
        .background(.compound.bgCanvasDefault)
        .overlay(alignment: .top) { Divider() }
    }
    
    @ViewBuilder
    private func icon(_ command: FormatCommand) -> some View {
        switch command {
        // The heading button is a text glyph.
        case .heading: Text(verbatim: "H").font(.compound.bodyLGSemibold)
        case .bold: CompoundIcon(\.bold)
        case .italic: CompoundIcon(\.italic)
        case .strikethrough: CompoundIcon(\.strikethrough)
        case .bulletList: CompoundIcon(\.listBulleted)
        case .numberedList: CompoundIcon(\.listNumbered)
        case .quote: CompoundIcon(\.quote)
        case .inlineCode: CompoundIcon(\.inlineCode)
        case .codeBlock: CompoundIcon(\.code)
        case .link: CompoundIcon(\.link)
        case .checklist: CompoundIcon(\.checkCircle)
        }
    }
    
    private func label(_ command: FormatCommand) -> String {
        switch command {
        case .heading: UntranslatedL10n.a11yMatchaFormatHeading
        case .bold: L10n.richTextEditorFormatBold
        case .italic: L10n.richTextEditorFormatItalic
        case .strikethrough: L10n.richTextEditorFormatStrikethrough
        case .bulletList: L10n.richTextEditorBulletList
        case .numberedList: L10n.richTextEditorNumberedList
        case .quote: L10n.richTextEditorQuote
        case .inlineCode: L10n.richTextEditorInlineCode
        case .codeBlock: L10n.richTextEditorCodeBlock
        case .link: L10n.richTextEditorLink
        case .checklist: UntranslatedL10n.a11yMatchaFormatChecklist
        }
    }
}
