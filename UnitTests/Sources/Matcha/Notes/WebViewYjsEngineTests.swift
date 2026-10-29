//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import CryptoKit
@testable import ElementX
import Foundation
import MatchaProtocol
import Testing

/// The bundled Yjs engine in a real headless web view.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct WebViewYjsEngineTests {
    @Test
    func theBundledEngineIsTheAndroidOneTheChecksumsRecord() throws {
        let sums = try String(contentsOf: #require(Bundle.main.url(forResource: "MatchaDocsEngine.sha256", withExtension: "txt")), encoding: .utf8)
        let recorded = Dictionary(uniqueKeysWithValues: sums.split(whereSeparator: \.isNewline).map { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            return (String(parts[1]), String(parts[0]))
        })
        #expect(Set(recorded.keys) == ["engine.html", "engine.js"])
        for (file, sum) in recorded {
            let data = try Data(contentsOf: #require(Bundle.main.url(forResource: file, withExtension: nil)))
            #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == sum, "\(file)")
        }
    }
    
    @Test
    func editsMadeInOneDocumentApplyToAnotherAndBack() async throws {
        let engine = WebViewYjsEngine()
        let alice = try await engine.open()
        let bob = try await engine.open()
        defer { [alice, bob].forEach { $0.close() } }
        
        let hello = try #require(try await alice.edit([TextChange(index: 0, remove: 0, insert: "Hello 😀")]))
        #expect(try await bob.apply(hello))
        #expect(try await bob.snapshot() == YjsSnapshot(text: "Hello 😀", entries: [:], isMissingUpdates: false))
        
        // Indices are UTF-16 offsets: the emoji counts as two.
        let world = try #require(try await bob.edit([TextChange(index: 8, remove: 0, insert: " world"), TextChange(index: 0, remove: 1, insert: "J")]))
        #expect(try await alice.applyAll([world, world]) == 2)
        #expect(try await alice.snapshot().text == "Jello 😀 world")
        #expect(try await alice.edit([]) == nil)
        
        let entry = try #require(try await alice.setEntry(key: "11111111-1111-4111-8111-111111111111", value: ["title": .string("Plans"), "createdAt": .integer(5)]))
        let merged = try await alice.merge([hello, world, entry])
        let carol = try await engine.open()
        defer { carol.close() }
        #expect(try await carol.apply(merged))
        let snapshot = try await carol.snapshot()
        #expect(snapshot.text == "Jello 😀 world")
        #expect(snapshot.entries["11111111-1111-4111-8111-111111111111"] == .object(["title": .string("Plans"), "createdAt": .integer(5)]))
    }
    
    @Test
    func aMalformedUpdateIsRefusedAndAnUpdateMissingItsPredecessorsIsHeldBack() async throws {
        let engine = WebViewYjsEngine()
        let writer = try await engine.open()
        let reader = try await engine.open()
        defer { [writer, reader].forEach { $0.close() } }
        
        let first = try #require(try await writer.edit([TextChange(index: 0, remove: 0, insert: "One")]))
        let second = try #require(try await writer.edit([TextChange(index: 3, remove: 0, insert: " two")]))
        #expect(try await !reader.apply(Data("garbage".utf8)))
        #expect(try await reader.applyAll([Data([0xFF, 0x01]), first]) == 0)
        
        #expect(try await reader.apply(second))
        #expect(try await reader.snapshot().isMissingUpdates)
        #expect(try await reader.snapshot().text == "")
        #expect(try await reader.apply(first))
        #expect(try await reader.snapshot() == YjsSnapshot(text: "One two", entries: [:], isMissingUpdates: false))
    }
    
    @Test
    func aStoppedEngineFailsItsDocumentsAndTheNextOneStartsAgain() async throws {
        let engine = WebViewYjsEngine()
        let document = try await engine.open()
        _ = try await document.edit([TextChange(index: 0, remove: 0, insert: "Lost")])
        
        engine.killContentProcessForTesting()
        var stopped = false
        for _ in 0..<100 where !stopped {
            do {
                _ = try await document.snapshot()
                try? await Task.sleep(for: .milliseconds(50))
            } catch {
                stopped = error == .stopped
            }
        }
        #expect(stopped)
        document.close()
        
        let next = try await engine.open()
        defer { next.close() }
        #expect(try await next.snapshot().text == "")
    }
}

struct TextDiffTests {
    @Test
    func typingDeletingAndReplacingAreOneChange() {
        #expect(TextDiff.changes(from: "Hello", to: "Hello").isEmpty)
        #expect(TextDiff.changes(from: "Hello", to: "Hello!") == [TextChange(index: 5, remove: 0, insert: "!")])
        #expect(TextDiff.changes(from: "Hello", to: "Hllo") == [TextChange(index: 1, remove: 1, insert: "")])
        #expect(TextDiff.changes(from: "a cat sat", to: "a dog sat") == [TextChange(index: 2, remove: 3, insert: "dog")])
        #expect(TextDiff.changes(from: "", to: "New") == [TextChange(index: 0, remove: 0, insert: "New")])
    }
    
    @Test
    func aWrapKeepsTheWrappedText() {
        #expect(TextDiff.changes(from: "say hi now", to: "say **hi** now") == [TextChange(index: 4, remove: 0, insert: "**"), TextChange(index: 6, remove: 0, insert: "**")])
        #expect(TextDiff.changes(from: "link", to: "[link](https://)") == [TextChange(index: 0, remove: 0, insert: "["), TextChange(index: 4, remove: 0, insert: "](https://)")])
    }
    
    @Test
    func surrogatePairsAreNeverSplit() {
        let changes = TextDiff.changes(from: "a😀b", to: "a😃b")
        #expect(changes == [TextChange(index: 1, remove: 2, insert: "😃")])
        #expect(TextDiff.apply(changes, to: "a😀b") == "a😃b")
    }
    
    @Test
    func applyingChangesGivesTheEditedText() {
        for (before, after) in [("", "abc"), ("abc", ""), ("hello world", "hello brave new world"), ("x", "**x**"), ("one\ntwo", "- one\n- two"), ("é😀", "😀é")] {
            #expect(TextDiff.apply(TextDiff.changes(from: before, to: after), to: before) == after)
        }
    }
    
    @Test
    func editsAreMovedPastRemoteEditsBeforeThemAndDroppedWhenTheyOverlap() {
        let local = TextDiff.changes(from: "Hello", to: "Hello!")
        #expect(TextDiff.apply(TextDiff.rebase(local, from: "Hello", onto: "Oh Hello"), to: "Oh Hello") == "Oh Hello!")
        #expect(TextDiff.rebase(local, from: "Hello", onto: "Hello") == local)
        #expect(TextDiff.rebase(TextDiff.changes(from: "Hello", to: "Helxlo"), from: "Hello", onto: "Ho").isEmpty)
        let atStart = TextDiff.changes(from: "world", to: "Hi world")
        #expect(TextDiff.apply(TextDiff.rebase(atStart, from: "world", onto: "world!"), to: "world!") == "Hi world!")
    }
    
    @Test
    func aCursorKeepsItsPlaceAroundRemoteEdits() {
        let inserted = TextDiff.changes(from: "Hello", to: "Oh Hello")
        #expect(TextDiff.mapOffset(5, through: inserted) == 8)
        #expect(TextDiff.mapOffset(0, through: inserted) == 0)
        let replaced = TextDiff.changes(from: "a cat sat", to: "a dog sat")
        #expect(TextDiff.mapOffset(3, through: replaced) == 5)
        #expect(TextDiff.mapOffset(9, through: replaced) == 9)
        #expect(TextDiff.mapOffset(1, through: replaced) == 1)
    }
}
