//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import CryptoKit
import Foundation
@testable import MatchaProtocol
import Testing

/// Runs the protocol conformance fixtures shared with the Android and web clients (copied from element-x-android
/// `docs/matcha/fixtures` by `Scripts/sync-fixtures.sh`; their README describes the format): every case must give what this
/// package computes.
struct FixtureTests {
    static let directory = Bundle.module.url(forResource: "Fixtures", withExtension: nil)
    static let files: [String] = {
        guard let directory, let enumerator = FileManager.default.enumerator(atPath: directory.path) else { return [] }
        return enumerator.compactMap { $0 as? String }.filter { $0.hasSuffix(".json") }.sorted()
    }()
    
    @Test
    func theFixturesAreThere() {
        #expect(Self.files.count >= 20)
    }
    
    @Test(arguments: files)
    func everyCaseGivesWhatThePackageComputes(file: String) throws {
        let fixture = try #require(try JSONValue(json: String(contentsOf: url(file), encoding: .utf8))?.objectValue)
        let op = try #require(fixture.string("op"))
        guard case let .array(cases) = fixture["cases"] else {
            Issue.record("\(file) has no cases")
            return
        }
        for value in cases {
            let testCase = try #require(value.objectValue)
            let input = try #require(testCase.object("input"))
            let expected = testCase.filter { $0.key == "expect" || $0.key == "error" }
            let actual = outcome { try Self.evaluate(op, input) }
            // By code point: String's == would also accept canonically equivalent text.
            let (actualJSON, expectedJSON) = (JSONValue.object(actual).jsonString, JSONValue.object(expected).jsonString)
            #expect(actualJSON.unicodeScalars.elementsEqual(expectedJSON.unicodeScalars),
                    "\(file) \"\(testCase.string("name") ?? "?")\": expected \(expectedJSON), got \(actualJSON)")
        }
    }
    
    @Test
    func theChecksumsListEveryFixtureFile() throws {
        #expect(try String(contentsOf: url("SHA256SUMS"), encoding: .utf8) == checksums())
    }
    
    /// The copy matches the Android fork's fixtures, when that checkout is at hand (`MATCHA_FIXTURES_SOURCE`, or an
    /// element-x-android next to this repository or one of its parent directories).
    @Test(.enabled(if: sourceDirectory != nil))
    func theCopyMatchesTheAndroidFixtures() throws {
        let source = try #require(Self.sourceDirectory)
        let sourceChecksums = try String(contentsOf: source.appending(path: "SHA256SUMS"), encoding: .utf8)
        let copyChecksums = try checksums()
        #expect(sourceChecksums == copyChecksums, "Run MatchaProtocol/Scripts/sync-fixtures.sh")
    }
    
    /// In the fixtures' format, not shared with them: ids that differ by code point but are canonically equivalent (U+212A KELVIN
    /// SIGN and K) are two ids to Kotlin, which compares code units, and one to Swift's `String`. The expected values follow the
    /// Android `projectThreadsAndBoard`.
    @Test
    func idsDifferingOnlyByCodePointStayApart() throws {
        let input = try #require(JSONValue(json: #"""
        {
            "rootId": "$Kb", "viewer": "@me:x", "directMembers": [], "legacyArchive": {"$K2": true},
            "threads": [{"id": "$K1", "rootBody": "Root", "rootSender": "@bob:x", "latestSender": null, "lastActivity": 100}],
            "events": [
                {"type": "com.matchahoneylatte.thread.metadata", "event_id": "$e1", "sender": "@eve:x",
                 "content": {"version": 1, "name": "Crafted", "m.relates_to": {"rel_type": "m.reference", "event_id": "$\u212A1"}}},
                {"type": "com.matchahoneylatte.thread.metadata", "event_id": "$e2", "sender": "@eve:x",
                 "content": {"version": 1, "name": "Crafted", "archived": false, "m.relates_to": {"rel_type": "m.thread", "event_id": "$\u212A1"}}},
                {"type": "com.matchahoneylatte.kanban.card", "event_id": "$e3", "sender": "@eve:x",
                 "content": {"version": 1, "card_id": "c1", "title": "Card", "description": "", "column": "todo", "archived": false,
                             "show_to_room": true, "thread_id": "$\u212A1", "m.relates_to": {"rel_type": "m.reference", "event_id": "$Kb"}}},
                {"type": "com.matchahoneylatte.kanban.card", "event_id": "$e4", "sender": "@eve:x",
                 "content": {"version": 1, "card_id": "c2", "title": "Other board", "description": "", "column": "todo", "archived": false,
                             "show_to_room": true, "m.relates_to": {"rel_type": "m.reference", "event_id": "$\u212Ab"}}},
                {"type": "com.matchahoneylatte.kanban.card", "event_id": "$e5", "sender": "@eve:x",
                 "content": {"version": 1, "card_id": "c3", "title": "Second", "description": "", "column": "todo", "archived": false,
                             "show_to_room": true, "thread_id": "$\u212A2", "m.relates_to": {"rel_type": "m.reference", "event_id": "$Kb"}}}
            ]
        }
        """#)?.objectValue)
        func thread(_ id: String, _ name: String, archived: Bool = false, source: String, hidden: Bool = false, _ participants: [String] = []) -> String {
            #"{"id": "\#(id)", "name": "\#(name)", "archived": \#(archived), "archiveExplicit": \#(archived), "nameSource": "\#(source)", "#
                + #""hasHiddenFirstReply": \#(hidden), "participants": \#(participants)}"#
        }
        func card(_ id: String, _ title: String, thread: String, archived: Bool = false, hasRevision: Bool = true, _ participants: [String] = []) -> String {
            #"{"id": "\#(id)", "title": "\#(title)", "description": "", "status": "todo", "archived": \#(archived), "threadId": "\#(thread)", "#
                + #""dueAt": null, "reminderRequested": null, "showToRoom": true, "hasRevision": \#(hasRevision), "earlierCardIds": [], "#
                + #""participants": \#(participants), "isShownToViewer": true}"#
        }
        let threads = [thread("$K1", "Root", source: "root_body", ["@bob:x"]),
                       thread(#"$\u212A1"#, "Crafted", source: "explicit", hidden: true, ["@eve:x"]),
                       thread(#"$\u212A2"#, "Second", source: "root_body"),
                       thread("$K2", "$K2", archived: true, source: "event_id")]
        let cards = [card(KanbanProtocol.threadCardID("$K1"), "Root", thread: "$K1", hasRevision: false, ["@bob:x"]),
                     card("c1", "Crafted", thread: #"$\u212A1"#, ["@eve:x"]),
                     card("c3", "Second", thread: #"$\u212A2"#),
                     card(KanbanProtocol.threadCardID("$K2"), "$K2", thread: "$K2", archived: true, hasRevision: false)]
        let expected = try #require(JSONValue(json: #"{"threads": [\#(threads.joined(separator: ","))], "cards": [\#(cards.joined(separator: ","))]}"#))
        
        let actual = try Self.evaluate("kanban.board", input)
        #expect(actual.jsonString.unicodeScalars.elementsEqual(expected.jsonString.unicodeScalars), "expected \(expected.jsonString), got \(actual.jsonString)")
        let encrypted = try #require(RawEvent(json: #"{"type": "m.room.encrypted", "content": {"m.relates_to": {"rel_type": "m.reference", "event_id": "$\u212A"}}}"#))
        #expect(!DocsProtocol.isUndecryptedFrame(encrypted, anchor: "$K"))
        let update = try #require(RawEvent(json: #"{"type": "com.matchahoneylatte.docs.update", "sender": "@eve:x", "content": {"doc": "main", "m.relates_to": {"rel_type": "m.reference", "event_id": "$K"}}}"#))
        #expect(DocsProtocol.parseFrame(update, anchor: "$K", documentID: "main") == .unrelated)
        let patch = try #require(RawEvent(json: #"{"type": "com.matchahoneylatte.thread.metadata", "content": {"version": 1, "name": "Crafted", "m.relates_to": {"rel_type": "m.reference", "event_id": "$K"}}}"#))
        #expect(ThreadMetadataProtocol.parsePatch(patch, rootID: "$K") == nil)
        // A crafted card title can stand in for a thread's root body; one equivalent to the id is still a root body to Kotlin.
        #expect(ThreadMetadataProtocol.resolve(rootID: "$K", rootBody: "$\u{212A}", patchesNewestFirst: []).nameSource == .rootBody)
    }
    
    // MARK: - Helpers
    
    static let sourceDirectory: URL? = {
        func isFixtures(_ directory: URL) -> Bool {
            FileManager.default.fileExists(atPath: directory.appending(path: "SHA256SUMS").path)
        }
        if let source = ProcessInfo.processInfo.environment["MATCHA_FIXTURES_SOURCE"].map({ URL(filePath: $0) }) {
            return isFixtures(source) ? source : nil
        }
        // Walking up also finds the checkout from a worktree kept elsewhere, such as element-group/worktrees/ios-*.
        let ancestors = sequence(first: URL(filePath: #filePath).deletingLastPathComponent()) { $0.pathComponents.count > 1 ? $0.deletingLastPathComponent() : nil }
        return ancestors.lazy.map { $0.appending(path: "element-x-android/docs/matcha/fixtures") }.first(where: isFixtures)
    }()
    
    private func url(_ path: String) throws -> URL {
        try #require(Self.directory).appending(path: path)
    }
    
    /// In the format of `shasum -a 256`.
    private func checksums() throws -> String {
        try Self.files.map { file in
            let digest = try SHA256.hash(data: Data(contentsOf: url(file))).map { String(format: "%02x", $0) }.joined()
            return "\(digest)  \(file)\n"
        }.joined()
    }
    
    /// A case's outcome: the value computed, or the code of the error raised.
    private func outcome(_ evaluate: () throws -> JSONValue) -> JSONObject {
        do {
            return try ["expect": evaluate()]
        } catch MatchaProtocolError.invalidArgument {
            return ["error": .string("invalid_argument")]
        } catch MatchaProtocolError.tooLarge {
            return ["error": .string("too_large")]
        } catch let error as FixtureError {
            return ["error": .string(error.code)]
        } catch {
            return ["error": .string("\(error)")]
        }
    }
}

struct FixtureError: Error {
    let code: String
}

// MARK: - Operations

extension FixtureTests {
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func evaluate(_ op: String, _ input: JSONObject) throws -> JSONValue {
        switch op {
        case "thread_metadata.parse_patch":
            return input.event.flatMap { ThreadMetadataProtocol.parsePatch($0, rootID: input.text("rootId")) }.json
        case "thread_metadata.resolve":
            let rootID = input.text("rootId")
            let patches = input.events.compactMap { ThreadMetadataProtocol.parsePatch($0, rootID: rootID) }
            return ThreadMetadataProtocol.resolve(rootID: rootID, rootBody: input.string("rootBody"), patchesNewestFirst: patches,
                                                  legacyArchived: input.bool("legacyArchived")).json
        case "thread_metadata.patch_content":
            return try content(ThreadMetadataProtocol.patchContent(rootID: input.text("rootId"), name: input.string("name"), archived: input.bool("archived")))
        case "thread_metadata.bootstrap_reply_content":
            return try content(ThreadMetadataProtocol.bootstrapReplyContent(rootID: input.text("rootId"), name: input.text("name")))
        case "thread_metadata.bootstrap_root":
            return JSONValue(input.event.flatMap(ThreadMetadataProtocol.bootstrapRootID))
        case "kanban.board_pointer":
            return JSONValue(KanbanProtocol.parseBoardPointer(input["content"]?.objectValue))
        case "kanban.parse_card":
            return input.event.flatMap { KanbanProtocol.parseCard($0, rootID: input.text("rootId")) }.map(\.json) ?? .null
        case "kanban.card_content":
            return try content(KanbanProtocol.cardContent(input.object("card")?.card ?? invalidFixture(), rootID: input.text("rootId")))
        case "kanban.thread_card_id":
            return .string(KanbanProtocol.threadCardID(input.text("threadId")))
        case "kanban.board":
            return board(input)
        case "tasks.local_deadline":
            let deadline = try KanbanProtocol.deadline(dateComponents(input.text("dateTime")), in: timeZone(input))
            return switch deadline {
            case .valid(let epochMillis): .object(["result": "valid", "epochMillis": .integer(epochMillis)])
            case .skipped: .object(["result": "skipped"])
            case .outOfRange: .object(["result": "out_of_range"])
            }
        case "reminders.command":
            return try .string(ReminderProtocol.command(reminderTime(input), message: input.text("message")))
        case "reminders.is_valid":
            let time = try reminderTime(input)
            let now = input.integer("now") ?? 0
            return .object(["dueAt": .integer(ReminderProtocol.dueAt(time, now: now)),
                            "isValid": .bool(ReminderProtocol.isValid(time, message: input.text("message"), now: now))])
        case "reminders.validate":
            let error = ReminderProtocol.validationError(dueAt: input.integer("dueAt"), message: input.text("message"),
                                                         maxMessageLength: Int(input.integer("maxMessageLength") ?? 0), now: input.integer("now") ?? 0)
            return JSONValue(error?.rawValue)
        case "reminders.local_instant":
            let instant = try ReminderProtocol.localInstant(dateComponents("\(input.text("date"))T\(input.text("time"))"), in: timeZone(input))
            return instant.map(JSONValue.integer) ?? .null
        case "reminders.parse_acknowledgement":
            return ReminderProtocol.parseAcknowledgement(input.string("body")).map { .object(["reminderId": .string($0.reminderID), "dueAt": .integer($0.dueAt)]) } ?? .null
        case "reminders.with_link":
            return .string(ReminderProtocol.withLink(input.text("message"), link: input.string("link")))
        case "docs.frames":
            let update = try Data(base64Encoded: input.text("update")) ?? invalidFixture()
            let frames = try DocsProtocol.frames(update: update, anchor: input.text("anchor"), updateID: input.text("updateId"), documentID: input.text("documentId"))
            return try .array(frames.map(content))
        case "docs.parse_frame":
            let event = try input.event ?? { throw FixtureError(code: "not_an_event") }()
            return switch DocsProtocol.parseFrame(event, anchor: input.text("anchor"), documentID: input.text("documentId")) {
            case .unrelated: .object(["result": "unrelated"])
            case .invalid: .object(["result": "invalid"])
            case .frame(let senderID, let frame):
                .object(["result": "frame", "senderId": .string(senderID), "updateId": .string(frame.updateID), "kind": .string(frame.kind.rawValue),
                         "chunks": .integer(Int64(frame.chunks)), "chunk": JSONValue(frame.chunk.map(Int64.init)),
                         "data": JSONValue(frame.data?.base64EncodedString())])
            }
        case "docs.assemble":
            return try assemble(input)
        case "docs.catalog":
            let catalog = DocsProtocol.catalogDocuments(input.object("entries") ?? [:])
            let documents = catalog.documents.map { JSONValue.object(["id": .string($0.id), "title": JSONValue($0.title), "createdAt": .integer($0.createdAt)]) }
            return .object(["documents": .array(documents), "isInvalid": .bool(catalog.isInvalid)])
        default:
            throw FixtureError(code: "unknown op \(op)")
        }
    }
    
    /// A room's threads and board as the store builds them (see the fixture's description). Each listed thread's latest activity is
    /// its latest reply's time, or its root's without a reply.
    private static func board(_ input: JSONObject) -> JSONValue {
        let threadList = input.array("threads").compactMap(\.objectValue).map { thread in
            let lastActivity = thread.integer("lastActivity") ?? 0
            let latestSenderID = thread.string("latestSender")
            return ListedThread(id: thread.text("id"), rootBody: thread.string("rootBody"), rootSenderID: thread.text("rootSender"),
                                rootTimestamp: lastActivity, latestSenderID: latestSenderID, latestTimestamp: latestSenderID.map { _ in lastActivity },
                                numberOfReplies: 0)
        }
        let legacyArchive = (input.object("legacyArchive") ?? [:]).compactMapValues { value -> Bool? in
            if case let .bool(archived) = value {
                archived
            } else {
                nil
            }
        }
        let (threads, board) = RoomProjection.threadsAndBoard(events: input.events,
                                                              boardRootID: input.text("rootId"),
                                                              threadList: threadList,
                                                              threadRepliers: [:],
                                                              legacyArchive: legacyArchive,
                                                              directMembers: Set(input.array("directMembers").compactMap(\.stringValue)))
        let viewer = input.text("viewer")
        return .object([
            "threads": .array(threads.map { thread in
                guard case var .object(json) = thread.metadata.json else { return .null }
                json["id"] = .string(thread.id)
                json["hasHiddenFirstReply"] = .bool(thread.hasHiddenFirstReply)
                json["participants"] = .array(thread.participants.sorted().map(JSONValue.string))
                return .object(json)
            }),
            "cards": .array((board?.cards ?? []).map { $0.json(viewer: viewer) })
        ])
    }
    
    /// Reassembles the updates the frames complete, the way the Android `RoomDocumentSession` ingests them.
    private static func assemble(_ input: JSONObject) throws -> JSONValue {
        let anchor = input.text("anchor")
        let documentID = input.text("documentId")
        var seen = Set<String>()
        var applied = Set<String>()
        var incoming = [String: DocPacket]()
        var updates = [JSONValue]()
        // Each event is read once by event id; events without one are skipped.
        for event in input.events {
            guard let eventID = event.eventID, seen.insert(eventID).inserted else { continue }
            if DocsProtocol.isUndecryptedFrame(event, anchor: anchor) {
                throw FixtureError(code: "decrypt_error")
            }
            switch DocsProtocol.parseFrame(event, anchor: anchor, documentID: documentID) {
            case .unrelated:
                break
            case .invalid:
                throw FixtureError(code: "invalid_update")
            case .frame(let senderID, let frame):
                let key = DocsProtocol.packetKey(senderID: senderID, updateID: frame.updateID)
                guard !applied.contains(key) else { break }
                guard let packet = (incoming[key] ?? DocPacket(count: frame.chunks)).adding(frame) else { throw FixtureError(code: "invalid_update") }
                if packet.isComplete {
                    updates.append(.string(packet.update.base64EncodedString()))
                    applied.insert(key)
                    incoming[key] = nil
                } else {
                    incoming[key] = packet
                }
            }
        }
        func keys(committed: Bool) -> JSONValue {
            .array(incoming.filter { $0.value.isCommitted == committed }.keys.sorted().map(JSONValue.string))
        }
        return .object(["updates": .array(updates), "missing": keys(committed: true), "pending": keys(committed: false)])
    }
    
    private static func content(_ json: String) throws -> JSONValue {
        try JSONValue(json: json) ?? invalidFixture()
    }
    
    private static func reminderTime(_ input: JSONObject) throws -> ReminderTime {
        let time = input.object("time") ?? [:]
        if let at = time.integer("at") {
            return .at(epochMillis: at)
        }
        guard let amount = time.integer("in"), let unit = time.string("unit").flatMap(ReminderUnit.init(rawValue:)) else { return try invalidFixture() }
        return .after(amount: amount, unit: unit)
    }
    
    /// `yyyy-MM-ddTHH:mm`.
    private static func dateComponents(_ text: String) throws -> DateComponents {
        let numbers = text.split { "-T:".contains($0) }.compactMap { Int($0) }
        guard numbers.count == 5 else { return try invalidFixture() }
        return DateComponents(year: numbers[0], month: numbers[1], day: numbers[2], hour: numbers[3], minute: numbers[4])
    }
    
    private static func timeZone(_ input: JSONObject) throws -> TimeZone {
        try TimeZone(identifier: input.text("timeZone")) ?? invalidFixture()
    }
    
    private static func invalidFixture<T>() throws -> T {
        throw FixtureError(code: "invalid fixture input")
    }
}

// MARK: - JSON

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
    
    init(_ value: String?) {
        self = value.map(JSONValue.string) ?? .null
    }
    
    init(_ value: Int64?) {
        self = value.map(JSONValue.integer) ?? .null
    }
    
    init(_ value: Bool?) {
        self = value.map(JSONValue.bool) ?? .null
    }
}

private extension JSONObject {
    var event: RawEvent? {
        self["event"].flatMap(RawEvent.init(value:))
    }
    
    var events: [RawEvent] {
        array("events").compactMap(RawEvent.init(value:))
    }
    
    func text(_ key: String) -> String {
        string(key) ?? ""
    }
    
    func array(_ key: String) -> [JSONValue] {
        if case let .array(values) = self[key] {
            values
        } else {
            []
        }
    }
    
    var card: CardRevision? {
        guard let status = string("status").flatMap(TaskStatus.init(rawValue:)), let archived = bool("archived"), let showToRoom = bool("showToRoom") else { return nil }
        let request = object("reminderRequested").flatMap { request in
            request.integer("at").map { ReminderRequestRef(eventID: request.text("eventId"), at: $0) }
        }
        return CardRevision(cardID: text("cardId"), title: text("title"), description: text("description"), status: status, archived: archived,
                            threadID: string("threadId"), dueAt: integer("dueAt"), reminderRequested: request, showToRoom: showToRoom)
    }
}

private extension ThreadMetadataPatch? {
    var json: JSONValue {
        map { .object(["name": JSONValue($0.name), "archived": JSONValue($0.archived)]) } ?? .null
    }
}

private extension ThreadMetadata {
    var json: JSONValue {
        .object(["name": .string(name), "archived": .bool(archived), "archiveExplicit": .bool(archiveExplicit), "nameSource": .string(nameSource.rawValue)])
    }
}

private extension ReminderRequestRef? {
    var json: JSONValue {
        map { .object(["eventId": .string($0.eventID), "at": .integer($0.at)]) } ?? .null
    }
}

private extension CardRevision {
    var json: JSONValue {
        .object(["cardId": .string(cardID), "title": .string(title), "description": .string(description), "status": .string(status.rawValue),
                 "archived": .bool(archived), "threadId": JSONValue(threadID), "dueAt": JSONValue(dueAt), "reminderRequested": reminderRequested.json,
                 "showToRoom": .bool(showToRoom)])
    }
}

private extension ProjectedCard {
    func json(viewer: String) -> JSONValue {
        .object(["id": .string(id), "title": .string(title), "description": .string(description), "status": .string(status.rawValue),
                 "archived": .bool(archived), "threadId": JSONValue(threadID), "dueAt": JSONValue(dueAt), "reminderRequested": reminderRequested.json,
                 "showToRoom": .bool(showToRoom), "hasRevision": .bool(hasRevision), "earlierCardIds": .array(earlierCards.map { .string($0.cardID) }),
                 "participants": .array(participants.sorted().map(JSONValue.string)), "isShownToViewer": .bool(isShownOnBoard(userID: viewer))])
    }
}
