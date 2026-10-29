//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import SwiftUI
import Testing

struct MatchaSwipeActionsTests {
    @Test
    func releasedRowOpensPastHalfItsButtonsAndClosesOtherwise() {
        let leading: CGFloat = 152 // Two buttons.
        let trailing: CGFloat = 76 // One.
        
        #expect(MatchaSwipe.restingOffset(offset: 77, velocity: 0, leadingWidth: leading, trailingWidth: trailing) == leading)
        #expect(MatchaSwipe.restingOffset(offset: 75, velocity: 0, leadingWidth: leading, trailingWidth: trailing) == 0)
        #expect(MatchaSwipe.restingOffset(offset: -39, velocity: 0, leadingWidth: leading, trailingWidth: trailing) == -trailing)
        // A fling opens a row dragged only a little, and a fling back closes an open one instead of opening the other side.
        #expect(MatchaSwipe.restingOffset(offset: 10, velocity: 1000, leadingWidth: leading, trailingWidth: trailing) == leading)
        #expect(MatchaSwipe.restingOffset(offset: leading, velocity: -2000, leadingWidth: leading, trailingWidth: trailing) == 0)
        // A side without buttons never opens.
        #expect(MatchaSwipe.restingOffset(offset: 0, velocity: -1000, leadingWidth: leading, trailingWidth: 0) == 0)
    }
    
    @Test
    func rightToLeftMirrorsTheRowOffset() throws {
        // The swipe and the bubble tail rely on a positive offset(x:) moving towards the trailing edge in either direction.
        func redColumns(_ direction: LayoutDirection) throws -> ClosedRange<Int> {
            let view = HStack(spacing: 0) {
                Color(red: 1, green: 0, blue: 0).frame(width: 10, height: 4).offset(x: 20)
                Spacer(minLength: 0)
            }
            .frame(width: 100, height: 4)
            .background(.white)
            .environment(\.layoutDirection, direction)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let isDrawn = pixels.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return context != nil
            }
            try #require(isDrawn)
            let red = (0..<image.width).filter { pixels[$0 * 4] > 200 && pixels[$0 * 4 + 1] < 50 }
            return try #require(red.first)...#require(red.last)
        }
        
        #expect(try redColumns(.leftToRight) == 20...29)
        #expect(try redColumns(.rightToLeft) == 70...79)
    }
    
    @Test
    func roomActionsFollowTheRoomsReadAndFavouriteState() throws {
        let summary = try #require([RoomSummary].mockRooms.first { $0.hasUnreadNotifications && !$0.isFavourite && !$0.isMuted })
        let unread = HomeScreenRoom(summary: summary)
        var sent: HomeScreenViewAction?
        
        let actions = MatchaSwipe.roomActions(for: unread) { sent = $0 }
        
        #expect(actions.leading.map(\.title) == [L10n.screenRoomlistMarkAsRead, L10n.commonFavourite])
        #expect(actions.trailing.map(\.title) == [L10n.commonMute, L10n.actionLeave])
        
        actions.leading[0].action()
        guard case .markRoomAsRead(unread.id) = sent else {
            Issue.record("Expected mark as read, got \(String(describing: sent))")
            return
        }
        actions.leading[1].action()
        guard case .markRoomAsFavourite(unread.id, true) = sent else {
            Issue.record("Expected favourite, got \(String(describing: sent))")
            return
        }
        actions.trailing[0].action()
        guard case .setRoomMuted(unread.id, true) = sent else {
            Issue.record("Expected mute, got \(String(describing: sent))")
            return
        }
        actions.trailing[1].action()
        guard case .leaveRoom(unread.id) = sent else {
            Issue.record("Expected leave, got \(String(describing: sent))")
            return
        }
    }
    
    @Test
    func aMutedRoomSwipesToUnmute() throws {
        let summary = try #require([RoomSummary].mockRooms.first { $0.isMuted })
        let muted = HomeScreenRoom(summary: summary)
        var sent: HomeScreenViewAction?
        
        let actions = MatchaSwipe.roomActions(for: muted) { sent = $0 }
        
        #expect(actions.trailing.map(\.title) == [L10n.commonUnmute, L10n.actionLeave])
        actions.trailing[0].action()
        guard case .setRoomMuted(muted.id, false) = sent else {
            Issue.record("Expected unmute, got \(String(describing: sent))")
            return
        }
    }
    
    @Test
    func muteAndUnmuteSetTheRoomsNotificationMode() async throws {
        let rooms: [RoomSummary] = .mockRooms
        let roomID = try #require(rooms.first { $0.joinRequestType == nil }?.id)
        let notificationSettings = NotificationSettingsProxyMock(with: .init())
        let (calls, continuation) = AsyncStream<String>.makeStream()
        notificationSettings.setNotificationModeRoomIdModeClosure = { continuation.yield("\($0) \($1)") }
        notificationSettings.unmuteRoomRoomIdIsEncryptedIsOneToOneClosure = { roomID, _, _ in continuation.yield("\(roomID) unmuted") }
        let clientProxy = ClientProxyMock(.init(roomSummaryProvider: RoomSummaryProviderMock(.init(state: .loaded(rooms))),
                                                notificationSettings: notificationSettings))
        let userSession = UserSessionMock(.init(clientProxy: clientProxy))
        let viewModel = HomeScreenViewModel(userSession: userSession,
                                            availableSessionsPublisher: .init([UserSessionDetails(userSession: userSession)]),
                                            selectedRoomPublisher: CurrentValueSubject<String?, Never>(nil).asCurrentValuePublisher(),
                                            analyticsService: AnalyticsServiceMock(.init()),
                                            bugReportService: BugReportServiceMock(.init()),
                                            userIndicatorController: UserIndicatorControllerMock())
        
        let muted = deferFulfillment(calls) { $0 == "\(roomID) mute" }
        viewModel.context.send(viewAction: .setRoomMuted(roomIdentifier: roomID, isMuted: true))
        try await muted.fulfill()
        
        let unmuted = deferFulfillment(calls) { $0 == "\(roomID) unmuted" }
        viewModel.context.send(viewAction: .setRoomMuted(roomIdentifier: roomID, isMuted: false))
        try await unmuted.fulfill()
    }
}
