//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

extension View {
    /// matcha: the chip bar under a chat's top bar, and the banner of the chat's Matcha writes over the bottom of its timeline.
    /// The modifiers stay in place without a bar, so hiding it never rebuilds the timeline.
    func matchaChatBar(_ context: ChatBarViewModel.Context?, isHidden: Bool = false) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            if let context, !isHidden {
                ChatBarView(context: context)
            }
        }
        .overlay(alignment: .bottom) {
            if let chat = context?.viewState.chat {
                MatchaChatBannerView(chat: chat)
            }
        }
    }
}

/// "Thread archived · Undo", "Couldn't save · Retry": a toast with an action, which `UserIndicatorController` toasts don't have.
struct MatchaChatBannerView: View {
    let chat: MatchaChat
    
    var body: some View {
        VStack(spacing: 0) {
            if let banner = chat.banner {
                HStack(spacing: 16) {
                    Text(banner.message)
                        .font(.compound.bodyMD)
                        .foregroundStyle(.compound.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(banner.actionTitle, action: banner.action)
                        .buttonStyle(.compound(.textLink))
                        .font(.compound.bodyMDSemibold)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .id(banner.id)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityAction(named: banner.actionTitle, banner.action)
                // While VoiceOver runs the banner doesn't time out.
                .accessibilityAction(named: L10n.actionDismiss) { chat.dismissBanner() }
            }
        }
        .animation(.elementDefault, value: chat.banner?.id)
    }
}

// MARK: - Previews

struct MatchaChatBannerView_Previews: PreviewProvider, TestablePreview {
    static let viewModel = {
        let viewModel = ChatBarViewModel.mock()
        viewModel.context.viewState.chat.banner = MatchaChatBanner(message: "Thread archived", actionTitle: "Undo") { }
        return viewModel
    }()
    
    static var previews: some View {
        Color.compound.bgCanvasDefault
            .matchaChatBar(viewModel.context)
    }
}
