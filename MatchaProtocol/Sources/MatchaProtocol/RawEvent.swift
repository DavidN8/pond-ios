//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

/// A decrypted Matrix event read from its raw JSON (as the SDK hands it over), with only the fields the protocol needs.
public struct RawEvent: Sendable, Hashable {
    public var type: String
    public var content: JSONObject
    public var eventID: String?
    public var senderID: String?
    public var timestamp: Int64?
    public var stateKey: String?
    public var isRedacted: Bool
    
    public init(type: String,
                content: JSONObject,
                eventID: String? = nil,
                senderID: String? = nil,
                timestamp: Int64? = nil,
                stateKey: String? = nil,
                isRedacted: Bool = false) {
        self.type = type
        self.content = content
        self.eventID = eventID
        self.senderID = senderID
        self.timestamp = timestamp
        self.stateKey = stateKey
        self.isRedacted = isRedacted
    }
    
    /// Parses a full event JSON object, or returns nil when it is not one.
    public init?(json: String?) {
        guard let json, let value = JSONValue(json: json) else { return nil }
        self.init(value: value)
    }
    
    /// Reads a full event, or returns nil when `value` is not an object with a string `type`.
    public init?(value: JSONValue) {
        guard let root = value.objectValue, let type = root.string("type") else { return nil }
        self.init(type: type,
                  content: root.object("content") ?? [:],
                  eventID: root.string("event_id"),
                  senderID: root.string("sender"),
                  timestamp: root.integer("origin_server_ts"),
                  stateKey: root.string("state_key"),
                  isRedacted: root.object("unsigned")?["redacted_because"] != nil)
    }
}
