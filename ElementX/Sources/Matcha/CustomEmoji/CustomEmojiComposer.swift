//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import HTMLParser
import MatchaProtocol
import SwiftUI
import WysiwygComposer

extension WysiwygComposerViewModel {
    /// Replaces the `:code` the editor offers suggestions for with `text`. The view model replaces only a slash command's
    /// suggestion with text (`setCommand`), so this goes through the editing path of the text view.
    func replaceCustomEmojiSuggestion(with text: String) {
        guard let suggestionPattern, suggestionPattern.key == .colon,
              let range = try? textView.attributedText.attributedRange(from: NSRange(location: Int(suggestionPattern.start),
                                                                                     length: Int(suggestionPattern.end) - Int(suggestionPattern.start))) else {
            return
        }
        // True when the text view is left to show the change, as it does for typed text; this text wasn't typed.
        if replaceText(range: range, replacementText: text) {
            applyAtributedContent()
        }
        updateCompressedHeightIfNeeded()
    }
}

// MARK: - Previews

@available(iOS 26.0, *)
struct CustomEmojiSending_Previews: PreviewProvider, TestablePreview {
    private static let emojis = [CustomEmoji(shortcode: "party", url: "mxc://example.org/party"),
                                 CustomEmoji(shortcode: "party_parrot", url: "mxc://example.org/parrot")]
    private static let pickerViewModel = EmojiPickerScreenViewModel(selectedEmojis: ["mxc://example.org/party"],
                                                                    emojiProvider: EmojiProvider(userSettings: .mock()),
                                                                    continuation: AsyncStream<String>.makeStream().continuation,
                                                                    loadCustomEmojiPacks: { [emojis] in [EmojiPack(id: "user", kind: .user, name: "Your emoji", emojis: emojis)] },
                                                                    mediaProvider: MediaProviderMock(.init()))
    
    static var previews: some View {
        CompletionSuggestionView(mediaProvider: MediaProviderMock(.init()),
                                 items: emojis.map { SuggestionItem(suggestionType: .customEmoji($0), range: .init(), rawSuggestionText: "par") }) { _ in }
            .previewDisplayName("Suggestions")
        
        EmojiPickerScreen(context: pickerViewModel.context)
            .previewDisplayName("Reaction picker")
            .snapshotPreferences(expect: pickerViewModel.context.observe(\.viewState.categories).map { $0.contains { $0.packName != nil } })
    }
}
