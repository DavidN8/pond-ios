//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

/// The Channels tab, like WhatsApp's Communities tab: each joined space is a header row with All notes, All boards and All chats,
/// then its channels (group chats), then the channels that are in no space. Pending space invites stay at the top.
struct ChannelsScreen: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    
    @Bindable var context: ChannelsScreenViewModel.Context
    
    var body: some View {
        mainContent
            .navigationTitle(UntranslatedL10n.screenHomeTabChannels)
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbar }
            .background(Color.compound.bgCanvasDefault.ignoresSafeArea())
            .onAppear { context.send(viewAction: .appeared) }
            .onDisappear { context.send(viewAction: .disappeared) }
    }
    
    @ViewBuilder
    private var mainContent: some View {
        switch context.viewState.content {
        case .loading:
            // Like the chat list while it loads.
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { _ in
                        HomeScreenRoomCell(room: .placeholder(), isSelected: false, mediaProvider: context.mediaProvider) { _ in }
                            .redacted(reason: .placeholder)
                            .shimmer()
                    }
                }
                .disabled(true)
                .accessibilityRepresentation {
                    Text(L10n.commonLoading)
                }
            }
            .scrollDisabled(true)
        case .empty:
            FullscreenDialog(horizontalPadding: 24) {
                TitleAndIcon(title: UntranslatedL10n.screenHomeChannelsEmptyTitle,
                             icon: \.spaceSolid,
                             iconStyle: .defaultSolid)
            } bottomContent: {
                Button(L10n.actionCreateSpace) {
                    context.send(viewAction: .createSpace)
                }
                .buttonStyle(.compound(.primary))
            }
        case .channels(let channels):
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(channels.invites) { invite in
                        ChannelsInviteRow(invite: invite,
                                          isSelected: invite.id == context.viewState.selectedID,
                                          hidesAvatars: context.viewState.hideInviteAvatars,
                                          mediaProvider: context.mediaProvider) {
                            context.send(viewAction: .openRoom(roomID: invite.id))
                        }
                    }
                    ForEach(Array(channels.spaces.enumerated()), id: \.element.id) { index, space in
                        if index > 0 || !channels.invites.isEmpty {
                            ChannelsSectionBand()
                        }
                        spaceSection(space)
                    }
                    if !channels.otherChannels.isEmpty {
                        // Without any space, the channels are the whole list and need no section.
                        if !channels.spaces.isEmpty {
                            ChannelsSectionBand()
                            ChannelsOtherHeader()
                        } else if !channels.invites.isEmpty {
                            ChannelsSectionBand()
                        }
                        channelRows(channels.otherChannels, isCompact: false)
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private func spaceSection(_ space: SpaceChannels) -> some View {
        ChannelsSpaceHeader(space: space, isSelected: space.id == context.viewState.selectedID, mediaProvider: context.mediaProvider) {
            context.send(viewAction: .openSpace(spaceID: space.id))
        }
        ChannelsShortcutRow(title: UntranslatedL10n.screenHomeChannelsAllNotes, spaceName: space.name) {
            CompoundIcon(asset: Asset.Images.matchaNotes)
        } action: {
            context.send(viewAction: .openSpaceNotes(spaceID: space.id))
        }
        ChannelsShortcutRow(title: UntranslatedL10n.screenHomeChannelsAllBoards, spaceName: space.name) {
            CompoundIcon(asset: Asset.Images.matchaBoard)
        } action: {
            context.send(viewAction: .openSpaceBoards(spaceID: space.id))
        }
        // The same as the header, under a name that says what it opens.
        ChannelsShortcutRow(title: UntranslatedL10n.screenHomeChannelsAllChats, spaceName: space.name) {
            CompoundIcon(\.chat)
        } action: {
            context.send(viewAction: .openSpace(spaceID: space.id))
        }
        channelRows(space.channels, isCompact: true)
    }
    
    /// A space's channels are compact rows, as Android's; the channels in no space are full size, as chats.
    private func channelRows(_ rooms: [HomeScreenRoom], isCompact: Bool) -> some View {
        ForEach(rooms) { room in
            HomeScreenRoomCell(room: room,
                               isSelected: room.id == context.viewState.selectedID,
                               mediaProvider: context.mediaProvider,
                               isCompact: isCompact,
                               // At accessibility sizes a name takes two lines rather than a few letters.
                               nameLineLimit: dynamicTypeSize.isAccessibilitySize ? 2 : 1) { action in
                if case .selectRoom(let roomID) = action {
                    context.send(viewAction: .openRoom(roomID: roomID))
                }
            }
            .contextMenu { channelMenu(room) }
        }
    }
    
    /// The Chats list's long-press menu, as Android's Channels tab.
    ///
    /// ponytail: without Report and Leave, which the Chats tab's view model guards (the last owner, a sheet); both are in Settings.
    @ViewBuilder
    private func channelMenu(_ room: HomeScreenRoom) -> some View {
        if room.badges.isDotShown {
            Button {
                context.send(viewAction: .markAsRead(roomID: room.id))
            } label: {
                Label(L10n.screenRoomlistMarkAsRead, icon: \.markAsRead)
            }
        } else {
            Button {
                context.send(viewAction: .markAsUnread(roomID: room.id))
            } label: {
                Label(L10n.screenRoomlistMarkAsUnread, icon: \.markAsUnread)
            }
        }
        
        if room.isFavourite {
            Button {
                context.send(viewAction: .setFavourite(roomID: room.id, isFavourite: false))
            } label: {
                Label(L10n.commonFavourited, icon: \.favouriteSolid)
            }
        } else {
            Button {
                context.send(viewAction: .setFavourite(roomID: room.id, isFavourite: true))
            } label: {
                Label(L10n.commonFavourite, icon: \.favourite)
            }
        }
        
        Button {
            context.send(viewAction: .showRoomDetails(roomID: room.id))
        } label: {
            Label(L10n.commonSettings, icon: \.settings)
        }
    }
    
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        MatchaSettingsToolbarItem(userProfile: context.viewState.userProfile, mediaProvider: context.mediaProvider) {
            context.send(viewAction: .showSettings)
        }
        
        ToolbarItem(placement: .primaryAction) {
            Button {
                context.send(viewAction: .createSpace)
            } label: {
                CompoundIcon(\.plus)
                    .accessibilityHidden(true)
            }
            .accessibilityLabel(L10n.actionCreateSpace)
            .matchaProminentToolbarButton()
        }
    }
}

