//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatchaProtocol

/// What a reminder is about, used to prefill the "Remind me" sheet.
struct RemindMeTarget: Equatable {
    /// Prefilled message text.
    var message = ""
    /// The message the reminder is about; a link to it is appended to the reminder once.
    var eventID: String?
    /// The thread the reminder is about; a link to it is appended once when there is no `eventID`.
    var threadID: String?
    /// A task's deadline in epoch milliseconds, offered as "At the deadline".
    var dueAt: Int64?
}

extension RemindMeTarget {
    /// A reminder about a message that reached the server, in its thread when the timeline is one. Like Android, a text, notice or emote
    /// is prefilled with its text and anything else only with its caption: a voice message's body is its file name, a location's a geo URI.
    init?(item: EventBasedTimelineItemProtocol, timelineKind: TimelineKind) {
        guard let eventID = item.id.eventID else { return nil }
        let message = item as? EventBasedMessageTimelineItemProtocol
        let text = switch message?.contentType {
        case .text, .notice, .emote: message?.body
        default: message?.mediaCaption
        }
        self.init(message: text ?? "", eventID: eventID, threadID: timelineKind.threadRootEventID)
    }
}

enum RemindMeScreenViewModelAction {
    /// The sheet closes: cancelled, or the reminder was requested.
    case dismiss
}

enum RemindMeOption: Hashable {
    /// Sent with the bot's relative mode, `!remind <seconds>s`.
    case inHours(Int)
    /// A task's deadline in epoch milliseconds, sent with the bot's absolute mode.
    case atDeadline(Int64)
    /// The date and time picked below the options, sent with the bot's absolute mode.
    case custom
}

/// What the link appended to the reminder points at.
enum RemindMeLink {
    case message
    case thread
}

/// Whether the reminder bot can post in this chat.
enum RemindMeBotState: Equatable {
    case checking
    case joined
    /// The bot is invited and has not joined yet; nothing can be sent until it has.
    case waiting(isChecking: Bool)
    /// The bot is not in the chat and the user may invite it, after confirming.
    case canInvite(isInviting: Bool, hasFailed: Bool)
    /// The bot is not in the chat and the user may not invite it, or it is banned.
    case cannotInvite
    /// The user cannot post in this chat, so the bot command cannot be sent.
    case cannotSend
    /// A DM without the bot: adding it would make the DM a group, so reminders are off.
    case unavailableInDM
}

struct RemindMeScreenViewState: BindableState {
    static let quickOptionHours = [2, 8, 24]
    
    /// The reminder bot of the user's homeserver.
    let botUserID: String
    let dueAt: Int64?
    let timeZone: TimeZone
    var link: RemindMeLink?
    /// The longest message that still fits once the link is appended.
    var maxMessageLength = MatchaConfig.reminderMessageMaxLength
    var botState = RemindMeBotState.checking
    /// When the sheet last read the clock; the options are shown relative to it.
    var now: Date
    /// The option the confirm button sends; nothing is chosen at first, so a single tap never posts.
    var selected: RemindMeOption?
    /// The option being sent, if any; the sheet can't be changed meanwhile.
    var sending: RemindMeOption?
    var hasSendFailed = false
    var showsEmptyMessageError = false
    
    var bindings: RemindMeScreenViewStateBindings {
        didSet {
            // Like Android, any edit hides the empty message error until the next confirm.
            if bindings.message != oldValue.message {
                showsEmptyMessageError = false
            }
        }
    }
    
    var quickOptions: [RemindMeOption] {
        let hours = Self.quickOptionHours.map(RemindMeOption.inHours)
        // Only a deadline within the bot's bounds; any message does.
        guard let dueAt, ReminderProtocol.isValid(.at(epochMillis: dueAt), message: "-", now: now.remindMeMillis) else { return hours }
        return hours + [.atDeadline(dueAt)]
    }
    
    /// The deadline drops out of the options once it has passed.
    var selectedOption: RemindMeOption? {
        guard let selected, selected == .custom || quickOptions.contains(selected) else { return nil }
        return selected
    }
    
