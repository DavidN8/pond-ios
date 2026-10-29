//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

@MainActor
struct DeadlineFormatterTests {
    private let locale = Locale(identifier: "en_GB")
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }()
    
    @Test
    func futureTimesNameTheDayWithinAWeekThenGiveTheDate() throws {
        let now = Date.now
        
        #expect(try format(days: 1, hour: 9, now: now) == "Tomorrow 09:00")
        
        let inThreeDays = try date(days: 3, hour: 17, now: now)
        let weekday = calendar.shortWeekdaySymbols[calendar.component(.weekday, from: inThreeDays) - 1]
        #expect(try format(days: 3, hour: 17, now: now) == "\(weekday) 17:00")
        
        let nextYear = try format(days: 400, hour: 17, now: now)
        let year = try calendar.component(.year, from: date(days: 400, hour: 17, now: now))
        #expect(nextYear.contains(String(year)))
        #expect(nextYear.contains("17:00"))
    }
    
    @Test
    func aTimeLaterTodayReadsToday() throws {
        let now = Date.now
        // Late in the evening there is no later time today to try.
        guard calendar.component(.hour, from: now) < 23 else { return }
        #expect(try format(days: 0, hour: 23, now: now) == "Today 23:00")
    }
    
    @Test
    func todayAndTomorrowAreRelativeToTheGivenNowRatherThanTheClock() throws {
        // A day long past, so the clock can't agree with it by chance.
        let now = try #require(calendar.date(from: DateComponents(year: 2023, month: 11, day: 14, hour: 10)))
        #expect(try format(days: 0, hour: 18, now: now) == "Today 18:00")
        #expect(try format(days: 1, hour: 9, now: now) == "Tomorrow 09:00")
    }
    
    @Test
    func pastTimesUseTheChatListsFormat() throws {
        let past = try date(days: -3, hour: 9, now: .now)
        #expect(DeadlineFormatter.format(millis(past), calendar: calendar, locale: locale) == past.formattedMinimal())
    }
    
    // MARK: - Helpers
    
    private func date(days: Int, hour: Int, now: Date) throws -> Date {
        let day = try #require(calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)))
        return try #require(calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day))
    }
    
    private func format(days: Int, hour: Int, now: Date) throws -> String {
        try DeadlineFormatter.format(millis(date(days: days, hour: hour, now: now)), now: now, calendar: calendar, locale: locale)
    }
    
    private func millis(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }
}
