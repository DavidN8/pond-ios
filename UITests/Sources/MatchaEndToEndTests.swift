//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import XCTest

/// Matcha end to end against the local Synapse (MATCHA_IOS.md §3.3): user B makes a space with notes on and a chat in it with two
/// named threads and a task board, through the client-server API; user A signs in to the real app and goes through the chat list,
/// the chat's chip bar, a reminder set from a message, a thread, the board (a task moved, archived and restored, renamed, its thread
/// opened), the Tasks tab (filters, table, New task), a note written in, and the Channels tab. Both users leave this run's rooms at the
/// end. Skipped unless `MATCHA_LOCAL_TEST_ENV` names the accounts file. With `MATCHA_SCREENS_DIR`, every screen's screenshot is
/// written there too (and the element tree, under `debug/`). Unlike the other UI tests it needs no particular simulator and records
/// no snapshot. The check of the tab helpers needs no accounts: it runs on upstream's mock session.
@MainActor
final class MatchaEndToEndTests: XCTestCase {
    private var app: XCUIApplication!
    private var screensDirectory: URL?
    
    func testSignInAndVisitEveryMatchaScreen() async throws {
        guard let accounts = LocalAccounts.load() else { throw XCTSkip("MATCHA_LOCAL_TEST_ENV doesn't name the accounts file") }
        executionTimeAllowance = 900
        continueAfterFailure = false
        screensDirectory = ProcessInfo.processInfo.environment["MATCHA_SCREENS_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        
        let seed = try await Seed.make(accounts)
        addTeardownBlock { try await seed.finish() }
        app = XCUIApplication()
        app.launch()
        try await signInIfNeeded(accounts)
        
        try await visitChat(seed)
        try await visitBoard(seed)
        try await visitTasksTab(seed)
        try await visitNotes(seed)
        try await visitChannels(seed)
    }
    
    /// The tab helpers on upstream's mock session, with no homeserver: scrolling minimizes the tab bar to the current tab, which
    /// then has no identifier, and `openTab` expands the bar first. The end-to-end runs reach that state only now and then.
    func testOpenTabExpandsTheMinimizedTabBar() async throws {
        app = XCUIApplication()
        app.launchEnvironment = ["UI_TESTS_SCREEN": UITestsScreenIdentifier.userSessionSpacesFlow.rawValue]
        app.launch()
        let spaces = tab(A11yIdentifiers.homeTabs.spaces)
        try await waitFor(spaces, timeout: 60)
        for _ in 0..<6 where !minimizedTab.exists {
            drag(towardsTop: false)
            try await Task.sleep(for: .milliseconds(500))
        }
        try await waitFor(minimizedTab)
        XCTAssertFalse(spaces.exists && spaces.isHittable, "The minimized tab bar still offers Spaces")
        
        try await openTab(A11yIdentifiers.homeTabs.spaces)
        try await waitFor(app.buttons[A11yIdentifiers.spacesScreen.spaceRoomName("The Foundation")], timeout: 30)
    }
    
    // MARK: - Steps
    
    /// The chat's chip bar names both threads; a message's long press sets a reminder; a thread opens from its chip.
    private func visitChat(_ seed: Seed) async throws {
        let chat = try await scrollTo(text(seed.chatName))
        try await snap("00a-chats-list")
        chat.tap()
        try await waitFor(button("Launch plan"), timeout: 90)
        try await waitFor(button("Venue"))
        try await waitFor(button("General"))
        try await snap("01-chat-chip-bar")
        
        text("Hello from B").press(forDuration: 1.2)
        try await waitFor(button("Remind me")).tap()
        if seed.hasReminderBot {
            // An allowed inviter put the local reminder bot in the chat, so the sheet offers its times; Set reminder sends the
            // `!remind` command, which the bot answers.
            // The options are a radio group, which XCTest reads as switches.
            try await waitFor(app.switches.matching(NSPredicate(format: "label BEGINSWITH 'In 2 hours'")).firstMatch, timeout: 30).tap()
            let set = try await waitFor(app.navigationBars.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Set reminder'")).firstMatch)
            try await snap("01a-remind-me")
            set.tap()
            XCTAssertTrue(set.waitForNonExistence(timeout: 30), "The Remind me sheet stayed open after Set reminder")
            try await snap("01b-reminder-requested")
            try await seed.waitForReminder(from: "Hello from B")
        } else {
            // Without an allowed inviter the bot isn't in the chat, so the sheet offers to add it. It is only shown, never
            // confirmed: the bot accepts invites from Android's test users only.
            try await waitFor(button("Add bot"), timeout: 30)
            try await snap("01a-remind-me")
            app.navigationBars.buttons["Cancel"].tap()
            XCTAssertTrue(button("Add bot").waitForNonExistence(timeout: 10), "Cancel left the Remind me sheet open")
        }
        
        button("Launch plan").tap()
        try await waitFor(text("I'll draft it"), timeout: 30)
        try await snap("02-thread")
        button("General").tap()
    }
    
    /// The board, from the top bar: a task moved from its long-press menu, another archived by a swipe and brought back by Undo,
    /// then renamed in the editor, and a task's thread opened in the board's place.
    private func visitBoard(_ seed: Seed) async throws {
        try await waitFor(app.navigationBars.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Tasks'")).firstMatch, timeout: 30).tap()
        let card = try await waitFor(row("Launch plan"), timeout: 60)
        try await snap("03-board")
        card.press(forDuration: 1.2)
        try await waitFor(app.buttons["Move to"]).tap()
        try await waitFor(app.buttons["In progress"]).tap()
        try await snap("04-board-task-moved")
        try await seed.waitForCards("Launch plan in progress") { $0.newest("e2e-launch")?.column == "doing" }
        
        // Both tasks are in progress now.
        try await waitFor(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'In progress'")).firstMatch).tap()
        try await waitFor(row("Venue")).swipeLeft()
        // A long swipe archives at once; a short one shows the button.
        if try await firstToAppear([text("Task archived"), app.buttons["Archive"]], timeout: 15) == 1 {
            app.buttons["Archive"].tap()
        }
        try await waitFor(text("Task archived"))
        try await snap("04a-board-task-archived")
        app.buttons["Undo"].tap()
        try await waitFor(row("Venue"), timeout: 30)
        try await seed.waitForCards("Venue archived, then restored") { cards in
            cards.newest("e2e-venue")?.isArchived == false && cards.contains { $0.id == "e2e-venue" && $0.isArchived }
        }
        
        // The editor renames a task (and its thread).
        row("Venue").press(forDuration: 1.2)
        try await waitFor(app.buttons["Edit task"]).tap()
        try await waitFor(field("Task name"), timeout: 30).clearAndTypeText("Venue booked", app: app)
        try await snap("04b-task-editor")
        app.buttons["Save"].tap()
        try await waitFor(row("Venue booked"), timeout: 30)
        try await snap("04c-board-task-renamed")
        try await seed.waitForCards("Venue renamed") { $0.newest("e2e-venue")?.title == "Venue booked" }
        
        // A task opens its thread, which takes the board's place above the chat.
        row("Launch plan").tap()
        try await waitFor(text("I'll draft it"), timeout: 30)
        try await snap("04d-thread-from-board")
    }
    
    /// The Tasks tab lists the task A replied to, in progress since the board's move. Earlier runs' chats hold tasks with the same
    /// title, so a row is told apart by its label: status, title, then this run's chat.
    private func visitTasksTab(_ seed: Seed) async throws {
        let movedTask = text("Status: In progress, Launch plan, \(seed.chatName)")
        try await openTab(A11yIdentifiers.homeTabs.tasks)
        try await scrollTo(movedTask, timeout: 120)
        try await snap("05-tasks-tab")
        // The chips narrow the list: To do leaves the task out, In progress shows it again.
        try await waitFor(button("To do")).tap()
        XCTAssertTrue(movedTask.waitForNonExistence(timeout: 15), "To do still lists the task in progress")
        try await waitFor(button("In progress")).tap()
        try await waitFor(movedTask, timeout: 30)
        try await snap("06-tasks-tab-in-progress")
        // The tab's avatar opens the settings, as on the other root tabs.
        try await waitFor(app.buttons[A11yIdentifiers.homeScreen.userAvatar]).tap()
        try await waitFor(app.buttons[A11yIdentifiers.settingsScreen.done], timeout: 30)
        try await snap("06a-settings-from-tasks-tab")
        app.buttons[A11yIdentifiers.settingsScreen.done].tap()
        
        // The table shows the same tasks in columns.
        try await waitFor(app.buttons["Show as table"]).tap()
        try await waitFor(button("Due"))
        try await snap("06b-tasks-table")
        try await waitFor(app.buttons["Show as list"]).tap()
        
        // New task: choose this run's chat, name the task, and it is to do. Chat ▾ narrows the tab to that chat, as earlier runs'
        // chats hold more tasks than scrolling can get through.
        try await waitFor(button("All")).tap()
        app.buttons["New task"].tap()
        try await chooseChat(seed.chatName)
        try await waitFor(field("Task name"), timeout: 30).clearAndTypeText("Book the caterer", app: app)
        try await snap("06c-new-task")
        app.buttons["Add task"].tap()
        try await seed.waitForCards("the new task") { $0.contains { $0.title == "Book the caterer" } }
        try await waitFor(button("Chat")).tap()
        try await chooseChat(seed.chatName)
        try await waitFor(text("Status: To do, Book the caterer, \(seed.chatName)"), timeout: 60)
        try await snap("06d-tasks-tab-new-task")
        
        // A task opens its thread, in its own chat, above the tab, as Android pushes it: Back returns to the tasks.
        try await scrollTo(movedTask).tap()
        try await waitFor(text("I'll draft it"), timeout: 30)
        try await waitFor(text(seed.chatName))
        try await snap("06e-task-opens-its-thread")
        try await goBack(to: movedTask)
    }
    
    /// The Notes tab, and the space's own notes under the space's name, written in and saved.
    private func visitNotes(_ seed: Seed) async throws {
        try await openTab(A11yIdentifiers.homeTabs.notes)
        try await scrollTo(text(seed.spaceName), timeout: 120)
        try await snap("07-notes-tab")
        try await below(text(seed.spaceName), label: "Space notes").tap()
        try await waitFor(text("This note is empty"), timeout: 60)
        try await snap("08-note")
        // A note gets the whole screen, as a chat does.
        XCTAssertFalse(app.tabBars.firstMatch.exists, "The tab bar shows over the note")
        
        app.buttons["Edit note"].tap()
        let editor = try await waitFor(app.textViews.firstMatch, timeout: 30)
        editor.tap()
        editor.typeText("Agenda for Friday")
        try await snap("08a-note-editing")
        app.navigationBars.buttons["Done"].tap()
        try await waitFor(text("Agenda for Friday"), timeout: 30)
        // Back shows again only once the homeserver has every edit, and the title says so.
        try await waitFor(app.buttons["BackButton"], timeout: 60)
        try await waitFor(text("Saved"))
        try await snap("08b-note-saved")
        
        // So does the space's own list, from its header.
        app.buttons["BackButton"].firstMatch.tap()
        try await scrollTo(text(seed.spaceName)).tap()
        try await waitFor(text("Write notes, plans and guides together"), timeout: 60)
        XCTAssertFalse(app.tabBars.firstMatch.exists, "The tab bar shows over the space's notes")
        try await snap("08c-space-notes-from-tab")
    }
    
    /// The Channels tab: the space with All notes, All boards and All chats, each opened, and a task of its boards.
    private func visitChannels(_ seed: Seed) async throws {
        try await openTab(A11yIdentifiers.homeTabs.channels)
        try await scrollTo(text(seed.spaceName), timeout: 120)
        try await snap("09-channels-tab")
        for (row, check, name) in [("All boards", "Venue", "10-space-boards"), ("All notes", "Space notes", "11-space-notes"), ("All chats", seed.chatName, "12-space-chats")] {
            // VoiceOver reads each shortcut with its space's name.
            try await below(text(seed.spaceName), label: "\(row), \(seed.spaceName)").tap()
            try await waitFor(text(check), timeout: 60)
            try await snap(name)
            // Back to the list: the tabs show again (a space's boards have its name too, as their subtitle).
            try await goBack(to: tab(A11yIdentifiers.homeTabs.channels))
        }
        // A task of the space's boards opens its thread above the boards, as the Tasks tab's: Back returns to them.
        let movedTask = text("Status: In progress, Launch plan, \(seed.chatName)")
        try await below(text(seed.spaceName), label: "All boards, \(seed.spaceName)").tap()
        try await waitFor(movedTask, timeout: 60).tap()
        try await waitFor(text("I'll draft it"), timeout: 30)
        try await waitFor(text(seed.chatName))
        try await snap("13-space-board-task-opens-its-thread")
        try await goBack(to: movedTask)
    }
    
    private func signInIfNeeded(_ accounts: LocalAccounts) async throws {
        let signIn = app.buttons[A11yIdentifiers.authenticationStartScreen.signIn]
        if try await firstToAppear([signIn, tab(A11yIdentifiers.homeTabs.chats)], timeout: 60) == 0 {
            signIn.tap()
            let server = try await waitFor(app.textFields[A11yIdentifiers.changeServerScreen.server], timeout: 30)
            server.clearAndTypeText(accounts.homeserver, app: app, verifyingValue: false)
            // The field completes earlier servers while you type, which can leave a second copy of the completion behind.
            for _ in 0..<20 where (server.value as? String).map({ $0 != accounts.homeserver && $0.hasPrefix(accounts.homeserver) }) == true {
                server.typeText(XCUIKeyboardKey.delete.rawValue)
            }
            XCTAssertEqual(server.value as? String, accounts.homeserver)
            app.buttons[A11yIdentifiers.changeServerScreen.continue].tap()
            let username = try await waitFor(app.textFields[A11yIdentifiers.loginScreen.emailUsername], timeout: 120)
            try await focus(username)
            username.clearAndTypeText(accounts.userA, app: app)
            app.secureTextFields[A11yIdentifiers.loginScreen.password].clearAndTypeText(accounts.passwordA, app: app)
            app.buttons[A11yIdentifiers.loginScreen.continue].tap()
        }
        // Onboarding, shown over the tabs at every launch while this device is unverified: skip confirming the identity (a debug
        // build's Skip) and decline notifications and analytics.
        let skip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Skip'")).firstMatch
        let notNow = app.buttons["Not now"]
        _ = try await firstToAppear([tab(A11yIdentifiers.homeTabs.chats), skip, notNow], timeout: 180)
        while skip.waitForExistence(timeout: 10) || notNow.exists {
            try await snap("00-onboarding-\(Int(Date.now.timeIntervalSince1970))")
            (skip.exists ? skip : notNow).tap()
        }
        try await waitFor(tab(A11yIdentifiers.homeTabs.chats), timeout: 60)
    }
    
    // MARK: - Helpers
    
    private func tab(_ identifier: String) -> XCUIElement {
        app.buttons[identifier]
    }
    
    /// The current tab of a minimized tab bar, which shows only it and Search.
    private var minimizedTab: XCUIElement {
        app.tabBars.buttons.matching(NSPredicate(format: "value == 'Collapsed'")).firstMatch
    }
    
    /// Goes back to the screen with the tabs (a chat hides them), then opens the tab.
    private func openTab(_ identifier: String) async throws {
        try await goBack(to: tab(identifier))
        tab(identifier).tap()
    }
    
    /// Taps `field` until the keyboard shows. On a new simulator the login screen's user name field ignored the first taps for
    /// over 10 s, which is all `clearAndTypeText` waits before typing into a field without focus.
    private func focus(_ field: XCUIElement, line: UInt = #line) async throws {
        for _ in 0..<6 {
            field.tap()
            if app.keyboards.firstMatch.waitForExistence(timeout: 10) {
                return
            }
        }
        throw try await stop("The keyboard never showed for \(field)", line: line)
    }
    
    private func button(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }
    
    /// Picks the chat named `name` in the Tasks tab's Choose a chat sheet, through its search field.
    private func chooseChat(_ name: String) async throws {
        let search = try await waitFor(app.searchFields.firstMatch, timeout: 30)
        search.tap()
        search.typeText(name)
        try await waitFor(button(name), timeout: 30).tap()
    }
    
    /// A list row holding an element labelled `label`, such as a task's title.
    private func row(_ label: String) -> XCUIElement {
        app.cells.containing(NSPredicate(format: "label == %@", label)).firstMatch
    }
    
    /// A text field or text view named by `label` or its placeholder.
    private func field(_ label: String) -> XCUIElement {
        let types = [XCUIElement.ElementType.textField, .textView].map(\.rawValue) as NSArray
        return app.descendants(matching: .any).matching(NSPredicate(format: "elementType IN %@ AND (label == %@ OR placeholderValue == %@)", types, label, label)).firstMatch
    }
    
    /// Any element whose label holds `text`: a timeline bubble's label also has its sender and time.
    private func text(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }
    
    @discardableResult
    private func waitFor(_ element: XCUIElement, timeout: TimeInterval = 15, line: UInt = #line) async throws -> XCUIElement {
        guard element.waitForExistence(timeout: timeout) else { throw try await stop("Not shown: \(element)", line: line) }
        return element
    }
    
    /// The index of the first of `elements` to exist.
    private func firstToAppear(_ elements: [XCUIElement], timeout: TimeInterval, line: UInt = #line) async throws -> Int {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if let index = elements.firstIndex(where: \.exists) {
                return index
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw try await stop("None appeared: \(elements)", line: line)
    }
    
    /// Waits for `element`, scrolling the screen's list until it can be tapped: towards it once the list has loaded it, else down
    /// the list and then back up.
    @discardableResult
    private func scrollTo(_ element: XCUIElement, timeout: TimeInterval = 120, line: UInt = #line) async throws -> XCUIElement {
        let deadline = Date.now.addingTimeInterval(timeout)
        _ = element.waitForExistence(timeout: min(20, timeout))
        var drags = 0
        while !(element.exists && element.isHittable) {
            guard Date.now < deadline else { throw try await stop("Not reached: \(element)", line: line) }
            if try await skipIdentityCover() {
                continue
            }
            drag(towardsTop: element.exists ? element.frame.midY < app.frame.midY : drags >= 25)
            drags = (drags + 1) % 50
            try await Task.sleep(for: .milliseconds(300))
        }
        return element
    }
    
    /// Scrolls the screen's list by half a screen. Unlike a swipe it has no momentum, which in a long list flung rows past
    /// without ever showing them.
    private func drag(towardsTop: Bool) {
        let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let (start, end) = towardsTop ? (upper, lower) : (lower, upper)
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0.1)
    }
    
    /// The element labelled `label` nearest below `anchor`, such as a row under its section's header.
    private func below(_ anchor: XCUIElement, label: String, line: UInt = #line) async throws -> XCUIElement {
        try await waitFor(anchor)
        for _ in 0..<4 {
            let candidates = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex
                .filter { $0.frame.minY >= anchor.frame.maxY - 1 && $0.isHittable }
            if let nearest = candidates.min(by: { $0.frame.minY < $1.frame.minY }) {
                return nearest
            }
            drag(towardsTop: false)
            try await Task.sleep(for: .milliseconds(500))
        }
        throw try await stop("No \(label) below \(anchor)", line: line)
    }
    
    /// Pops screens until `element` can be tapped. Scrolling down minimizes the tab bar to the current tab and Search (upstream's
    /// bar; the Matcha tabs keep theirs), so at a tab's root the current tab is tapped to expand the bar again. The identity cover
    /// can come back over the tabs while this device is unverified: it is skipped again.
    private func goBack(to element: XCUIElement) async throws {
        for _ in 0..<6 where !(element.exists && element.isHittable) {
            if try await skipIdentityCover() {
                continue
            }
            let back = app.buttons["BackButton"].firstMatch
            if back.exists {
                back.tap()
            } else if minimizedTab.exists {
                minimizedTab.tap()
            } else {
                drag(towardsTop: true)
            }
            try await Task.sleep(for: .seconds(1))
        }
        try await waitFor(element)
    }
    
    /// Skips the identity cover if it came back, as it does while this device is unverified and other runs sign the same account in.
    private func skipIdentityCover() async throws -> Bool {
        let skip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Skip'")).firstMatch
        guard skip.exists else { return false }
        try await snap("00-onboarding-\(Int(Date.now.timeIntervalSince1970))")
        skip.tap()
        try await Task.sleep(for: .seconds(1))
        return true
    }
    
    /// Records the failure with a screenshot of where it happened.
    private func stop(_ message: String, line: UInt) async throws -> Error {
        try? await snap("failed-line-\(line)")
        XCTFail(message, file: #filePath, line: line)
        return Stopped()
    }
    
    private func snap(_ name: String) async throws {
        try await Task.sleep(for: .seconds(1))
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let screensDirectory else { return }
        let debugDirectory = screensDirectory.appending(path: "debug")
        try FileManager.default.createDirectory(at: debugDirectory, withIntermediateDirectories: true)
        try screenshot.pngRepresentation.write(to: screensDirectory.appending(path: "\(name).png"))
        try app.debugDescription.write(to: debugDirectory.appending(path: "\(name).txt"), atomically: true, encoding: .utf8)
    }
}

private struct Stopped: Error { }

// MARK: - The local homeserver

/// The throwaway accounts of `.matcha-local-test.env`, named by `MATCHA_LOCAL_TEST_ENV`.
private struct LocalAccounts {
    let homeserver: String
    let userA: String
    let passwordA: String
    let userB: String
    let passwordB: String
    /// One of the local reminder bot's `ALLOWED_INVITERS`, which the seed has invite the bot into the chat; nil skips that.
    let botInviter: (user: String, password: String)?
    
    static func load() -> LocalAccounts? {
        guard let path = ProcessInfo.processInfo.environment["MATCHA_LOCAL_TEST_ENV"],
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var values = [String: String]()
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces.union(["\"", "'"])) }
            if parts.count == 2 {
                values[parts[0]] = parts[1]
            }
        }
        guard let homeserver = values["MATCHA_LOCAL_HOMESERVER"], let userA = values["MATCHA_LOCAL_USER_A"], let passwordA = values["MATCHA_LOCAL_PASSWORD_A"],
              let userB = values["MATCHA_LOCAL_USER_B"], let passwordB = values["MATCHA_LOCAL_PASSWORD_B"] else { return nil }
        let botInviter = values["MATCHA_LOCAL_BOT_INVITER"].flatMap { user in values["MATCHA_LOCAL_BOT_INVITER_PASSWORD"].map { (user, $0) } }
        return LocalAccounts(homeserver: homeserver, userA: userA, passwordA: passwordA, userB: userB, passwordB: passwordB, botInviter: botInviter)
    }
}

/// A space whose notes are on (encrypted, docs updates at power level 0) holding a chat with a task board and two named threads,
/// in the web client's wire format: "Launch plan", named when it was made and answered by A, and "Venue", renamed, both with a card.
/// Not on the main actor: after a failure the test's main thread never runs again, and the teardown still has to leave the rooms.
private struct Seed {
    let spaceName: String
    let chatName: String
    private let spaceID: String
    private let chatID: String
    private let boardRootID: String
    private let sessionA: Session
    private let sessionB: Session
    /// The bot inviter's session, while the reminder bot is in the chat.
    private let sessionInviter: Session?
    
