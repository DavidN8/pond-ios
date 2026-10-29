//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import MatchaProtocol
import SwiftUI

/// Custom emoji reactions (MSC4027): the key is the image's mxc URL. The SDK's aggregation drops the shortcode the reaction
/// carried, so the name comes from the room's packs.
enum CustomEmojiReactions {
    static func isCustomEmoji(key: String) -> Bool {
        key.hasPrefix("mxc://")
    }
    
    /// The custom emoji keys of the items' reactions that have no label yet.
    static func unlabelledKeys(in items: [RoomTimelineItemProtocol], labels: [String: String]) -> Set<String> {
        Set(items.lazy
            .compactMap { $0 as? EventBasedTimelineItemProtocol }
            .flatMap(\.properties.reactions)
            .map(\.key)
            .filter { isCustomEmoji(key: $0) && labels[$0] == nil })
    }
    
    /// Toggles a reaction. While custom emoji are on, a custom emoji reaction carries the `:code:` its image has in the room's packs
    /// last read (MSC4027), as the web client sends it, without waiting for the server; the SDK's toggle removes it like any other.
    static func toggle(_ key: String,
                       to eventOrTransactionID: TimelineItemIdentifier.EventOrTransactionID,
                       roomID: String,
                       timelineController: TimelineControllerProtocol,
                       userSession: UserSessionProtocol) async {
        guard isCustomEmoji(key: key) else {
            return await timelineController.toggleReaction(key, to: eventOrTransactionID)
        }
        // ponytail: the first emoji with this image; the picker's own shortcode only differs when packs share an image.
        let emoji = userSession.userSettings.app.matchaWorkspacesEnabled
            ? userSession.matchaService.customEmojiPacks.cachedPacks(roomID: roomID).emoji(url: key)
            : nil
        // Even without a shortcode: the upstream toggle logs the key, an emoji's URL.
        await timelineController.toggleReaction(key, to: eventOrTransactionID, shortcode: emoji.map { ":\($0.shortcode):" })
    }
    
    /// `:code:` of each key found in the packs, the generic name otherwise.
    static func labels(for keys: Set<String>, in packs: [EmojiPack]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: keys.map { key in
            (key, packs.emoji(url: key).map { ":\($0.shortcode):" } ?? UntranslatedL10n.a11yMatchaCustomReaction)
        })
    }
}

extension AggregatedReaction {
    /// The key as VoiceOver reads it: a custom emoji's `:code:` or generic name, else the key as displayed.
    func spokenKey(labels: [String: String]?) -> String {
        guard CustomEmojiReactions.isCustomEmoji(key: key) else { return displayKey }
        return labels?[key] ?? UntranslatedL10n.a11yMatchaCustomReaction
    }
}

/// A reaction's key: its text, or a custom emoji's image in a square of `size`.
struct ReactionKeyView: View {
    @Environment(\.timelineContext) private var context
    
    let reaction: AggregatedReaction
    let size: CGFloat
    
    var body: some View {
        if CustomEmojiReactions.isCustomEmoji(key: reaction.key), let mediaProvider = context?.mediaProvider {
            CustomEmojiImage(url: reaction.key, size: size, mediaProvider: mediaProvider)
                .accessibilityLabel(reaction.spokenKey(labels: context?.viewState.customEmojiReactionLabels))
        } else {
            Text(reaction.displayKey)
        }
    }
}

/// A custom emoji's image in a square of `size`, as in reactions, the reaction picker and the composer's suggestions.
struct CustomEmojiImage: View {
    /// The image's mxc URL.
    let url: String
    let size: CGFloat
    let mediaProvider: MediaProviderProtocol?
    
    var body: some View {
        if let url = URL(string: url), let mediaProvider {
            // ponytail: the full image through the media cache, so an animated GIF shows its first frame, as inline emoji do.
            LoadableImage(url: url, mediaProvider: mediaProvider) { image in
                image.scaledToFit()
            } placeholder: {
                Color.clear
            }
            .frame(width: size, height: size)
        } else {
            Color.clear
                .frame(width: size, height: size)
        }
    }
}
