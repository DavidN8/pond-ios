//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import MatchaProtocol
import MatrixRustSDK
import SwiftUI

typealias RemindMeScreenViewModelType = StateStoreViewModelV2<RemindMeScreenViewState, RemindMeScreenViewAction>

/// The "Remind me" sheet: checks that the reminder bot is in the chat (inviting it after confirmation), then posts a `!remind`
/// command that the bot schedules. Only the bot's own reply confirms a reminder, so success here only means "requested".
class RemindMeScreenViewModel: RemindMeScreenViewModelType, RemindMeScreenViewModelProtocol {
    /// A message reminder is prefilled with the start of the message.
    static let prefillMaxLength = 200
    
    private let target: RemindMeTarget
    private let roomProxy: JoinedRoomProxyProtocol
    private let userIndicatorController: UserIndicatorControllerProtocol
    private let clock: () -> Date
    private let onRequested: ((ReminderRequestRef) async -> Void)?
    
    private var linkURL: String?
    private var waitingForBot: AnyCancellable?
    
    private let actionsSubject: PassthroughSubject<RemindMeScreenViewModelAction, Never> = .init()
    var actionsPublisher: AnyPublisher<RemindMeScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    /// - Parameters:
    ///   - onRequested: called once the command is sent, with its event and when it is due, so a task can record the request
    ///     on its card.
    init(target: RemindMeTarget,
         roomProxy: JoinedRoomProxyProtocol,
         userIndicatorController: UserIndicatorControllerProtocol,
         timeZone: TimeZone = .current,
         clock: @escaping () -> Date = Date.init,
         onRequested: ((ReminderRequestRef) async -> Void)? = nil) {
        self.target = target
        self.roomProxy = roomProxy
        self.userIndicatorController = userIndicatorController
        self.clock = clock
        self.onRequested = onRequested
        
        let now = clock()
        super.init(initialViewState: .init(botUserID: Self.botUserID(in: roomProxy),
                                           dueAt: target.dueAt,
                                           timeZone: timeZone,
                                           now: now,
                                           bindings: .init(message: String(target.message.prefix(Self.prefillMaxLength)),
                                                           customDate: Self.tomorrowMorning(after: now, in: timeZone))))
        
        Task {
            await resolveLink()
            await refreshBotState()
        }
    }
    
    /// Whether "Remind me" is offered in `room`: in a DM only once the reminder bot has joined, since inviting it would turn the
    /// DM into a group. Each entry point also needs the user to be able to post; the sheet checks both again.
    static func isOffered(in room: JoinedRoomProxyProtocol) -> Bool {
        let botUserID = botUserID(in: room)
        return !room.infoPublisher.value.isDM || room.membersPublisher.value.contains { $0.userID == botUserID && $0.membership == .join }
    }
    
    // MARK: - Public
    
    override func process(viewAction: RemindMeScreenViewAction) {
        switch viewAction {
        case .select(let option):
            state.now = clock()
            state.selected = option
        case .confirm:
            Task { await confirm() }
        case .inviteBot:
            Task { await inviteBot() }
        case .checkBotAgain:
            Task { await checkBotAgain() }
        case .cancel:
            actionsSubject.send(.dismiss)
        }
    }
    
    // MARK: - Private
    
    private static func botUserID(in room: JoinedRoomProxyProtocol) -> String {
        MatchaConfig.reminderBotUserID(sessionUserID: room.ownUserID)
    }
    
    /// The custom time starts at 09:00 tomorrow.
    private static func tomorrowMorning(after now: Date, in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        var components = calendar.dateComponents([.year, .month, .day], from: tomorrow)
        components.hour = 9
        components.minute = 0
        return ReminderProtocol.localInstant(components, in: timeZone).map(Date.init(remindMeMillis:)) ?? tomorrow
    }
    
    private func resolveLink() async {
        guard let eventID = target.eventID ?? target.threadID else { return }
        switch await roomProxy.matrixToEventPermalink(eventID) {
        case .success(let url):
            linkURL = url.absoluteString
            state.link = target.eventID != nil ? .message : .thread
            state.maxMessageLength = MatchaConfig.reminderMessageMaxLength - url.absoluteString.utf16.count - 1
        case .failure(let error):
            MXLog.error("Could not build the link for a reminder: \(error)")
        }
    }
    
