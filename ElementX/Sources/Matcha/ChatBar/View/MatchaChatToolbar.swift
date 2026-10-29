//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

/// Starting a call from ⋯, with the rules of the call buttons it replaces.
struct MatchaStartCall {
    /// Voice calls are only offered in DMs.
    let isDM: Bool
    let canStartCall: Bool
    let action: (_ isVoiceCall: Bool) -> Void
}

/// The chat's top bar actions with the Matcha workspaces: All threads, the task board with its open-task count, and ⋯. Starting a
/// call moves into ⋯; an ongoing call keeps its Join button in the bar, since it can't wait in a menu, and All threads moves into ⋯
/// meanwhile so the chat's name keeps its room on a narrow phone. At accessibility text sizes All threads is with the More items
/// (the bar's More chip, else ⋯) for the same reason. Until the chat has a chip bar, its New thread is in ⋯, so a chat that doesn't
/// use threads yet can start one. ⋯ is left out when it would be empty.
struct MatchaChatToolbar: ToolbarContent {
    let context: ChatBarViewModel.Context
    /// Nil while calls are hidden or a call is ongoing.
    var startCall: MatchaStartCall?
    var isJoinShown = false
    
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    
    var body: some ToolbarContent {
        if !isJoinShown, !dynamicTypeSize.isAccessibilitySize {
            ToolbarItem(placement: .primaryAction) {
                allThreadsButton
            }
        }
        
        ToolbarItem(placement: .primaryAction) {
            Button { context.send(viewAction: .board) } label: {
                CompoundIcon(asset: Asset.Images.matchaBoard)
                    .overlay(alignment: .topTrailing) {
                        if context.viewState.openTaskCount > 0 {
                            // Off the icon's corner, inside the button's 44 pt glass.
                            MatchaCounterBadge(count: context.viewState.openTaskCount)
                                .offset(x: 10, y: -8)
                        }
                    }
            }
            .accessibilityLabel(tasksLabel)
        }
        
        if startCall != nil || isJoinShown || showsNewThread || showsMoreItems {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    menuItems
                } label: {
                    CompoundIcon(\.overflowHorizontal)
                }
                .accessibilityLabel(UntranslatedL10n.commonMatchaMore)
            }
        }
    }
    
    private var allThreadsButton: some View {
        Button { context.send(viewAction: .allThreads) } label: {
            Label(UntranslatedL10n.commonMatchaAllThreads, icon: \.threads)
        }
    }
    
    private var showsNewThread: Bool {
        context.viewState.canCreateThread && !context.viewState.showsBar
    }
    
    /// Remind me and Space notes, which the bar's More chip has while it is shown.
    private var showsMoreItems: Bool {
        !context.viewState.showsBar && !MatchaChatMoreItems.isEmpty(context.viewState, dynamicTypeSize: dynamicTypeSize)
    }
    
    private var tasksLabel: String {
        let count = context.viewState.openTaskCount
        return count > 0 ? "\(UntranslatedL10n.commonMatchaTasks), \(UntranslatedL10n.a11yMatchaOpenTasks(count))" : UntranslatedL10n.commonMatchaTasks
    }
    
    @ViewBuilder
    private var menuItems: some View {
        if let startCall {
            if startCall.isDM {
                Button { startCall.action(true) } label: {
                    Label(L10n.actionVoiceCall, icon: \.voiceCall)
                }
                .disabled(!startCall.canStartCall)
            }
            Button { startCall.action(false) } label: {
                Label(L10n.actionVideoCall, icon: \.videoCall)
            }
            .disabled(!startCall.canStartCall)
        }
        if isJoinShown, !dynamicTypeSize.isAccessibilitySize {
            allThreadsButton
        }
        if showsNewThread {
            Button { context.send(viewAction: .newThread) } label: {
                Label(UntranslatedL10n.commonMatchaNewThread, icon: \.plus)
            }
        }
        if showsMoreItems {
            MatchaChatMoreItems(context: context)
        }
    }
}

/// The Chats tab's green count, on the board button (Android's `CounterAtom`), in place of the system's red badge.
struct MatchaCounterBadge: View {
    let count: Int
    
    var body: some View {
        Text(count.formatted())
            .font(.compound.bodyXSSemibold)
            .foregroundStyle(.compound.textOnSolidPrimary)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .background(.compound.bgAccentRest, in: Capsule())
            .fixedSize()
            .accessibilityHidden(true)
    }
}

// MARK: - Previews

struct MatchaChatToolbar_Previews: PreviewProvider, TestablePreview {
    static let viewModel = ChatBarViewModel.mock(canCreateThread: true, openTaskCount: 3)
    static let noChipBarViewModel = ChatBarViewModel.mock(showsBar: false, canCreateThread: true, openTaskCount: 12)
    static let noTasksViewModel = ChatBarViewModel.mock()
    
    static var previews: some View {
        ElementNavigationStack {
            Color.clear.toolbar { MatchaChatToolbar(context: viewModel.context) }
        }
        .previewDisplayName("Open tasks")
        
        ElementNavigationStack {
            Color.clear.toolbar { MatchaChatToolbar(context: noChipBarViewModel.context) }
        }
        .previewDisplayName("No chip bar yet")
        
        ElementNavigationStack {
            Color.clear.toolbar { MatchaChatToolbar(context: noTasksViewModel.context) }
        }
        .previewDisplayName("No open tasks, can't create threads")
        
        ElementNavigationStack {
            Color.clear.toolbar {
                MatchaChatToolbar(context: viewModel.context, startCall: MatchaStartCall(isDM: true, canStartCall: true) { _ in })
            }
        }
        .previewDisplayName("Calls shown")
        
        ElementNavigationStack {
            Color.clear.toolbar { MatchaChatToolbar(context: viewModel.context, isJoinShown: true) }
        }
        .previewDisplayName("Ongoing call")
        
        ElementNavigationStack {
            Color.clear.toolbar { MatchaChatToolbar(context: viewModel.context) }
        }
        .dynamicTypeSize(.accessibility1)
        .previewDisplayName("Accessibility text size")
    }
}
