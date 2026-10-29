//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import MatchaProtocol
import Testing

@MainActor
struct NoBoardAnswersTests {
    @Test
    func anAnswerLastsItsLifetimeOnTheMonotonicClock() {
        var now = Duration.seconds(1000)
        let answers = NoBoardAnswers { now }
        answers.record(roomID: "!a:x")
        
        #expect(answers.isRecent(roomID: "!a:x"))
        #expect(!answers.isRecent(roomID: "!b:x"))
        now += MatchaConfig.noBoardAnswerLifetime - .seconds(1)
        #expect(answers.isRecent(roomID: "!a:x"))
        now += .seconds(1)
        #expect(!answers.isRecent(roomID: "!a:x"))
    }
    
    @Test
    func aClockMovedBackDoesntStretchAnAnswer() {
        var now = Duration.seconds(1000)
        let answers = NoBoardAnswers { now }
        answers.record(roomID: "!a:x")
        
        now = .zero
        #expect(!answers.isRecent(roomID: "!a:x"))
    }
    
    @Test
    func pointingAChatAtABoardForgetsItsAnswerAndIsTakenOnce() {
        let answers = NoBoardAnswers { .zero }
        answers.record(roomID: "!a:x")
        
        answers.pointed(roomID: "!a:x")
        #expect(!answers.isRecent(roomID: "!a:x"))
        #expect(answers.takePointed(roomID: "!a:x"))
        #expect(!answers.takePointed(roomID: "!a:x"))
        #expect(!answers.takePointed(roomID: "!b:x"))
    }
    
    @Test
    func theDefaultClockMovesForward() async throws {
        let before = NoBoardAnswers.monotonicNow()
        try await Task.sleep(for: .milliseconds(10))
        #expect(NoBoardAnswers.monotonicNow() > before)
    }
}
