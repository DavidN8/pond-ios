//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// When a reminder should fire: after a delay, or at an exact instant.
public enum ReminderTime: Sendable, Hashable {
    case after(amount: Int64, unit: ReminderUnit)
    case at(epochMillis: Int64)
}

public enum ReminderUnit: String, Sendable, CaseIterable {
    case seconds, minutes, hours, days
    
    public var seconds: Int64 {
        switch self {
        case .seconds: 1
        case .minutes: 60
        case .hours: 3600
        case .days: 86400
        }
    }
}

/// The bot's reply to a scheduling command.
public struct ReminderAcknowledgement: Sendable, Hashable {
    public var reminderID: String
    public var dueAt: Int64
    
    public init(reminderID: String, dueAt: Int64) {
        self.reminderID = reminderID
        self.dueAt = dueAt
    }
}

/// The first reason a reminder cannot be requested.
public enum ReminderError: String, Sendable {
    /// The picked local time doesn't exist: a clock change skips it.
    case nonexistentTime = "nonexistent_time"
    case notInFuture = "not_in_future"
    case tooFar = "too_far"
    case emptyMessage = "empty_message"
    case messageTooLong = "message_too_long"
}

/// Text commands understood by the Matcha reminder bot, identical to what the web client sends:
/// `!remind <seconds>s <message>` or `!remind at <UTC ISO instant with milliseconds> <message>`.
public enum ReminderProtocol {
    private static let maxDelayMillis = MatchaConfig.reminderMaxDelayDays * 86_400_000
    private static let acknowledgementPrefix = "Scheduled r-"
    
    /// The instant the reminder fires, given the time the command is sent. Overflow wraps, as on Android; `isValid` bounds it first.
    public static func dueAt(_ time: ReminderTime, now: Int64) -> Int64 {
        switch time {
        case .after(let amount, let unit): now &+ amount &* unit.seconds &* 1000
        case .at(let epochMillis): epochMillis
        }
    }
    
    public static func isValidMessage(_ message: String) -> Bool {
        (1...MatchaConfig.reminderMessageMaxLength).contains(message.kotlinTrimmed.utf16Length)
    }
    
    /// Checks the same bounds as the bot: in the future, at most a year away, with a 1 to 2000 character message.
    public static func isValid(_ time: ReminderTime, message: String, now: Int64) -> Bool {
        if case let .after(amount, _) = time, amount <= 0 || amount > 999_999_999 {
            return false
        }
        let dueAt = dueAt(time, now: now)
        return isWithinBounds(dueAt, now: now) && isValidMessage(message)
    }
    
    /// The first reason the reminder sheet refuses a reminder, or nil. `dueAt` is nil when the picked local time doesn't exist.
    public static func validationError(dueAt: Int64?, message: String, maxMessageLength: Int, now: Int64) -> ReminderError? {
        guard let dueAt else { return .nonexistentTime }
        if dueAt <= now {
            return .notInFuture
        }
        if !isWithinBounds(dueAt, now: now) {
            return .tooFar
        }
        if message.isKotlinBlank {
            return .emptyMessage
        }
        if message.kotlinTrimmed.utf16Length > maxMessageLength {
            return .messageTooLong
        }
        return nil
    }
    
    /// The command to send as a plain text message. Delays are sent in seconds, like the web client does.
    public static func command(_ time: ReminderTime, message: String) -> String {
        let when = switch time {
        case .after(let amount, let unit): "\(amount &* unit.seconds)s"
        case .at(let epochMillis): "at \(formatInstant(epochMillis))"
        }
        return "!remind \(when) \(message.kotlinTrimmed)"
    }
    
