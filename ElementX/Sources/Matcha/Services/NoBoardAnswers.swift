//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import MatchaProtocol

/// When the homeserver last said a chat has no board, so the Tasks tab doesn't ask every chat again each time it is shown. An
/// answer lasts `MatchaConfig.noBoardAnswerLifetime`; a board this client points a chat at forgets that chat's answer at once.
/// One per session, owned by `MatchaService`.
final class NoBoardAnswers {
    private nonisolated static let origin = ContinuousClock.now
    
    private let now: () -> Duration
    private var answeredAt: [String: Duration] = [:]
    /// Chats this client pointed at a board, until the Tasks tab, which may still hold "no board" for them, takes the news.
    private var pointedRoomIDs: Set<String> = []
    
    /// - Parameter now: monotonic time: a wall clock set back would keep an answer for far longer than its lifetime.
    init(now: @escaping () -> Duration = NoBoardAnswers.monotonicNow) {
        self.now = now
    }
    
    nonisolated static func monotonicNow() -> Duration {
        origin.duration(to: .now)
    }
    
    func isRecent(roomID: String) -> Bool {
        guard let answeredAt = answeredAt[roomID] else { return false }
        return (.zero..<MatchaConfig.noBoardAnswerLifetime).contains(now() - answeredAt)
    }
    
    func record(roomID: String) {
        answeredAt[roomID] = now()
    }
    
    func forget(roomID: String) {
        answeredAt[roomID] = nil
    }
    
    /// This client pointed `roomID` at a board: its answer is forgotten, and the Tasks tab checks the chat again.
    func pointed(roomID: String) {
        forget(roomID: roomID)
        pointedRoomIDs.insert(roomID)
    }
    
    /// Whether this client pointed `roomID` at a board since this was last asked.
    func takePointed(roomID: String) -> Bool {
        pointedRoomIDs.remove(roomID) != nil
    }
}
