//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatchaProtocol
import MatrixRustSDK

/// The relations `fetchRelatedEventsJSON` can follow.
nonisolated enum RawRelationType {
    /// `m.reference`.
    case reference
    /// `m.thread`: the replies of a thread root.
    case thread
}

/// One page of raw event JSON, newest first.
nonisolated struct RawEventsPage: Equatable {
    let events: [String]
    /// The token of the next, older page, or nil at the end.
    let nextBatch: String?
}

/// The raw event reads and writes the Matcha features need, which `JoinedRoomProxy` and `ClientProxy` expose.
/// `fetchRelationsJson` and `fetchStateEventContentJson` exist only in the Matcha-patched Rust SDK.
extension RoomProtocol {
    func sendRawEvent(type: String, contentJSON: String) async -> Result<String, RoomProxyError> {
        do {
            return try await .success(sendRaw(eventType: type, content: contentJSON, requestConfigOverride: nil))
        } catch {
            MXLog.error("Failed sending a \(type) event with error: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    func sendRawStateEvent(type: String, stateKey: String, contentJSON: String) async -> Result<String, RoomProxyError> {
        do {
            return try await .success(sendStateEventRaw(eventType: type, stateKey: stateKey, content: contentJSON, requestConfigOverride: nil))
        } catch {
            MXLog.error("Failed sending a \(type) state event with error: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    func stateEventsJSON(type: String) async -> Result<[String: String], RoomProxyError> {
        do {
            let events = try await stateEvents(eventType: stateEventTypeFromString(s: type))
            return .success(Dictionary(events.map { ($0.stateKey, $0.contentJson) }) { _, last in last })
        } catch {
            MXLog.error("Failed reading the stored \(type) state with error: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    func storedStateEventID(type: String, stateKey: String) async -> Result<String?, RoomProxyError> {
        do {
            let events = try await stateEvents(eventType: stateEventTypeFromString(s: type))
            return .success(events.first { $0.stateKey == stateKey }?.eventId)
        } catch {
            MXLog.error("Failed reading the stored \(type) state with error: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    func fetchStateEventContentJSON(type: String, stateKey: String) async -> Result<String?, RoomProxyError> {
        do {
            return try await .success(fetchStateEventContentJson(eventType: type, stateKey: stateKey))
        } catch {
            MXLog.error("Failed fetching the \(type) state with error: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    func fetchRelatedEventsJSON(eventID: String, relation: RawRelationType, from: String?, limit: Int) async -> Result<RawEventsPage, RoomProxyError> {
        let relationType: RelationType = switch relation {
        case .reference: .reference
        case .thread: .thread
        }
        
        do {
            let page = try await fetchRelationsJson(eventId: eventID, relationType: relationType, from: from, limit: UInt32(clamping: limit))
            return .success(RawEventsPage(events: page.events, nextBatch: page.nextBatch))
        } catch {
            MXLog.error("Failed fetching the events related to \(eventID) with error: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    /// The SDK subscriptions end when the stream is dropped or the task iterating it is cancelled.
    func rawMessageLikeEvents(types: Set<String>) -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let handles = types.map { type in
            subscribeToMessageLikeEvents(eventType: messageLikeEventTypeFromString(s: type),
                                         listener: SDKListener { event in continuation.yield(event.rawJSON(type: type)) })
        }
        continuation.onTermination = { _ in
            handles.forEach { $0.cancel() }
        }
        return stream
    }
    
    /// A live timeline of only `types`, threaded events included. It shows no senders, so it doesn't fetch the room's members, as on
    /// Android.
    func eventTypesTimeline(types: Set<String>) async -> Result<TimelineProxyProtocol, RoomProxyError> {
        let filter = TimelineEventFilter.include(types.sorted().map { .eventType(timelineEventTypeFromString(s: $0)) })
        
        do {
            let sdkTimeline = try await timelineWithConfiguration(configuration: .init(focus: .live(hideThreadedEvents: false),
                                                                                       filter: .eventFilter(filter: filter),
                                                                                       internalIdPrefix: "event_types_",
                                                                                       dateDividerMode: .daily,
                                                                                       trackReadReceipts: .disabled,
                                                                                       reportUtds: true))
            let timeline = TimelineProxy(timeline: sdkTimeline, kind: .live, fetchesMembers: false)
            await timeline.subscribeForUpdates()
            return .success(timeline)
        } catch {
            MXLog.error("Failed creating a timeline of \(types.sorted()) with error: \(error)")
            return .failure(.sdkError(error))
        }
    }
}

nonisolated extension EventTimelineItemProxy {
    /// The event's JSON exactly as the SDK holds it, for the protocol parsers. `debugInfo.originalJSON` is not: it goes through
    /// `JSONSerialization`, which reads `1.0` as `1` and drops a leading U+FEFF, so it would accept events the other clients reject.
    var originalJSON: String? {
        item.lazyProvider.debugInfo().originalJson
    }
}

nonisolated extension RoomMessageLikeEvent {
    /// The event in the shape of a timeline event's JSON, for parsers that read `type`, `event_id`, `sender` and `content`.
    func rawJSON(type: String) -> String {
        "{\"type\":\(JSONValue.string(type).jsonString),\"event_id\":\(JSONValue.string(eventId).jsonString)," +
            "\"sender\":\(JSONValue.string(sender).jsonString),\"origin_server_ts\":\(timestamp),\"content\":\(contentJson)}"
    }
}

/// A room's whole state from the homeserver (`GET /rooms/{roomId}/state`), which the Rust SDK can't read: the sliding sync stores
/// only the state it asks for, and `fetchStateEventContentJson` reads one known state key at a time.
/// ponytail: app-level HTTP with the session's access token, so a token refresh the SDK hasn't finished fails it and callers fall
/// back to the SDK's reads; it downloads every state event, members included, so add an SDK call if big rooms make it slow.
nonisolated enum RoomStateRequest {
    enum Failure: Error {
        case invalidURL
        case status(Int)
        case notAnArrayOfEvents
    }
    
    private static let urlSession = URLSession(configuration: .ephemeral)
    // RFC 3986's unreserved characters: a room ID's `!` and `:` are escaped too.
    private static let pathSegmentAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    
    /// The contents of the room's state events of `type`, by state key.
    static func fetchContents(ofType type: String, roomID: String, session: Session) async throws -> [String: String] {
        guard let request = request(homeserverURL: session.homeserverUrl, accessToken: session.accessToken, roomID: roomID) else {
            throw Failure.invalidURL
        }
        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.status(status) }
        guard let contents = contents(ofType: type, in: data) else { throw Failure.notAnArrayOfEvents }
        return contents
    }
    
    static func request(homeserverURL: String, accessToken: String, roomID: String) -> URLRequest? {
        let base = homeserverURL.hasSuffix("/") ? String(homeserverURL.dropLast()) : homeserverURL
        guard let encodedRoomID = roomID.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed),
              let url = URL(string: base + "/_matrix/client/v3/rooms/\(encodedRoomID)/state"),
              ["https", "http"].contains(url.scheme) else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }
    
    /// The contents of the state events of `type` in a `/state` response, by state key; nil unless it is an array.
    static func contents(ofType type: String, in data: Data) -> [String: String]? {
        guard case .array(let events)? = String(data: data, encoding: .utf8).flatMap(JSONValue.init(json:)) else { return nil }
        var contents = [String: String]()
        for event in events {
            guard let event = event.objectValue, event.string("type") == type, let stateKey = event.string("state_key"),
                  let content = event["content"], content.objectValue != nil else { continue }
            contents[stateKey] = content.jsonString
        }
        return contents
    }
}
