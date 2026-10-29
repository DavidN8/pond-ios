//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import MatchaProtocol
import MatrixRustSDK
import SwiftUI

/// The "Remind me" sheet. Present it inside a navigation stack; it dismisses itself through its view model's actions.
struct RemindMeScreen: View {
    @Bindable var context: RemindMeScreenViewModel.Context
    
    private var isSending: Bool {
        context.viewState.sending != nil
    }
    
    /// Read out by VoiceOver as it appears, like Android's live regions: it shows away from the button that caused it.
    private var announcement: String? {
        switch context.viewState.botState {
        case .joined where context.viewState.hasSendFailed: UntranslatedL10n.screenMatchaReminderErrorSend
        case .waiting: UntranslatedL10n.screenMatchaReminderBotWaiting
        case .canInvite(_, hasFailed: true): UntranslatedL10n.screenMatchaReminderBotInviteError
        default: nil
        }
    }
    
    var body: some View {
        Form {
            content
        }
        .compoundList()
        .safeAreaInset(edge: .bottom) {
            bottomButton
        }
        .navigationTitle(isInviteStep ? UntranslatedL10n.screenMatchaReminderBotInviteTitle : UntranslatedL10n.screenMatchaReminderTitle)
        .navigationSubtitle(context.viewState.chosenTime ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.actionCancel) {
                    context.send(viewAction: .cancel)
                }
                // Like the swipe: a send in flight still goes out, so the sheet waits for it.
                .disabled(isSending)
            }
            // The re-skin's sheets confirm at the top right; the subtitle says when.
            if case .joined = context.viewState.botState {
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button(UntranslatedL10n.screenMatchaReminderSet) {
                            context.send(viewAction: .confirm)
                        }
                        .disabled(!context.viewState.canConfirm)
                        .accessibilityLabel(context.viewState.confirmTitle)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(isSending)
        .onChange(of: announcement) { _, announcement in
            if let announcement {
                AccessibilityNotification.Announcement(announcement).post()
            }
        }
    }
    
    @ViewBuilder
    private var content: some View {
        switch context.viewState.botState {
        case .checking:
            ListRow(kind: .custom {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(ListRowPadding.insets)
            })
        case .joined:
            messageSection
            optionsSection
            if context.viewState.selectedOption == .custom {
                customSection
            }
        case .waiting(let isChecking):
            messageSection
            Section {
                ListRow(label: .plain(title: UntranslatedL10n.screenMatchaReminderBotWaiting),
                        details: .isWaiting(true),
                        kind: .label)
                ListRow(label: .plain(title: L10n.actionRetry),
                        details: .isWaiting(isChecking),
                        kind: .button { context.send(viewAction: .checkBotAgain) })
                    .disabled(isChecking)
            }
        case .canInvite(_, let hasFailed):
            infoSection(UntranslatedL10n.screenMatchaReminderBotInviteBody(context.viewState.botUserID),
                        error: hasFailed ? UntranslatedL10n.screenMatchaReminderBotInviteError : nil)
        case .cannotInvite:
            infoSection(UntranslatedL10n.screenMatchaReminderBotNoPermission)
        case .cannotSend:
            infoSection(UntranslatedL10n.screenMatchaReminderCannotSend)
        case .unavailableInDM:
            infoSection(UntranslatedL10n.screenMatchaReminderBotDmUnavailable)
        }
    }
    
    private var messageSection: some View {
        Section {
            ListRow(label: .plain(title: UntranslatedL10n.screenMatchaReminderMessageHint),
                    kind: .textField(text: $context.message, axis: .vertical))
                .lineLimit(1...4)
                .disabled(isSending)
        } footer: {
            if let error = context.viewState.messageError {
                errorText(error)
            } else if let link = context.viewState.link {
                Text(link == .message ? UntranslatedL10n.screenMatchaReminderLinkMessage : UntranslatedL10n.screenMatchaReminderLinkThread)
                    .compoundListSectionFooter()
            }
        }
    }
    
    /// A radio group with nothing chosen at first: choosing only fills in the confirm button, which posts.
    private var optionsSection: some View {
        Section {
            ForEach(context.viewState.quickOptions + [.custom], id: \.self) { option in
                ListRow(label: .plain(title: title(for: option)),
                        details: option == .custom ? nil : .title(context.viewState.label(for: option)),
                        kind: .selection(isSelected: context.viewState.selectedOption == option) {
                            context.send(viewAction: .select(option))
                        })
                        .disabled(isSending)
            }
        } footer: {
            if context.viewState.hasSendFailed {
                errorText(UntranslatedL10n.screenMatchaReminderErrorSend)
            } else {
                Text(UntranslatedL10n.screenMatchaReminderHelper)
                    .compoundListSectionFooter()
            }
        }
    }
    
