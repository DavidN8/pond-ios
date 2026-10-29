//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import MatchaProtocol
import SwiftUI

/// The chip bar under a chat's top bar and its warning strip; it also hosts the New thread and Rename thread sheet, so ⋯ can
/// open it in a chat that has no bar yet.
struct ChatBarView: View {
    @Bindable var context: ChatBarViewModel.Context
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isKeyboardShown = false
    /// Counts chip taps, for the selection haptic.
    @State private var chipTaps = 0
    
    var body: some View {
        VStack(spacing: 0) {
            if Self.showsChips(showsBar: context.viewState.showsBar,
                               verticalSizeClass: verticalSizeClass,
                               horizontalSizeClass: horizontalSizeClass,
                               isKeyboardShown: isKeyboardShown) {
                chips
                if let warning = context.viewState.warning {
                    MatchaWarningStrip(text: warning.message)
                }
            }
        }
        .background(Color.compound.bgCanvasDefault)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in isKeyboardShown = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in isKeyboardShown = false }
        .sheet(item: $context.threadNameSheet) { _ in
            ThreadNameSheetView(context: context)
        }
    }
    
    private var chips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(title: UntranslatedL10n.screenMatchaThreadsGeneral, target: .general)
                    
                    // Namespaced ids, so a thread can never collide with the fixed chips.
                    ForEach(context.viewState.threads) { thread in
                        threadChip(thread)
                            .id("thread:" + thread.id)
                    }
                    
                    if context.viewState.canCreateThread {
                        Button { context.send(viewAction: .newThread) } label: {
                            Label(UntranslatedL10n.commonMatchaNewThread, icon: \.plus)
                        }
                        .buttonStyle(ChatBarChipStyle(isSelected: false))
                    }
                    
                    if !MatchaChatMoreItems.isEmpty(context.viewState, dynamicTypeSize: dynamicTypeSize) {
                        Menu {
                            MatchaChatMoreItems(context: context)
                        } label: {
                            CompoundIcon(\.overflowHorizontal, size: .xSmall, relativeTo: .compound.bodyMD)
                        }
                        .menuStyle(.button)
                        .buttonStyle(ChatBarChipStyle(isSelected: false))
                        .accessibilityLabel(UntranslatedL10n.commonMatchaMore)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .sensoryFeedback(.selection, trigger: chipTaps)
            .onAppear { scrollToSelection(proxy, animated: false) }
            .onChange(of: context.viewState.threads) { scrollToSelection(proxy, animated: true) }
        }
    }
    
    private func chip(title: String, target: ChatBarSelection) -> some View {
        Button {
            chipTaps += 1
            context.send(viewAction: .select(target))
        } label: {
            Text(title)
        }
        .buttonStyle(ChatBarChipStyle(isSelected: context.viewState.selection == target))
        .accessibilityAddTraits(context.viewState.selection == target ? .isSelected : [])
    }
    
    private func threadChip(_ thread: ChatBarThread) -> some View {
        let name = thread.name ?? UntranslatedL10n.commonMatchaThreadUntitled
        let isSelected = context.viewState.selection == .thread(id: thread.id)
        return Button {
            chipTaps += 1
            context.send(viewAction: .select(.thread(id: thread.id)))
        } label: {
            HStack(spacing: 4) {
                if thread.isArchived {
                    CompoundIcon(asset: Asset.Images.matchaArchive, size: .xSmall, relativeTo: .compound.bodyMD)
                        .accessibilityLabel(UntranslatedL10n.a11yMatchaThreadArchived)
                }
                Text(name)
                    .lineLimit(1)
                    .frame(maxWidth: 160)
            }
        }
        .buttonStyle(ChatBarChipStyle(isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            if context.viewState.canManageThreads {
                Button { context.send(viewAction: .renameThread(id: thread.id)) } label: {
                    Label(UntranslatedL10n.screenMatchaThreadsRenameTitle, icon: \.edit)
                }
                Button { context.send(viewAction: .setArchived(threadID: thread.id, archived: !thread.isArchived)) } label: {
                    if thread.isArchived {
                        Label(UntranslatedL10n.actionMatchaUnarchive, systemImage: "tray.and.arrow.up")
                    } else {
                        Label { Text(UntranslatedL10n.actionMatchaArchive) } icon: { Asset.Images.matchaArchive.swiftUIImage }
                    }
                }
            }
            if context.viewState.canRemind {
                Button { context.send(viewAction: .remindMe(threadID: thread.id)) } label: {
                    Label(UntranslatedL10n.actionMatchaRemindMe, icon: \.notifications)
                }
            }
            Button { context.send(viewAction: .viewTask(threadID: thread.id)) } label: {
                Label(UntranslatedL10n.screenMatchaThreadsViewTask, icon: \.checkCircle)
            }
        }
    }
    
    private func scrollToSelection(_ proxy: ScrollViewProxy, animated: Bool) {
        guard case .thread(let id) = context.viewState.selection else { return }
        withAnimation(animated ? .elementDefault : nil) {
            proxy.scrollTo("thread:" + id)
        }
    }
    
    /// The bar gives way to the content on a short window (a phone in landscape), and to the keyboard on a narrow one (spec §4a).
    static func showsChips(showsBar: Bool, verticalSizeClass: UserInterfaceSizeClass?, horizontalSizeClass: UserInterfaceSizeClass?, isKeyboardShown: Bool) -> Bool {
        showsBar && verticalSizeClass != .compact && !(isKeyboardShown && horizontalSizeClass == .compact)
    }
}

