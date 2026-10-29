//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import MatchaProtocol
import Testing

struct ThreadMetadataProtocolTests {
    private static let root = "$root:example.org"
    private static let relation = #""m.relates_to": {"rel_type": "m.reference", "event_id": "\#(root)"}"#
    
    @Test
    func aPatchCarriesOnlyTheFieldsItChanges() throws {
        let rename = try event(#"{"version": 1, "name": "  Ship beta  ", \#(Self.relation)}"#)
        #expect(ThreadMetadataProtocol.parsePatch(rename, rootID: Self.root) == ThreadMetadataPatch(name: "Ship beta", archived: nil))
        let archive = try event(#"{"version": 1, "archived": true, \#(Self.relation)}"#)
        #expect(ThreadMetadataProtocol.parsePatch(archive, rootID: Self.root) == ThreadMetadataPatch(name: nil, archived: true))
    }
    
    @Test(arguments: [
        (#"{"version": 2, "name": "x", \#(relation)}"#, MatchaConfig.eventThreadMetadata, false),
        (#"{"version": 1, "name": "x", "m.relates_to": {"rel_type": "m.reference", "event_id": "$other"}}"#, MatchaConfig.eventThreadMetadata, false),
        (#"{"version": 1, "name": "x", "m.relates_to": {"rel_type": "m.thread", "event_id": "\#(root)"}}"#, MatchaConfig.eventThreadMetadata, false),
        (#"{"version": 1, "name": "x", \#(relation)}"#, "m.room.message", false),
        (#"{"version": 1, "name": "x", \#(relation)}"#, MatchaConfig.eventThreadMetadata, true),
        (#"{"version": 1, "name": "   ", \#(relation)}"#, MatchaConfig.eventThreadMetadata, false),
        (#"{"version": 1, "name": "\#(String(repeating: "a", count: 101))", \#(relation)}"#, MatchaConfig.eventThreadMetadata, false),
        (#"{"version": 1, "archived": "yes", \#(relation)}"#, MatchaConfig.eventThreadMetadata, false),
        (#"{"version": 1, \#(relation)}"#, MatchaConfig.eventThreadMetadata, false)
    ])
    func malformedUnrelatedAndRedactedPatchesAreIgnored(content: String, type: String, redacted: Bool) throws {
        #expect(try ThreadMetadataProtocol.parsePatch(event(content, type: type, redacted: redacted), rootID: Self.root) == nil)
    }
    
    @Test
    func theLatestValueOfEachFieldWinsIndependently() {
        let metadata = ThreadMetadataProtocol.resolve(rootID: Self.root,
                                                      rootBody: "Original body",
                                                      patchesNewestFirst: [ThreadMetadataPatch(name: nil, archived: true),
                                                                           ThreadMetadataPatch(name: "Newest name", archived: nil),
                                                                           ThreadMetadataPatch(name: "Older name", archived: false)])
        #expect(metadata == ThreadMetadata(name: "Newest name", archived: true, archiveExplicit: true))
    }
    
    @Test
    func aRestoreIsExplicitWhileTheDefaultActiveStateIsNot() {
        let restored = ThreadMetadataProtocol.resolve(rootID: Self.root, rootBody: "Body", patchesNewestFirst: [ThreadMetadataPatch(name: nil, archived: false)])
        #expect(restored.archiveExplicit)
        let untouched = ThreadMetadataProtocol.resolve(rootID: Self.root, rootBody: "Body", patchesNewestFirst: [])
        #expect(untouched == ThreadMetadata(name: "Body", archived: false, archiveExplicit: false, nameSource: .rootBody))
    }
    
    @Test
    func theLegacyStateFlagIsOnlyAFallback() {
        #expect(ThreadMetadataProtocol.resolve(rootID: Self.root, rootBody: "Body", patchesNewestFirst: [], legacyArchived: true).archived)
        let patched = ThreadMetadataProtocol.resolve(rootID: Self.root,
                                                     rootBody: "Body",
                                                     patchesNewestFirst: [ThreadMetadataPatch(name: nil, archived: false)],
                                                     legacyArchived: true)
        #expect(!patched.archived)
    }
    
    @Test
    func theNameSourceTellsASharedNameFromARootMessageAndAnEventID() {
        func source(_ body: String?, _ patches: [ThreadMetadataPatch]) -> ThreadNameSource {
            ThreadMetadataProtocol.resolve(rootID: Self.root, rootBody: body, patchesNewestFirst: patches).nameSource
        }
        #expect(source("Body", [ThreadMetadataPatch(name: "Named", archived: nil)]) == .explicit)
        #expect(source("Body", []) == .rootBody)
        #expect(source(nil, []) == .eventID)
        #expect(source("  ", []) == .eventID)
    }
    
    @Test
    func theFallbackNameCollapsesWhitespaceTruncatesAndFallsBackToTheRootID() {
        #expect(ThreadMetadataProtocol.fallbackName(rootBody: "Line one\n\n  line   two", rootID: Self.root) == "Line one line two")
        #expect(ThreadMetadataProtocol.fallbackName(rootBody: String(repeating: "x", count: 150), rootID: Self.root).count == 100)
        #expect(ThreadMetadataProtocol.fallbackName(rootBody: "   ", rootID: Self.root) == Self.root)
        #expect(ThreadMetadataProtocol.fallbackName(rootBody: nil, rootID: Self.root) == Self.root)
    }
    
    @Test
    func writtenPatchesRoundTripThroughTheReader() throws {
        let content = try ThreadMetadataProtocol.patchContent(rootID: Self.root, name: " Renamed ")
        #expect(try ThreadMetadataProtocol.parsePatch(event(content), rootID: Self.root) == ThreadMetadataPatch(name: "Renamed", archived: nil))
        #expect(JSONValue(json: content)?.objectValue?["archived"] == nil)
    }
    
    @Test
    func theBootstrapReplyIsAHiddenThreadReplyNotAMetadataPatch() throws {
        let content = try ThreadMetadataProtocol.bootstrapReplyContent(rootID: Self.root, name: "Plan")
        let relation = try #require(JSONValue(json: content)?.objectValue?.object("m.relates_to"))
        #expect(relation.string("rel_type") == "m.thread")
        #expect(relation.string("event_id") == Self.root)
        #expect(try ThreadMetadataProtocol.parsePatch(event(content), rootID: Self.root) == nil)
        #expect(try ThreadMetadataProtocol.bootstrapRootID(event(content)) == Self.root)
    }
    
    @Test
    func aNamedThreadsRootIsItsTrimmedName() throws {
        let root = try #require(JSONValue(json: ThreadMetadataProtocol.rootMessageContent(name: "  Plan  "))?.objectValue)
        #expect(root == ["msgtype": "m.text", "body": "Plan"])
        #expect(throws: MatchaProtocolError.invalidArgument) {
            try ThreadMetadataProtocol.rootMessageContent(name: "   ")
        }
    }
    
    // MARK: - Helpers
    
    private func event(_ content: String, type: String = MatchaConfig.eventThreadMetadata, redacted: Bool = false) throws -> RawEvent {
        let unsigned = redacted ? #", "unsigned": {"redacted_because": {}}"# : ""
        return try #require(RawEvent(json: #"{"type": "\#(type)", "event_id": "$e", "sender": "@a:b", "origin_server_ts": 1, "content": \#(content)\#(unsigned)}"#))
    }
}
