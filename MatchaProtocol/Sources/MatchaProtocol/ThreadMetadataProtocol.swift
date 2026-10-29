//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

/// One shared change to a thread's name or archive state; absent fields are left as they were.
public struct ThreadMetadataPatch: Sendable, Hashable {
    public var name: String?
    public var archived: Bool?
    
    public init(name: String?, archived: Bool?) {
        self.name = name
        self.archived = archived
    }
}

/// Where a thread's name comes from.
public enum ThreadNameSource: String, Sendable {
    /// A member named the thread.
    case explicit
    /// Nobody named it; the root message text stands in.
    case rootBody = "root_body"
    /// Neither a name nor a readable root message exists; the name is the root event id.
    case eventID = "event_id"
}

/// A thread's resolved shared metadata.
public struct ThreadMetadata: Sendable, Hashable {
    public var name: String
    public var archived: Bool
    /// True when a member explicitly archived or restored the thread, as opposed to the default active state.
    public var archiveExplicit: Bool
    public var nameSource: ThreadNameSource
    
    public init(name: String, archived: Bool, archiveExplicit: Bool, nameSource: ThreadNameSource = .explicit) {
        self.name = name
        self.archived = archived
        self.archiveExplicit = archiveExplicit
        self.nameSource = nameSource
    }
}

public enum MatchaProtocolError: Error, Equatable {
    /// The content would break the protocol, e.g. an invalid name or title.
    case invalidArgument
    /// A document update larger than `MatchaConfig.docsMaxChunks` frames, or an empty one.
    case tooLarge
}

/// Thread names and archive state, shared with the other clients through `com.matchahoneylatte.thread.metadata` events.
/// Patches are encrypted timeline events related to the thread root; room state and redactions are never used.
public enum ThreadMetadataProtocol {
    public static func isValidName(_ value: String?) -> Bool {
        guard let value else { return false }
        return (1...MatchaConfig.threadNameMaxLength).contains(value.kotlinTrimmed.utf16Length)
    }
    
    /// Reads a patch for `rootID`, or nil when `event` is not a valid patch for that thread.
    public static func parsePatch(_ event: RawEvent, rootID: String) -> ThreadMetadataPatch? {
        guard !event.isRedacted, event.type == MatchaConfig.eventThreadMetadata else { return nil }
        let content = event.content
        guard content.integer("version") == 1, rootID.isSameID(content.referenceTarget) else { return nil }
        let name = content.string("name").flatMap { isValidName($0) ? $0.kotlinTrimmed : nil }
        let archived = content.bool("archived")
        guard name != nil || archived != nil else { return nil }
        return ThreadMetadataPatch(name: name, archived: archived)
    }
    
    /// The latest value of each field wins independently, so a rename never undoes a concurrent archive.
    ///
    /// - Parameters:
    ///   - rootID: the thread root event id, the name of last resort.
    ///   - rootBody: the root message body, used as the name until someone names the thread.
    ///   - patchesNewestFirst: the valid patches for this thread in server order, newest first.
    ///   - legacyArchived: the archive flag of the legacy state event, read only as a fallback.
    public static func resolve(rootID: String, rootBody: String?, patchesNewestFirst: [ThreadMetadataPatch], legacyArchived: Bool? = nil) -> ThreadMetadata {
        let name = patchesNewestFirst.lazy.compactMap(\.name).first
        let archived = patchesNewestFirst.lazy.compactMap(\.archived).first
        let shownName = name ?? fallbackName(rootBody: rootBody, rootID: rootID)
        let nameSource: ThreadNameSource = if name != nil {
            .explicit
        } else if shownName.isSameID(rootID) {
            .eventID
        } else {
            .rootBody
        }
        return ThreadMetadata(name: shownName,
                              archived: archived ?? (legacyArchived == true),
                              archiveExplicit: archived != nil || legacyArchived != nil,
                              nameSource: nameSource)
    }
    
    public static func fallbackName(rootBody: String?, rootID: String) -> String {
        let collapsed = rootBody?.collapsingASCIIWhitespace.kotlinTrimmed ?? ""
        return collapsed.isEmpty ? rootID : collapsed.utf16Prefix(MatchaConfig.threadNameMaxLength)
    }
    
    /// Content of a patch event changing only the given fields.
    public static func patchContent(rootID: String, name: String? = nil, archived: Bool? = nil) throws(MatchaProtocolError) -> String {
        guard name != nil || archived != nil, name == nil || isValidName(name) else { throw .invalidArgument }
        var content: JSONObject = ["version": .integer(1), "m.relates_to": reference(rootID)]
        if let name {
            content["name"] = .string(name.kotlinTrimmed)
        }
        if let archived {
            content["archived"] = .bool(archived)
        }
        return JSONValue.object(content).jsonString
    }
    
    /// Content of the root message of a new named thread: the name as plain text, like the web client's.
    public static func rootMessageContent(name: String) throws(MatchaProtocolError) -> String {
        guard isValidName(name) else { throw .invalidArgument }
        return JSONValue.object(["msgtype": .string("m.text"), "body": .string(name.kotlinTrimmed)]).jsonString
    }
    
    /// Content of the hidden first reply that makes the homeserver treat a new root as a thread before anyone replies.
    /// It is a thread reply, not a metadata patch: readers only consider `m.reference` relations.
    public static func bootstrapReplyContent(rootID: String, name: String) throws(MatchaProtocolError) -> String {
        guard isValidName(name) else { throw .invalidArgument }
        let content: JSONObject = [
            "version": .integer(1),
            "name": .string(name.kotlinTrimmed),
            "archived": .bool(false),
            "m.relates_to": .object([
                "rel_type": .string(MatchaConfig.relationTypeThread),
                "event_id": .string(rootID),
                "is_falling_back": .bool(true),
                "m.in_reply_to": .object(["event_id": .string(rootID)])
            ])
        ]
        return JSONValue.object(content).jsonString
    }
    
    /// The thread root of a hidden bootstrap reply (see `bootstrapReplyContent`), or nil for any other event.
    public static func bootstrapRootID(_ event: RawEvent) -> String? {
        guard event.type == MatchaConfig.eventThreadMetadata else { return nil }
        return event.content.relationTarget(MatchaConfig.relationTypeThread)
    }
    
    static func reference(_ eventID: String) -> JSONValue {
        .object(["rel_type": .string(MatchaConfig.relationTypeReference), "event_id": .string(eventID)])
    }
}
