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
import MatrixRustSDK
import Testing

/// Android's `RoomReminderPresenterTest`, against the room proxy mocks with an injected clock and time zone.
@MainActor
struct RemindMeScreenViewModelTests {
    private static let amsterdam = TimeZone(identifier: "Europe/Amsterdam") ?? .gmt
    /// Saturday; clocks go forward at 02:00 on Sunday 29 March 2026 in Amsterdam.
    private static let now = date(2026, 3, 28, 12, 0)
    private static let hour: Int64 = 3_600_000
    private static let link = "https://matrix.to/#/!room:server.org/$message"
    private static let botID = "@matcha-reminder:server.org"
    
    @Test
    func theBotIsInTheChatSoTheOptionsAreOfferedWithTheMessageLink() async throws {
        let room = ReminderRoom()
        let viewModel = makeViewModel(room: room)
        #expect(viewModel.context.viewState.botState == .checking)
        try await awaitBotState(viewModel, .joined)
        
        let state = viewModel.context.viewState
        #expect(state.botUserID == Self.botID)
        #expect(state.bindings.message == "Call the venue")
        #expect(state.link == .message)
        #expect(state.maxMessageLength == MatchaConfig.reminderMessageMaxLength - Self.link.utf16.count - 1)
        #expect(state.quickOptions == [.inHours(2), .inHours(8), .inHours(24)])
        #expect(state.selectedOption == nil)
        #expect(!state.canConfirm)
        #expect(state.confirmTitle == UntranslatedL10n.screenMatchaReminderSet)
        // 09:00 on Sunday is after the change to summer time, UTC+2.
        #expect(state.bindings.customDate == Self.utc(2026, 3, 29, 7, 0))
        let nowMillis = Self.now.remindMeMillis
        #expect(state.label(for: .inHours(2)) == formatted(nowMillis + 2 * Self.hour))
        #expect(state.label(for: .inHours(24)) == formatted(nowMillis + 24 * Self.hour))
        #expect(state.label(for: .custom) == formatted(Self.utc(2026, 3, 29, 7, 0).remindMeMillis))
    }
    
    @Test
    func aThreadReminderLinksTheThreadAndALongMessageIsPrefilledWithItsStart() async throws {
        let viewModel = makeViewModel(target: .init(message: String(repeating: "A", count: 500), threadID: "$thread"))
        try await awaitBotState(viewModel, .joined)
        #expect(viewModel.context.viewState.link == .thread)
        #expect(viewModel.context.viewState.bindings.message.count == RemindMeScreenViewModel.prefillMaxLength)
    }
    
    @Test
    func aDeadlineIsOfferedOnlyWhenItIsAheadAndWithinAYear() async throws {
        let deadline = Self.now.addingTimeInterval(3 * 86400).remindMeMillis
        let ahead = makeViewModel(target: .init(message: "Task", dueAt: deadline))
        try await awaitBotState(ahead, .joined)
        #expect(ahead.context.viewState.quickOptions.last == .atDeadline(deadline))
        
        for dueAt in [Self.now.remindMeMillis - 1, Self.now.addingTimeInterval(366 * 86400).remindMeMillis] {
            let viewModel = makeViewModel(target: .init(message: "Task", dueAt: dueAt))
            try await awaitBotState(viewModel, .joined)
            #expect(viewModel.context.viewState.quickOptions == [.inHours(2), .inHours(8), .inHours(24)])
        }
    }
    
    @Test
    func choosingAnOptionSendsNothingAndConfirmingSendsTheRelativeCommandOnceWithTheLinkOnce() async throws {
        let room = ReminderRoom()
        let indicators = UserIndicatorControllerMock()
        let viewModel = makeViewModel(target: .init(message: "Call the venue\n\(Self.link)", eventID: "$message"), room: room, indicators: indicators)
        try await awaitBotState(viewModel, .joined)
        
        viewModel.context.send(viewAction: .select(.inHours(8)))
        viewModel.context.send(viewAction: .select(.inHours(2)))
        #expect(viewModel.context.viewState.selectedOption == .inHours(2))
        #expect(viewModel.context.viewState.confirmTitle == UntranslatedL10n.screenMatchaReminderConfirm(formatted(Self.now.remindMeMillis + 2 * Self.hour)))
        #expect(room.sent.isEmpty)
        
        try await confirmAndAwaitDismiss(viewModel)
        #expect(room.sent.map(\.type) == ["m.room.message"])
        #expect(room.sent.first?.body == "!remind 7200s Call the venue\n\(Self.link)")
        #expect(room.sent.first?.msgtype == "m.text")
        #expect(indicators.submitIndicatorDelayReceivedArguments?.indicator.title == UntranslatedL10n.screenMatchaReminderRequested)
    }
    
