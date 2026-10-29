//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
@testable import MatchaProtocol
import Testing

struct ReminderProtocolTests {
    private static let now: Int64 = 1_767_225_600_000 // 2026-01-01T00:00:00Z
    
    @Test
    func relativeRemindersAreSentInSeconds() {
        #expect(ReminderProtocol.command(.after(amount: 10, unit: .minutes), message: " Check build ") == "!remind 600s Check build")
        #expect(ReminderProtocol.command(.after(amount: 2, unit: .days), message: "x") == "!remind 172800s x")
    }
    
    @Test
    func exactRemindersAreSentAsAUTCInstantWithMilliseconds() {
        #expect(ReminderProtocol.command(.at(epochMillis: Self.now + 9 * 3_600_000), message: "Review") == "!remind at 2026-01-01T09:00:00.000Z Review")
    }
    
    @Test(arguments: [
        (ReminderTime.after(amount: 1, unit: .seconds), "x", true),
        (.after(amount: 365, unit: .days), "x", true),
        (.after(amount: 366, unit: .days), "x", false),
        (.after(amount: 0, unit: .minutes), "x", false),
        (.at(epochMillis: now), "x", false),
        (.at(epochMillis: now - 1), "x", false),
        (.after(amount: 1, unit: .hours), "   ", false),
        (.after(amount: 1, unit: .hours), String(repeating: "m", count: 2001), false)
    ])
    func boundsMatchTheBot(time: ReminderTime, message: String, isValid: Bool) {
        #expect(ReminderProtocol.isValid(time, message: message, now: Self.now) == isValid)
    }
    
    @Test
    func aThreadLinkIsAppendedOnce() {
        let link = "https://matrix.to/#/!r:x/$t"
        #expect(ReminderProtocol.withLink("Do it", link: link) == "Do it\n\(link)")
        #expect(ReminderProtocol.withLink("Do it\n\(link)", link: link) == "Do it\n\(link)")
        #expect(ReminderProtocol.withLink("", link: link) == link)
        #expect(ReminderProtocol.withLink("Do it", link: nil) == "Do it")
    }
    
    @Test
    func theSheetsTextIsTheTrimmedMessageThenTheLink() {
        let link = "https://matrix.to/#/!r:x/$t"
        // Trimmed first, so trailing spaces never sit between the message and the link or push it over the bot's limit.
        #expect(ReminderProtocol.text(message: " Do it \n", link: link) == "Do it\n\(link)")
        #expect(ReminderProtocol.text(message: "  ", link: link) == link)
        #expect(ReminderProtocol.text(message: " Do it ", link: nil) == "Do it")
    }
    
    @Test
    func aLocalTimeIgnoresTheTimeZoneAndCalendarItsComponentsCarry() throws {
        let jakarta = try #require(TimeZone(identifier: "Asia/Jakarta"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = jakarta
        // What a date picker's date gives: every component, the time zone and calendar included.
        let components = calendar.dateComponents(in: jakarta, from: Date(timeIntervalSince1970: TimeInterval(Self.now / 1000)))
        #expect(ReminderProtocol.localInstant(components, in: jakarta) == Self.now)
        #expect(KanbanProtocol.deadline(components, in: jakarta) == .valid(epochMillis: Self.now))
    }
    
    @Test
    func theBotAcknowledgementIsParsed() {
        let ack = ReminderProtocol.parseAcknowledgement("Scheduled r-0123456789abcdef for 2026-01-01T09:00:00.000Z. Cancel with !remind cancel r-0123456789abcdef.")
        #expect(ack == ReminderAcknowledgement(reminderID: "r-0123456789abcdef", dueAt: Self.now + 9 * 3_600_000))
        #expect(ReminderProtocol.parseAcknowledgement("Reminder for @a:b: hi") == nil)
    }
}
