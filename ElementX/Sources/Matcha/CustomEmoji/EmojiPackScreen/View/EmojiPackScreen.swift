//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import MatchaProtocol
import SwiftUI

/// A custom emoji pack, as the web client's `EmojiPackSettingsView`: upload emoji or stickers from the photo library, tap one to rename
/// it, swipe to remove it. Images show their first frame.
struct EmojiPackScreen: View {
    @Bindable var context: EmojiPackScreenViewModel.Context
    
    var body: some View {
        Form {
            uploadSection
            switch context.viewState.loadState {
            case .loading:
                Section {
                    ListRow(label: .plain(title: L10n.commonLoading), details: .isWaiting(true), kind: .label)
                }
            case .failed:
                Section {
                    ListRow(label: .plain(title: L10n.errorUnknown), kind: .label)
                    ListRow(label: .action(title: L10n.actionRetry, icon: \.restart), kind: .button { context.send(viewAction: .retry) })
                }
            case .loaded:
                imageSection(context.viewState.emojis,
                             count: UntranslatedL10n.screenMatchaEmojiCount(context.viewState.emojis.count),
                             empty: UntranslatedL10n.screenMatchaEmojiEmpty,
                             isLast: false)
                imageSection(context.viewState.stickers,
                             count: UntranslatedL10n.screenMatchaStickersCount(context.viewState.stickers.count),
                             empty: UntranslatedL10n.screenMatchaStickersEmpty,
                             isLast: true)
            }
        }
        .compoundList()
        .navigationTitle(UntranslatedL10n.screenMatchaEmojiTitle)
        .navigationBarTitleDisplayMode(.inline)
        .alert(item: $context.alertInfo)
    }
    
    // MARK: - Private
    
    private var uploadSection: some View {
        Section {
            if context.viewState.canEdit {
                ListRow(label: .default(title: UntranslatedL10n.screenMatchaEmojiUpload, icon: \.reactionAdd),
                        details: .isWaiting(context.viewState.isBusy),
                        kind: .button { context.send(viewAction: .upload(.emoticon)) })
                    .disabled(!context.viewState.isEditable)
                    .accessibilityValue(context.viewState.isBusy ? UntranslatedL10n.screenMatchaEmojiBusy : "")
                ListRow(label: .default(title: UntranslatedL10n.screenMatchaStickersUpload, icon: \.sticker),
                        kind: .button { context.send(viewAction: .upload(.sticker)) })
                    .disabled(!context.viewState.isEditable)
            }
        } footer: {
            Text(context.viewState.canEdit ? "\(context.viewState.description)\n\n\(UntranslatedL10n.screenMatchaEmojiUploadHint)" : context.viewState.description)
                .compoundListSectionFooter()
        }
    }
    
    /// The pack's emoji or its stickers; the read-only note goes under the last one.
    private func imageSection(_ images: [CustomEmoji], count: String, empty: String, isLast: Bool) -> some View {
        Section {
            if images.isEmpty {
                ListRow(label: .plain(title: empty), kind: .label)
            }
            ForEach(images, id: \.shortcode) { image in
                emojiRow(image)
            }
        } header: {
            if !images.isEmpty {
                Text(count)
                    .compoundListSectionHeader()
            }
        } footer: {
            if isLast, !context.viewState.canEdit {
                Text(UntranslatedL10n.screenMatchaEmojiReadOnly)
                    .compoundListSectionFooter()
            }
        }
    }
    
    @ViewBuilder
    private func emojiRow(_ emoji: CustomEmoji) -> some View {
        let code = ":\(emoji.shortcode):"
        let label = ListRowLabel.avatar(title: code,
                                        icon: CustomEmojiImage(url: emoji.url, size: 32, mediaProvider: context.mediaProvider)
                                            .accessibilityHidden(true))
        if context.viewState.canEdit {
            ListRow(label: label, kind: .button { context.send(viewAction: .rename(shortcode: emoji.shortcode)) })
                .disabled(!context.viewState.isEditable)
                .accessibilityHint(UntranslatedL10n.screenMatchaEmojiNameLabel(code))
                .swipeActions {
                    if context.viewState.isEditable {
                        Button(role: .destructive) {
                            context.send(viewAction: .remove(shortcode: emoji.shortcode))
                        } label: {
                            Label(L10n.actionRemove, icon: \.delete)
                        }
                        .accessibilityLabel(UntranslatedL10n.screenMatchaEmojiRemove(code))
                    }
                }
        } else {
            ListRow(label: label, kind: .label)
        }
    }
}

// MARK: - Previews

struct EmojiPackScreen_Previews: PreviewProvider, TestablePreview {
    private static let pack = #"""
    {"images": {"party_parrot": {"url": "mxc://example.org/parrot"}, "wave": {"url": "mxc://example.org/wave"},
                "sticker": {"url": "mxc://example.org/sticker", "usage": ["sticker"]}}}
    """#
    
    static let roomViewModel = makeViewModel(room: .init(name: "Crew", members: .allMembersAsAdmin), serverPack: .success(pack))
    static let readOnlyViewModel = makeViewModel(room: .init(name: "Crew", isSpace: true), serverPack: .success(pack))
    static let personalViewModel = makeViewModel(room: nil, serverPack: nil)
    static let loadingViewModel = makeViewModel(room: .init(name: "Crew", members: .allMembersAsAdmin), serverPack: nil)
    static let failedViewModel = makeViewModel(room: .init(name: "Crew", members: .allMembersAsAdmin), serverPack: .failure(.sdkError(RoomProxyMockError.generic)))
    
    static var previews: some View {
        preview(roomViewModel, isLoaded: true)
            .previewDisplayName("Room pack")
        preview(readOnlyViewModel, isLoaded: true)
            .previewDisplayName("Space pack, read only")
        preview(personalViewModel, isLoaded: true)
            .previewDisplayName("Empty personal pack")
        preview(loadingViewModel, isLoaded: false)
            .previewDisplayName("Loading")
        preview(failedViewModel, isLoaded: false)
            .previewDisplayName("Failed")
    }
    
    private static func preview(_ viewModel: EmojiPackScreenViewModel, isLoaded: Bool) -> some View {
        ElementNavigationStack {
            EmojiPackScreen(context: viewModel.context)
        }
        .snapshotPreferences(expect: viewModel.context.observe(\.viewState.loadState).map { $0 != .loading || !isLoaded })
    }
    
    /// A room's pack screen whose read of the server's pack gives `serverPack`, or never ends when nil; the empty personal pack
    /// without a room.
    private static func makeViewModel(room: JoinedRoomProxyMockConfiguration?, serverPack: Result<String?, RoomProxyError>?) -> EmojiPackScreenViewModel {
        let clientProxy = ClientProxyMock(.init())
        let target: EmojiPackTarget
        if let room {
            let roomProxy = JoinedRoomProxyMock(room)
            roomProxy.fetchStateEventContentJSONTypeStateKeyClosure = { _, _ in
                guard let serverPack else {
                    try? await Task.sleep(for: .seconds(3600))
                    return .success(nil)
                }
                return serverPack
            }
            target = .room(roomProxy)
        } else {
            target = .user
        }
        return EmojiPackScreenViewModel(target: target,
                                        clientProxy: clientProxy,
                                        customEmojiPacks: CustomEmojiPacks(clientProxy: clientProxy),
                                        mediaProvider: MediaProviderMock(.init()))
    }
}
