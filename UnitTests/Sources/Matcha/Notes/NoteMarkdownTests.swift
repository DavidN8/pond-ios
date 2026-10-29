//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import SwiftUI
import Testing

struct MarkdownParserTests {
    @Test
    func blocksAreReadLineByLine() {
        let blocks = MarkdownParser.parse("""
        # Title
        Some text
        on two lines.
        
        - item
          - nested
        - [ ] todo
        - [x] done
        3. third
        > quoted
        > more
        ---
        ```
        code *not bold*
        ```
        | A | B |
        | --- | --- |
        | 1 | 2 |
        """)
        #expect(blocks == [.heading(level: 1, text: "Title"),
                           .paragraph("Some text on two lines."),
                           .listItem(depth: 0, marker: "•", text: "item"),
                           .listItem(depth: 1, marker: "•", text: "nested"),
                           .listItem(depth: 0, marker: "☐", text: "todo"),
                           .listItem(depth: 0, marker: "☑", text: "done"),
                           .listItem(depth: 0, marker: "3.", text: "third"),
                           .quote("quoted\nmore"),
                           .rule,
                           .code("code *not bold*"),
                           .table([["A", "B"], ["1", "2"]])])
    }
    
    @Test
    func anUnclosedFenceRunsToTheEndAndAnEmptyNoteHasNoBlocks() {
        #expect(MarkdownParser.parse("```\nlet x") == [.code("let x")])
        #expect(MarkdownParser.parse("").isEmpty)
        #expect(MarkdownParser.parse("\n\n").isEmpty)
    }
    
    @Test
    func inlineStylesAndLinks() {
        let text = MarkdownParser.inline("a **b** *c* ~~d~~ `e` [f](https://x.org) <https://y.org> https://z.org. [g](javascript:alert) \\*h")
        #expect(String(text.characters) == "a b c d e f https://y.org https://z.org. g *h")
        let bold = text.runs.first { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        #expect(bold.map { String(text[$0.range].characters) } == "b")
        let italic = text.runs.first { $0.inlinePresentationIntent?.contains(.emphasized) == true }
        #expect(italic.map { String(text[$0.range].characters) } == "c")
        // A script link is shown as plain text.
        #expect(text.runs.compactMap(\.link?.absoluteString) == ["https://x.org", "https://y.org", "https://z.org"])
    }
    
    @Test
    func aClosingRunOfHashesIsDroppedOnlyAfterASpace() {
        #expect(MarkdownParser.parse("## Plans ##\n# C#\n# ###\n#\n#hashtag") == [.heading(level: 2, text: "Plans"),
                                                                                  .heading(level: 1, text: "C#"),
                                                                                  .heading(level: 1, text: ""),
                                                                                  .heading(level: 1, text: ""),
                                                                                  .paragraph("#hashtag")])
    }
    
    @Test
    func rulesAndTableDelimiters() {
        #expect(MarkdownParser.parse("* * *\n___\n   ---\n    ---\n-- -x") == [.rule, .rule, .rule, .paragraph("--- -- -x")])
        guard case .table = MarkdownParser.parse("| A | B |\n|:--|--:|\n| 1 | 2 |").first else {
            Issue.record("Not a table")
            return
        }
        guard case .paragraph = MarkdownParser.parse("| A |\n| - - |").first else {
            Issue.record("Not a paragraph")
            return
        }
    }
    
    @Test
    func hostileTextIsReadInLinearTime() {
        let long = 10000
        let lines = ["# a" + String(repeating: " ", count: long) + "b",
                     String(repeating: "- ", count: long) + "x",
                     String(repeating: "|---", count: long) + "x",
                     String(repeating: "[", count: long),
                     String(repeating: "<", count: long) + ">",
                     String(repeating: "`", count: long),
                     String(repeating: "[a](", count: long),
                     String(repeating: "*a ", count: long)]
        let started = ContinuousClock.now
        for line in lines {
            for case .paragraph(let text) in MarkdownParser.parse(line) {
                _ = MarkdownParser.inline(text)
            }
        }
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(MarkdownParser.parse(lines[0]) == [.heading(level: 1, text: "a" + String(repeating: " ", count: long) + "b")])
        #expect(MarkdownParser.inline(String(repeating: "`", count: long)).characters.count == long)
    }
    
    @Test
    func snakeCaseWordsStayPlain() {
        let text = MarkdownParser.inline("use snake_case_name here")
        #expect(String(text.characters) == "use snake_case_name here")
        #expect(text.runs.allSatisfy { $0.inlinePresentationIntent == nil })
    }
}

struct MarkdownFormattingTests {
    @Test
    func inlineStylesWrapTheSelectionAndToggleOffAgain() {
        let bold = MarkdownFormatting.apply(.bold, to: FormattedText("say hi now", 4, 6))
        #expect(bold == FormattedText("say **hi** now", 6, 8))
        #expect(MarkdownFormatting.isActive(.bold, in: bold))
        #expect(!MarkdownFormatting.isActive(.italic, in: bold))
        #expect(MarkdownFormatting.apply(.bold, to: bold) == FormattedText("say hi now", 4, 6))
        #expect(MarkdownFormatting.apply(.bold, to: FormattedText("say **hi** now", 4, 10)) == FormattedText("say hi now", 4, 6))
        #expect(MarkdownFormatting.apply(.italic, to: FormattedText("a", 1)) == FormattedText("a**", 2))
        #expect(MarkdownFormatting.apply(.strikethrough, to: FormattedText("old", 0, 3)).text == "~~old~~")
        #expect(MarkdownFormatting.apply(.inlineCode, to: FormattedText("run x", 4, 5)).text == "run `x`")
    }
    
