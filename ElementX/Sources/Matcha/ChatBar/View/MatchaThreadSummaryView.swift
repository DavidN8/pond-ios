//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

/// The bubble summary of a thread the chat's store knows, like Android's thread footer: its name (the root's text until it is named)
/// and the replies people see, then who replied last. A named thread nobody answered yet shows only its name, since its one reply
/// is the hidden one that named it.
struct MatchaThreadSummaryView: View {
    @EnvironmentObject private var context: TimelineViewModel.Context
    
    let threadSummary: TimelineItemThreadSummary
    let thread: MatchaThreadInfo
    
    /// The replies people see, or 0 while the summary is loading.
    private var replies: Int {
        guard case let .loaded(_, _, _, numberOfReplies) = threadSummary else { return 0 }
        return max(numberOfReplies - thread.hiddenReplies, 0)
    }
    
    var body: some View {
        HStack(spacing: 4) {
            CompoundIcon(\.threads, size: .xSmall, relativeTo: .compound.bodyXS)
                .foregroundColor(.compound.iconAccentPrimary)
                .accessibilityLabel(L10n.commonThread)
            
            Text(thread.name ?? UntranslatedL10n.commonMatchaThreadUntitled)
                .font(.compound.bodyXSSemibold)
                .foregroundColor(thread.name == nil ? MatchaColors.bubbleSecondaryText : .compound.textPrimary)
            
            if replies > 0, case let .loaded(senderID, sender, _, _) = threadSummary {
                Text("· " + L10n.commonReplies(replies))
                    .font(.compound.bodyXS)
                    .foregroundColor(MatchaColors.bubbleSecondaryText)
                    .layoutPriority(1)
                
                LoadableAvatarImage(url: sender.avatarURL,
                                    name: sender.displayName,
                                    contentID: senderID,
                                    avatarSize: .user(on: .threadSummary),
                                    mediaProvider: context.mediaProvider)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .lineLimit(1)
        .padding(.vertical, 7.0)
        .padding(.horizontal, 8.0)
        .background(Color.compound.bgSubtlePrimary)
        .cornerRadius(8)
    }
}

// MARK: - Previews

struct MatchaThreadSummaryView_Previews: PreviewProvider, TestablePreview {
    static let viewModel = TimelineViewModel.mock
    static let alice = TimelineItemSender(id: "@alice:matrix.org", displayName: "Alice")
    
    static var previews: some View {
        VStack(alignment: .leading, spacing: 20) {
            // A named thread nobody answered: its only reply is the hidden one.
            MatchaThreadSummaryView(threadSummary: .loaded(senderID: alice.id, sender: alice, latestEventContent: .redacted, numberOfReplies: 1),
                                    thread: MatchaThreadInfo(name: "Launch plan", isNamed: true, isArchived: false, hiddenReplies: 1))
            MatchaThreadSummaryView(threadSummary: .loaded(senderID: alice.id, sender: alice,
                                                           latestEventContent: .message(.text(.init(body: "Sounds good"))), numberOfReplies: 4),
                                    thread: MatchaThreadInfo(name: "Launch plan", isNamed: true, isArchived: false, hiddenReplies: 1))
            MatchaThreadSummaryView(threadSummary: .loading,
                                    thread: MatchaThreadInfo(name: nil, isNamed: true, isArchived: false, hiddenReplies: 0))
        }
        .padding()
        .environmentObject(viewModel.context)
        .previewLayout(.sizeThatFits)
    }
}
