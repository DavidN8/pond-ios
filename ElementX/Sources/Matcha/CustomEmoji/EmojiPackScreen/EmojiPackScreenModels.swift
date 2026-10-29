//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatchaProtocol
import MatrixRustSDK

/// The custom emoji pack an Emoji screen manages (MSC2545): the personal pack in account data, or a room's or space's own pack, its
/// `im.ponies.room_emotes` state with the empty state key.
enum EmojiPackTarget {
    case user
    case room(JoinedRoomProxyProtocol)
    
    /// Whether the user may change a room's pack: power levels let them send its state.
    static func canEditRoomPack(_ info: RoomInfoProxyProtocol) -> Bool {
        info.powerLevels?.canOwnUser(sendStateEvent: stateEventTypeFromString(s: ImagePacks.roomEmotesEventType)) ?? false
    }
    
    /// Whether room details and space settings show the Emoji row: custom emoji are on, and the user may change the pack or it has
    /// emoji or stickers to see.
    static func showsRoomRow(roomProxy: JoinedRoomProxyProtocol, userSession: UserSessionProtocol) async -> Bool {
        guard userSession.userSettings.app.matchaWorkspacesEnabled else { return false }
        if canEditRoomPack(roomProxy.infoPublisher.value) {
            return true
        }
        guard case .success(let json?) = await roomProxy.fetchStateEventContentJSON(type: ImagePacks.roomEmotesEventType, stateKey: "") else {
            return false
        }
        let content = JSONValue(json: json)
        return !ImagePacks.parseEmojiImages(content).isEmpty || !ImagePacks.parseImages(content, usage: .sticker).isEmpty
    }
}

enum EmojiPackScreenViewModelAction {
    /// Pick images from the photo library and pass them to `upload(urls:usage:)`.
    case pickImages(ImageUsage)
}

nonisolated enum EmojiPackScreenLoadState: Equatable {
    case loading
    case loaded
    case failed
}

struct EmojiPackScreenViewState: BindableState {
    /// What the pack is for, which differs for the personal pack, a room and a space.
    let description: String
    var loadState = EmojiPackScreenLoadState.loading
    /// The pack's emoji, sorted by shortcode; images other clients stored for other uses are kept but not shown.
    var emojis: [CustomEmoji] = []
    /// The pack's stickers, sorted by shortcode. An image without a usage is both, so it shows in both lists.
    var stickers: [CustomEmoji] = []
    /// The user may upload, rename and remove emoji.
    var canEdit = false
    /// A change is being saved; edits wait until it is done.
    var isBusy = false
    var bindings = EmojiPackScreenViewStateBindings()
    
    var isEditable: Bool {
        canEdit && !isBusy && loadState == .loaded
    }
}

struct EmojiPackScreenViewStateBindings {
    var alertInfo: AlertInfo<EmojiPackScreenAlert>?
}

enum EmojiPackScreenAlert: Hashable {
    case rename
    case error
}

enum EmojiPackScreenViewAction {
    case retry
    case upload(ImageUsage)
    /// Ask for a new name for the emoji.
    case rename(shortcode: String)
    case remove(shortcode: String)
}
