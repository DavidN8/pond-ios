//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import Foundation
import MatchaProtocol
import MatrixRustSDK
import Testing

/// The `m.room.create` event of the notes test rooms, which every frame relates to.
let notesAnchor = "$create"
let notesSender = "@bob:x"
let notesRelation = #"{"rel_type": "m.reference", "event_id": "$create"}"#

/// A stand-in for the Yjs engine. An update is a JSON array of operations `{id, deps, text?, key?, value?}`: an operation applies
/// once every operation it depends on has, like Yjs's pending structs, and the last applied text wins.
final class FakeYjsEngine: YjsEngineProtocol {
    private(set) var documents: [FakeYjsDocument] = []
    var openError: YjsEngineError?
    /// Runs before each `applyAll` of any of its documents, which can stop that document first.
    var beforeApplyAll: ((FakeYjsDocument) async -> Void)?
    private let stoppedSubject = PassthroughSubject<Void, Never>()
    
    var stoppedPublisher: AnyPublisher<Void, Never> {
        stoppedSubject.eraseToAnyPublisher()
    }
    
    /// Stops the engine as an ended web content process does: every open document fails from now on.
    func stop() {
        documents.forEach { $0.isStopped = true }
        stoppedSubject.send()
    }
    
    func open() async throws(YjsEngineError) -> YjsDocumentProtocol {
        if let openError {
            throw openError
        }
        let document = FakeYjsDocument(engine: self)
        documents.append(document)
        return document
    }
    
    static func operation(_ id: String, text: String? = nil, deps: [String] = [], key: String? = nil, value: JSONObject? = nil) -> JSONValue {
        var operation: JSONObject = ["id": .string(id), "deps": .array(deps.map(JSONValue.string))]
        operation["text"] = text.map(JSONValue.string)
        operation["key"] = key.map(JSONValue.string)
        operation["value"] = value.map(JSONValue.object)
        return .object(operation)
    }
    
    static func update(_ operations: JSONValue...) -> Data {
        Data(JSONValue.array(operations).jsonString.utf8)
    }
}

final class FakeYjsDocument: YjsDocumentProtocol {
    private weak var engine: FakeYjsEngine?
    private(set) var isClosed = false
    /// Every call fails as on an ended web content process; `FakeYjsEngine.stop()` also says so.
    var isStopped = false
    private(set) var applyCount = 0
    private(set) var applyAllCount = 0
    private(set) var snapshotCount = 0
    private var text = ""
    private var entries: JSONObject = [:]
    private var appliedIDs: [String] = []
    private var pending: [JSONObject] = []
    private var localCount = 0
    
    init(engine: FakeYjsEngine) {
        self.engine = engine
    }
    
    func apply(_ update: Data) async throws(YjsEngineError) -> Bool {
        if isStopped {
            throw .stopped
        }
        guard case .array(let values)? = JSONValue(json: String(bytes: update, encoding: .utf8) ?? "") else { return false }
        let operations = values.compactMap(\.objectValue)
        guard operations.count == values.count else { return false }
        applyCount += 1
        pending += operations
        var progress = true
        while progress {
            progress = false
            var index = 0
            while index < pending.count {
                let operation = pending[index]
                if deps(operation).allSatisfy(appliedIDs.contains) {
                    pending.remove(at: index)
                    integrate(operation)
                    progress = true
                } else {
                    index += 1
                }
            }
        }
        return true
    }
    
    func applyAll(_ updates: [Data]) async throws(YjsEngineError) -> Int {
        await engine?.beforeApplyAll?(self)
        if isStopped {
            throw .stopped
        }
        applyAllCount += 1
        var applied = 0
        for update in updates {
            guard try await apply(update) else { break }
            applied += 1
        }
        return applied
    }
    
    func snapshot() async throws(YjsEngineError) -> YjsSnapshot {
        if isStopped {
            throw .stopped
        }
        snapshotCount += 1
        return YjsSnapshot(text: text, entries: entries, isMissingUpdates: !pending.isEmpty)
    }
    
    func edit(_ changes: [TextChange]) async throws(YjsEngineError) -> Data? {
        if isStopped {
            throw .stopped
        }
        guard !changes.isEmpty else { return nil }
        return local(FakeYjsEngine.operation(nextLocalID(), text: TextDiff.apply(changes, to: text), deps: Array(appliedIDs.suffix(1))))
    }
    