/// A space at the head of its channels: its rounded-square avatar, its name and how many of its channels the user is in.
private struct ChannelsSpaceHeader: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    
    let space: SpaceChannels
    let isSelected: Bool
    let mediaProvider: MediaProviderProtocol?
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                if dynamicTypeSize < .accessibility3 {
                    RoomAvatarImage(avatar: space.avatar, avatarSize: .room(on: .spaces), mediaProvider: mediaProvider)
                        .dynamicTypeSize(dynamicTypeSize < .accessibility1 ? dynamicTypeSize : .accessibility1)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(space.name)
                        .font(.compound.bodyLGSemibold)
                        .foregroundStyle(.compound.textPrimary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    Text(UntranslatedL10n.screenHomeChannelsCount(space.channels.count))
                        .font(.compound.bodyMD)
                        .foregroundStyle(.compound.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(HomeScreenRoomCellButtonStyle(isSelected: isSelected))
        // VoiceOver users can jump from space to space.
        .accessibilityAddTraits(.isHeader)
    }
}

/// A pending space invite and who sent it, which opens the invite to accept or decline, as a space invite on Android's Spaces tab.
private struct ChannelsInviteRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    
    let invite: HomeScreenRoom
    let isSelected: Bool
    let hidesAvatars: Bool
    let mediaProvider: MediaProviderProtocol?
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                if dynamicTypeSize < .accessibility3 {
                    RoomAvatarImage(avatar: hidesAvatars ? invite.avatar.removingAvatar : invite.avatar,
                                    avatarSize: .room(on: .spaces),
                                    mediaProvider: mediaProvider)
                        .dynamicTypeSize(dynamicTypeSize < .accessibility1 ? dynamicTypeSize : .accessibility1)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(invite.name)
                        .font(.compound.bodyLGSemibold)
                        .foregroundStyle(.compound.textPrimary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    if let inviter = invite.inviter {
                        RoomInviterLabel(inviter: inviter, shouldHideAvatar: hidesAvatars, mediaProvider: mediaProvider)
                            .font(.compound.bodyMD)
                            .foregroundStyle(.compound.textSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if invite.badges.isDotShown {
                    Circle()
                        .fill(Color.compound.iconAccentPrimary)
                        .frame(width: 12, height: 12)
                        .accessibilityLabel(L10n.a11yNotificationsNewMessages)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(HomeScreenRoomCellButtonStyle(isSelected: isSelected))
    }
}

/// A space's notes, boards or chats: an icon tile in the avatars' column, and a regular label under the bolder names.
private struct ChannelsShortcutRow<Icon: View>: View {
    let title: String
    /// Read out after the title, as every space has the same three rows.
    let spaceName: String
    @ViewBuilder let icon: Icon
    let action: () -> Void
    
    @ScaledMetric(relativeTo: .compound.bodyLG) private var tileSize = 40.0
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                icon
                    .foregroundStyle(.compound.iconSecondary)
                    .frame(width: tileSize, height: tileSize)
                    .background(.compound.bgSubtleSecondary, in: .rect(cornerRadius: 10))
                    // Centred under the space's avatar, so the labels line up with the channels' names.
                    .frame(minWidth: Avatars.Size.room(on: .chats).value)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.compound.bodyLG)
                    .foregroundStyle(.compound.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(UntranslatedL10n.a11yMatchaSpaceShortcut(title, spaceName))
    }
}

/// An 8 pt band in the raised fill between the blocks, like the space screen's sections and WhatsApp's communities.
private struct ChannelsSectionBand: View {
    var body: some View {
        Rectangle()
            .fill(Color.compound.bgSubtleSecondary)
            .frame(height: 8)
            .accessibilityHidden(true)
    }
}

private struct ChannelsOtherHeader: View {
    var body: some View {
        Text(UntranslatedL10n.screenHomeChannelsOtherSection)
            .font(.compound.bodyMDSemibold)
            .foregroundStyle(.compound.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Previews

struct ChannelsScreen_Previews: PreviewProvider, TestablePreview {
    static let viewModel = makeViewModel(summaries: .mockChannels)
    static let noSpacesViewModel = makeViewModel(summaries: .mockChannels, spaces: [])
    static let emptyViewModel = makeViewModel(summaries: [], spaces: [])
    static let loadingViewModel = makeViewModel(summaries: nil)
    static let invitesViewModel = makeViewModel(summaries: .mockSpaceInvites + .mockChannels)
    
    static var previews: some View {
        ElementNavigationStack {
            ChannelsScreen(context: viewModel.context)
        }
        .previewDisplayName("Spaces and other channels")
        
        ElementNavigationStack {
            ChannelsScreen(context: noSpacesViewModel.context)
        }
        .previewDisplayName("No space")
        
        ElementNavigationStack {
            ChannelsScreen(context: emptyViewModel.context)
        }
        .previewDisplayName("Empty")
        
        ElementNavigationStack {
            ChannelsScreen(context: loadingViewModel.context)
        }
        .previewDisplayName("Loading")
        
        ElementNavigationStack {
            ChannelsScreen(context: invitesViewModel.context)
        }
        .previewDisplayName("Invites")
    }
    
    /// The rooms of the mocks' first space are its channels; nil summaries keep the room list loading.
    static func makeViewModel(summaries: [RoomSummary]?, spaces: [SpaceServiceRoom] = .mockChannelSpaces) -> ChannelsScreenViewModel {
        let clientProxy = ClientProxyMock(.init())
        clientProxy.staticRoomSummaryProvider = RoomSummaryProviderMock(.init(state: summaries.map { .loaded($0) } ?? .loading))
        let filters = spaces.first.map { [SpaceServiceFilter(room: $0, level: 0, descendants: ["!general:matrix.org", "!design:matrix.org"])] } ?? []
        clientProxy.spaceService = SpaceServiceProxyMock(.init(topLevelSpaces: spaces, spaceFilters: filters))
        let viewModel = ChannelsScreenViewModel(userSession: UserSessionMock(.init(clientProxy: clientProxy)),
                                                selectedIDPublisher: .init(nil),
                                                userIndicatorController: UserIndicatorControllerMock())
        viewModel.context.send(viewAction: .appeared)
        return viewModel
    }
}

private extension [RoomSummary] {
    static var mockChannels: [RoomSummary] {
        [.mock(id: "!general:matrix.org", name: "general"),
         .mock(id: "!design:matrix.org", name: "design"),
         .mock(id: "!weekend:matrix.org", name: "Weekend plans")]
    }
}

private extension [SpaceServiceRoom] {
    static var mockChannelSpaces: [SpaceServiceRoom] {
        Array([SpaceServiceRoom].mockJoinedSpaces.prefix(2))
    }
}