    @Test
    func theChosenTimeIsNamedUnderTheTitleWhileSetCanSendIt() async throws {
        let room = ReminderRoom(canInvite: true)
        let viewModel = makeViewModel(room: room)
        try await awaitBotState(viewModel, .joined)
        #expect(viewModel.context.viewState.chosenTime == nil)
        
        viewModel.context.send(viewAction: .select(.inHours(8)))
        #expect(viewModel.context.viewState.chosenTime == formatted(Self.now.remindMeMillis + 8 * Self.hour))
        viewModel.context.send(viewAction: .select(.custom))
        viewModel.context.customDate = Self.date(2026, 3, 30, 9, 30)
        #expect(viewModel.context.viewState.chosenTime == formatted(Self.date(2026, 3, 30, 9, 30).remindMeMillis))
        
        // The bot left: Set is gone, and so is what it would send.
        room.botMembership = .leave
        viewModel.context.send(viewAction: .confirm)
        try await awaitBotState(viewModel, .canInvite(isInviting: false, hasFailed: false))
        #expect(viewModel.context.viewState.chosenTime == nil)
        #expect(room.sent.isEmpty)
    }
    
    @Test
    func theDeadlineOptionSendsTheAbsoluteCommand() async throws {
        let room = ReminderRoom()
        let deadline = Self.date(2026, 4, 1, 17, 0).remindMeMillis
        let viewModel = makeViewModel(target: .init(message: "Task", dueAt: deadline), room: room)
        try await awaitBotState(viewModel, .joined)
        
        viewModel.context.send(viewAction: .select(.atDeadline(deadline)))
        try await confirmAndAwaitDismiss(viewModel)
        #expect(room.sent.first?.body == "!remind at 2026-04-01T15:00:00.000Z Task")
    }
    
    @Test
    func aChosenDeadlineThatHasPassedIsNoLongerChosenAndNotSent() async throws {
        let room = ReminderRoom()
        var clockNow = Self.now
        let deadline = Self.now.addingTimeInterval(3600).remindMeMillis
        let viewModel = makeViewModel(target: .init(message: "Task", dueAt: deadline), room: room) { clockNow }
        try await awaitBotState(viewModel, .joined)
        viewModel.context.send(viewAction: .select(.atDeadline(deadline)))
        #expect(viewModel.context.viewState.selectedOption == .atDeadline(deadline))
        
        clockNow = Self.now.addingTimeInterval(2 * 3600)
        viewModel.context.send(viewAction: .confirm)
        try await deferFulfillment(viewModel.context.observe(\.viewState.now)) { $0 == clockNow }.fulfill()
        #expect(viewModel.context.viewState.selectedOption == nil)
        #expect(viewModel.context.viewState.quickOptions == [.inHours(2), .inHours(8), .inHours(24)])
        #expect(room.sent.isEmpty)
    }
    
    @Test
    func theCustomDateAndTimeAreSentInTheAbsoluteMode() async throws {
        let room = ReminderRoom()
        let viewModel = makeViewModel(target: .init(message: "Call the venue"), room: room)
        try await awaitBotState(viewModel, .joined)
        
        viewModel.context.send(viewAction: .select(.custom))
        viewModel.context.customDate = Self.date(2026, 3, 30, 9, 30)
        #expect(viewModel.context.viewState.customError == nil)
        #expect(viewModel.context.viewState.canConfirm)
        try await confirmAndAwaitDismiss(viewModel)
        // Summer time has started: 09:30 in Amsterdam is 07:30 UTC.
        #expect(room.sent.first?.body == "!remind at 2026-03-30T07:30:00.000Z Call the venue")
    }
    
