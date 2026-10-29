//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct ThreadTimelineScreen: View {
    @ObservedObject private var context: ThreadTimelineScreenViewModelType.Context
    @ObservedObject private var timelineContext: TimelineViewModelType.Context
    private let composerToolbar: ComposerToolbar
    private let chatBarContext: ChatBarViewModel.Context? // matcha
    
    init(context: ThreadTimelineScreenViewModelType.Context,
         timelineContext: TimelineViewModelType.Context,
         composerToolbar: ComposerToolbar,
         chatBarContext: ChatBarViewModel.Context? = nil) {
        self.context = context
        self.timelineContext = timelineContext
        self.composerToolbar = composerToolbar
        self.chatBarContext = chatBarContext
    }
    
    var body: some View {
        TimelineView(timelineContext: timelineContext)
            .background(.compound.bgCanvasDefault)
            .toolbarRole(RoomHeaderView.toolbarRole)
            .navigationTitle(L10n.commonThread)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .toolbarBackground(.visible, for: .navigationBar) // Fix the toolbar's background.
            .navigationBarBackButtonHidden(isMessageSelectionActive)
            .timelineMediaPreview(viewModel: $context.mediaPreviewViewModel)
            .overlay(alignment: .top) {
                FloatingDateBadge(dateText: timelineContext.floatingDate?.formattedDateSeparator()) {
                    timelineContext.send(viewAction: .scrollToFirstItemForCurrentDate)
                }
                .padding(.top, 13)
            }
            .overlay(alignment: .bottomTrailing) {
                TimelineScrollButton(isHidden: !timelineContext.viewState.shouldShowScrollToBottomButton) {
                    timelineContext.send(viewAction: .scrollToBottom)
                }
            }
            .matchaChatBar(chatBarContext, isHidden: isMessageSelectionActive) // matcha
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    composer
                        .padding(.top, 8)
                        .background(MatchaColors.chatWallpaper.ignoresSafeArea()) // matcha: the timeline above is on the wallpaper too
                        .environmentObject(timelineContext)
                        .environment(\.timelineContext, timelineContext)
                        .environment(\.matchaChatBar, chatBarContext) // matcha: Task, as in the chat (Android's thread view has it too)
                        // Make sure the reply header honours the hideTimelineMedia setting too.
                        .environment(\.shouldAutomaticallyLoadImages, !timelineContext.viewState.hideTimelineMedia)
                        .collapsedInPlace(isMessageSelectionActive)
                    
                    if isMessageSelectionActive {
                        TimelineMessageSelectionActionBar(context: timelineContext)
                    }
                }
            }
    }
    
    private var isMessageSelectionActive: Bool {
        timelineContext.viewState.messageSelection.isActive
    }
    
    @ViewBuilder
    private var composer: some View {
        if context.viewState.canSendMessage {
            composerToolbar
        } else {
            ComposerDisabledView()
        }
    }
    
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // .principal + .primaryAction works better than .navigation leading + trailing
        // as the latter disables interaction in the action button for rooms with long names
        ToolbarItem(placement: .principal) {
            // matcha: like Android, a thread keeps the room's bar with who is typing below, else the thread's name.
            let subtitle = chatBarContext.map { $0.viewState.subtitle.thread(name: $0.viewState.threadName, typingMembers: timelineContext.viewState.typingMembers) }
            RoomHeaderView(roomName: chatBarContext == nil ? L10n.commonThread : context.viewState.roomTitle,
                           roomSubtitle: subtitle?.text ?? context.viewState.roomTitle,
                           isRoomSubtitleTyping: subtitle?.isTyping ?? false,
                           roomAvatar: context.viewState.roomAvatar,
                           dmRecipientDetails: context.viewState.dmRecipientDetails,
                           roomHistorySharingState: context.viewState.roomHistorySharingState,
                           mediaProvider: context.mediaProvider) {
                // There is no action but the iOS 26 designs have it looking like a button.
            }
        }
        
        if isMessageSelectionActive {
            TimelineMessageSelectionToolbar {
                timelineContext.send(viewAction: .clearMessageSelection)
            }
        } else if let chatBarContext { // matcha
            MatchaChatToolbar(context: chatBarContext)
        }
    }
}
