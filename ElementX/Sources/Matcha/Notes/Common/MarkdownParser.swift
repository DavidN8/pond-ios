//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatchaProtocol

/// A block of a Markdown note.
nonisolated enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// `marker` is what shows: a bullet, a number such as "2.", or a checkbox.
    case listItem(depth: Int, marker: String, text: String)
    case quote(String)
    case code(String)
    case rule
    /// The first row is the header.
    case table([[String]])
}

/// A small Markdown reader for the note preview, a port of Android's `MarkdownParser`: headings, paragraphs, bulleted, numbered and
/// checklist items, quotes, fenced code, rules and tables, with bold, italic, strikethrough, code, links and bare links inside
/// them. Raw HTML stays text, as on the web.
///
/// Any member writes the text, so reading it stays linear: no pattern backtracks or recurses per character, and inline searches
/// that only move forward reuse their last answer. Indices are UTF-16 code units, as on Android.
///
/// ponytail: no nested quotes, setext headings or reference links; a full CommonMark library if notes need them.
nonisolated enum MarkdownParser {
    /// The list markers of checklist items.
    static let uncheckedMarker = "☐"
    static let checkedMarker = "☑"
    
    // MARK: - Blocks
    
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks = [MarkdownBlock]()
        var paragraph = [String]()
        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.map(\.kotlinTrimmed).joined(separator: " ")))
            }
            paragraph = []
        }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let fence = match(fencePattern, line)?.first {
                flush()
                let closing = lines.indices.dropFirst(index + 1).first { lines[$0].kotlinTrimmedStart.hasPrefix(fence) } ?? lines.count
                blocks.append(.code(lines[(index + 1)..<closing].joined(separator: "\n")))
                index = closing + 1
            } else if line.isKotlinBlank {
                flush()
                index += 1
            } else if line.kotlinTrimmedStart.hasPrefix("|"), index + 1 < lines.count, isTableDelimiter(lines[index + 1]) {
                flush()
                let end = lines.indices.dropFirst(index + 2).first { !lines[$0].kotlinTrimmedStart.hasPrefix("|") } ?? lines.count
                blocks.append(.table(([line] + lines[(index + 2)..<end]).map(cells)))
                index = end
            } else if match(quotePattern, line) != nil {
                flush()
                let end = lines.indices.dropFirst(index).first { match(quotePattern, lines[$0]) == nil } ?? lines.count
                blocks.append(.quote(lines[index..<end].compactMap { match(quotePattern, $0)?.first }.joined(separator: "\n")))
                index = end
            } else {
                if let block = lineBlock(line) {
                    flush()
                    blocks.append(block)
                } else {
                    paragraph.append(line)
                }
                index += 1
            }
        }
        flush()
        return blocks
    }
    
    private static func lineBlock(_ line: String) -> MarkdownBlock? {
        if let groups = match(headingPattern, line) {
            return .heading(level: groups[0].utf16.count, text: headingText(groups[1]))
        }
        if isRule(line) {
            return .rule
        }
        if let groups = match(taskPattern, line) {
            return .listItem(depth: depth(groups[0]), marker: groups[1].isKotlinBlank ? uncheckedMarker : checkedMarker, text: groups[2])
        }
        if let groups = match(bulletPattern, line) {
            return .listItem(depth: depth(groups[0]), marker: "•", text: groups[1])
        }
        if let groups = match(orderedPattern, line) {
            return .listItem(depth: depth(groups[0]), marker: "\(groups[1]).", text: groups[2])
        }
        return nil
    }
    
    /// A heading's text without its optional closing run of `#`, which only counts after a space.
    private static func headingText(_ text: String) -> String {
        let trimmed = text.kotlinTrimmedEnd
        let open = String(trimmed.reversed().drop { $0 == "#" }.reversed())
        guard let last = open.unicodeScalars.last else { return "" }
        return last.isKotlinWhitespace ? open.kotlinTrimmedEnd : trimmed
    }
    
    /// Three or more of the same `-`, `*` or `_`, with spaces between.
    private static func isRule(_ line: String) -> Bool {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3, let mark = line.dropFirst(indent).first, "-*_".contains(mark) else { return false }
        let marks = line.unicodeScalars.filter { !$0.isKotlinWhitespace }
        return marks.count >= 3 && marks.allSatisfy { Character($0) == mark }
    }
    
    /// A table's delimiter row, such as `| --- | :-: |`.
    private static func isTableDelimiter(_ line: String) -> Bool {
        line.kotlinTrimmed.removingPrefix("|").removingSuffix("|").components(separatedBy: "|").allSatisfy { cell in
            let dashes = cell.kotlinTrimmed.removingPrefix(":").removingSuffix(":")
            return !dashes.isEmpty && dashes.allSatisfy { $0 == "-" }
        }
    }
    
    private static func depth(_ indent: String) -> Int {
        indent.replacingOccurrences(of: "\t", with: "    ").utf16.count / indentPerLevel
    }
    
    private static func cells(_ line: String) -> [String] {
        line.kotlinTrimmed.removingPrefix("|").removingSuffix("|").components(separatedBy: "|").map(\.kotlinTrimmed)
    }
    
    /// The capture groups of `pattern` matching the whole of `line` (empty strings for groups that took no part), or nil.
    private static func match(_ pattern: NSRegularExpression, _ line: String) -> [String]? {
        let text = line as NSString
        guard let result = pattern.firstMatch(in: line, range: NSRange(location: 0, length: text.length)) else { return nil }
        return (1..<max(result.numberOfRanges, 1)).map { index in
            let range = result.range(at: index)
            return range.location == NSNotFound ? "" : text.substring(with: range)
        }
    }
    
    // MARK: - Inline
    
    /// Inline Markdown as styled text, with links to open in the browser.
    static func inline(_ text: String) -> AttributedString {
        var output = AttributedString()
        appendInline(Array(text.utf16), style: Style(), to: &output)
        return output
    }
    
    private struct Style {
        var intent: InlinePresentationIntent = []
        var link: URL?
    }
    
    private static func appendInline(_ text: [UTF16.CodeUnit], style: Style, to output: inout AttributedString) {
        let search = ForwardSearch(text: text)
        var plain = [UTF16.CodeUnit]()
        var index = 0
        while index < text.count {
            if let token = token(text, search: search, start: index, style: style) {
                append(plain, style: style, to: &output)
                plain = []
                token.append(&output)
                index = token.end
            } else {
                plain.append(text[index])
                index += 1
            }
        }
        append(plain, style: style, to: &output)
    }
    
    private struct Token {
        let end: Int
        let append: (inout AttributedString) -> Void
    }
    
    /// The token starting at `start`, or nil when the character there is plain text.
    private static func token(_ text: [UTF16.CodeUnit], search: ForwardSearch, start: Int, style: Style) -> Token? { // swiftlint:disable:this cyclomatic_complexity
        let char = text[start]
        if char == ascii("\\"), start + 1 < text.count, escapable.contains(text[start + 1]) {
            return Token(end: start + 2) { append([text[start + 1]], style: style, to: &$0) }
        }
        if char == ascii("`") {
            var runEnd = start
            while runEnd < text.count, text[runEnd] == ascii("`") {
                runEnd += 1
            }
            let run = Array(text[start..<runEnd])
            let end = search.index(of: run, from: runEnd)
            if end > runEnd {
                var code = style
                code.intent.insert(.code)
                let content = Array(string(text[runEnd..<end]).kotlinTrimmed.utf16)
                return Token(end: end + run.count) { append(content, style: code, to: &$0) }
            }
            // A run that never closes is plain text, all of it.
            return Token(end: runEnd) { append(run, style: style, to: &$0) }
        }
        for (marker, intent) in [("**", InlinePresentationIntent.stronglyEmphasized), ("__", .stronglyEmphasized), ("~~", .strikethrough)] {
            let marker = Array(marker.utf16)
            guard text.hasPrefix(marker, at: start) else { continue }
            let end = search.index(of: marker, from: start + marker.count)
            if end > start + marker.count {
                var inner = style
                inner.intent.insert(intent)
                let content = Array(text[(start + marker.count)..<end])
                return Token(end: end + marker.count) { appendInline(content, style: inner, to: &$0) }
            }
        }
        if opensEmphasis(text, start) {
            let end = search.index(of: [char], from: start + 1)
            if end > start + 1, !isWhitespace(text[end - 1]) {
                var inner = style
                inner.intent.insert(.emphasized)
                let content = Array(text[(start + 1)..<end])
                return Token(end: end + 1) { appendInline(content, style: inner, to: &$0) }
            }
        }
        if char == ascii("[") || text.hasPrefix(Array("![".utf16), at: start) {
            let labelStart = char == ascii("!") ? start + 2 : start + 1
            let labelEnd = search.index(of: Array("](".utf16), from: labelStart)
            let urlEnd = labelEnd < 0 ? -1 : search.index(of: [ascii(")")], from: labelEnd + 2)
            if labelEnd >= 0, urlEnd > labelEnd {
                let url = string(text[(labelEnd + 2)..<urlEnd]).kotlinTrimmed.components(separatedBy: " ").first ?? ""
                // Images never load: their description stands in, as a link to the image.
                let label = Array(text[labelStart..<labelEnd])
                return Token(end: urlEnd + 1) { appendLink(label: label, url: url, style: style, to: &$0) }
            }
        }
        if char == ascii("<"),
           // An autolink holds no space and no '<', so the scan stops at the next one.
           let end = text.indices.dropFirst(start + 1).first(where: { text[$0] == ascii(">") || text[$0] == ascii("<") || isWhitespace(text[$0]) }),
           text[end] == ascii(">") {
            let url = string(text[(start + 1)..<end])
            if isSafe(url) {
                return Token(end: end + 1) { appendLink(label: Array(url.utf16), url: url, style: style, to: &$0) }
            }
        }
        if isBareLink(text, start) {
            let end = text.indices.dropFirst(start).first { isWhitespace(text[$0]) || text[$0] == ascii("<") } ?? text.count
            var url = Array(text[start..<end])
            while let last = url.last, Array(".,;:!?)".utf16).contains(last) {
                url.removeLast()
            }
            let link = string(url)
            return Token(end: start + url.count) { appendLink(label: url, url: link, style: style, to: &$0) }
        }
        return nil
    }
    
    /// A link; a bare address is its own label and is not read again as Markdown.
    private static func appendLink(label: [UTF16.CodeUnit], url: String, style: Style, to output: inout AttributedString) {
        let isBare = label.isEmpty || string(label) == url
        if isSafe(url), let link = URL(string: url) {
            var linked = style
            linked.link = link
            if isBare {
                append(Array(url.utf16), style: linked, to: &output)
            } else {
                appendInline(label, style: linked, to: &output)
            }
        } else if isBare {
            append(Array(url.utf16), style: style, to: &output)
        } else {
            appendInline(label, style: style, to: &output)
        }
    }
    
    private static func append(_ text: [UTF16.CodeUnit], style: Style, to output: inout AttributedString) {
        guard !text.isEmpty else { return }
        var run = AttributedString(string(text))
        if !style.intent.isEmpty {
            run.inlinePresentationIntent = style.intent
        }
        if let link = style.link {
            run.link = link
        }
        output.append(run)
    }
    
    /// `*` opens emphasis before a non-space; `_` only at the start of a word, so snake_case stays plain.
    private static func opensEmphasis(_ text: [UTF16.CodeUnit], _ start: Int) -> Bool {
        let char = text[start]
        let isMarker = char == ascii("*") || char == ascii("_") && isWordStart(text, start)
        return isMarker && start + 1 < text.count && !isWhitespace(text[start + 1])
    }
    
    private static func isBareLink(_ text: [UTF16.CodeUnit], _ start: Int) -> Bool {
        guard isWordStart(text, start) else { return false }
        let rest = string(text[start..<min(text.count, start + 8)]).lowercased()
        return rest.hasPrefix("https://") || rest.hasPrefix("http://")
    }
    
    private static func isSafe(_ url: String) -> Bool {
        let lowercased = url.lowercased()
        return safeSchemes.contains { lowercased.hasPrefix($0) } && !url.unicodeScalars.contains(where: \.isKotlinWhitespace)
    }
    
    private static func isWordStart(_ text: [UTF16.CodeUnit], _ index: Int) -> Bool {
        index == 0 || !isLetterOrDigit(text[index - 1])
    }
    
    /// Kotlin's `Char.isWhitespace()` for a UTF-16 code unit.
    private static func isWhitespace(_ unit: UTF16.CodeUnit) -> Bool {
        Unicode.Scalar(unit)?.isKotlinWhitespace ?? false
    }
    
    /// Kotlin's `Char.isLetterOrDigit()`: a surrogate is neither.
    private static func isLetterOrDigit(_ unit: UTF16.CodeUnit) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return [.uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber].contains(scalar.properties.generalCategory)
    }
    
    private static func string(_ units: some Collection<UTF16.CodeUnit>) -> String {
        String(utf16CodeUnits: Array(units), count: units.count)
    }
    
    private static func ascii(_ character: Unicode.Scalar) -> UTF16.CodeUnit {
        UTF16.CodeUnit(character.value)
    }
    
    /// `indexOf` for searches whose start only moves forward: each needle's last answer still holds until the start passes it, so
    /// text full of unmatched markers is read in linear time.
    private final class ForwardSearch {
        private let text: [UTF16.CodeUnit]
        private var last: [[UTF16.CodeUnit]: (from: Int, found: Int)] = [:]
        
        init(text: [UTF16.CodeUnit]) {
            self.text = text
        }
        
        /// The first index of `needle` at or after `start`, or -1.
        func index(of needle: [UTF16.CodeUnit], from start: Int) -> Int {
            if let (from, found) = last[needle], start >= from, found < 0 || start <= found {
                return found
            }
            let found = text.indices.dropFirst(start).first { text.hasPrefix(needle, at: $0) } ?? -1
            last[needle] = (start, found)
            return found
        }
    }
    
    // MARK: - Patterns
    
    // Java's `\s`, which the Android patterns use: ASCII whitespace only.
    private static let space = #"[ \t\x{0B}\f\r]"#
    // swiftlint:disable force_try
    private static let headingPattern = try! NSRegularExpression(pattern: #"^ {0,3}(#{1,6})(?:[ \t]+(.*))?$"#)
    private static let taskPattern = try! NSRegularExpression(pattern: #"^(\#(space)*)[-*+]\#(space)+\[([ xX])\]\#(space)+(.*)$"#)
    private static let bulletPattern = try! NSRegularExpression(pattern: #"^(\#(space)*)[-*+]\#(space)+(.*)$"#)
    private static let orderedPattern = try! NSRegularExpression(pattern: #"^(\#(space)*)(\d{1,9})[.)]\#(space)+(.*)$"#)
    private static let quotePattern = try! NSRegularExpression(pattern: #"^ {0,3}>\#(space)?(.*)$"#)
    private static let fencePattern = try! NSRegularExpression(pattern: #"^ {0,3}(```|~~~)"#)
    // swiftlint:enable force_try
    private static let indentPerLevel = 2
    private static let safeSchemes = ["https://", "http://", "mailto:"]
    private static let escapable = Set("\\`*_{}[]()#+-.!|~<>".utf16)
}

private nonisolated extension [UTF16.CodeUnit] {
    func hasPrefix(_ prefix: [UTF16.CodeUnit], at index: Int) -> Bool {
        index + prefix.count <= count && self[index..<(index + prefix.count)].elementsEqual(prefix)
    }
}

// Kotlin's trim and isBlank come from the MatchaProtocol package, which reads names the same way.
nonisolated extension String {
    func removingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
    
    func removingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