    @Test
    func aCustomTimeThatIsNotAheadOrMoreThanAYearAheadIsRefused() async throws {
        let room = ReminderRoom()
        let viewModel = makeViewModel(target: .init(message: "Call the venue"), room: room)
        try await awaitBotState(viewModel, .joined)
        viewModel.context.send(viewAction: .select(.custom))
        
        for (date, error) in [(Self.date(2026, 3, 28, 11, 59), ReminderError.notInFuture), (Self.date(2027, 3, 29, 12, 0), .tooFar)] {
            viewModel.context.customDate = date
            #expect(viewModel.context.viewState.customError == error)
            #expect(!viewModel.context.viewState.canConfirm)
            viewModel.context.send(viewAction: .confirm)
        }
        // Exactly one year ahead is still accepted.
        viewModel.context.customDate = Self.date(2027, 3, 28, 12, 0)
        #expect(viewModel.context.viewState.customError == nil)
        await Task.yield()
        #expect(room.sent.isEmpty)
    }
    
    @Test
    func theCustomTimeIsCheckedAgainWhenSentAsTheSheetMayStayOpenPastIt() async throws {
        let room = ReminderRoom()
        var clockNow = Self.now
        let viewModel = makeViewModel(target: .init(message: "Call the venue"), room: room) { clockNow }
        try await awaitBotState(viewModel, .joined)
        viewModel.context.send(viewAction: .select(.custom))
        viewModel.context.customDate = Self.date(2026, 3, 28, 12, 30)
        #expect(viewModel.context.viewState.customError == nil)
        
        clockNow = Self.now.addingTimeInterval(3600)
        viewModel.context.send(viewAction: .confirm)
        try await deferFulfillment(viewModel.context.observe(\.viewState.customError)) { $0 == .notInFuture }.fulfill()
        #expect(room.sent.isEmpty)
    }
    
    @Test
    func anEmptyOrTooLongMessageIsNotSent() async throws {
        let room = ReminderRoom()
        let viewModel = makeViewModel(target: .init(message: "  "), room: room)
        try await awaitBotState(viewModel, .joined)
        #expect(viewModel.context.viewState.messageError == nil)
        
        viewModel.context.send(viewAction: .select(.inHours(8)))
        viewModel.context.send(viewAction: .confirm)
        try await deferFulfillment(viewModel.context.observe(\.viewState.messageError)) { $0 == .emptyMessage }.fulfill()
        
        viewModel.context.message = String(repeating: "A", count: MatchaConfig.reminderMessageMaxLength + 1)
        #expect(viewModel.context.viewState.messageError == .messageTooLong)
        viewModel.context.send(viewAction: .confirm)
        viewModel.context.message = String(repeating: "A", count: MatchaConfig.reminderMessageMaxLength)
        #expect(viewModel.context.viewState.messageError == nil)
        await Task.yield()
        #expect(room.sent.isEmpty)
    }
    
    @Test
    func editingTheMessageHidesTheEmptyMessageErrorUntilTheNextConfirm() async throws {
        let room = ReminderRoom()
        let viewModel = makeViewModel(target: .init(message: ""), room: room)
        try await awaitBotState(viewModel, .joined)
        viewModel.context.send(viewAction: .select(.inHours(2)))
        viewModel.context.send(viewAction: .confirm)
        try await deferFulfillment(viewModel.context.observe(\.viewState.messageError)) { $0 == .emptyMessage }.fulfill()
        
        // Like Android, any edit hides it: typing and clearing again doesn't bring it back before the next confirm.
        viewModel.context.message = "C"
        viewModel.context.message = ""
        #expect(viewModel.context.viewState.messageError == nil)
        viewModel.context.send(viewAction: .confirm)
        try await deferFulfillment(viewModel.context.observe(\.viewState.messageError)) { $0 == .emptyMessage }.fulfill()
        #expect(room.sent.isEmpty)
    }
    
