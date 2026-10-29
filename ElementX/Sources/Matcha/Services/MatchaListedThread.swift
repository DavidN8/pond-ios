//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import MatchaProtocol
import MatrixRustSDK

/// A thread of the SDK's thread list as the Matcha room store reads it.
nonisolated struct MatchaListedThread: Sendable, Equatable {
    var thread: ListedThread
    /// Why the root can't be decrypted, when it can't and the SDK knows: it only tells for Megolm events.
    var rootUTDCause: UtdCause?
}

nonisolated extension MatchaListedThread {
    init(_ item: ThreadListItem) {
        var rootBody: String?
        var isRootUnreadable = false
        if case let .msgLike(content) = item.rootEvent.content {
            switch content.kind {
            case .message(let message):
                rootBody = message.body
            case .unableToDecrypt(let message):
                isRootUnreadable = true
                if case let .megolmV1AesSha2(_, cause) = message {
                    rootUTDCause = cause
                }
            default:
                break
            }
        }
        thread = ListedThread(id: item.rootEvent.eventId,
                              rootBody: rootBody,
                              rootSenderID: item.rootEvent.sender,
                              rootTimestamp: Int64(clamping: item.rootEvent.timestamp),
                              isRootUnreadable: isRootUnreadable,
                              latestSenderID: item.latestEvent?.sender,
                              latestTimestamp: item.latestEvent.map { Int64(clamping: $0.timestamp) },
                              numberOfReplies: Int(item.numReplies))
    }
}
