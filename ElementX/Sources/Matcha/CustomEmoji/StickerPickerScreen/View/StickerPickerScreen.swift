//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import MatchaProtocol
import SwiftUI

/// The composer's sticker sheet: a tab per pack over its grid of stickers, and a search of every pack by shortcode and body. Tapping a
/// sticker sends it. Animated stickers show their first frame, as custom emoji do.
struct StickerPickerScreen: View {
    @Bindable var context: StickerPickerScreenViewModel.Context
    
    @ScaledMetric(relativeTo: .title) private var stickerSize: Double = 88
    @ScaledMetric(relativeTo: .title) private var tabIconSize: Double = 32
    
    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.compound.bgCanvasDefault)
            .navigationTitle(UntranslatedL10n.screenMatchaStickersTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.actionCancel) { context.send(viewAction: .dismiss) }
                }
            }
            .searchable(text: $context.searchQuery, placement: .navigationBarDrawer(displayMode: .always))
            .compoundSearchField()
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
    }
    
    // MARK: - Private
    
    @ViewBuilder
    private var content: some View {
        if let packs = context.viewState.packs {
            if packs.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    if !context.viewState.isSearching {
                        tabs(packs)
                    }
                    grid
                }
            }
        } else {
            ProgressView()
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: 8) {
            CompoundIcon(\.sticker, size: .medium, relativeTo: .compound.headingMD)
                .foregroundStyle(.compound.iconSecondary)
            Text(UntranslatedL10n.screenMatchaStickersEmpty)
                .font(.compound.headingSMSemibold)
                .foregroundStyle(.compound.textPrimary)
            Text(UntranslatedL10n.screenMatchaStickersEmptyHint)
                .font(.compound.bodyMD)
                .foregroundStyle(.compound.textSecondary)
        }
        .multilineTextAlignment(.center)
        .padding(24)
    }
    
    private func tabs(_ packs: [EmojiPack]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(packs) { pack in
                    let isSelected = pack.id == context.viewState.selectedPackID
                    Button {
                        context.send(viewAction: .selectPack(id: pack.id))
                    } label: {
                        CustomEmojiImage(url: pack.avatarURL ?? pack.emojis.first?.url ?? "", size: tabIconSize, mediaProvider: context.mediaProvider)
                            .padding(6)
                            .background(isSelected ? Color.compound.bgSubtleSecondary : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .accessibilityLabel(pack.name)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }
    
    private var grid: some View {
        ScrollView {
            let packs = context.viewState.shownPacks
            if packs.isEmpty {
                Text(L10n.commonNoResults)
                    .font(.compound.bodyMD)
                    .foregroundStyle(.compound.textSecondary)
                    .padding(24)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: stickerSize), spacing: 8)], spacing: 8) {
                ForEach(packs) { pack in
                    Section {
                        ForEach(pack.emojis, id: \.shortcode) { sticker in
                            Button {
                                context.send(viewAction: .send(sticker))
                            } label: {
                                CustomEmojiImage(url: sticker.url, size: stickerSize, mediaProvider: context.mediaProvider)
                            }
                            .accessibilityLabel(sticker.body ?? sticker.shortcode)
                        }
                    } header: {
                        EmojiPickerScreenHeaderView(title: pack.name)
                            .padding(.top, 8)
                    }
                }
            }
            .padding(.horizontal, 12)
        }
    }
}

// MARK: - Previews

struct StickerPickerScreen_Previews: PreviewProvider, TestablePreview {
    static let packs = [
        EmojiPack(id: "user", kind: .user, name: "Your stickers", emojis: [
            CustomEmoji(shortcode: "pepe_happy", url: "mxc://example.org/happy", body: "Happy"),
            CustomEmoji(shortcode: "pepe_sad", url: "mxc://example.org/sad")
        ]),
        EmojiPack(id: "!room:example.org|", kind: .room, roomID: "!room:example.org", stateKey: "", name: "Crew", emojis: [
            CustomEmoji(shortcode: "party", url: "mxc://example.org/party")
        ])
    ]
    
    static let loadedViewModel = makeViewModel(packs: packs)
    static let searchViewModel = makeViewModel(packs: packs, searchQuery: "pepe")
    static let emptyViewModel = makeViewModel(packs: [])
    static let loadingViewModel = makeViewModel(packs: nil)
    
    static var previews: some View {
        preview(loadedViewModel, isLoaded: true)
            .previewDisplayName("Packs")
        preview(searchViewModel, isLoaded: true)
            .previewDisplayName("Search")
        preview(emptyViewModel, isLoaded: true)
            .previewDisplayName("No stickers")
        preview(loadingViewModel, isLoaded: false)
            .previewDisplayName("Loading")
    }
    
    private static func preview(_ viewModel: StickerPickerScreenViewModel, isLoaded: Bool) -> some View {
        ElementNavigationStack {
            StickerPickerScreen(context: viewModel.context)
        }
        .snapshotPreferences(expect: viewModel.context.observe(\.viewState.packs).map { $0 != nil || !isLoaded })
    }
    
    /// A picker whose packs are `packs`, or that never finishes loading when nil.
    private static func makeViewModel(packs: [EmojiPack]?, searchQuery: String = "") -> StickerPickerScreenViewModel {
        let viewModel = StickerPickerScreenViewModel(roomProxy: JoinedRoomProxyMock(.init()),
                                                     threadRootEventID: nil,
                                                     loadStickerPacks: {
                                                         guard let packs else {
                                                             try? await Task.sleep(for: .seconds(3600))
                                                             return []
                                                         }
                                                         return packs
                                                     },
                                                     mediaProvider: MediaProviderMock(.init()),
                                                     userIndicatorController: UserIndicatorControllerMock())
        viewModel.context.searchQuery = searchQuery
        return viewModel
    }
}
