//
// Copyright 2025 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct RoomThreadListScreen: View {
    @Bindable var context: RoomThreadListScreenViewModel.Context
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                matchaArchiveFilter // matcha
                
                ForEach(context.viewState.visibleItems) { item in // matcha: visibleItems
                    Button {
                        context.send(viewAction: .tappedThread(threadRootEventID: item.id))
                    } label: {
                        RoomThreadListCell(item: item, mediaProvider: context.mediaProvider, matchaThread: context.viewState.matchaThreads[item.id]) // matcha
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(ThreadCellButtonStyle())
                }
                
                footer
            }
        }
        .background(Color.compound.bgCanvasDefault.ignoresSafeArea())
        .navigationTitle(L10n.commonThreads)
        .navigationBarTitleDisplayMode(.inline)
    }
    
    /// matcha: the Active and Archived chips, and what each shows when empty.
    @ViewBuilder
    private var matchaArchiveFilter: some View {
        if let filter = context.archiveFilter {
            // The chip bar's chips, as Android's All threads.
            HStack(spacing: 8) {
                ForEach(ThreadArchiveFilter.allCases, id: \.self) { option in
                    Button { context.archiveFilter = option } label: {
                        Text(option == .active ? UntranslatedL10n.commonMatchaActive : UntranslatedL10n.commonMatchaArchived)
                    }
                    .buttonStyle(ChatBarChipStyle(isSelected: filter == option))
                    .accessibilityAddTraits(filter == option ? .isSelected : [])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .sensoryFeedback(.selection, trigger: filter)
            
            if context.viewState.visibleItems.isEmpty, !context.viewState.isPaginating {
                VStack(spacing: 8) {
                    Text(filter == .active ? UntranslatedL10n.screenMatchaThreadsListEmptyTitle : UntranslatedL10n.screenMatchaThreadsListArchivedEmpty)
                        .font(.compound.headingSMSemibold)
                        .foregroundStyle(.compound.textPrimary)
                    if filter == .active {
                        Text(UntranslatedL10n.screenMatchaThreadsListEmptyBody)
                            .font(.compound.bodyMD)
                            .foregroundStyle(.compound.textSecondary)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(32)
            }
        }
    }
    
    private var footer: some View {
        // Needs to be wrapped in a LazyStack otherwise appearance calls don't trigger
        LazyVStack(spacing: 0) {
            ProgressView()
                .padding()
                .opacity(context.viewState.isPaginating ? 1 : 0)
            
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(.compound.bgCanvasDefault)
                .onAppear {
                    context.send(viewAction: .oldestItemDidAppear)
                }
                .onDisappear {
                    context.send(viewAction: .oldestItemDidDisappear)
                }
        }
    }
}

private struct RoomThreadListCell: View {
    let item: RoomThreadListItem
    let mediaProvider: MediaProviderProtocol?
    /// matcha: the thread's shared name and hidden replies.
    var matchaThread: MatchaThreadInfo?
    
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            LoadableAvatarImage(url: item.rootMessageDetails.sender.avatarURL,
                                name: item.rootMessageDetails.sender.displayName,
                                contentID: item.rootMessageDetails.sender.id,
                                avatarSize: .user(on: .threadList),
                                mediaProvider: mediaProvider)
                .accessibilityHidden(true)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: 16) {
                    creatorDetails
                    Spacer()
                    timestamp
                }
                
                rootMessageDetails
                latestMessageDetails
            }
        }
    }
    
    private var creatorDetails: some View {
        Text(item.rootMessageDetails.sender.disambiguatedDisplayName ?? item.rootMessageDetails.sender.id)
            .font(.compound.bodyLGSemibold)
            .foregroundColor(.compound.textPrimary)
            .lineLimit(1)
    }
    
    @ViewBuilder
    private var rootMessageDetails: some View {
        if let matchaThread { // matcha: the shared name, else the root message, else "Untitled thread", as on Android
            Text(matchaThread.name ?? item.rootMessageDetails.message.map { String($0.characters) }?.matchaFirstLine ?? UntranslatedL10n.commonMatchaThreadUntitled)
                .font(.compound.bodyMD)
                .foregroundColor(.compound.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let message = item.rootMessageDetails.message {
            Text(message)
                .font(.compound.bodyMD)
                .foregroundColor(.compound.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    
    @ViewBuilder
    private var latestMessageDetails: some View {
        if let latestMessageDetails = item.latestMessageDetails {
            HStack(alignment: .center, spacing: 8) {
                Label {
                    Text("\(max(Int(item.numberOfReplies) - (matchaThread?.hiddenReplies ?? 0), 0))") // matcha: without the hidden reply
                        .font(.compound.bodySMSemibold)
                        .foregroundColor(.compound.textSecondary)
                } icon: {
                    CompoundIcon(\.threads, size: .small, relativeTo: .compound.bodySMSemibold)
                        .foregroundColor(.compound.iconSecondary)
                }
                .labelStyle(.custom(spacing: 4, alignment: .center, iconLayout: .trailing))
                
                LoadableAvatarImage(url: latestMessageDetails.sender.avatarURL,
                                    name: latestMessageDetails.sender.displayName,
                                    contentID: latestMessageDetails.sender.id,
                                    avatarSize: .user(on: .threadSummary),
                                    mediaProvider: mediaProvider)
                    .accessibilityHidden(true)
                
                if let message = latestMessageDetails.message {
                    Text(message)
                        .font(.compound.bodySM)
                        .foregroundColor(.compound.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
    
    private var timestamp: some View {
        if let latestMessageDetails = item.latestMessageDetails {
            Text(latestMessageDetails.timestamp.formattedMinimal())
                .font(.compound.bodySM)
                .foregroundColor(.compound.textSecondary)
        } else {
            Text(item.rootMessageDetails.timestamp.formattedTime())
                .font(.compound.bodySM)
                .foregroundColor(.compound.textSecondary)
        }
    }
}

private struct ThreadCellButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.compound.bgSubtleSecondary : Color.compound.bgCanvasDefault)
            .contentShape(Rectangle())
    }
}

// MARK: - Previews

struct RoomThreadListScreen_Previews: PreviewProvider, TestablePreview {
    static let viewModel = makeViewModel()
    // matcha: the Active chip with a named thread nobody answered yet, and the empty Archived chip.
    static let matchaViewModel = makeViewModel(matchaThreads: ["1": MatchaThreadInfo(name: "Launch plan", isNamed: true, isArchived: false, hiddenReplies: 1)])
    static let matchaArchivedViewModel = {
        let viewModel = makeViewModel(matchaThreads: [:])
        viewModel.context.archiveFilter = .archived
        return viewModel
    }()
    
    static var previews: some View {
        RoomThreadListScreen(context: viewModel.context)
        RoomThreadListScreen(context: matchaViewModel.context)
            .previewDisplayName("Matcha active")
        RoomThreadListScreen(context: matchaArchivedViewModel.context)
            .previewDisplayName("Matcha archived empty")
    }
    
    static func makeViewModel(matchaThreads: [String: MatchaThreadInfo]? = nil) -> RoomThreadListScreenViewModel {
        let viewModel = RoomThreadListScreenViewModel(threadListServiceProxy: RoomThreadListServiceProxyMock(.init()),
                                                      mediaProvider: MediaProviderMock(.init()))
        if let matchaThreads { // matcha
            viewModel.state.matchaThreads = matchaThreads
            viewModel.state.bindings.archiveFilter = .active
        }
        return viewModel
    }
}

// MARK: - Matcha

private extension String {
    /// The first line with text, trimmed, as Android names a thread after its root message.
    var matchaFirstLine: String? {
        split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }
}
