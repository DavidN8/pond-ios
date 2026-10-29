//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import MatrixRustSDK
import Testing

struct MatchaReadTicksTests {
    private let me = "@me:matrix.org"
    private let alice = "@alice:matrix.org"
    private let bob = "@bob:matrix.org"
    
    @Test
    func ownMessageIsReadOnceEveryOtherMemberHasAReceiptOnItOrANewerItem() {
        let members = [member(me), member(alice), member(bob)]
        let oldest = message(isOutgoing: true)
        let middle = message(isOutgoing: true, readers: [alice])
        let newest = message(isOutgoing: false, readers: [bob])
        
        let readIDs = MatchaReadTicks.readItemIDs(in: [oldest, middle, newest], members: members, ownUserID: me)
        
        #expect(readIDs == [oldest.id.uniqueID, middle.id.uniqueID])
    }
    
    @Test
    func ownMessageIsNotReadWhileAMemberHasNoReceiptAtOrAfterIt() {
        let members = [member(me), member(alice), member(bob)]
        let items = [message(isOutgoing: true, readers: [alice]), message(isOutgoing: true)]
        
        #expect(MatchaReadTicks.readItemIDs(in: items, members: members, ownUserID: me).isEmpty)
    }
    
    @Test
    func leftMembersServiceMembersAndReminderBotsAreNotWaitedFor() {
        let members = [member(me),
                       member(alice),
                       member(bob, membership: .leave),
                       member("@bridge:matrix.org", isServiceMember: true),
                       member("@matcha-reminder:matrix.org"),
                       member("@matcha-reminder:other.org")]
        let item = message(isOutgoing: true, readers: [alice])
        
        #expect(MatchaReadTicks.readItemIDs(in: [item], members: members, ownUserID: me) == [item.id.uniqueID])
    }
    
    @Test
    func aRoomWithNobodyElseOrMoreMembersThanTheCapNeverShowsRead() {
        let alone = message(isOutgoing: true, readers: [alice])
        #expect(MatchaReadTicks.readItemIDs(in: [alone], members: [member(me)], ownUserID: me).isEmpty)
        
        let crowd = (0...MatchaReadTicks.maxMembers).map { "@user\($0):matrix.org" }
        let large = message(isOutgoing: true, readers: crowd)
        #expect(MatchaReadTicks.readItemIDs(in: [large], members: [member(me)] + crowd.map { member($0) }, ownUserID: me).isEmpty)
    }
    
    @Test
    func seenByListsEveryReaderOfTheItemOrANewerOneOnce() {
        let item = message(isOutgoing: true, readers: [alice])
        let newer = message(isOutgoing: false, readers: [bob, alice, me])
        let older = message(isOutgoing: false, readers: ["@charlie:matrix.org"])
        
        let receipts = MatchaReadTicks.readReceipts(upTo: item.id, in: [older, item, newer], ownUserID: me)
        
        #expect(receipts.map(\.userID) == [bob, alice])
    }
    
    @Test
    func tickFollowsTheMessagesOwnSendState() {
        let local = message(isOutgoing: true, id: .event(uniqueID: .init("local"), eventOrTransactionID: .transactionID("txn")))
        let sent = message(isOutgoing: true)
        
        #expect(MatchaTick(timelineItem: message(isOutgoing: false), deliveryStatus: nil, isRead: true) == nil)
        #expect(MatchaTick(timelineItem: local, deliveryStatus: .sendingFailed(.unknown(reason: nil)), isRead: false) == nil)
        #expect(MatchaTick(timelineItem: local, deliveryStatus: .sending, isRead: false) == .sending)
        #expect(MatchaTick(timelineItem: local, deliveryStatus: .sent, isRead: false) == .sent)
        #expect(MatchaTick(timelineItem: sent, deliveryStatus: nil, isRead: false) == .sent)
        #expect(MatchaTick(timelineItem: sent, deliveryStatus: nil, isRead: true) == .read)
    }
    
    @Test
    func aPendingEditOrAFailedReactionLeavesTheTickOfASentMessage() {
        // Upstream's delivery status of a sent message is that of our pending edit or redaction, or a failed reaction, on it.
        let sent = message(isOutgoing: true)
        
        #expect(MatchaTick(timelineItem: sent, deliveryStatus: .sending, isRead: true) == .read)
        #expect(MatchaTick(timelineItem: sent, deliveryStatus: .sendingFailed(.unknown(reason: nil)), isRead: false) == .sent)
    }
    
    @Test
    func seenByIsOfferedForOwnSentMessagesOnly() throws {
        let own = try #require(makeActions(for: message(isOutgoing: true)))
        let others = try #require(makeActions(for: message(isOutgoing: false)))
        let unsent = try #require(makeActions(for: message(isOutgoing: true, id: .event(uniqueID: .init("local"), eventOrTransactionID: .transactionID("txn")))))
        
        #expect(own.actions.contains(.seenBy))
        #expect(!others.actions.contains(.seenBy))
        #expect(!unsent.actions.contains(.seenBy))
    }
    
