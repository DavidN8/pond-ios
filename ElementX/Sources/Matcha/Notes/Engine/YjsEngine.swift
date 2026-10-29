//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import MatchaProtocol

/// Runs the Yjs documents of Matcha notes. Documents live in memory only.
protocol YjsEngineProtocol: AnyObject {
    /// Fires when the engine stopped on its own (its web content process ended): its open documents are gone, and `open()` starts a
    /// new one.
    var stoppedPublisher: AnyPublisher<Void, Never> { get }
    /// Opens a new, empty document. Throws `YjsEngineError` when the engine can't run.
    func open() async throws(YjsEngineError) -> YjsDocumentProtocol
}

/// One Yjs document, with its `Y.Text` "markdown" and its `Y.Map` "documents" (used by the catalog).
protocol YjsDocumentProtocol: AnyObject {
    /// Applies a remote update after checking it on a copy; false when the update is malformed and was not applied.
    func apply(_ update: Data) async throws(YjsEngineError) -> Bool
    /// Applies remote updates in order, each checked like `apply`, and stops at the first malformed one; returns how many applied.
    func applyAll(_ updates: [Data]) async throws(YjsEngineError) -> Int
    /// The current content, and whether updates are waiting for causal predecessors that have not arrived.
    func snapshot() async throws(YjsEngineError) -> YjsSnapshot
    /// Applies local text changes and returns the update they produced, or nil when nothing changed.
    func edit(_ changes: [TextChange]) async throws(YjsEngineError) -> Data?
    /// Sets an entry of the "documents" map and returns the update it produced, or nil when nothing changed.
    func setEntry(key: String, value: JSONObject) async throws(YjsEngineError) -> Data?
    /// Merges updates into one.
    func merge(_ updates: [Data]) async throws(YjsEngineError) -> Data
    func close()
}

nonisolated struct YjsSnapshot: Equatable, Sendable {
    var text: String
    var entries: JSONObject
    var isMissingUpdates: Bool
}

/// Replaces `remove` UTF-16 code units at `index` with `insert`; indices are UTF-16 offsets, as in JavaScript.
nonisolated struct TextChange: Equatable, Sendable {
    var index: Int
    var remove: Int
    var insert: String
}

/// The engine could not do what was asked. The engine's own message may quote document text, so it is never kept.
nonisolated enum YjsEngineError: Error, Equatable {
    /// The engine page did not load or stopped (its web content process ended); opening a document again starts a new one.
    case stopped
    case documentClosed
    case timedOut(operation: String)
    case failed(operation: String)
}