extension EnvironmentValues {
    /// matcha: the chat's chip bar, for the composer's Task item; nil outside a chat with the Matcha features.
    @Entry var matchaChatBar: ChatBarViewModel.Context?
}

/// Remind me and Space notes: the bar's More chip, and the top bar's ⋯ while the chat has no bar (Android's More chip). At
/// accessibility text sizes All threads too, which leaves the top bar for the chat's name.
struct MatchaChatMoreItems: View {
    let context: ChatBarViewModel.Context
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Button { context.send(viewAction: .allThreads) } label: {
                Label(UntranslatedL10n.commonMatchaAllThreads, icon: \.threads)
            }
        }
        if context.viewState.canRemind {
            Button { context.send(viewAction: .remindMe(threadID: nil)) } label: {
                Label(UntranslatedL10n.actionMatchaRemindMe, icon: \.notifications)
            }
        }
        let spaces = context.viewState.chat.parentSpaces
        if spaces.count == 1, let space = spaces.first {
            Button { context.send(viewAction: .openSpaceNotes(spaceID: space.id)) } label: {
                spaceNotesLabel
            }
        } else if spaces.count > 1 {
            // With several joined parent spaces the user picks one first, as on Android.
            Menu {
                ForEach(spaces, id: \.id) { space in
                    Button(space.name) { context.send(viewAction: .openSpaceNotes(spaceID: space.id)) }
                }
            } label: {
                spaceNotesLabel
            }
        }
    }
    
    private var spaceNotesLabel: some View {
        Label { Text(UntranslatedL10n.commonMatchaSpaceDocs) } icon: { CompoundIcon(asset: Asset.Images.matchaNotes) }
    }
    
    static func isEmpty(_ viewState: ChatBarViewState, dynamicTypeSize: DynamicTypeSize) -> Bool {
        !dynamicTypeSize.isAccessibilitySize && !viewState.canRemind && viewState.chat.parentSpaces.isEmpty
    }
}

/// The chips of the bar, like the re-skinned room list filters (WHATSAPP_DESIGN §4a): 32 pt capsules, filled and borderless, tonal
/// green and semibold when selected.
struct ChatBarChipStyle: ButtonStyle {
    let isSelected: Bool
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(isSelected ? .compound.bodyMDSemibold : .compound.bodyMD)
            .foregroundStyle(isSelected ? .compound.textBadgeAccent : .compound.textSecondary)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(isSelected ? Color.compound.bgAccentSubtle : .compound.bgSubtleSecondary, in: Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Capsule())
    }
}

/// A one-line notice under a bar, shared with the task board.
struct MatchaWarningStrip: View {
    let text: String
    /// One line under a bar; the board's notices take three, as on Android.
    var lineLimit = 1
    
    var body: some View {
        Label {
            Text(text)
                .lineLimit(lineLimit)
        } icon: {
            CompoundIcon(\.warning, size: .xSmall, relativeTo: .compound.bodySM)
        }
        .font(.compound.bodySM)
        .foregroundStyle(MatchaColors.noticePillText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(minHeight: 32)
        .background(MatchaColors.noticePillBackground)
    }
}

extension MatchaWarning {
    var message: String {
        switch self {
        case .undecryptable: UntranslatedL10n.screenMatchaThreadsWarningUndecryptable
        case .historyUnavailable: UntranslatedL10n.screenMatchaThreadsWarningHistory
        case .noAccess: UntranslatedL10n.screenMatchaThreadsWarningAccess
        case .network: UntranslatedL10n.screenMatchaThreadsWarningNetwork
        }
    }
}

// MARK: - Previews

struct ChatBarView_Previews: PreviewProvider, TestablePreview {
    static let threads = [ChatBarThread(id: "$t1", name: "Launch plan", isArchived: false),
                          ChatBarThread(id: "$t2", name: "Design review for the onboarding flow and the new home screen", isArchived: false),
                          ChatBarThread(id: "$t3", name: "Bugs", isArchived: false),
                          ChatBarThread(id: "$t4", name: nil, isArchived: false)]
    
    static var previews: some View {
        VStack(spacing: 16) {
            ChatBarView(context: makeViewModel().context)
            ChatBarView(context: makeViewModel(selection: .thread(id: "$t2")).context)
            ChatBarView(context: makeViewModel(selection: .thread(id: "$old"),
                                               threads: threads + [ChatBarThread(id: "$old", name: "Venue shortlist", isArchived: true)],
                                               canCreateThread: false).context)
            ChatBarView(context: makeViewModel(warning: .undecryptable).context)
            // The More chip, with Remind me.
            ChatBarView(context: makeViewModel(threads: Array(threads.prefix(1)), canRemind: true).context)
            Spacer()
        }
        .previewDisplayName("States")
    }
    
    static func makeViewModel(selection: ChatBarSelection = .general,
                              threads: [ChatBarThread] = threads,
                              canCreateThread: Bool = true,
                              canRemind: Bool = false,
                              warning: MatchaWarning? = nil) -> ChatBarViewModel {
        ChatBarViewModel.mock(selection: selection, threads: threads, canCreateThread: canCreateThread, canRemind: canRemind, warning: warning)
    }
}
