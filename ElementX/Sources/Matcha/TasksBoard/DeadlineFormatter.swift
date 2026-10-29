//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// Formats a task deadline or a reminder time. Future times read "Today 14:05", "Tomorrow 09:00", "Tue 17:00" within six days,
/// else "3 Nov, 17:00" with the year when it differs; past times use the chat list's format.
enum DeadlineFormatter {
    /// The system's own names for today and tomorrow, by locale.
    private static var dayNameFormatters = [Locale: RelativeDateTimeFormatter]()
    
    static func format(_ epochMillis: Int64, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epochMillis) / 1000)
        guard date >= now else { return date.formattedMinimal() }
        
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0, 1:
            // Named from the day count, so relative to `now` rather than the clock.
            let dayName = dayNameFormatter(locale).localizedString(from: DateComponents(day: days))
            return UntranslatedL10n.commonMatchaDayAndTime(dayName, date.formatted(style.hour().minute()))
        case 2...6:
            return date.formatted(style.weekday(.abbreviated).hour().minute())
        default:
            let isThisYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            return date.formatted(isThisYear ? style.day().month(.abbreviated).hour().minute() : style.day().month(.abbreviated).year().hour().minute())
        }
    }
    
    private static func dayNameFormatter(_ locale: Locale) -> RelativeDateTimeFormatter {
        if let formatter = dayNameFormatters[locale] {
            return formatter
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.dateTimeStyle = .named
        formatter.formattingContext = .beginningOfSentence
        dayNameFormatters[locale] = formatter
        return formatter
    }
}
