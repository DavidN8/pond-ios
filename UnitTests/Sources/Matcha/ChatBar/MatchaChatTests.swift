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
import Testing

@MainActor
struct MatchaChatTests {
    @Test
    func theChatHasAChipBarOnceAnActiveThreadIsNamed() async throws {
        let fixture = try MatchaRoomFixture(items: [aThreadPatchItem(1, threadID: "$t1", name: "Plan")], threads: [aThreadListItem("$t1")])
        let store = fixture.store()
        await store.settle()
        
        #expect(store.snapshot.hasChatBar)
        #expect(store.snapshot.threadInfos["$t1"] == MatchaThreadInfo(name: "Plan", isNamed: true, isArchived: false, hiddenReplies: 0))
    }
    
    @Test
    func aThreadNamedWhenItWasCreatedGivesAChipBarThroughItsHiddenFirstReply() async throws {
        let fixture = MatchaRoomFixture(threads: [aThreadListItem("$t1", body: "Plan", numberOfReplies: 1)])
        fixture.threadReplies = try ["$t1": [aMatchaEvent(2, type: MatchaConfig.eventThreadMetadata,
                                                          content: ThreadMetadataProtocol.bootstrapReplyContent(rootID: "$t1", name: "Plan"))]]
        let store = fixture.store()
        await store.settle()
        
        #expect(store.snapshot.hasChatBar)
        // The thread list counts the hidden reply; nobody sees it.
        #expect(store.snapshot.threadInfos["$t1"] == MatchaThreadInfo(name: "Plan", isNamed: true, isArchived: false, hiddenReplies: 1))
    }
    
    @Test
    func aBoardAloneUnnamedThreadsOrAnArchivedNamedThreadGiveNoChipBar() async throws {
        let fixture = try MatchaRoomFixture(items: [aCardItem(1, id: "c1", title: "Card"),
                                                    aThreadPatchItem(2, threadID: "$old", name: "Old"),
                                                    aThreadPatchItem(3, threadID: "$old", archived: true)],
                                            threads: [aThreadListItem("$t1"), aThreadListItem("$old")])
        fixture.boardPointer = .success(aBoardRoot)
        let store = fixture.store()
        await store.settle()
        
        #expect(store.snapshot.board != nil)
        #expect(!store.snapshot.hasChatBar)
        #expect(store.snapshot.threadInfos["$t1"]?.isNamed == false)
        #expect(store.snapshot.threadInfos["$old"]?.isArchived == true)
    }
    
    @Test
    func thereAreNoOpenTasksUntilTheStoreHasLoadedOrWithoutABoard() async throws {
        let fixture = try MatchaRoomFixture(items: [aCardItem(1, id: "c1", title: "Card")])
        fixture.boardPointer = .success(aBoardRoot)
        let gate = Gate()
        fixture.relationsResult = { _, _, _, _ in
            await gate.wait()
            return .success(.init(events: [], nextBatch: nil))
        }
        let store = fixture.store()
        await waitForSnapshot(store) { $0.board?.cards.count == 1 }
        #expect(!store.snapshot.isLoaded)
        #expect(store.snapshot.openTaskCount(userID: matchaUser) == 0)
        
        gate.open()
        await store.settle()
        #expect(store.snapshot.openTaskCount(userID: matchaUser) == 1)
        
        var withoutBoard = store.snapshot
        withoutBoard.board = nil
        #expect(withoutBoard.openTaskCount(userID: matchaUser) == 0)
    }
    
    @Test
    func aBannerTimesOutUnlessVoiceOverIsRunning() async throws {
        let fixture = try MatchaRoomFixture(items: [aThreadPatchItem(1, threadID: "$t1", name: "Plan")], threads: [aThreadListItem("$t1")])
        let store = fixture.store()
        var isVoiceOverRunning = true
        let chat = MatchaChat(store: store, bannerDuration: .milliseconds(50)) { isVoiceOverRunning }
        
        #expect(await chat.setArchived(threadID: "$t1", archived: true))
        try await Task.sleep(for: .milliseconds(300))
        #expect(chat.banner != nil)
        
        isVoiceOverRunning = false
        #expect(await chat.setArchived(threadID: "$t1", archived: false))
        await eventually { chat.banner == nil }
    }
    
    @Test
    func aBannersActionDismissesItBeforeRunning() async throws {
        let fixture = try MatchaRoomFixture(items: [aThreadPatchItem(1, threadID: "$t1", name: "Plan")], threads: [aThreadListItem("$t1")])
        let chat = MatchaChat(store: fixture.store())
        
        #expect(await chat.setArchived(threadID: "$t1", archived: true))
        let banner = try #require(chat.banner)
        chat.dismissBanner()
        #expect(chat.banner == nil)
        
        chat.banner = banner
        banner.action()
        #expect(chat.banner == nil)
        await eventually { fixture.sent.count == 2 }
    }
}
