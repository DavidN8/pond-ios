//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum ChannelsScreenViewModelAction {
    case openSpace(SpaceRoomListProxyProtocol)
    /// A channel, or a pending space invite, which the room flow shows as an invite.
    case openRoom(roomID: String)
    /// A channel's settings, from its long-press menu.
    case openRoomDetails(roomID: String)
    case openSpaceNotes(spaceID: String)
    case openSpaceBoards(spaceID: String)
    case showSettings
    case createSpace
}

/// The Channels tab, in place of the Spaces tab while the Matcha workspaces are on, as Android's `HomeChannelsView`.
struct ChannelsScreenViewState: BindableState {
    var userProfile: UserProfile
    var content = ChannelsContent.loading
    /// The space or chat shown next to the list, highlighted.
    var selectedID: String?
    /// The user's setting to hide the avatars of invites, for the space invites.
    var hideInviteAvatars = false
}

enum ChannelsContent: Equatable {
    /// Until the room list is loaded: skeleton rows.
    case loading
    /// No space, no channel and no invite.
    case empty
    case channels(Channels)
}

/// The joined group chats ("channels"): under the top-level space they belong to, then the ones in no space.
struct Channels: Equatable {
    /// Pending space invites, at the top as on Android's Spaces tab.
    var invites: [HomeScreenRoom]
    var spaces: [SpaceChannels]
    var otherChannels: [HomeScreenRoom]
    
    var isEmpty: Bool {
        invites.isEmpty && spaces.isEmpty && otherChannels.isEmpty
    }
}

/// A joined top-level space and the joined channels of its whole tree, most recent first.
struct SpaceChannels: Equatable, Identifiable {
    let id: String
    let name: String
    let avatar: RoomAvatar
    let channels: [HomeScreenRoom]
}

enum ChannelsScreenViewAction {
    case appeared
    case disappeared
    case openSpace(spaceID: String)
    case openRoom(roomID: String)
    case openSpaceNotes(spaceID: String)
    case openSpaceBoards(spaceID: String)
    case showSettings
    case createSpace
    // A channel's long-press menu, as the Chats list's.
    case markAsRead(roomID: String)
    case markAsUnread(roomID: String)
    case setFavourite(roomID: String, isFavourite: Bool)
    case showRoomDetails(roomID: String)
}
