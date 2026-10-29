//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

typealias ChannelsScreenViewModelType = StateStoreViewModelV2<ChannelsScreenViewState, ChannelsScreenViewAction>

/// The channels grouped by space, Android's `HomeSpacesPresenter.channelsFlow`, from what the SDK already knows: no room is opened.
/// The list is only built while the tab is on screen.
class ChannelsScreenViewModel: ChannelsScreenViewModelType, ChannelsScreenViewModelProtocol {
    private let clientProxy: ClientProxyProtocol
    private let accountSettings: AccountSettings
    private let userIndicatorController: UserIndicatorControllerProtocol
    private var listCancellable: AnyCancellable?
    
    private let actionsSubject: PassthroughSubject<ChannelsScreenViewModelAction, Never> = .init()
    var actionsPublisher: AnyPublisher<ChannelsScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(userSession: UserSessionProtocol,
         selectedIDPublisher: CurrentValuePublisher<String?, Never>,
         userIndicatorController: UserIndicatorControllerProtocol) {
        clientProxy = userSession.clientProxy
        accountSettings = userSession.userSettings.account
        self.userIndicatorController = userIndicatorController
        
        super.init(initialViewState: ChannelsScreenViewState(userProfile: userSession.clientProxy.userProfilePublisher.value),
                   mediaProvider: userSession.mediaProvider)
        
        selectedIDPublisher
            .weakAssign(to: \.state.selectedID, on: self)
            .store(in: &cancellables)
        
        userSession.clientProxy.userProfilePublisher
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.state.userProfile, on: self)
            .store(in: &cancellables)
        