    @Test
    func aFailedSendSaysSoAndKeepsTheOptions() async throws {
        let room = ReminderRoom()
        room.sendResult = .failure(.sdkError(RoomProxyMockError.generic))
        let viewModel = makeViewModel(room: room)
        try await awaitBotState(viewModel, .joined)
        
        viewModel.context.send(viewAction: .select(.inHours(24)))
        viewModel.context.send(viewAction: .confirm)
        try await deferFulfillment(viewModel.context.observe(\.viewState.hasSendFailed)) { $0 }.fulfill()
        #expect(viewModel.context.viewState.sending == nil)
        #expect(viewModel.context.viewState.selectedOption == .inHours(24))
        #expect(viewModel.context.viewState.canConfirm)
    }
    
    @Test
    func aTaskReminderReportsTheRequestBeforeClosing() async throws {
        var requests: [ReminderRequestRef] = []
        let viewModel = RemindMeScreenViewModel(target: .init(message: "Book the venue", threadID: "$thread"),
                                                roomProxy: ReminderRoom().room,
                                                userIndicatorController: UserIndicatorControllerMock(),
                                                timeZone: Self.amsterdam,
                                                clock: { Self.now },
                                                onRequested: { requests.append($0) })
        try await awaitBotState(viewModel, .joined)
        viewModel.context.send(viewAction: .select(.inHours(2)))
        try await confirmAndAwaitDismiss(viewModel)
        #expect(requests == [ReminderRequestRef(eventID: "$command", at: Self.now.remindMeMillis + 2 * Self.hour)])
    }
    
    @Test
    func theBotIsInvitedSoTheUserWaitsAndTheOptionsAppearOnceItJoins() async throws {
        let room = ReminderRoom(botMembership: .invite)
        let viewModel = makeViewModel(room: room)
        try await awaitBotState(viewModel, .waiting(isChecking: false))
        
        // Retrying while the bot has not joined looks again and keeps waiting.
        let lookups = room.room.updatedMemberUserIDCallsCount
        viewModel.context.send(viewAction: .checkBotAgain)
        await waitUntil { room.room.updatedMemberUserIDCallsCount == lookups + 1 && viewModel.context.viewState.botState == .waiting(isChecking: false) }
        #expect(room.room.updatedMemberUserIDCallsCount == lookups + 1)
        #expect(viewModel.context.viewState.botState == .waiting(isChecking: false))
        
        // The bot joins: the member count changes and the sheet moves on by itself.
        room.botMembership = .join
        room.roomInfo.joinedMembersCount = 3
        room.info.send(room.roomInfo)
        try await awaitBotState(viewModel, .joined)
        #expect(room.sent.isEmpty)
    }
    
    @Test
    func aBotJoiningWhileACheckIsOutIsNotMissed() async throws {
        let room = ReminderRoom(botMembership: .invite)
        let viewModel = makeViewModel(room: room)
        try await awaitBotState(viewModel, .waiting(isChecking: false))
        
        // Retry reads the membership just before the bot joins, then hangs on the network until the join has synced.
        let lookUp = room.room.updatedMemberUserIDClosure
        let (network, answer) = AsyncStream<Void>.makeStream()
        room.room.updatedMemberUserIDClosure = { [membership = room.botMembership] userID in
            for await _ in network {
                break
            }
            return .success(RoomMemberProxyMock(with: .init(userID: userID, membership: membership ?? .leave)))
        }
        let lookups = room.room.updatedMemberUserIDCallsCount
        viewModel.context.send(viewAction: .checkBotAgain)
        await waitUntil { room.room.updatedMemberUserIDCallsCount == lookups + 1 }
        
        room.botMembership = .join
        room.roomInfo.joinedMembersCount = 3
        room.info.send(room.roomInfo)
        room.room.updatedMemberUserIDClosure = lookUp
        try await Task.sleep(for: .milliseconds(50))
        answer.yield(())
        
        try await deferFulfillment(viewModel.context.observe(\.viewState.botState), timeout: .seconds(2)) { $0 == .joined }.fulfill()
    }
    
    @Test
    func theBotIsCheckedWithoutReloadingEveryMember() async throws {
        let room = ReminderRoom(botMembership: .invite)
        let viewModel = makeViewModel(room: room)
        try await awaitBotState(viewModel, .waiting(isChecking: false))
        room.botMembership = .join
        room.roomInfo.joinedMembersCount = 3
        room.info.send(room.roomInfo)
        try await awaitBotState(viewModel, .joined)
        viewModel.context.send(viewAction: .select(.inHours(2)))
        try await confirmAndAwaitDismiss(viewModel)
        
        // Opening, the member count's change and the confirm each read the bot alone.
        #expect(!room.room.updateMembersCalled)
        #expect(room.sent.count == 1)
    }
    
