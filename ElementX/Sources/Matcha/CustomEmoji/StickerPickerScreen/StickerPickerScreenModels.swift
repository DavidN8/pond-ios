//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatchaProtocol

enum StickerPickerScreenViewModelAction {
    case dismiss
}

struct StickerPickerScreenViewState: BindableState {
    /// The room's sticker packs in picker order, one tab each; nil while they load.
    var packs: [EmojiPack]?
    var selectedPackID: String?
    var bindings = StickerPickerScreenViewStateBindings()
    
    /// What the grid shows: the selected pack, or while searching every pack with a sticker whose shortcode or body matches.
    var shownPacks: [EmojiPack] {
        let packs = packs ?? []
        let query = bindings.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return packs.filter { $0.id == selectedPackID }
        }
        return packs.compactMap { pack in
            let stickers = pack.emojis.filter { $0.shortcode.localizedStandardContains(query) || $0.body?.localizedStandardContains(query) == true }
            return stickers.isEmpty ? nil : EmojiPack(id: pack.id, kind: pack.kind, roomID: pack.roomID, stateKey: pack.stateKey,
                                                      name: pack.name, avatarURL: pack.avatarURL, emojis: stickers)
        }
    }
    
    var isSearching: Bool {
        !bindings.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct StickerPickerScreenViewStateBindings {
    var searchQuery = ""
}

enum StickerPickerScreenViewAction {
    case selectPack(id: String)
    case send(CustomEmoji)
    case dismiss
}