    func setEntry(key: String, value: JSONObject) async throws(YjsEngineError) -> Data? {
        if isStopped {
            throw .stopped
        }
        return local(FakeYjsEngine.operation(nextLocalID(), deps: Array(appliedIDs.suffix(1)), key: key, value: value))
    }
    
    func merge(_ updates: [Data]) async throws(YjsEngineError) -> Data {
        if isStopped {
            throw .stopped
        }
        let operations = updates.flatMap { update -> [JSONValue] in
            guard case .array(let values)? = JSONValue(json: String(bytes: update, encoding: .utf8) ?? "") else { return [] }
            return values
        }
        return Data(JSONValue.array(operations).jsonString.utf8)
    }
    
    func close() {
        isClosed = true
    }
    
    private func deps(_ operation: JSONObject) -> [String] {
        guard case .array(let deps)? = operation["deps"] else { return [] }
        return deps.compactMap(\.stringValue)
    }
    
    private func integrate(_ operation: JSONObject) {
        guard let id = operation.string("id"), !appliedIDs.contains(id) else { return }
        appliedIDs.append(id)
        if let text = operation.string("text") {
            self.text = text
        }
        if let key = operation.string("key"), let value = operation.object("value") {
            entries[key] = .object(value)
        }
    }
    
    private func nextLocalID() -> String {
        defer { localCount += 1 }
        return "local-\(localCount)-\(ObjectIdentifier(self).hashValue)"
    }
    
    private func local(_ operation: JSONValue) -> Data {
        if let operation = operation.objectValue {
            integrate(operation)
        }
        return Data(JSONValue.array([operation]).jsonString.utf8)
    }
}

/// A space room for the notes tests over `MatchaRoomFixture`: its info can change, its stored state answers the setup's reads,
/// and it hands out stores and document sessions over the fake engine.
final class NotesRoomFixture {
    let base: MatchaRoomFixture
    let info: CurrentValueSubject<RoomInfoProxyProtocol, Never>
    let engine = FakeYjsEngine()
    let reachability = CurrentValueSubject<HomeserverReachability, Never>(.reachable)
    /// Stored state contents by event type, for the empty state key.
    var stateEvents: [String: String] = [:]
    private(set) var sentState: [(type: String, content: String)] = []
    var enableEncryptionResult: Result<Void, RoomProxyError> = .success(())
    
    var room: JoinedRoomProxyMock {
        base.room
    }
    
    /// The scan timeline's items, oldest first.
    var items: [TimelineItemProxy] {
        get { base.items }
        set { base.items = newValue }
    }
    
    init(items: [TimelineItemProxy] = [],
         roomID: String = "!space:x",
         isSpace: Bool = true,
         isEncrypted: Bool = true,
         canSend: Bool = true,
         canSendState: Bool = false,
         createEventID: String? = notesAnchor) {
        base = MatchaRoomFixture(roomID: roomID, items: items, canSendState: canSendState)
        base.createEventID = createEventID
        var sentCount = 0
        base.sendResult = { _, _ in
            sentCount += 1
            return .success("$sent-\(sentCount)")
        }
        let roomInfo = base.roomInfo
        roomInfo.isSpace = isSpace
        roomInfo.isEncrypted = isEncrypted
        roomInfo.displayName = "Matcha team"
        (roomInfo.powerLevels as? RoomPowerLevelsProxyMock)?.canOwnUserSendMessageReturnValue = canSend
        info = .init(roomInfo)
        base.room.infoPublisher = info.asCurrentValuePublisher()
        base.room.stateEventsJSONTypeClosure = { [self] type in
            .success(stateEvents[type].map { ["": $0] } ?? [:])
        }
        base.room.sendRawStateEventTypeStateKeyContentJSONClosure = { [self] type, _, content in
            sentState.append((type, content))
            stateEvents[type] = content
            return .success("$state")
        }
        base.room.enableEncryptionClosure = { [self] in
            if case .success = enableEncryptionResult {
                stateEvents["m.room.encryption"] = #"{"algorithm": "m.megolm.v1.aes-sha2"}"#
            }
            return enableEncryptionResult
        }
    }
    
    /// The room's info changed, as a sync would say.
    func updateInfo(_ change: (RoomInfoProxyMock) -> Void) {
        change(base.roomInfo)
        info.send(base.roomInfo)
    }
    