    @Test
    func retryFindsTheBotJoined() async throws {
        let room = ReminderRoom(botMembership: .invite)
        let viewModel = makeViewModel(room: room)
        try await awaitBotState(viewModel, .waiting(isChecking: false))
        room.botMembership = .join
        viewModel.context.send(viewAction: .checkBotAgain)
        try await awaitBotState(viewModel, .joined)
    }
    
    @Test
    func theBotIsNotInTheChatSoTheUserConfirmsTheBotIsInvitedAndTheUserWaits() async throws {
        let room = ReminderRoom(botMembership: nil, canInvite: true)
        let viewModel = makeViewModel(room: room)
        try await awaitBotState(viewModel, .canInvite(isInviting: false, hasFailed: false))
        #expect(room.invited.isEmpty)
        
        viewModel.context.send(viewAction: .inviteBot)
        try await awaitBotState(viewModel, .waiting(isChecking: false))
        #expect(room.invited == [Self.botID])
        #expect(room.sent.isEmpty)
    }
    
    @Test
    func aFailedInviteSaysSo() async throws {
        let room = ReminderRoom(botMembership: .leave, canInvite: true)
        room.inviteResult = .failure(.sdkError(RoomProxyMockError.generic))
        let viewModel = makeViewModel(room: room)
        try await awaitBotState(viewModel, .canInvite(isInviting: false, hasFailed: false))
        viewModel.context.send(viewAction: .inviteBot)
        try await awaitBotState(viewModel, .canInvite(isInviting: false, hasFailed: true))
    }
    
    @Test(arguments: [MembershipState?.none, .leave, .invite, .ban])
    func aDMWithoutTheBotGetsNoRemindersAndNeverInvitesIt(botMembership: MembershipState?) async throws {
        let room = ReminderRoom(botMembership: botMembership, canInvite: true, isDM: true)
        let viewModel = makeViewModel(room: room)
        try await awaitBotState(viewModel, .unavailableInDM)
        #expect(!RemindMeScreenViewModel.isOffered(in: room.room))
        
        viewModel.context.send(viewAction: .inviteBot)
        viewModel.context.send(viewAction: .select(.inHours(2)))
        viewModel.context.send(viewAction: .confirm)
        await Task.yield()
        #expect(room.invited.isEmpty)
        #expect(room.sent.isEmpty)
    }
    
    @Test
    func aDMWithTheBotGetsReminders() async throws {
        let room = ReminderRoom(isDM: true)
        #expect(RemindMeScreenViewModel.isOffered(in: room.room))
        try await awaitBotState(makeViewModel(room: room), .joined)
    }
    
    @Test
    func aGroupOffersRemindersWhereverTheBotIs() {
        #expect(RemindMeScreenViewModel.isOffered(in: ReminderRoom(botMembership: nil).room))
    }
    
    @Test
    func theBotIsNotInTheChatAndTheUserCannotInviteItOrItIsBanned() async throws {
        try await awaitBotState(makeViewModel(room: ReminderRoom(botMembership: nil, canInvite: false)), .cannotInvite)
        try await awaitBotState(makeViewModel(room: ReminderRoom(botMembership: .ban, canInvite: true)), .cannotInvite)
    }
    
    @Test
    func theUserCannotPostInTheChat() async throws {
        try await awaitBotState(makeViewModel(room: ReminderRoom(canSend: false)), .cannotSend)
    }
    
    @Test
    func theBotLeftWhileTheSheetWasOpenSoNothingIsSent() async throws {
        let room = ReminderRoom(canInvite: true)
        let viewModel = makeViewModel(room: room)
        try await awaitBotState(viewModel, .joined)
        
        room.botMembership = .leave
        viewModel.context.send(viewAction: .select(.inHours(2)))
        viewModel.context.send(viewAction: .confirm)
        try await awaitBotState(viewModel, .canInvite(isInviting: false, hasFailed: false))
        #expect(viewModel.context.viewState.sending == nil)
        #expect(room.sent.isEmpty)
    }
    