    var hasReminderBot: Bool {
        sessionInviter != nil
    }
    
    static func make(_ accounts: LocalAccounts) async throws -> Seed {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMdd-HHmmss"
        let stamp = formatter.string(from: .now)
        let spaceName = "Matcha E2E \(stamp)"
        let chatName = "E2E chat \(stamp)"
        let sessionB = try await Session.login(accounts.homeserver, user: accounts.userB, password: accounts.passwordB)
        let sessionA = try await Session.login(accounts.homeserver, user: accounts.userA, password: accounts.passwordA)
        for session in [sessionA, sessionB] {
            try await session.leaveEarlierTestRooms()
        }
        
        let encryption: [String: Any] = ["type": "m.room.encryption", "state_key": "", "content": ["algorithm": "m.megolm.v1.aes-sha2"]]
        let powerLevels: [String: Any] = ["events": ["m.room.power_levels": 100, "m.room.encryption": 100, "m.room.name": 50, "m.space.child": 50,
                                                     "com.matchahoneylatte.docs.update": 0, "m.room.encrypted": 0]]
        let spaceID = try await sessionB.createRoom(["name": spaceName,
                                                     "preset": "private_chat",
                                                     "invite": [sessionA.userID],
                                                     "creation_content": ["type": "m.space"],
                                                     "initial_state": [encryption],
                                                     "power_level_content_override": powerLevels])
        let sessionInviter = try await accounts.botInviter.asyncMap { try await Session.login(accounts.homeserver, user: $0.user, password: $0.password) }
        let chatID = try await sessionB.createRoom(["name": chatName, "preset": "private_chat", "invite": [sessionA.userID] + (sessionInviter.map { [$0.userID] } ?? [])])
        try await sessionB.state(spaceID, "m.space.child", key: chatID, ["via": [sessionB.serverName]])
        try await sessionB.state(chatID, "m.space.parent", key: spaceID, ["via": [sessionB.serverName], "canonical": true])
        try await sessionA.join(spaceID)
        try await sessionA.join(chatID)
        if let sessionInviter {
            try await sessionInviter.join(chatID)
            try await sessionInviter.inviteReminderBot(chatID)
        }
        
        let metadata = "com.matchahoneylatte.thread.metadata"
        try await sessionB.send(chatID, "m.room.message", ["msgtype": "m.text", "body": "Hello from B"])
        let launch = try await sessionB.send(chatID, "m.room.message", ["msgtype": "m.text", "body": "Launch plan"])
        try await sessionB.send(chatID, metadata, ["version": 1, "name": "Launch plan", "archived": false, "m.relates_to": threadRelation(launch)])
        try await sessionA.send(chatID, "m.room.message", ["msgtype": "m.text", "body": "I'll draft it", "m.relates_to": threadRelation(launch)])
        let venue = try await sessionB.send(chatID, "m.room.message", ["msgtype": "m.text", "body": "Can someone check the venue?"])
        try await sessionB.send(chatID, "m.room.message", ["msgtype": "m.text", "body": "Booked for Friday", "m.relates_to": threadRelation(venue)])
        try await sessionB.send(chatID, metadata, ["version": 1, "name": "Venue", "m.relates_to": reference(venue)])
        
        let root = try await sessionB.send(chatID, "com.matchahoneylatte.kanban.board", ["version": 1])
        try await sessionB.state(chatID, "com.matchahoneylatte.kanban", key: "", ["version": 1, "event_id": root])
        for (cardID, title, column, threadID) in [("e2e-launch", "Launch plan", "todo", launch), ("e2e-venue", "Venue", "doing", venue)] {
            try await sessionB.send(chatID, "com.matchahoneylatte.kanban.card", ["version": 1, "card_id": cardID, "title": title, "description": "",
                                                                                 "column": column, "archived": false, "show_to_room": true,
                                                                                 "thread_id": threadID, "m.relates_to": reference(root)])
        }
        return Seed(spaceName: spaceName, chatName: chatName, spaceID: spaceID, chatID: chatID, boardRootID: root,
                    sessionA: sessionA, sessionB: sessionB, sessionInviter: sessionInviter)
    }
    