    var messageError: ReminderError? {
        // Any time that is valid leaves only the message's own errors.
        switch ReminderProtocol.validationError(dueAt: now.remindMeMillis + 1, message: bindings.message, maxMessageLength: maxMessageLength, now: now.remindMeMillis) {
        case .messageTooLong: .messageTooLong
        case .emptyMessage where showsEmptyMessageError: .emptyMessage
        default: nil
        }
    }
    
    /// Why the picked date and time cannot be requested.
    var customError: ReminderError? {
        ReminderProtocol.validationError(dueAt: bindings.customDate.remindMeMillis, message: bindings.message, maxMessageLength: maxMessageLength, now: now.remindMeMillis)
    }
    
    var canConfirm: Bool {
        guard botState == .joined, sending == nil, let selectedOption else { return false }
        return selectedOption != .custom || customError == nil
    }
    
    /// When Set reminds, shown under the title as the button at the top right is too narrow to say it (plan I9, spec rule 8).
    var chosenTime: String? {
        guard botState == .joined, let selectedOption else { return nil }
        return label(for: selectedOption)
    }
    
    /// "Set reminder · Today at 14:05" once a time is chosen.
    var confirmTitle: String {
        guard let selectedOption else { return UntranslatedL10n.screenMatchaReminderSet }
        return UntranslatedL10n.screenMatchaReminderConfirm(label(for: selectedOption))
    }
    
    /// When an option reminds, like "Today at 14:05".
    func label(for option: RemindMeOption) -> String {
        let dueAt = switch option {
        case .inHours(let hours): ReminderProtocol.dueAt(.after(amount: Int64(hours), unit: .hours), now: now.remindMeMillis)
        case .atDeadline(let dueAt): dueAt
        case .custom: bindings.customDate.remindMeMillis
        }
        return RemindMeTimeFormatter.string(epochMillis: dueAt, now: now, timeZone: timeZone)
    }
}

struct RemindMeScreenViewStateBindings {
    var message: String
    var customDate: Date
}

enum RemindMeScreenViewAction {
    case select(RemindMeOption)
    case confirm
    /// Invites the reminder bot, after the user confirmed it.
    case inviteBot
    /// Checks again whether the reminder bot has joined.
    case checkBotAgain
    case cancel
}

/// Reminder times as the options show them: "Today at 14:05", "Tomorrow at 09:00", "Tue 17:00" within six days, else "3 Nov,
/// 17:00" with the year when it differs. "Today" and "Tomorrow" are the device clock's, so `now` is the current time.
///
/// ponytail: Android's `DeadlineFormatter`; share one with the task deadlines once the board has its own.
nonisolated enum RemindMeTimeFormatter {
    static func string(epochMillis: Int64, now: Date, timeZone: TimeZone, locale: Locale = .current) -> String {
        let date = Date(remindMeMillis: epochMillis)
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        calendar.locale = locale
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone)
        switch calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0 {
        case 0, 1:
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.doesRelativeDateFormatting = true
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: date)
        case 2...6:
            return date.formatted(style.weekday(.abbreviated).hour().minute())
        default:
            let dayAndTime = style.day().month(.abbreviated).hour().minute()
            return date.formatted(calendar.isDate(date, equalTo: now, toGranularity: .year) ? dayAndTime : dayAndTime.year())
        }
    }
    
    /// "GMT+7", "GMT+5:30", "GMT-3" or "GMT" for the offset of `timeZone` at `date`.
    static func offset(of timeZone: TimeZone, at date: Date) -> String {
        let seconds = timeZone.secondsFromGMT(for: date)
        guard seconds != 0 else { return "GMT" }
        let hours = abs(seconds) / 3600
        let minutes = abs(seconds) % 3600 / 60
        return "GMT\(seconds < 0 ? "-" : "+")\(hours)" + (minutes == 0 ? "" : String(format: ":%02d", minutes))
    }
}

nonisolated extension Date {
    /// Epoch milliseconds, as the reminder protocol counts time.
    var remindMeMillis: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded())
    }
    
    init(remindMeMillis: Int64) {
        self.init(timeIntervalSince1970: TimeInterval(remindMeMillis) / 1000)
    }
}