    @Test
    func cancellingClosesTheSheet() async throws {
        let viewModel = makeViewModel()
        let dismissed = deferFulfillment(viewModel.actionsPublisher) { _ in true }
        viewModel.context.send(viewAction: .cancel)
        try await dismissed.fulfill()
    }
    
    @Test
    func aMessageThatReachedTheServerOffersRemindMeOnlyWhereTheRoomDoes() throws {
        let sent = TextRoomTimelineItem(id: .randomEvent, timestamp: .mock, isOutgoing: false, isEditable: false, canBeRepliedTo: true,
                                        sender: .init(id: "@alice:matrix.org"), content: .init(body: "Hello"))
        #expect(try #require(makeActions(for: sent, canRemind: true)).actions.contains(.remindMe))
        #expect(try #require(makeActions(for: sent, canRemind: false)).actions.contains(.remindMe) == false)
        #expect(try #require(makeActions(for: sent, canRemind: true, canSend: false)).actions.contains(.remindMe) == false)
        #expect(try #require(makeActions(for: sent, canRemind: true, timelineKind: .pinned)).actions.contains(.remindMe) == false)
        
        let unsent = TextRoomTimelineItem(id: .event(uniqueID: .init("local"), eventOrTransactionID: .transactionID("txn")), timestamp: .mock,
                                          isOutgoing: true, isEditable: true, canBeRepliedTo: true, sender: .init(id: "@me:x"), content: .init(body: "Hi"))
        #expect(makeActions(for: unsent, canRemind: true)?.actions.contains(.remindMe) != true)
        
        let target = try #require(RemindMeTarget(item: sent, timelineKind: .thread(rootEventID: "$root")))
        #expect(target == RemindMeTarget(message: "Hello", eventID: sent.id.eventID, threadID: "$root"))
    }
    
    @Test
    func onlyATextOrACaptionPrefillsTheMessageLikeAndroid() {
        // Android prefills text-based messages with their text and anything else with its caption, so never a file name or a geo URI.
        let voice = VoiceMessageRoomTimelineItem(id: .randomEvent, timestamp: .mock, isOutgoing: false, isEditable: false, canBeRepliedTo: true,
                                                 sender: .init(id: "@alice:matrix.org"),
                                                 content: .init(filename: "voice-message.ogg", duration: 10, waveform: nil, source: nil, fileSize: nil, contentType: nil))
        let location = LocationRoomTimelineItem(id: .randomEvent, timestamp: .mock, isOutgoing: false, isEditable: false, canBeRepliedTo: true,
                                                sender: .init(id: "@alice:matrix.org"), content: .init(body: "Location was shared at geo:51.5,-0.1"))
        let image = ImageRoomTimelineItem(id: .randomEvent, timestamp: .mock, isOutgoing: false, isEditable: false, canBeRepliedTo: true,
                                          sender: .init(id: "@alice:matrix.org"),
                                          content: .init(filename: "venue.jpg", caption: "The venue", imageInfo: .mockImage, thumbnailInfo: nil))
        #expect(RemindMeTarget(item: voice, timelineKind: .live)?.message == "")
        #expect(RemindMeTarget(item: location, timelineKind: .live)?.message == "")
        #expect(RemindMeTarget(item: image, timelineKind: .live)?.message == "The venue")
    }
    
    @Test
    func aMessagesRemindMeOpensTheSheetAboutItWhileMatchaIsOnAndItsDismissClosesIt() async throws {
        let message = TextRoomTimelineItem(id: .randomEvent, timestamp: .mock, isOutgoing: false, isEditable: false, canBeRepliedTo: true,
                                           sender: .init(id: "@alice:matrix.org"), content: .init(body: "Call the venue"))
        let room = ReminderRoom()
        let timeline = makeTimelineViewModel(room: room, items: [message], timelineKind: .thread(rootEventID: "$root"))
        #expect(timeline.context.viewState.canRemind)
        
        timeline.context.send(viewAction: .handleTimelineItemMenuAction(itemID: message.id, action: .remindMe))
        let sheet = try #require(timeline.context.viewState.bindings.remindMeViewModel)
        #expect(sheet.context.viewState.bindings.message == "Call the venue")
        try await awaitBotState(sheet, .joined)
        #expect(sheet.context.viewState.link == .message)
        
        sheet.context.send(viewAction: .cancel)
        #expect(timeline.context.viewState.bindings.remindMeViewModel == nil)
        #expect(room.sent.isEmpty)
        
        let settings = UserSettings.mock()
        settings.app.matchaWorkspacesEnabled = false
        #expect(!makeTimelineViewModel(room: room, items: [message], settings: settings).context.viewState.canRemind)
    }
    
