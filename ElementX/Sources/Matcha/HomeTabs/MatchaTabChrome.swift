//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

/// A root tab's settings, behind the user's avatar at the leading edge, as on the Chats tab.
struct MatchaSettingsToolbarItem: ToolbarContent {
    let userProfile: UserProfile
    let mediaProvider: MediaProviderProtocol?
    let action: () -> Void
    
    var body: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            AvatarSettingsButton(userProfile: userProfile, mediaProvider: mediaProvider, action: action)
                .buttonStyle(.borderless)
        }
        .backportSharedBackgroundVisibility(.hidden)
    }
}

/// The Matcha icons as Compound key paths, which the tab bar takes: `\.matchaBoard`, like `\.chat`. Nonisolated like Compound's
/// own icons, so they name the assets of `Asset.Images.matchaBoard` and the others rather than reading them on the main actor.
nonisolated extension CompoundIcons {
    var matchaBoard: Image {
        Image("images/matcha-board")
    }
    
    var matchaBoardSolid: Image {
        Image("images/matcha-board-solid")
    }
    
    var matchaNotes: Image {
        Image("images/matcha-notes")
    }
    
    var matchaNotesSolid: Image {
        Image("images/matcha-notes-solid")
    }
}