    /// Waits until the homeserver's card revisions, newest first, pass `check`, such as once the app sent one.
    func waitForCards(_ what: String, _ check: ([Card]) -> Bool) async throws {
        for _ in 0..<30 {
            let page = try await sessionB.call("GET", "/_matrix/client/v1/rooms/\(chatID.escaped)/relations/\(boardRootID.escaped)/m.reference?dir=b&limit=100")
            let cards = (page["chunk"] as? [[String: Any]] ?? []).compactMap { ($0["content"] as? [String: Any]).flatMap(Card.init) }
            if check(cards) {
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        XCTFail("The homeserver's cards don't show \(what)")
    }
    
    /// Waits until the chat holds A's `!remind` command for the message `body` (the message's link and text after the time) and the
    /// reminder bot's answer after it.
    func waitForReminder(from body: String) async throws {
        let bot = "@matcha-reminder:\(sessionB.serverName)"
        for _ in 0..<60 {
            let page = try await sessionB.call("GET", "/_matrix/client/v3/rooms/\(chatID.escaped)/messages?dir=b&limit=50")
            let events = (page["chunk"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "m.room.message" }
            let command = events.first { event in
                let text = (event["content"] as? [String: Any])?["body"] as? String ?? ""
                return event["sender"] as? String == sessionA.userID && text.hasPrefix("!remind ") && text.contains(body)
            }
            if let command, let sentAt = command["origin_server_ts"] as? Int,
               events.contains(where: { $0["sender"] as? String == bot && ($0["origin_server_ts"] as? Int ?? 0) >= sentAt }) {
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        XCTFail("The chat has no !remind command from A answered by the reminder bot")
    }
    
    /// Both users leave this run's chat and space, so later runs' tabs don't list them, then the API's sessions sign out. They don't
    /// forget them: the homeserver's sliding sync leaves forgotten rooms out, so the app would never hear of the leave and kept
    /// listing them as joined (the Tasks tab then "couldn't check" them).
    func finish() async throws {
        for session in [sessionA, sessionB] {
            for roomID in [chatID, spaceID] {
                _ = try await session.call("POST", "/_matrix/client/v3/rooms/\(roomID.escaped)/leave", [:])
            }
            let joined = try await session.call("GET", "/_matrix/client/v3/joined_rooms")["joined_rooms"] as? [String] ?? []
            XCTAssertTrue(Set(joined).isDisjoint(with: [chatID, spaceID]), "\(session.userID) is still in this run's rooms")
            _ = try await session.call("POST", "/_matrix/client/v3/logout", [:])
        }
        if let sessionInviter {
            _ = try await sessionInviter.call("POST", "/_matrix/client/v3/rooms/\(chatID.escaped)/leave", [:])
            _ = try await sessionInviter.call("POST", "/_matrix/client/v3/logout", [:])
        }
    }
    
    private static func threadRelation(_ rootID: String) -> [String: Any] {
        ["rel_type": "m.thread", "event_id": rootID, "is_falling_back": true, "m.in_reply_to": ["event_id": rootID]]
    }
    
    private static func reference(_ eventID: String) -> [String: Any] {
        ["rel_type": "m.reference", "event_id": eventID]
    }
}

private struct Session {
    let homeserver: String
    let token: String
    let userID: String
    
    var serverName: String {
        String(userID.split(separator: ":", maxSplits: 1).last ?? "")
    }
    
    static func login(_ homeserver: String, user: String, password: String) async throws -> Session {
        let anonymous = Session(homeserver: homeserver, token: "", userID: "")
        let identifier: [String: Any] = ["type": "m.id.user", "user": user]
        let response = try await anonymous.call("POST", "/_matrix/client/v3/login", ["type": "m.login.password",
                                                                                     "identifier": identifier,
                                                                                     "password": password,
                                                                                     "initial_device_display_name": "Matcha end-to-end seed"])
        return try Session(homeserver: homeserver, token: XCTUnwrap(response["access_token"] as? String), userID: XCTUnwrap(response["user_id"] as? String))
    }
    
    func createRoom(_ body: [String: Any]) async throws -> String {
        let response = try await call("POST", "/_matrix/client/v3/createRoom", body)
        return try XCTUnwrap(response["room_id"] as? String)
    }
    
    func join(_ roomID: String) async throws {
        _ = try await call("POST", "/_matrix/client/v3/join/\(roomID.escaped)", [:])
    }
    
    /// Leaves (without forgetting, as `finish`) the rooms that earlier runs of this test and the local homeserver suites left behind, once they are an hour
    /// old, so the Channels and Notes tabs stay short enough to scroll through; a run going on elsewhere keeps its rooms. A test room
    /// is named "Matcha E2E <stamp>" or "E2E chat <stamp>" here, and "<words> <8 hex digits>" by the suites.
    func leaveEarlierTestRooms() async throws {
        let testName = /^(Matcha E2E|E2E chat) \d{4}-\d{6}$|^[A-Za-z0-9 ]+ [0-9A-F]{8}$/
        let anHourAgo = Int(Date.now.addingTimeInterval(-3600).timeIntervalSince1970 * 1000)
        for roomID in try await call("GET", "/_matrix/client/v3/joined_rooms")["joined_rooms"] as? [String] ?? [] {
            guard let name = try? await call("GET", "/_matrix/client/v3/rooms/\(roomID.escaped)/state/m.room.name")["name"] as? String,
                  name.wholeMatch(of: testName) != nil,
                  let first = try await call("GET", "/_matrix/client/v3/rooms/\(roomID.escaped)/messages?dir=f&limit=1")["chunk"] as? [[String: Any]],
                  let createdAt = first.first?["origin_server_ts"] as? Int, createdAt < anHourAgo else { continue }
            _ = try await call("POST", "/_matrix/client/v3/rooms/\(roomID.escaped)/leave", [:])
        }
    }
    
    /// Invites the local reminder bot and waits until it has joined.
    func inviteReminderBot(_ roomID: String) async throws {
        let bot = "@matcha-reminder:\(serverName)"
        _ = try await call("POST", "/_matrix/client/v3/rooms/\(roomID.escaped)/invite", ["user_id": bot])
        for _ in 0..<30 {
            let member = try? await call("GET", "/_matrix/client/v3/rooms/\(roomID.escaped)/state/m.room.member/\(bot.escaped)")
            if member?["membership"] as? String == "join" {
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw SeedError(path: "the reminder bot's join", status: nil, code: nil)
    }
    
    @discardableResult
    func send(_ roomID: String, _ type: String, _ content: [String: Any]) async throws -> String {
        let response = try await call("PUT", "/_matrix/client/v3/rooms/\(roomID.escaped)/send/\(type)/\(UUID().uuidString)", content)
        return try XCTUnwrap(response["event_id"] as? String)
    }
    
    func state(_ roomID: String, _ type: String, key: String, _ content: [String: Any]) async throws {
        _ = try await call("PUT", "/_matrix/client/v3/rooms/\(roomID.escaped)/state/\(type)/\(key.escaped)", content)
    }
    
    /// One request, waiting out the homeserver's rate limits.
    func call(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = try URLRequest(url: XCTUnwrap(URL(string: homeserver + path)))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        for _ in 0..<10 {
            let (data, response) = try await URLSession.shared.data(for: request)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            switch (response as? HTTPURLResponse)?.statusCode {
            case 200:
                return json
            case 429:
                try await Task.sleep(for: .milliseconds(json["retry_after_ms"] as? Int ?? 5000))
            case let status:
                // Only the error code: the body of a login could echo what was sent.
                throw SeedError(path: path.split(separator: "?").first.map(String.init) ?? path, status: status, code: json["errcode"] as? String)
            }
        }
        throw SeedError(path: path, status: 429, code: nil)
    }
}

/// A revision of a task card, as the board's relations return it.
private struct Card {
    let id: String
    let title: String
    let column: String
    let isArchived: Bool
    
    init?(_ content: [String: Any]) {
        guard let id = content["card_id"] as? String else { return nil }
        self.id = id
        title = content["title"] as? String ?? ""
        column = content["column"] as? String ?? ""
        isArchived = content["archived"] as? Bool ?? false
    }
}

private extension [Card] {
    /// The latest revision of the card `id`: the relations come newest first.
    func newest(_ id: String) -> Card? {
        first { $0.id == id }
    }
}

private struct SeedError: Error {
    let path: String
    let status: Int?
    let code: String?
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let self else { return nil }
        return try await transform(self)
    }
}

private extension String {
    var escaped: String {
        addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? self
    }
}