        userSession.clientProxy.hideInviteAvatarsPublisher
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.state.hideInviteAvatars, on: self)
            .store(in: &cancellables)
    }
    
    // MARK: - Public
    
    override func process(viewAction: ChannelsScreenViewAction) {
        switch viewAction {
        case .appeared:
            startListing()
        case .disappeared:
            listCancellable = nil
        case .openSpace(let spaceID):
            Task { await openSpace(spaceID: spaceID) }
        case .openRoom(let roomID):
            actionsSubject.send(.openRoom(roomID: roomID))
        case .openSpaceNotes(let spaceID):
            actionsSubject.send(.openSpaceNotes(spaceID: spaceID))
        case .openSpaceBoards(let spaceID):
            actionsSubject.send(.openSpaceBoards(spaceID: spaceID))
        case .showSettings:
            actionsSubject.send(.showSettings)
        case .createSpace:
            actionsSubject.send(.createSpace)
        case .markAsRead(let roomID):
            Task { await setUnread(false, roomID: roomID) }
        case .markAsUnread(let roomID):
            Task { await setUnread(true, roomID: roomID) }
        case .setFavourite(let roomID, let isFavourite):
            Task { await setFavourite(isFavourite, roomID: roomID) }
        case .showRoomDetails(let roomID):
            actionsSubject.send(.openRoomDetails(roomID: roomID))
        }
    }
    
    /// Android's `groupChannels`: each joined top-level space with the channels of its whole tree, then the channels in no space.
    /// A channel is a joined group chat: not a DM, not a space. The summaries come in the room list's order, most recent first.
    static func channels(spaces: [SpaceServiceRoom],
                         filters: [SpaceServiceFilter],
                         summaries: [RoomSummary],
                         showAllActivity: Bool,
                         seenInvites: Set<String>) -> Channels {
        let trees = topLevelSpaceTrees(filters)
        let inAnySpace = filters.reduce(into: Set<String>()) { $0.formUnion($1.descendants) }
        let channels = summaries
            .filter { $0.isJoined && !$0.isSpace && !$0.isDM }
            .map { HomeScreenRoom(summary: $0, showAllActivity: showAllActivity) }
        // Android lists the space invites of its Spaces tab; here they come from the room list, as on the Chats tab.
        let invites = summaries
            .filter { $0.isSpace && $0.joinRequestType?.isInvite == true }
            .map { HomeScreenRoom(summary: $0, showAllActivity: showAllActivity, seenInvites: seenInvites) }
        return Channels(invites: invites,
                        spaces: spaces.map { space in
                            let tree = trees[space.id] ?? []
                            return SpaceChannels(id: space.id,
                                                 name: space.name,
                                                 avatar: space.avatar,
                                                 channels: channels.filter { tree.contains($0.id) })
                        },
                        otherChannels: channels.filter { !inAnySpace.contains($0.id) })
    }
    
    /// Each top-level space's whole tree, by space ID: a level 0 filter holds the direct children of a top-level space, and the
    /// deeper filters that follow it hold the rest of its tree.
    static func topLevelSpaceTrees(_ filters: [SpaceServiceFilter]) -> [String: Set<String>] {
        var trees = [String: Set<String>]()
        var topLevelSpaceID: String?
        for filter in filters {
            if filter.level == 0 {
                topLevelSpaceID = filter.room.id
            }
            if let topLevelSpaceID {
                trees[topLevelSpaceID, default: []].formUnion(filter.descendants)
            }
        }
        return trees
    }
    
    // MARK: - Private
    
    /// ponytail: every row is built again on each room list update while the tab is on screen, as the Chats list does; keep the
    /// rows of unchanged rooms (Android's `e4ca235ec5`) if a large account shows it.
    private func startListing() {
        guard listCancellable == nil else { return }
        let roomList = clientProxy.staticRoomSummaryProvider
        let spaceService = clientProxy.spaceService
        listCancellable = roomList.statePublisher
            .combineLatest(roomList.roomListPublisher)
            .combineLatest(spaceService.topLevelSpacesPublisher.combineLatest(spaceService.spaceFilterPublisher),
                           accountSettings.seenInvitesPublisher.combineLatest(accountSettings.showAllRoomListActivityPublisher))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rooms, spaces, settings in
                let (state, summaries) = rooms
                // Loaded comes before the provider has published its rooms, as the Chats list knows: that is no empty state yet.
                // A joined space is counted but never listed, so spaces alone are a list.
                let isPublishing = summaries.isEmpty && spaces.0.isEmpty && state.totalNumberOfRooms != 0
                guard state.isLoaded, !isPublishing else {
                    self?.state.content = .loading
                    return
                }
                let channels = Self.channels(spaces: spaces.0,
                                             filters: spaces.1,
                                             summaries: summaries,
                                             showAllActivity: settings.1,
                                             seenInvites: settings.0)
                self?.state.content = channels.isEmpty ? .empty : .channels(channels)
            }
    }
    
    /// As the Chats list: read also sends a receipt, private unless the user shares their presence.
    private func setUnread(_ isUnread: Bool, roomID: String) async {
        guard case let .joined(roomProxy) = await clientProxy.roomForIdentifier(roomID) else {
            MXLog.error("Failed retrieving room for identifier: \(roomID)")
            return
        }
        if case .failure(let error) = await roomProxy.flagAsUnread(isUnread) {
            MXLog.error("Failed flagging room \(roomID) as unread: \(isUnread) with error: \(error)")
        } else if !isUnread, case .failure(let error) = await roomProxy.markAsRead(receiptType: accountSettings.sharePresence ? .read : .readPrivate) {
            MXLog.error("Failed marking room \(roomID) as read with error: \(error)")
        }
    }
    
    private func setFavourite(_ isFavourite: Bool, roomID: String) async {
        guard case let .joined(roomProxy) = await clientProxy.roomForIdentifier(roomID) else {
            MXLog.error("Failed retrieving room for identifier: \(roomID)")
            return
        }
        if case .failure(let error) = await roomProxy.flagAsFavourite(isFavourite) {
            MXLog.error("Failed marking room \(roomID) as favourite: \(isFavourite) with error: \(error)")
        }
    }
    
    private func openSpace(spaceID: String) async {
        switch await clientProxy.spaceService.spaceRoomList(spaceID: spaceID) {
        case .success(let spaceRoomListProxy):
            actionsSubject.send(.openSpace(spaceRoomListProxy))
        case .failure(let error):
            MXLog.error("Unable to open space \(spaceID): \(error)")
            userIndicatorController.submitIndicator(UserIndicator(id: "\(Self.self)-Failure",
                                                                  type: .toast,
                                                                  title: L10n.errorUnknown,
                                                                  icon: \.close))
        }
    }
}
