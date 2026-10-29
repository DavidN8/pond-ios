//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import MatchaProtocol

/// The outcome of creating a named thread.
enum NamedThreadResult: Equatable {
    case created(threadID: String)
    /// The root message was sent but the thread could not be set up; `MatchaRoomStore.retrySetup(threadID:name:)` tries again.
    case rootOnly(threadID: String)
    /// Nothing was sent.
    case failed
}

extension MatchaRoomStore {
    /// Sends the root message, then the hidden first reply that names it and makes it a thread, as the web client does. An
    /// invalid name sends nothing.
    func createNamedThread(name: String) async -> NamedThreadResult {
        guard let rootContent = try? ThreadMetadataProtocol.rootMessageContent(name: name) else { return .failed }
        let rootID: String
        switch await send(type: "m.room.message", contentJSON: rootContent) {
        case .success(let eventID):
            rootID = eventID
        case .failure(let error):
            MXLog.warning("Could not send the root of a new thread: \(error)")
            return .failed
        }
        switch await retrySetup(threadID: rootID, name: name) {
        case .success: return .created(threadID: rootID)
        case .failure: return .rootOnly(threadID: rootID)
        }
    }
    
    /// Sends the bootstrap reply of a named thread again, after `NamedThreadResult.rootOnly`.
    func retrySetup(threadID: String, name: String) async -> Result<Void, RoomProxyError> {
        let content: String
        do {
            content = try ThreadMetadataProtocol.bootstrapReplyContent(rootID: threadID, name: name)
        } catch {
            return .failure(.sdkError(error))
        }
        let result = await send(type: MatchaConfig.eventThreadMetadata, contentJSON: content)
        if case .failure(let error) = result {
            MXLog.warning("Could not set up the new thread \(threadID): \(error)")
        }
        return result.map { _ in }
    }
}