    @Test
    func timelineShowsTheReadTicksAndSeenByOpensTheReaders() async throws {
        let item = message(isOutgoing: true)
        let newer = message(isOutgoing: false, readers: [alice])
        let viewModel = makeTimelineViewModel(items: [item, newer])
        
        #expect(viewModel.context.viewState.timelineState.matchaReadUniqueIDs == [item.id.uniqueID])
        #expect(viewModel.context.viewState.matchaIsRead(item.id))
        
        let deferred = deferFulfillment(viewModel.context.$viewState) { $0.bindings.readReceiptsSummaryInfo?.orderedReceipts.map(\.userID) == [alice] }
        viewModel.context.send(viewAction: .handleTimelineItemMenuAction(itemID: item.id, action: .seenBy))
        try await deferred.fulfill()
    }
    
    @Test
    func youSeeNoReadTicksOrReadersWhileYouDontShareYourOwnReceipts() async throws {
        // Share presence off also stops rendering receipts, as on Android and as upstream hides the receipt avatars.
        let userSettings = UserSettings.mock()
        userSettings.account.sharePresence = false
        let item = message(isOutgoing: true)
        let viewModel = makeTimelineViewModel(items: [item, message(isOutgoing: false, readers: [alice])], userSettings: userSettings)
        
        #expect(!viewModel.context.viewState.matchaIsRead(item.id))
        
        let deferred = deferFulfillment(viewModel.context.$viewState) { $0.bindings.readReceiptsSummaryInfo?.orderedReceipts.isEmpty == true }
        viewModel.context.send(viewAction: .handleTimelineItemMenuAction(itemID: item.id, action: .seenBy))
        try await deferred.fulfill()
    }
    
    @Test
    func seenByShowsNothingForAMessageGoneDuringTheMenusDismissal() async throws {
        let gone = message(isOutgoing: true)
        let viewModel = makeTimelineViewModel(items: [message(isOutgoing: false, readers: [alice])])
        
        let noSheet = deferFailure(viewModel.context.$viewState, timeout: .milliseconds(300)) { $0.bindings.readReceiptsSummaryInfo != nil }
        viewModel.context.send(viewAction: .handleTimelineItemMenuAction(itemID: gone.id, action: .seenBy))
        try await noSheet.fulfill()
    }
    
    // MARK: - Helpers
    
    private func makeTimelineViewModel(items: [RoomTimelineItemProtocol], userSettings: UserSettings = .mock()) -> TimelineViewModel {
        TimelineViewModel(roomProxy: JoinedRoomProxyMock(.init(name: "", members: [.mockMe, .mockAlice])),
                          timelineController: TimelineControllerMock(.init(timelineItems: items)),
                          userSession: UserSessionMock(.init(userSettings: userSettings)),
                          mediaPlayerProvider: MediaPlayerProviderMock(),
                          userIndicatorController: UserIndicatorControllerMock(),
                          appMediator: AppMediatorMock(.init()),
                          analyticsService: AnalyticsServiceMock(.init()),
                          emojiProvider: EmojiProvider(userSettings: .mock()),
                          linkMetadataProvider: LinkMetadataProvider(),
                          timelineControllerFactory: TimelineControllerFactoryMock(.init()))
    }
    
    private func member(_ userID: String, membership: MembershipState = .join, isServiceMember: Bool = false) -> RoomMemberProxyMock {
        RoomMemberProxyMock(with: .init(userID: userID, membership: membership, isServiceMember: isServiceMember))
    }
    
    private func message(isOutgoing: Bool, readers: [String] = [], id: TimelineItemIdentifier = .randomEvent) -> TextRoomTimelineItem {
        TextRoomTimelineItem(id: id,
                             timestamp: .mock,
                             isOutgoing: isOutgoing,
                             isEditable: isOutgoing,
                             canBeRepliedTo: true,
                             sender: .init(id: isOutgoing ? me : alice),
                             content: .init(body: "Hello"),
                             properties: RoomTimelineItemProperties(orderedReadReceipts: readers.map { ReadReceipt(userID: $0, formattedTimestamp: nil) }))
    }
    
    private func makeActions(for item: RoomTimelineItemProtocol) -> TimelineItemMenuActions? {
        TimelineItemMenuActionProvider(timelineItem: item,
                                       canCurrentUserSendMessage: true,
                                       canCurrentUserRedactSelf: true,
                                       canCurrentUserRedactOthers: false,
                                       canCurrentUserPin: true,
                                       pinnedEventIDs: [],
                                       isViewSourceEnabled: false,
                                       areThreadsEnabled: true,
                                       timelineKind: .live,
                                       emojiProvider: EmojiProvider(userSettings: .mock()))
            .makeActions()
    }
}