    @Test
    func eachRemindMeSheetFromTheTimelineReplacesTheLastOnesSubscription() throws {
        let message = TextRoomTimelineItem(id: .randomEvent, timestamp: .mock, isOutgoing: false, isEditable: false, canBeRepliedTo: true,
                                           sender: .init(id: "@alice:matrix.org"), content: .init(body: "Call the venue"))
        let timeline = makeTimelineViewModel(room: ReminderRoom(), items: [message])
        let subscriptions = timeline.cancellables.count
        
        for _ in 0..<3 {
            timeline.context.send(viewAction: .handleTimelineItemMenuAction(itemID: message.id, action: .remindMe))
            try #require(timeline.context.viewState.bindings.remindMeViewModel).context.send(viewAction: .cancel)
            #expect(timeline.context.viewState.bindings.remindMeViewModel == nil)
        }
        #expect(timeline.cancellables.count == subscriptions)
    }
    
    @Test
    func timeZoneOffsetsAreLabelledLikeAndroid() throws {
        let date = Self.now
        #expect(RemindMeTimeFormatter.offset(of: Self.amsterdam, at: date) == "GMT+1")
        #expect(try RemindMeTimeFormatter.offset(of: #require(TimeZone(identifier: "Asia/Kolkata")), at: date) == "GMT+5:30")
        #expect(try RemindMeTimeFormatter.offset(of: #require(TimeZone(identifier: "America/Sao_Paulo")), at: date) == "GMT-3")
        #expect(RemindMeTimeFormatter.offset(of: .gmt, at: date) == "GMT")
        // "Today" and "Tomorrow" come from the device's clock, so this one is relative to the real now.
        let tomorrow = Date.now.addingTimeInterval(86400)
        let label = RemindMeTimeFormatter.string(epochMillis: tomorrow.remindMeMillis, now: .now, timeZone: .current, locale: Locale(identifier: "en_GB"))
        #expect(label.contains("Tomorrow"))
    }
    
    // MARK: - Helpers
    
    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, in timeZone: TimeZone = amsterdam) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) ?? .distantPast
    }
    
    private static func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        date(year, month, day, hour, minute, in: .gmt)
    }
    
    private func formatted(_ epochMillis: Int64) -> String {
        RemindMeTimeFormatter.string(epochMillis: epochMillis, now: Self.now, timeZone: Self.amsterdam)
    }
    
    private func makeViewModel(target: RemindMeTarget = .init(message: "Call the venue", eventID: "$message"),
                               room: ReminderRoom = ReminderRoom(),
                               indicators: UserIndicatorControllerMock = UserIndicatorControllerMock(),
                               clock: @escaping () -> Date = { now }) -> RemindMeScreenViewModel {
        RemindMeScreenViewModel(target: target, roomProxy: room.room, userIndicatorController: indicators, timeZone: Self.amsterdam, clock: clock)
    }
    
    private func awaitBotState(_ viewModel: RemindMeScreenViewModel, _ botState: RemindMeBotState) async throws {
        try await deferFulfillment(viewModel.context.observe(\.viewState.botState)) { $0 == botState }.fulfill()
    }
    
    /// Waits up to 2 seconds for `condition`, which state changes made by the view model's own tasks can't be observed for.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
    
    private func confirmAndAwaitDismiss(_ viewModel: RemindMeScreenViewModel) async throws {
        let dismissed = deferFulfillment(viewModel.actionsPublisher) { _ in true }
        viewModel.context.send(viewAction: .confirm)
        try await dismissed.fulfill()
    }
    
    private func makeTimelineViewModel(room: ReminderRoom,
                                       items: [RoomTimelineItemProtocol],
                                       timelineKind: TimelineKind = .live,
                                       settings: UserSettings = .mock()) -> TimelineViewModel {
        TimelineViewModel(roomProxy: room.room,
                          timelineController: TimelineControllerMock(.init(timelineKind: timelineKind, timelineItems: items)),
                          userSession: UserSessionMock(.init(userSettings: settings)),
                          mediaPlayerProvider: MediaPlayerProviderMock(),
                          userIndicatorController: UserIndicatorControllerMock(),
                          appMediator: AppMediatorMock(.init()),
                          analyticsService: AnalyticsServiceMock(.init()),
                          emojiProvider: EmojiProvider(userSettings: .mock()),
                          linkMetadataProvider: LinkMetadataProvider(),
                          timelineControllerFactory: TimelineControllerFactoryMock(.init()))
    }
    
    private func makeActions(for item: RoomTimelineItemProtocol, canRemind: Bool, canSend: Bool = true, timelineKind: TimelineKind = .live) -> TimelineItemMenuActions? {
        TimelineItemMenuActionProvider(timelineItem: item,
                                       canCurrentUserSendMessage: canSend,
                                       canCurrentUserRedactSelf: true,
                                       canCurrentUserRedactOthers: false,
                                       canCurrentUserPin: true,
                                       pinnedEventIDs: [],
                                       isViewSourceEnabled: false,
                                       areThreadsEnabled: true,
                                       timelineKind: timelineKind,
                                       emojiProvider: EmojiProvider(userSettings: .mock()),
                                       canRemind: canRemind)
            .makeActions()
    }
}