    private var customSection: some View {
        Section {
            ListRow(kind: .custom {
                DatePicker(UntranslatedL10n.screenMatchaReminderCustom,
                           selection: $context.customDate,
                           in: context.viewState.now...context.viewState.now.addingTimeInterval(TimeInterval(MatchaConfig.reminderMaxDelayDays * 86400)),
                           displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.graphical)
                    .environment(\.timeZone, context.viewState.timeZone)
                    .padding(.horizontal, ListRowPadding.horizontal)
                    .disabled(isSending)
            })
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                let timeZone = context.viewState.timeZone
                Text(UntranslatedL10n.screenMatchaReminderTimezone(timeZone.identifier,
                                                                   RemindMeTimeFormatter.offset(of: timeZone, at: context.customDate)))
                    .compoundListSectionFooter()
                if let error = context.viewState.customError {
                    errorText(error)
                }
            }
        }
    }
    
    @ViewBuilder
    private var bottomButton: some View {
        switch context.viewState.botState {
        case .canInvite(let isInviting, _):
            Button {
                context.send(viewAction: .inviteBot)
            } label: {
                HStack(spacing: 8) {
                    if isInviting {
                        ProgressView()
                    }
                    Text(UntranslatedL10n.screenMatchaReminderBotInviteAction)
                }
            }
            .buttonStyle(.compound(.primary))
            .disabled(isInviting)
            .padding(16)
            .background(Color.compound.bgSubtleSecondaryLevel0.ignoresSafeArea())
        default:
            EmptyView()
        }
    }
    
    private var isInviteStep: Bool {
        if case .canInvite = context.viewState.botState {
            true
        } else {
            false
        }
    }
    
    private func infoSection(_ text: String, error: String? = nil) -> some View {
        Section {
            ListRow(label: .plain(title: text), kind: .label)
        } footer: {
            if let error {
                errorText(error)
            }
        }
    }
    
    private func title(for option: RemindMeOption) -> String {
        switch option {
        case .inHours(let hours): UntranslatedL10n.screenMatchaReminderInHours(hours)
        case .atDeadline: UntranslatedL10n.screenMatchaReminderAtDeadline
        case .custom: UntranslatedL10n.screenMatchaReminderCustom
        }
    }
    
    private func errorText(_ error: ReminderError) -> some View {
        let text = switch error {
        case .emptyMessage: UntranslatedL10n.screenMatchaReminderErrorEmpty
        case .messageTooLong: UntranslatedL10n.screenMatchaReminderErrorTooLong(context.viewState.maxMessageLength.formatted())
        case .notInFuture: UntranslatedL10n.screenMatchaReminderErrorPast
        case .tooFar: UntranslatedL10n.screenMatchaReminderErrorTooFar
        case .nonexistentTime: UntranslatedL10n.screenMatchaReminderErrorDst
        }
        return errorText(text)
    }
    
    private func errorText(_ text: String) -> some View {
        Text(text)
            .font(.compound.bodySM)
            .foregroundStyle(.compound.textCriticalPrimary)
    }
}

// MARK: - Previews

struct RemindMeScreen_Previews: PreviewProvider, TestablePreview {
    static let joinedViewModel = makeViewModel()
    static let deadlineViewModel = makeViewModel(dueAt: Date.mock.addingTimeInterval(3 * 86400).remindMeMillis, selected: .inHours(2))
    static let customViewModel = makeViewModel(selected: .custom)
    static let waitingViewModel = makeViewModel(botMembership: .invite)
    static let inviteViewModel = makeViewModel(botMembership: nil)
    static let directViewModel = makeViewModel(botMembership: nil, isDirect: true)
    static let cannotSendViewModel = makeViewModel(canSendMessages: false)
    
    static var previews: some View {
        preview(joinedViewModel, "Options") { $0 == .joined }
        preview(deadlineViewModel, "Task with a deadline") { $0 == .joined }
        preview(customViewModel, "Pick date and time") { $0 == .joined }
        preview(waitingViewModel, "Waiting for the bot") { $0 == .waiting(isChecking: false) }
        preview(inviteViewModel, "Invite the bot") { $0 == .canInvite(isInviting: false, hasFailed: false) }
        preview(directViewModel, "Unavailable in a DM") { $0 == .unavailableInDM }
        preview(cannotSendViewModel, "Can't send") { $0 == .cannotSend }
    }
    
    private static func preview(_ viewModel: RemindMeScreenViewModel, _ name: String, isLoaded: @escaping (RemindMeBotState) -> Bool) -> some View {
        ElementNavigationStack {
            RemindMeScreen(context: viewModel.context)
        }
        .previewDisplayName(name)
        .snapshotPreferences(expect: viewModel.context.observe(\.viewState.botState).map(isLoaded))
    }
    
    static func makeViewModel(dueAt: Int64? = nil,
                              selected: RemindMeOption? = nil,
                              botMembership: MembershipState? = .join,
                              isDirect: Bool = false,
                              canSendMessages: Bool = true) -> RemindMeScreenViewModel {
        var members: [RoomMemberProxyMock] = [.mockMe, .mockAlice]
        if let botMembership {
            members.append(RoomMemberProxyMock(with: .init(userID: "@matcha-reminder:matrix.org", displayName: "Reminders", membership: botMembership)))
        }
        let roomProxy = JoinedRoomProxyMock(.init(isDirect: isDirect,
                                                  members: members,
                                                  powerLevelsConfiguration: .init(canUserSendMessage: canSendMessages)))
        roomProxy.matrixToEventPermalinkReturnValue = .success(.mockMatrixToEvent)
        let viewModel = RemindMeScreenViewModel(target: .init(message: "Call the venue about Saturday", eventID: "$message", dueAt: dueAt),
                                                roomProxy: roomProxy,
                                                userIndicatorController: UserIndicatorControllerMock(),
                                                timeZone: TimeZone(identifier: "Europe/London") ?? .gmt) { .mock }
        if let selected {
            viewModel.context.send(viewAction: .select(selected))
        }
        return viewModel
    }
}

private extension URL {
    static var mockMatrixToEvent: URL {
        URL(string: "https://matrix.to/#/!room:matrix.org/$message") ?? .homeDirectory
    }
}
