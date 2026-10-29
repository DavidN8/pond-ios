//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

/// The Channels tab on the real SDK against the local throwaway homeserver: the space filters and the room list the mocks stand in
/// for. Skipped unless `MATCHA_LOCAL_TEST_ENV` names the accounts file (see `MatchaLocalHomeserverTests`). It makes four rooms, and
/// Synapse's default `rc_room_creation` lets an account make one a minute once its burst of ten is spent, hence the time limit.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)), .enabled(if: MatchaLocalHomeserver.configuration != nil, "No local homeserver is configured"))
struct ChannelsLocalHomeserverTests {
    @Test
    func aSpacesChannelIsListedUnderItAnotherChatUnderOtherChannelsAndADMNowhere() async throws {
        let server = try #require(MatchaLocalHomeserver.configuration)
        try await server.signedIn(.b) { bob in
            try await server.signedIn(.a) { alice in
                let tag = UUID().uuidString.prefix(8)
                let spaceID = try await alice.client.createRoom(name: "Channels space \(tag)", topic: nil, accessType: .private,
                                                                isSpace: true, userIDs: [], avatarURL: nil, aliasLocalPart: nil).get()
                let inSpaceID = try await alice.client.createRoom(name: "In the space \(tag)", topic: nil, accessType: .private,
                                                                  isSpace: false, userIDs: [], avatarURL: nil, aliasLocalPart: nil).get()
                let otherID = try await alice.client.createRoom(name: "Outside \(tag)", topic: nil, accessType: .private,
                                                                isSpace: false, userIDs: [], avatarURL: nil, aliasLocalPart: nil).get()
                let dmID = try await alice.client.createDirectRoom(with: bob.userID, expectedRoomName: nil).get()
                try await alice.client.spaceService.addChild(inSpaceID, to: spaceID).get()
                
                let viewModel = ChannelsScreenViewModel(userSession: UserSessionMock(.init(clientProxy: alice.client)),
                                                        selectedIDPublisher: .init(nil),
                                                        userIndicatorController: UserIndicatorControllerMock())
                viewModel.context.send(viewAction: .appeared)
                // The DM first, so that leaving it out is checked on a list that has it.
                try await deferFulfillment(alice.client.staticRoomSummaryProvider.roomListPublisher.map { $0.contains { $0.id == dmID && $0.isDM } },
                                           timeout: .seconds(60)) { $0 }.fulfill()
                var listed: Channels?
                try await deferFulfillment(viewModel.context.observe(\.viewState.content), timeout: .seconds(60)) { content in
                    guard case .channels(let channels) = content,
                          channels.spaces.first(where: { $0.id == spaceID })?.channels.map(\.id) == [inSpaceID],
                          channels.otherChannels.contains(where: { $0.id == otherID }) else {
                        return false
                    }
                    listed = channels
                    return true
                }.fulfill()
                
                let channels = try #require(listed)
                let channelIDs = channels.otherChannels.map(\.id) + channels.spaces.flatMap { $0.channels.map(\.id) }
                #expect(!channels.otherChannels.contains { $0.id == inSpaceID })
                #expect(!channelIDs.contains(dmID))
                #expect(!channelIDs.contains(spaceID))
                // The screen may have built its list before the DM came; the same grouping on the room list that has it.
                let spaceService = alice.client.spaceService
                let grouped = ChannelsScreenViewModel.channels(spaces: spaceService.topLevelSpacesPublisher.value,
                                                               filters: spaceService.spaceFilterPublisher.value,
                                                               summaries: alice.client.staticRoomSummaryProvider.roomListPublisher.value,
                                                               showAllActivity: true,
                                                               seenInvites: [])
                #expect(!grouped.otherChannels.contains { $0.id == dmID })
                #expect(grouped.otherChannels.contains { $0.id == otherID })
            }
        }
    }
}