    private func confirm() async {
        guard state.sending == nil, state.botState == .joined, let option = state.selectedOption else { return }
        state.now = clock()
        let nowMillis = state.now.remindMeMillis
        let time: ReminderTime = switch option {
        case .inHours(let hours): .after(amount: Int64(hours), unit: .hours)
        case .atDeadline(let dueAt): .at(epochMillis: dueAt)
        case .custom: .at(epochMillis: state.bindings.customDate.remindMeMillis)
        }
        let message = state.bindings.message
        if let error = ReminderProtocol.validationError(dueAt: ReminderProtocol.dueAt(time, now: nowMillis),
                                                        message: message,
                                                        maxMessageLength: state.maxMessageLength,
                                                        now: nowMillis) {
            // The custom time shows every error; the quick options only fail on the message.
            state.showsEmptyMessageError = error == .emptyMessage
            return
        }
        
        state.sending = option
        state.hasSendFailed = false
        // The bot may have left, or the user lost the right to post, while the sheet was open.
        let botState = await checkBot()
        guard botState == .joined else {
            updateBotState(botState)
            state.sending = nil
            return
        }
        let text = ReminderProtocol.text(message: message, link: linkURL)
        let sentAt = clock().remindMeMillis
        guard ReminderProtocol.isValid(time, message: text, now: sentAt) else {
            // The picked time passed while checking; the refreshed clock makes the sheet show why.
            state.now = clock()
            state.sending = nil
            return
        }
        
        let content = JSONValue.object(["msgtype": .string("m.text"), "body": .string(ReminderProtocol.command(time, message: text))])
        switch await roomProxy.sendRawEvent(type: "m.room.message", contentJSON: content.jsonString) {
        case .success(let eventID):
            await onRequested?(ReminderRequestRef(eventID: eventID, at: ReminderProtocol.dueAt(time, now: sentAt)))
            userIndicatorController.submitIndicator(UserIndicator(title: UntranslatedL10n.screenMatchaReminderRequested, icon: \.check))
            actionsSubject.send(.dismiss)
        case .failure(let error):
            MXLog.error("Could not request a reminder: \(error)")
            state.sending = nil
            state.hasSendFailed = true
        }
    }
    
    private func inviteBot() async {
        guard case .canInvite(isInviting: false, _) = state.botState else { return }
        updateBotState(.canInvite(isInviting: true, hasFailed: false))
        switch await roomProxy.invite(userID: state.botUserID) {
        case .success:
            updateBotState(.waiting(isChecking: false))
        case .failure(let error):
            MXLog.error("Could not invite the reminder bot: \(error)")
            updateBotState(.canInvite(isInviting: false, hasFailed: true))
        }
    }
    
    private func checkBotAgain() async {
        guard case .waiting(isChecking: false) = state.botState else { return }
        updateBotState(.waiting(isChecking: true))
        await refreshBotState()
    }
    
    /// Checks the bot, and again if the member count moved meanwhile: a check that is out ignores the member count's changes, so a
    /// join that synced while it read the old membership would leave the sheet waiting.
    private func refreshBotState() async {
        let joinedMembersCount = roomProxy.infoPublisher.value.joinedMembersCount
        let botState = await checkBot()
        updateBotState(botState)
        if case .waiting = botState, roomProxy.infoPublisher.value.joinedMembersCount != joinedMembersCount {
            await refreshBotState()
        }
    }
    
    private func checkBot() async -> RemindMeBotState {
        let info = roomProxy.infoPublisher.value
        guard info.membership == .joined, let powerLevels = info.powerLevels, powerLevels.canOwnUser(sendMessage: .roomMessage) else {
            return .cannotSend
        }
        // The members are read when the room opens; read the bot again so a join or leave since is seen.
        let membership: MembershipState? = switch await roomProxy.updatedMember(userID: state.botUserID) {
        case .success(let member): member.membership
        case .failure: nil
        }
        // Adding the bot to a DM would turn it into a group, so a DM only gets reminders when the bot is already in it.
        if membership != .join, info.isDM {
            return .unavailableInDM
        }
        return switch membership {
        case .join: .joined
        case .invite: .waiting(isChecking: false)
        // An invite would fail until someone lifts the ban.
        case .ban: .cannotInvite
        default: powerLevels.canOwnUserInvite() ? .canInvite(isInviting: false, hasFailed: false) : .cannotInvite
        }
    }
    
    private func updateBotState(_ botState: RemindMeBotState) {
        state.botState = botState
        guard case .waiting = botState else {
            waitingForBot = nil
            return
        }
        guard waitingForBot == nil else { return }
        // Memberships arrive with syncs: look again whenever the member count changes, so the options appear once the bot joins.
        waitingForBot = roomProxy.infoPublisher
            .map(\.joinedMembersCount)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.checkBotAgain() }
            }
    }
}

extension RemindMeScreenViewModel: Identifiable { }
