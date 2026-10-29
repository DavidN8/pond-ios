//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

extension View {
    /// The chat list's swipe actions (plan I12 step 2).
    func matchaRoomSwipeActions(for room: HomeScreenRoom, send: @escaping (HomeScreenViewAction) -> Void) -> some View {
        let actions = MatchaSwipe.roomActions(for: room, send: send)
        return matchaSwipeActions(leading: actions.leading, trailing: actions.trailing)
    }
    
    /// A root tab's main toolbar button ("+"), as WhatsApp's green circle. Plain in the iPad sidebar, where toolbar glass isn't supported.
    func matchaProminentToolbarButton() -> some View {
        modifier(MatchaProminentToolbarButton())
    }
    
    /// The day separator and the floating date over the timeline (`WHATSAPP_DESIGN.md` §3.3).
    func matchaDatePill() -> some View {
        font(.compound.bodySM)
            .foregroundStyle(.compound.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(MatchaColors.systemPillBackground, in: .rect(cornerRadius: 8))
            .shadow(color: MatchaColors.surfaceShadow, radius: 0, y: 1)
    }
    
    /// Rows of a menu sheet as one rounded card, for a sheet on `bgSubtleSecondaryLevel0`. Give it the rows (a `ForEach`), not a stack.
    func matchaMenuCard() -> some View {
        VStack(spacing: 0) {
            self
        }
        .background(.compound.bgCanvasDefaultLevel1, in: .rect(cornerRadius: 12))
    }
}

extension MatchaSwipe {
    /// Read state and favourite from the leading edge, mute and leave from the trailing one (plan I12). Settings stay in the context menu.
    static func roomActions(for room: HomeScreenRoom,
                            send: @escaping (HomeScreenViewAction) -> Void) -> (leading: [MatchaSwipeAction], trailing: [MatchaSwipeAction]) {
        let readState: MatchaSwipeAction = if room.badges.isDotShown {
            .init(title: L10n.screenRoomlistMarkAsRead, icon: \.markAsRead, tint: .compound.iconInfoPrimary) {
                send(.markRoomAsRead(roomIdentifier: room.id))
            }
        } else {
            .init(title: L10n.screenRoomlistMarkAsUnread, icon: \.markAsUnread, tint: .compound.iconInfoPrimary) {
                send(.markRoomAsUnread(roomIdentifier: room.id))
            }
        }
        let favourite = MatchaSwipeAction(title: room.isFavourite ? L10n.commonFavourited : L10n.commonFavourite,
                                          icon: room.isFavourite ? \.favouriteSolid : \.favourite,
                                          tint: .compound.iconSecondary) {
            send(.markRoomAsFavourite(roomIdentifier: room.id, isFavourite: !room.isFavourite))
        }
        let isMuted = room.badges.isMuteShown
        let mute = MatchaSwipeAction(title: isMuted ? L10n.commonUnmute : L10n.commonMute,
                                     icon: isMuted ? \.notifications : \.notificationsOff,
                                     tint: .compound.iconSecondary) {
            send(.setRoomMuted(roomIdentifier: room.id, isMuted: !isMuted))
        }
        let leave = MatchaSwipeAction(title: L10n.actionLeave, icon: \.leave, tint: .compound.bgCriticalPrimary) {
            send(.leaveRoom(roomIdentifier: room.id))
        }
        return ([readState, favourite], [mute, leave])
    }
}

private struct MatchaProminentToolbarButton: ViewModifier {
    @Environment(\.isInSidebar) private var isInSidebar
    
    func body(content: Content) -> some View {
        if isInSidebar {
            content
        } else {
            content
                .backportButtonStyleGlassProminent()
                .tint(.compound.bgAccentRest)
                .foregroundStyle(.compound.iconOnSolidPrimary)
        }
    }
}

// MARK: - Previews

struct MatchaStyle_Previews: PreviewProvider, TestablePreview {
    static let rooms = RoomSummaryProviderMock(.init(state: .loaded(.mockRooms))).roomListPublisher.value.prefix(3).map { HomeScreenRoom(summary: $0) }
    
    static var previews: some View {
        ElementNavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rooms) { room in
                        HomeScreenRoomCell(room: room, isSelected: false, mediaProvider: MediaProviderMock(.init())) { _ in }
                            .matchaRoomSwipeActions(for: room) { _ in }
                    }
                }
            }
            .navigationTitle("Chats")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { } label: { CompoundIcon(\.plus) }
                        .matchaProminentToolbarButton()
                }
            }
        }
        .previewDisplayName("Chat list")
        
        VStack(spacing: 16) {
            ForEach([TimelineItemMenuAction.reply(isThread: false), .copy, .pin], id: \.self) { action in
                Button { } label: { action.label }
                    .buttonStyle(.menuSheet)
            }
            .matchaMenuCard()
        }
        .padding(16)
        .background(.compound.bgSubtleSecondaryLevel0)
        .previewDisplayName("Menu card")
    }
}
