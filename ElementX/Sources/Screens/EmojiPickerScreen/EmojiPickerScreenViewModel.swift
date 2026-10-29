//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import MatchaProtocol
import SwiftUI

typealias EmojiPickerScreenViewModelType = StateStoreViewModelV2<EmojiPickerScreenViewState, EmojiPickerScreenViewAction>

class EmojiPickerScreenViewModel: EmojiPickerScreenViewModelType, EmojiPickerScreenViewModelProtocol {
    private let emojiProvider: EmojiProviderProtocol
    private let continuation: EmojiPickerScreenContinuation
    private let loadCustomEmojiPacks: CustomEmojiPacksLoader? // matcha
    private var customEmojiPacks = [EmojiPack]() // matcha
    private var searchString: String? // matcha: the custom emoji are searched here
    
    private var actionsSubject: PassthroughSubject<EmojiPickerScreenViewModelAction, Never> = .init()
    var actions: AnyPublisher<EmojiPickerScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(mode: EmojiPickerScreenMode = .reaction,
         selectedEmojis: Set<String>,
         emojiProvider: EmojiProviderProtocol,
         continuation: EmojiPickerScreenContinuation,
         loadCustomEmojiPacks: CustomEmojiPacksLoader? = nil, // matcha
         mediaProvider: MediaProviderProtocol? = nil) { // matcha
        let initialViewState = EmojiPickerScreenViewState(mode: mode, categories: [], selectedEmojis: selectedEmojis)
        self.emojiProvider = emojiProvider
        self.continuation = continuation
        self.loadCustomEmojiPacks = loadCustomEmojiPacks // matcha
        super.init(initialViewState: initialViewState, mediaProvider: mediaProvider) // matcha: mediaProvider
        loadEmojis()
        loadCustomEmoji() // matcha
    }
    
    // MARK: - Public
    
    func stop() {
        continuation.finish() // Ensure the continuation always finishes even without a selection.
    }
    
    override func process(viewAction: EmojiPickerScreenViewAction) {
        switch viewAction {
        case let .search(searchString: searchString):
            self.searchString = searchString // matcha
            Task {
                let categories = await emojiProvider.categories(searchString: searchString)
                state.categories = convert(emojiCategories: categories)
            }
        case let .emojiTapped(emoji: emoji):
            selectEmoji(emoji)
        case .dismiss:
            actionsSubject.send(.dismiss)
        }
    }
    
    // MARK: - Private
    
    private func loadEmojis() {
        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let categories = await self.emojiProvider.categories(searchString: nil)
            self.state.categories = convert(emojiCategories: categories)
        }
    }
    
    private func convert(emojiCategories: [EmojiCategory]) -> [EmojiPickerEmojiCategoryViewData] {
        emojiCategories.compactMap { emojiCategory in
            let emojisViewData: [EmojiPickerEmojiViewData] = emojiCategory.emojis.compactMap { emojiItem in
                EmojiPickerEmojiViewData(id: "\(emojiCategory.id)-\(emojiItem.id)", value: emojiItem.unicode)
            }
            
            return EmojiPickerEmojiCategoryViewData(id: emojiCategory.id, emojis: emojisViewData)
        }
        .insertingCustomEmoji(customEmojiCategories) // matcha
    }
    
    private func selectEmoji(_ emoji: EmojiPickerEmojiViewData) {
        emojiProvider.markEmojiAsFrequentlyUsed(emoji.value)
        
        continuation.yield(emoji.value)
        continuation.finish()
        
        actionsSubject.send(.dismiss)
    }
}

// MARK: - Matcha

private extension EmojiPickerScreenViewModel {
    /// One category per custom emoji pack of the room, matching the search by shortcode.
    var customEmojiCategories: [EmojiPickerEmojiCategoryViewData] {
        customEmojiPacks.compactMap { pack in
            let emojis = pack.emojis
                .filter { searchString?.isEmpty != false || $0.shortcode.range(of: searchString ?? "", options: .caseInsensitive) != nil }
                .map { EmojiPickerEmojiViewData(id: "custom:\(pack.id)-\($0.shortcode)", value: $0.url, customEmojiName: ":\($0.shortcode):") }
            return emojis.isEmpty ? nil : EmojiPickerEmojiCategoryViewData(id: "custom:\(pack.id)", emojis: emojis, packName: pack.name)
        }
    }
    
    /// Reads the room's packs as the picker opens, then shows them.
    func loadCustomEmoji() {
        guard let loadCustomEmojiPacks else { return }
        Task { [weak self] in
            let packs = await loadCustomEmojiPacks()
            guard let self, !packs.isEmpty else { return }
            customEmojiPacks = packs
            let categories = await emojiProvider.categories(searchString: searchString)
            state.categories = convert(emojiCategories: categories)
        }
    }
}

private extension [EmojiPickerEmojiCategoryViewData] {
    /// Custom emoji go after the frequently used emoji and before the others, as on the web client.
    func insertingCustomEmoji(_ categories: [EmojiPickerEmojiCategoryViewData]) -> Self {
        var result = self
        result.insert(contentsOf: categories, at: first?.id == EmojiCategory.frequentlyUsedCategoryIdentifier ? 1 : 0)
        return result
    }
}
