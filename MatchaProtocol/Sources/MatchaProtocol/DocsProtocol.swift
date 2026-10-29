//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// One part of a document update as sent in a `com.matchahoneylatte.docs.update` event.
public struct DocFrame: Sendable, Hashable {
    public enum Kind: String, Sendable {
        case update, chunk, commit
    }
    
    public var updateID: String
    public var kind: Kind
    public var chunks: Int
    /// Nil for a commit.
    public var chunk: Int?
    /// Nil for a commit.
    public var data: Data?
}

/// How a timeline event relates to one document.
public enum DocFrameResult: Sendable, Hashable {
    /// Not a frame of this document, or not related to its anchor: skipped.
    case unrelated
    /// A frame of this document that breaks the protocol, so the document can't be trusted.
    case invalid
    case frame(senderID: String, frame: DocFrame)
}

/// The parts of one update received so far, from one sender (see `DocsProtocol.packetKey`).
public struct DocPacket: Sendable, Hashable {
    public let count: Int
    public private(set) var parts: [Int: Data] = [:]
    public private(set) var isCommitted = false
    
    public init(count: Int) {
        self.count = count
    }
    
    public var isComplete: Bool {
        isCommitted && parts.count == count
    }
    
    /// This packet with `frame` added, or nil when the frame contradicts it: another part count, or a part sent again differently.
    public func adding(_ frame: DocFrame) -> DocPacket? {
        guard frame.chunks == count else { return nil }
        var packet = self
        if frame.kind != .chunk {
            packet.isCommitted = true
        }
        if let data = frame.data, let chunk = frame.chunk {
            if let previous = parts[chunk], previous != data {
                return nil
            }
            packet.parts[chunk] = data
        }
        return packet
    }
    
    /// The parts joined in order; only for a complete packet.
    public var update: Data {
        (0..<count).reduce(into: Data()) { $0.append(parts[$1] ?? Data()) }
    }
}

/// A document of a space, as named in its catalog.
public struct SpaceDocument: Sendable, Hashable {
    public var id: String
    /// The original main document has no name until someone names it; it is shown as "Space notes".
    public var title: String?
    public var createdAt: Int64
    
    public init(id: String, title: String?, createdAt: Int64) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
    }
}

/// The documents a catalog names, with `isInvalid` when an entry is malformed, which makes the whole catalog untrustworthy.
public struct CatalogDocuments: Sendable, Hashable {
    public var documents: [SpaceDocument]
    public var isInvalid: Bool
}

/// The Matcha documents wire protocol, identical to the web client's `documents.ts` and `documentCatalog.ts`: Yjs updates split
/// into frames related to the room's `m.room.create` event, a catalog document of names and the reserved `main` document.
public enum DocsProtocol {
    public static let mainDocumentID = "main"
    public static let catalogDocumentID = "catalog"
    public static let eventRoomEncrypted = "m.room.encrypted"
    public static let eventPowerLevels = "m.room.power_levels"
    public static let encryptionAlgorithm = "m.megolm.v1.aes-sha2"
    
    private static let maxDataLength = (MatchaConfig.docsChunkBytes + 2) / 3 * 4
    /// JavaScript's `Number.MAX_SAFE_INTEGER`, as the web client requires.
    private static let maxSafeInteger: Int64 = 9_007_199_254_740_991
    
    /// A user-facing document: the reserved main document or a lowercase UUID. The catalog is never one.
    public static func isDocumentID(_ value: String) -> Bool {
        let groups = value.split(separator: "-", omittingEmptySubsequences: false)
        let isUUID = groups.map(\.utf16.count) == [8, 4, 4, 4, 12] && groups.allSatisfy { $0.unicodeScalars.allSatisfy(\.isLowercaseHexDigit) }
        return value == mainDocumentID || isUUID
    }
    
    /// Surrounding whitespace is not part of a name.
    public static func isValidName(_ value: String) -> Bool {
        (1...MatchaConfig.documentNameMaxLength).contains(value.kotlinTrimmed.utf16Length)
    }
    
    /// Updates are told apart by sender and update id, so a frame or an update sent twice is applied once.
    public static func packetKey(senderID: String, updateID: String) -> String {
        "\(senderID):\(updateID)"
    }
    
    /// A frame this device can't decrypt (yet): its relation to `anchor` stays readable.
    public static func isUndecryptedFrame(_ event: RawEvent, anchor: String) -> Bool {
        event.type == eventRoomEncrypted && anchor.isSameID(event.content.referenceTarget)
    }
    