    @Test
    func italicNeverEatsHalfOfABoldPair() {
        let inBold = FormattedText("**hi**", 2, 4)
        #expect(!MarkdownFormatting.isActive(.italic, in: inBold))
        #expect(MarkdownFormatting.apply(.italic, to: inBold).text == "***hi***")
        #expect(MarkdownFormatting.apply(.italic, to: FormattedText("***hi***", 3, 5)).text == "**hi**")
    }
    
    @Test
    func lineStylesToggleAPrefixOnEverySelectedLine() {
        #expect(MarkdownFormatting.apply(.bulletList, to: FormattedText("one\ntwo", 0, 7)).text == "- one\n- two")
        #expect(MarkdownFormatting.apply(.bulletList, to: FormattedText("- one\n- two", 0, 11)).text == "one\ntwo")
        #expect(MarkdownFormatting.apply(.numberedList, to: FormattedText("- one\n- two", 0, 11)).text == "1. one\n2. two")
        #expect(MarkdownFormatting.apply(.checklist, to: FormattedText("1. one", 3)).text == "- [ ] one")
        #expect(MarkdownFormatting.apply(.quote, to: FormattedText("a\n\nb", 0, 4)).text == "> a\n\n> b")
        #expect(MarkdownFormatting.apply(.heading, to: FormattedText("Title", 2)) == FormattedText("# Title", 4))
        #expect(MarkdownFormatting.apply(.heading, to: FormattedText("## Title", 5)) == FormattedText("Title", 2))
        #expect(MarkdownFormatting.isActive(.checklist, in: FormattedText("text\n- [x] done", 12)))
        #expect(!MarkdownFormatting.isActive(.bulletList, in: FormattedText("text\n- [x] done", 12)))
        // Only the selected line changes.
        #expect(MarkdownFormatting.apply(.quote, to: FormattedText("one\ntwo\nthree", 5)).text == "one\n> two\nthree")
    }
    
    @Test
    func aCombiningMarkAfterTheIndentIsKept() {
        // The last space of the indent and the mark are one Character.
        #expect(MarkdownFormatting.apply(.bulletList, to: FormattedText("  \u{0301}x", 0)).text == "  - \u{0301}x")
        #expect(MarkdownFormatting.apply(.bulletList, to: FormattedText("  - \u{0301}x", 0)).text == "  \u{0301}x")
    }
    
    @Test
    func linksAndCodeBlocks() {
        #expect(MarkdownFormatting.apply(.link, to: FormattedText("see docs", 4, 8)) == FormattedText("see [docs](https://)", 11, 19))
        #expect(MarkdownFormatting.apply(.link, to: FormattedText("", 0)) == FormattedText("[](https://)", 1))
        #expect(MarkdownFormatting.apply(.codeBlock, to: FormattedText("a b", 2, 3)).text == "a \n```\nb\n```")
        #expect(MarkdownFormatting.apply(.codeBlock, to: FormattedText("x", 0, 1)).text == "```\nx\n```")
    }
}

struct EditEchoesTests {
    @Test
    func echoesOfEarlierKeystrokesNeverRollTheFieldBackWhileNewerOnesArePending() {
        var echoes = EditEchoes("")
        ["a", "ab", "abc"].forEach { echoes.sent($0) }
        #expect(["a", "a", "ab", "abc"].map { echoes.isBehindField($0) } == [true, true, true, false])
    }
    
    @Test
    func aChangeMadeElsewhereIsNotAnEcho() {
        var echoes = EditEchoes("x")
        var answers = [echoes.isBehindField("x by bob")]
        echoes.sent("xy")
        answers.append(echoes.isBehindField("x by bob"))
        echoes.reset("x by bob")
        answers.append(echoes.isBehindField("x by bob"))
        #expect(answers == [false, false, false])
    }
    
    @Test
    func aTextTypedTwiceIsMatchedInOrder() {
        var echoes = EditEchoes("x")
        ["xa", "x", "xb"].forEach { echoes.sent($0) }
        #expect(["x", "xb"].map { echoes.isBehindField($0) } == [true, false])
    }
}

struct NoteTextEditorTests {
    @Test
    func formattingCanBeUndone() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let textView = NoteUITextView()
        window.addSubview(textView)
        textView.text = "say hi"
        var edits = [String]()
        let coordinator = NoteTextEditor.Coordinator(text: "say hi") { _, after in edits.append(after) }
        textView.delegate = coordinator
        coordinator.textView = textView
        textView.selectedRange = NSRange(location: 4, length: 2)
        
        coordinator.apply(.bold)
        #expect(textView.text == "say **hi**")
        #expect(textView.selectedRange == NSRange(location: 6, length: 2))
        #expect(edits == ["say **hi**"])
        let undoManager = try #require(textView.undoManager)
        #expect(undoManager.canUndo)
        undoManager.undo()
        #expect(textView.text == "say hi")
    }
}