/// A joined room of `@me:server.org` whose reminder bot has `botMembership`, recording what is sent and who is invited. The room's
/// mock holds on to the fixture, so a view model's checks keep working after a test lets go of it.
@MainActor
private final class ReminderRoom {
    let room: JoinedRoomProxyMock
    let roomInfo: RoomInfoProxyMock
    let info: CurrentValueSubject<RoomInfoProxyProtocol, Never>
    var botMembership: MembershipState?
    var sendResult: Result<String, RoomProxyError> = .success("$command")
    var inviteResult: Result<Void, RoomProxyError> = .success(())
    struct SentEvent {
        let type: String
        let body: String?
        let msgtype: String?
    }
    
    private(set) var sent: [SentEvent] = []
    private(set) var invited: [String] = []
    
    init(botMembership: MembershipState? = .join, canSend: Bool = true, canInvite: Bool = false, isDM: Bool = false) {
        self.botMembership = botMembership
        let configuration = JoinedRoomProxyMockConfiguration(id: "!room:server.org",
                                                             isDirect: isDM,
                                                             members: [RoomMemberProxyMock(with: .init(userID: "@me:server.org", membership: .join))],
                                                             ownUserID: "@me:server.org",
                                                             powerLevelsConfiguration: .init(canUserSendMessage: canSend, canUserInvite: canInvite))
        room = JoinedRoomProxyMock(configuration)
        roomInfo = RoomInfoProxyMock(configuration)
        roomInfo.isDM = isDM
        roomInfo.joinedMembersCount = 2
        info = .init(roomInfo)
        room.infoPublisher = info.asCurrentValuePublisher()
        
        room.updatedMemberUserIDClosure = { [self] userID in
            guard let membership = self.botMembership else { return .failure(.sdkError(RoomProxyMockError.generic)) }
            return .success(RoomMemberProxyMock(with: .init(userID: userID, membership: membership)))
        }
        if let botMembership {
            room.membersPublisher = CurrentValueSubject([RoomMemberProxyMock(with: .init(userID: "@matcha-reminder:server.org", membership: botMembership))])
                .asCurrentValuePublisher()
        }
        room.matrixToEventPermalinkClosure = { eventID in
            .success(URL(string: "https://matrix.to/#/!room:server.org/\(eventID)") ?? .homeDirectory)
        }
        room.sendRawEventTypeContentJSONClosure = { [self] type, contentJSON in
            let content = JSONValue(json: contentJSON)?.objectValue
            sent.append(SentEvent(type: type, body: content?.string("body"), msgtype: content?.string("msgtype")))
            return sendResult
        }
        room.inviteUserIDClosure = { [self] userID in
            invited.append(userID)
            return inviteResult
        }
    }
}