    /// Splits an update into frame contents; several frames end with a commit that is sent only after every part.
    public static func frames(update: Data, anchor: String, updateID: String, documentID: String) throws(MatchaProtocolError) -> [String] {
        let size = MatchaConfig.docsChunkBytes
        let count = (update.count + size - 1) / size
        guard (1...MatchaConfig.docsMaxChunks).contains(count) else { throw .tooLarge }
        func frame(_ kind: DocFrame.Kind, chunk: Int?) -> String {
            var content: JSONObject = [
                "version": .integer(1),
                "doc": .string(documentID),
                "update_id": .string(updateID),
                "kind": .string(kind.rawValue),
                "chunks": .integer(Int64(count)),
                "m.relates_to": ThreadMetadataProtocol.reference(anchor)
            ]
            if let chunk {
                let start = update.startIndex + chunk * size
                content["chunk"] = .integer(Int64(chunk))
                content["data"] = .string(update[start..<min(update.endIndex, start + size)].base64EncodedString())
            }
            return JSONValue.object(content).jsonString
        }
        let kind: DocFrame.Kind = count == 1 ? .update : .chunk
        return (0..<count).map { frame(kind, chunk: $0) } + (count > 1 ? [frame(.commit, chunk: nil)] : [])
    }
    
    /// Reads a frame of `documentID` related to `anchor`, validating it exactly like the web client.
    public static func parseFrame(_ event: RawEvent, anchor: String, documentID: String) -> DocFrameResult {
        let content = event.content
        guard event.type == MatchaConfig.eventDocsUpdate, anchor.isSameID(content.referenceTarget), content.string("doc") == documentID else { return .unrelated }
        guard !event.isRedacted, let senderID = event.senderID, let frame = parseHeader(content).flatMap({ parseBody(content, header: $0) }) else {
            return .invalid
        }
        return .frame(senderID: senderID, frame: frame)
    }
    
    /// Reads a catalog's "documents" map like the web client: valid entries plus the main document, oldest first.
    public static func catalogDocuments(_ entries: JSONObject) -> CatalogDocuments {
        var documents = [SpaceDocument]()
        var isInvalid = false
        for (id, value) in entries {
            if let document = catalogEntry(id: id, metadata: value.objectValue) {
                documents.append(document)
            } else {
                isInvalid = true
            }
        }
        // Existing spaces already have this document; it never needs a migration.
        if !documents.contains(where: { $0.id == mainDocumentID }) {
            documents.append(SpaceDocument(id: mainDocumentID, title: nil, createdAt: 0))
        }
        documents.sort { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        return CatalogDocuments(documents: documents, isInvalid: isInvalid)
    }
    
    // MARK: - Private
    
    /// The parts every frame has, as a commit; nil when any is invalid.
    private static func parseHeader(_ content: JSONObject) -> DocFrame? {
        guard let updateID = content.string("update_id"),
              updateID.consists(of: { $0.isASCIIAlphanumeric || $0 == "." || $0 == "_" || $0 == "-" }, lengths: 1...128),
              let chunks = content.integer("chunks"), (1...Int64(MatchaConfig.docsMaxChunks)).contains(chunks),
              let kind = content.string("kind").flatMap(DocFrame.Kind.init(rawValue:)),
              content.integer("version") == 1 else { return nil }
        return DocFrame(updateID: updateID, kind: kind, chunks: Int(chunks), chunk: nil, data: nil)
    }
    
    private static func parseBody(_ content: JSONObject, header: DocFrame) -> DocFrame? {
        let chunks = header.chunks
        if header.kind == .commit {
            return content["data"] == nil && content["chunk"] == nil && chunks >= 2 ? header : nil
        }
        let isSizeValid = header.kind == .update ? chunks == 1 : chunks >= 2
        guard isSizeValid,
              let chunk = content.integer("chunk"), (0..<Int64(chunks)).contains(chunk), header.kind != .update || chunk == 0,
              let data = content.string("data"), let bytes = decodeBase64(data),
              !bytes.isEmpty, bytes.count <= MatchaConfig.docsChunkBytes else { return nil }
        var frame = header
        frame.chunk = Int(chunk)
        frame.data = bytes
        return frame
    }
    
    /// Strict standard base64 with padding, like Kotlin's decoder: the padding bits must be zero.
    private static func decodeBase64(_ text: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
        let bytes = Array(text.utf8)
        let padding = bytes.reversed().prefix { $0 == UInt8(ascii: "=") }.count
        let body = bytes.dropLast(padding)
        guard !bytes.isEmpty, bytes.count <= maxDataLength, bytes.count % 4 == 0, padding <= 2,
              let last = body.last.flatMap(alphabet.firstIndex(of:)),
              body.allSatisfy(alphabet.contains),
              padding == 0 || last & (padding == 1 ? 0x03 : 0x0F) == 0 else { return nil }
        return Data(base64Encoded: text)
    }
    
    private static func catalogEntry(id: String, metadata: JSONObject?) -> SpaceDocument? {
        guard isDocumentID(id), let metadata,
              let title = metadata.string("title"), isValidName(title),
              let createdAt = metadata.integer("createdAt"), (0...maxSafeInteger).contains(createdAt) else { return nil }
        return SpaceDocument(id: id, title: title, createdAt: createdAt)
    }
}
