//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatchaProtocol

/// The buttons of the formatting row, in their order.
nonisolated enum FormatCommand: CaseIterable, Sendable {
    case heading
    case bold
    case italic
    case strikethrough
    case bulletList
    case numberedList
    case quote
    case inlineCode
    case codeBlock
    case link
    case checklist
}

/// A text field's text and selection, in UTF-16 code units like `UITextView`'s `selectedRange`.
nonisolated struct FormattedText: Equatable, Sendable {
    var text: String
    var selection: NSRange
    
    init(_ text: String, selection: NSRange) {
        self.text = text
        self.selection = selection
    }
    
    init(_ text: String, _ start: Int, _ end: Int? = nil) {
        self.init(text, selection: NSRange(location: start, length: (end ?? start) - start))
    }
}

/// Markdown formatting of the selection, after the web client's `markdownCommands.ts` and Android's `MarkdownFormatting`: inline
/// styles wrap or unwrap the selection, block styles toggle a prefix on every selected line. Only the touched text changes, so
/// concurrent edits elsewhere survive.
nonisolated enum MarkdownFormatting {
    static func apply(_ command: FormatCommand, to value: FormattedText) -> FormattedText {
        switch command {
        case .bold: wrap(value, marker: "**")
        case .italic: wrap(value, marker: "*")
        case .strikethrough: wrap(value, marker: "~~")
        case .inlineCode: wrap(value, marker: "`")
        case .codeBlock: codeBlock(value)
        case .link: link(value)
        case .heading, .bulletList, .numberedList, .checklist, .quote: prefixLines(value, command: command)
        }
    }
    
    /// Whether the selection already has this style, to tint its button.
    static func isActive(_ command: FormatCommand, in value: FormattedText) -> Bool {
        switch command {
        case .bold: isWrapped(value, marker: "**")
        case .italic: isWrapped(value, marker: "*")
        case .strikethrough: isWrapped(value, marker: "~~")
        case .inlineCode: isWrapped(value, marker: "`")
        case .codeBlock, .link: false
        case .heading, .bulletList, .numberedList, .checklist, .quote: matches(sameItem(command), currentLine(value).kotlinTrimmedStart)
        }
    }
    
    // MARK: - Inline
    
    private static func isWrapped(_ value: FormattedText, marker: String) -> Bool {
        let text = value.text as NSString
        let start = value.selection.lowerBound
        let end = value.selection.upperBound
        let length = (marker as NSString).length
        return start >= length && text.has(marker, at: start - length) && text.has(marker, at: end) && (marker != "*" || isItalicRun(text, start, end))
    }
    
    /// A single asterisk is italic only when it is not part of a bold pair: the runs around the selection must be odd.
    private static func isItalicRun(_ text: NSString, _ start: Int, _ end: Int) -> Bool {
        let star = UTF16.CodeUnit(UInt8(ascii: "*"))
        var before = 0
        while start - before > 0, text.character(at: start - before - 1) == star {
            before += 1
        }
        var after = 0
        while end + after < text.length, text.character(at: end + after) == star {
            after += 1
        }
        return before % 2 == 1 && after % 2 == 1
    }
    
    private static func wrap(_ value: FormattedText, marker: String) -> FormattedText {
        let text = value.text as NSString
        let start = value.selection.lowerBound
        let end = value.selection.upperBound
        let length = (marker as NSString).length
        if isWrapped(value, marker: marker) {
            let unwrapped = NSMutableString(string: value.text)
            unwrapped.deleteCharacters(in: NSRange(location: end, length: length))
            unwrapped.deleteCharacters(in: NSRange(location: start - length, length: length))
            return FormattedText(unwrapped as String, start - length, end - length)
        }
        let selected = text.substring(with: value.selection) as NSString
        let includesMarkers = selected.length >= 2 * length && selected.has(marker, at: 0) && selected.has(marker, at: selected.length - length)
            && (marker != "*" || isItalicRun(selected, length, selected.length - length))
        if includesMarkers {
            let inner = selected.substring(with: NSRange(location: length, length: selected.length - 2 * length))
            return FormattedText(text.replacingCharacters(in: value.selection, with: inner), start, start + (inner as NSString).length)
        }
        return FormattedText(text.replacingCharacters(in: value.selection, with: marker + (selected as String) + marker), start + length, end + length)
    }
    
    private static func codeBlock(_ value: FormattedText) -> FormattedText {
        let text = value.text as NSString
        let start = value.selection.lowerBound
        let end = value.selection.upperBound
        let newline = UTF16.CodeUnit(UInt8(ascii: "\n"))
        let lineBreakBefore = start > 0 && text.character(at: start - 1) != newline ? "\n" : ""
        let lineBreakAfter = end < text.length && text.character(at: end) != newline ? "\n" : ""
        let before = lineBreakBefore + fence + "\n"
        let after = "\n" + fence + lineBreakAfter
        let replacement = before + text.substring(with: value.selection) + after
        let offset = (before as NSString).length
        return FormattedText(text.replacingCharacters(in: value.selection, with: replacement), start + offset, end + offset)
    }
    
    private static func link(_ value: FormattedText) -> FormattedText {
        let text = value.text as NSString
        let start = value.selection.lowerBound
        let selected = text.substring(with: value.selection)
        let newText = text.replacingCharacters(in: value.selection, with: "[\(selected)](\(linkURL))")
        // With a label, select the address to type over it; without one, type the label first.
        guard !selected.isEmpty else { return FormattedText(newText, start + 1) }
        let urlStart = start + (selected as NSString).length + 3
        return FormattedText(newText, urlStart, urlStart + (linkURL as NSString).length)
    }
    
    // MARK: - Lines
    
    private static func sameItem(_ command: FormatCommand) -> NSRegularExpression {
        switch command {
        case .heading: anyHeading
        case .quote: quote
        case .checklist: checklistItem
        case .numberedList: numberedItem
        default: bulletItem
        }
    }
    
    private static func currentLine(_ value: FormattedText) -> String {
        let text = value.text as NSString
        let cursor = value.selection.lowerBound
        let before = cursor == 0 ? NSRange(location: NSNotFound, length: 0) : text.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: cursor))
        let start = before.location == NSNotFound ? 0 : before.location + 1
        let after = text.range(of: "\n", options: [], range: NSRange(location: cursor, length: text.length - cursor))
        let end = after.location == NSNotFound ? text.length : after.location
        return text.substring(with: NSRange(location: start, length: end - start))
    }
    
    private static func prefixLines(_ value: FormattedText, command: FormatCommand) -> FormattedText {
        let lines = value.text.components(separatedBy: "\n")
        var lineStarts = [0]
        for line in lines.dropLast() {
            lineStarts.append(lineStarts[lineStarts.count - 1] + (line as NSString).length + 1)
        }
        let selection = value.selection
        let isCollapsed = selection.length == 0
        let selectionEnd = isCollapsed ? selection.upperBound : max(selection.lowerBound, selection.upperBound - 1)
        let first = lineStarts.lastIndex { $0 <= selection.lowerBound } ?? 0
        let last = lineStarts.lastIndex { $0 <= selectionEnd } ?? first
        let selected = Array(lines[first...last])
        let same = sameItem(command)
        let existing = switch command {
        case .heading: anyHeading
        case .quote: quote
        default: anyListItem
        }
        let nonEmpty = selected.filter { !$0.isKotlinBlank }
        let remove = !nonEmpty.isEmpty && nonEmpty.allSatisfy { matches(same, $0.kotlinTrimmedStart) }
        var number = 1
        let changed = selected.map { line -> String in
            if line.isKotlinBlank, selected.count > 1 {
                return line
            }
            // Split by scalars: a combining mark after the indent makes one Character with its last space.
            let scalars = line.unicodeScalars
            let restStart = scalars.firstIndex { !$0.isKotlinWhitespace } ?? scalars.endIndex
            let indent = String(scalars[..<restStart])
            let rest = String(scalars[restStart...])
            let oldPrefix = prefixMatch(existing, rest) ?? ""
            let marker = if remove {
                ""
            } else {
                switch command {
                case .heading: "# "
                case .quote: "> "
                case .checklist: "- [ ] "
                case .numberedList: "\(number). "
                default: "- "
                }
            }
            if command == .numberedList, !remove {
                number += 1
            }
            return indent + marker + (rest as NSString).substring(from: (oldPrefix as NSString).length)
        }
        let newText = (lines[..<first] + changed + lines[(last + 1)...]).joined(separator: "\n")
        let firstStart = lineStarts[first]
        if isCollapsed, first == last, let line = changed.first, let original = selected.first {
            // Keep the cursor on the same character of the line, after the new prefix.
            let lineDelta = (line as NSString).length - (original as NSString).length
            let cursor = min(max(selection.location + lineDelta, firstStart), firstStart + (line as NSString).length)
            return FormattedText(newText, cursor)
        }
        let changedEnd = firstStart + (changed.joined(separator: "\n") as NSString).length
        return FormattedText(newText, firstStart, min(changedEnd, (newText as NSString).length))
    }
    
    private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        prefixMatch(pattern, text) != nil
    }
    
    /// What `pattern`, which is anchored at the start, matches at the start of `text`.
    private static func prefixMatch(_ pattern: NSRegularExpression, _ text: String) -> String? {
        let text = text as NSString
        guard let match = pattern.firstMatch(in: text as String, range: NSRange(location: 0, length: text.length)), match.range.location == 0 else { return nil }
        return text.substring(with: match.range)
    }
    
    // Java's `\s`, which the Android patterns use: ASCII whitespace only.
    private static let space = #"[ \t\n\x{0B}\f\r]"#
    // swiftlint:disable force_try
    private static let anyHeading = try! NSRegularExpression(pattern: #"^#{1,6}\#(space)+"#)
    private static let quote = try! NSRegularExpression(pattern: #"^>\#(space)?"#)
    private static let anyListItem = try! NSRegularExpression(pattern: #"^(?:[-*+]\#(space)+(?:\[[ xX]\]\#(space)+)?|\d+[.)]\#(space)+)"#)
    private static let checklistItem = try! NSRegularExpression(pattern: #"^[-*+]\#(space)+\[[ xX]\]\#(space)+"#)
    private static let bulletItem = try! NSRegularExpression(pattern: #"^[-*+]\#(space)+(?!\[[ xX]\])"#)
    private static let numberedItem = try! NSRegularExpression(pattern: #"^\d+[.)]\#(space)+"#)
    // swiftlint:enable force_try
    private static let linkURL = "https://"
    private static let fence = "```"
}

private nonisolated extension NSString {
    func has(_ marker: String, at index: Int) -> Bool {
        let length = (marker as NSString).length
        return index >= 0 && index + length <= self.length && substring(with: NSRange(location: index, length: length)) == marker
    }
}