    /// `yyyy-MM-ddTHH:mm:ss.SSSZ` in UTC, like JavaScript's `toISOString()`.
    public static func formatInstant(_ epochMillis: Int64) -> String {
        let seconds = epochMillis >= 0 ? epochMillis / 1000 : (epochMillis - 999) / 1000
        let parts = LocalTime.utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                                         from: Date(timeIntervalSince1970: TimeInterval(seconds)))
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
                      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0,
                      Int(epochMillis - seconds * 1000))
    }
    
    /// Appends a link to the thread the reminder is about, once. Containment is by UTF-16 code unit, as on Android.
    public static func withLink(_ message: String, link: String?) -> String {
        guard let link, !message.utf16.contains(link.utf16) else { return message }
        return message.isKotlinBlank ? link : "\(message)\n\(link)"
    }
    
    /// What Android's reminder sheet sends after the time: the message trimmed, then the link to what it is about, once.
    public static func text(message: String, link: String?) -> String {
        withLink(message.kotlinTrimmed, link: link)
    }
    
    /// Parses the bot's `Scheduled r-… for <instant>.` notice, like Android's `^Scheduled (r-[a-f0-9]{16}) for (\S+)\.`.
    public static func parseAcknowledgement(_ body: String?) -> ReminderAcknowledgement? {
        guard let body, body.unicodeScalars.starts(with: acknowledgementPrefix.unicodeScalars) else { return nil }
        let scalars = Array(body.unicodeScalars)
        let hexStart = acknowledgementPrefix.unicodeScalars.count
        let forStart = hexStart + 16
        let tokenStart = forStart + " for ".unicodeScalars.count
        guard scalars.count > tokenStart,
              scalars[hexStart..<forStart].allSatisfy(\.isLowercaseHexDigit),
              String(String.UnicodeScalarView(scalars[forStart..<tokenStart])) == " for " else { return nil }
        // `\S+\.` backtracks to the last period before the next whitespace.
        let token = scalars[tokenStart...].prefix { !$0.isASCIIWhitespace }
        guard let period = token.lastIndex(of: "."), period > tokenStart,
              let dueAt = parseInstant(String(String.UnicodeScalarView(scalars[tokenStart..<period]))) else { return nil }
        return ReminderAcknowledgement(reminderID: "r-" + String(String.UnicodeScalarView(scalars[hexStart..<forStart])), dueAt: dueAt)
    }
    
    /// The instant of a wall-clock date and time (year, month, day, hour, minute) in `timeZone`, or nil when a daylight saving change
    /// skips that time. A time repeated by a change takes the earlier offset.
    public static func localInstant(_ components: DateComponents, in timeZone: TimeZone) -> Int64? {
        LocalTime.instant(components, in: timeZone)
    }
    
    // MARK: - Private
    
    private static func isWithinBounds(_ dueAt: Int64, now: Int64) -> Bool {
        dueAt > now && dueAt &- now <= maxDelayMillis
    }
    
    /// Java's `Instant.parse` for what the bot sends: `uuuu-MM-ddTHH:mm:ss[.fraction]Z`, the fraction cut to milliseconds.
    /// ponytail: offsets, a lowercase z and leap seconds, which Java also accepts, are refused; the bot never sends them.
    private static func parseInstant(_ text: String) -> Int64? {
        let bytes = Array(text.utf8)
        let layout = Array("0000-00-00T00:00:00".utf8)
        guard bytes.count >= 20, bytes.last == UInt8(ascii: "Z"),
              zip(bytes, layout).allSatisfy({ $1 == UInt8(ascii: "0") ? $0.isASCIIDigit : $0 == $1 }) else { return nil }
        let fraction = bytes[layout.count..<(bytes.count - 1)]
        guard fraction.isEmpty || (fraction.first == UInt8(ascii: ".") && (2...10).contains(fraction.count) && fraction.dropFirst().allSatisfy(\.isASCIIDigit)) else {
            return nil
        }
        func number(_ range: Range<Int>) -> Int {
            String(bytes: bytes[range], encoding: .ascii).flatMap { Int($0) } ?? 0
        }
        let components = DateComponents(year: number(0..<4), month: number(5..<7), day: number(8..<10),
                                        hour: number(11..<13), minute: number(14..<16), second: number(17..<19))
        guard let seconds = LocalTime.utcSeconds(components) else { return nil }
        let millis = String(bytes: fraction.dropFirst(), encoding: .ascii).flatMap { Int64(($0 + "00").prefix(3)) } ?? 0
        return seconds * 1000 + millis
    }
}

/// Wall-clock times in a time zone, as `java.time` resolves them: a time skipped by a clock change doesn't exist, a repeated one
/// takes the earlier offset.
enum LocalTime {
    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }
    
    /// The instant in epoch milliseconds, or nil for a skipped time.
    static func instant(_ components: DateComponents, in timeZone: TimeZone) -> Int64? {
        guard let local = utcSeconds(components) else { return nil }
        // ponytail: the offsets a day either side are the candidates; a zone changing twice within a day would need more.
        let candidates = Set([-86400, 86400].map { timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(local + $0))) })
        let instants = candidates.map { local - Int64($0) }.filter { instant in
            timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(instant))) == Int(local - instant)
        }
        return instants.min().map { $0 * 1000 }
    }
    
    /// The seconds since the epoch of `components` read as UTC, or nil when they are not a real date and time.
    static func utcSeconds(_ components: DateComponents) -> Int64? {
        // Only the wall-clock fields: `date(from:)` would honour a time zone the components carry, as `dateComponents(in:from:)` sets.
        let wallClock = DateComponents(year: components.year, month: components.month, day: components.day,
                                       hour: components.hour, minute: components.minute, second: components.second ?? 0)
        guard let date = utcCalendar.date(from: wallClock) else { return nil }
        let back = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard back.year == wallClock.year, back.month == wallClock.month, back.day == wallClock.day,
              back.hour == wallClock.hour, back.minute == wallClock.minute, back.second == wallClock.second else { return nil }
        return Int64(date.timeIntervalSince1970.rounded())
    }
}

private extension UInt8 {
    var isASCIIDigit: Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(self)
    }
}
