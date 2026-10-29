//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import MatchaProtocol
import Testing

/// The "Remind me" sheet against the real Rust SDK and the local throwaway homeserver of `MatchaLocalHomeserverTests` (same
/// `MATCHA_LOCAL_TEST_ENV` file): the sheet invites the reminder bot into a new group chat and another member sees the invite, then
/// the sheet sends the command once and that member reads exactly that event back decrypted. The local bot only joins rooms its
/// `ALLOWED_INVITERS` invite it to, which aren't the test accounts, so the sending sheet reads the bot as joined and everything else
/// from the real room; the bot's acknowledgement is therefore not checked here.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: MatchaLocalHomeserver.configuration != nil, "No local homeserver is configured"))
struct RemindMeLocalHomeserverTests {
    @Test
    func theSheetInvitesTheBotThenSendsOneCommandThatAnotherMemberReadsBack() async throws {
        let server = try #require(MatchaLocalHomeserver.configuration)
        try await server.signedIn(.a) { alice in
            try await server.signedIn(.b) { bob in
                let roomID = try await alice.client.createRoom(name: "Matcha reminders \(UUID().uuidString.prefix(8))", topic: nil, accessType: .private,
                                                               isSpace: false, userIDs: [bob.userID], avatarURL: nil, aliasLocalPart: nil).get()
                try await bob.client.joinRoom(roomID, via: []).get()
                let room = try await alice.joinedRoom(roomID)
                room.subscribeToRoomInfoUpdates()
                let messageID = try await room.sendRawEvent(type: "m.room.message", contentJSON: #"{"msgtype": "m.text", "body": "Call the venue"}"#).get()
                let link = try await room.matrixToEventPermalink(messageID).get().absoluteString
                let bobRoom = try await bob.joinedRoom(roomID)
                let bobTimeline = try await bobRoom.eventTypesTimeline(types: ["m.room.message"]).get()
                let target = RemindMeTarget(message: "Call the venue", eventID: messageID)
                
                let inviting = RemindMeScreenViewModel(target: target, roomProxy: room, userIndicatorController: UserIndicatorControllerMock())
                let botID = inviting.context.viewState.botUserID
                #expect(botID == MatchaConfig.reminderBotUserID(sessionUserID: alice.userID))
                // A new group chat has no bot, and its creator may invite it.
                try await deferFulfillment(inviting.context.observe(\.viewState.botState), timeout: .seconds(30)) {
                    $0 == .canInvite(isInviting: false, hasFailed: false)
                }.fulfill()
                inviting.context.send(viewAction: .inviteBot)
                try await deferFulfillment(inviting.context.observe(\.viewState.botState), timeout: .seconds(30)) {
                    $0 == .waiting(isChecking: false)
                }.fulfill()
                let isInvited = await poll(timeout: .seconds(30)) {
                    guard case .success(let member) = await bobRoom.updatedMember(userID: botID) else { return false }
                    return member.membership == .invite || member.membership == .join
                }
                #expect(isInvited, "Bob never saw the reminder bot invited")
                
                var requests: [ReminderRequestRef] = []
                let sending = RemindMeScreenViewModel(target: target,
                                                      roomProxy: botJoined(room, botID: botID),
                                                      userIndicatorController: UserIndicatorControllerMock(),
                                                      clock: Date.init) { requests.append($0) }
                try await deferFulfillment(sending.context.observe(\.viewState.botState), timeout: .seconds(30)) { $0 == .joined }.fulfill()
                sending.context.send(viewAction: .select(.inHours(2)))
                let dismissed = deferFulfillment(sending.actionsPublisher, timeout: .seconds(30)) { _ in true }
                let sentAfter = Date.now.remindMeMillis
                sending.context.send(viewAction: .confirm)
                try await dismissed.fulfill()
                let sentBefore = Date.now.remindMeMillis
                let request = try #require(requests.first)
                #expect(requests.count == 1)
                #expect((sentAfter + 7_200_000...sentBefore + 7_200_000).contains(request.at))
                
                // Bob reads the command back decrypted, exactly as the other clients send it, and only once.
                var commands: [RawEvent] = []
                let isRead = await poll(timeout: .seconds(45)) {
                    commands = bobTimeline.timelineItemProvider.itemProxies.compactMap { item -> RawEvent? in
                        guard case .event(let event) = item else { return nil }
                        return RawEvent(json: event.originalJSON)
                    }
                    .filter { $0.content.string("body")?.hasPrefix("!remind") == true }
                    return commands.contains { $0.eventID == request.eventID }
                }
                try #require(isRead, "Bob never read the reminder command")
                #expect(commands.count == 1)
                let command = try #require(commands.first)
                #expect(command.eventID == request.eventID)
                #expect(command.type == "m.room.message")
                #expect(command.senderID == alice.userID)
                #expect(command.content.string("msgtype") == "m.text")
                #expect(command.content.string("body") == "!remind 7200s Call the venue\n\(link)")
            }
        }
    }
    
    /// `room` as the sheet uses it, except that the reminder bot reads as joined.
    private func botJoined(_ room: JoinedRoomProxyProtocol, botID: String) -> JoinedRoomProxyMock {
        let proxy = JoinedRoomProxyMock()
        proxy.underlyingOwnUserID = room.ownUserID
        proxy.underlyingInfoPublisher = room.infoPublisher
        proxy.updatedMemberUserIDClosure = { userID in
            guard userID == botID else { return await room.updatedMember(userID: userID) }
            return .success(RoomMemberProxyMock(with: .init(userID: botID, membership: .join)))
        }
        proxy.matrixToEventPermalinkClosure = { await room.matrixToEventPermalink($0) }
        proxy.sendRawEventTypeContentJSONClosure = { await room.sendRawEvent(type: $0, contentJSON: $1) }
        return proxy
    }
    
    /// Whether `condition` held within `timeout`, asking twice a second.
    private func poll(timeout: Duration, _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }
}