    func store() -> MatchaRoomStore {
        base.store(readsDocumentAnchor: true)
    }
    
    func session(store: MatchaRoomStore? = nil, documentID: String = DocsProtocol.mainDocumentID, isReadOnly: Bool = false) -> RoomDocumentSession {
        var updateCount = 0
        return RoomDocumentSession(documentID: documentID,
                                   room: room,
                                   store: store ?? self.store(),
                                   engine: engine,
                                   reachability: reachability.asCurrentValuePublisher(),
                                   isReadOnly: isReadOnly) {
            defer { updateCount += 1 }
            return "\(documentID)-update-\(updateCount)"
        }
    }
    
    /// The notes context of this space over a new store, as `SpaceNotesContextFactory` makes one.
    func context(isEarlierChatDocument: Bool = false, newDocumentID: @escaping () -> String = { "33333333-3333-4333-8333-333333333333" }) -> SpaceNotesContext {
        let store = store()
        let catalogSession = isEarlierChatDocument ? nil : session(store: store, documentID: DocsProtocol.catalogDocumentID)
        return SpaceNotesContext(room: room,
                                 store: store,
                                 reachability: reachability.asCurrentValuePublisher(),
                                 catalogSession: catalogSession,
                                 catalog: catalogSession.map { DocumentCatalog(session: $0, room: room, clock: { 1000 }, newDocumentID: newDocumentID) }) { [self] in
            session(store: store, documentID: $0, isReadOnly: isEarlierChatDocument)
        }
    }
    
    /// Stored state that has notes turned on.
    func turnNotesOn() {
        stateEvents["m.room.encryption"] = #"{"algorithm": "m.megolm.v1.aes-sha2"}"#
        stateEvents[DocsProtocol.eventPowerLevels] = #"{"users": {"@admin:x": 100}, "events_default": 50, "events": {"com.matchahoneylatte.docs.update": 0, "m.room.encrypted": 0}}"#
    }
}

private var frameItemCount = 1000

/// A scan timeline item carrying a frame (or another event) related to the anchor.
func aFrameItem(_ eventID: String, content: String, sender: String = notesSender, type: String = MatchaConfig.eventDocsUpdate, timestamp: Int = 2) -> TimelineItemProxy {
    frameItemCount += 1
    let json = #"{"type": "\#(type)", "event_id": "\#(eventID)", "sender": "\#(sender)", "origin_server_ts": \#(timestamp), "content": \#(content)}"#
    return aTimelineItem(frameItemCount, json: json, eventID: eventID)
}

/// The frames of one update, as scan timeline items with the ids "<prefix>-0", "<prefix>-1" and so on.
func frameItems(_ prefix: String, update: Data, updateID: String, documentID: String = DocsProtocol.mainDocumentID, sender: String = notesSender, timestamp: Int = 2) throws -> [TimelineItemProxy] {
    try DocsProtocol.frames(update: update, anchor: notesAnchor, updateID: updateID, documentID: documentID).enumerated().map { index, frame in
        aFrameItem("\(prefix)-\(index)", content: frame, sender: sender, timestamp: timestamp)
    }
}

/// The single frame of a small update.
func aFrame(_ update: Data, updateID: String, documentID: String = DocsProtocol.mainDocumentID, anchor: String = notesAnchor) throws -> String {
    try #require(DocsProtocol.frames(update: update, anchor: anchor, updateID: updateID, documentID: documentID).first)
}

/// A catalog update naming `documentID`.
func aCatalogEntry(_ operationID: String, documentID: String, title: String, createdAt: Int64 = 1) -> Data {
    FakeYjsEngine.update(FakeYjsEngine.operation(operationID, key: documentID, value: ["title": .string(title), "createdAt": .integer(createdAt)]))
}

/// Waits until `condition` holds for `session`'s state, recording an issue when it doesn't within a few seconds.
@discardableResult
func waitForState(_ session: RoomDocumentSession,
                  sourceLocation: SourceLocation = #_sourceLocation,
                  where condition: @escaping @Sendable (DocumentSessionState) -> Bool) async -> DocumentSessionState? {
    let state = await firstValue(of: session.statePublisher, timeout: .seconds(10), where: condition)
    if state == nil {
        Issue.record("No state came that satisfies the condition: \(session.state)", sourceLocation: sourceLocation)
    }
    return state
}
