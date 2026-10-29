//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import Foundation
import MatchaProtocol
import Testing

@MainActor
struct ChatBarViewModelTests {
    @Test
    func threadChipsWaitForTheMetadataToLoad() async throws {
        let fixture = try MatchaRoomFixture(items: [aThreadPatchItem(1, threadID: "$t1", name: "Plan")], threads: [aThreadListItem("$t1")])
        let gate = Gate()
        fixture.relationsResult = { _, _, _, _ in
            await gate.wait()
            return .success(.init(events: [], nextBatch: nil))
        }
        let (viewModel, store, _) = makeViewModel(fixture)
        
        #expect(viewModel.context.viewState.threads.isEmpty)
        #expect(!viewModel.context.viewState.showsBar)
        
        gate.open()
        await store.settle()
        #expect(viewModel.context.viewState.threads.map(\.name) == ["Plan"])
        #expect(viewModel.context.viewState.showsBar)
    }
    
    @Test
    func upToFourActiveThreadsAreShownNewestActivityFirst() async throws {
        let fixture = try MatchaRoomFixture(items: [aThreadPatchItem(1, threadID: "$old", archived: true)],
                                            threads: (1...6).map { aThreadListItem("$t\($0)", body: "Thread \($0)", timestamp: Int64($0)) }
                                                + [aThreadListItem("$old", timestamp: 100)])
        let (viewModel, store, _) = makeViewModel(fixture)
        await store.settle()
        
        #expect(viewModel.context.viewState.threads.map(\.id) == ["$t6", "$t5", "$t4", "$t3"])
    }
    
    @Test
    func theOpenThreadGetsItsOwnChipWhenItIsNotAmongTheActiveOnes() async throws {
        let fixture = try MatchaRoomFixture(items: [aThreadPatchItem(1, threadID: "$old", name: "Venue shortlist"),
                                                    aThreadPatchItem(2, threadID: "$old", archived: true)],
                                            threads: [aThreadListItem("$t1"), aThreadListItem("$old")])
        let (viewModel, store, _) = makeViewModel(fixture, selection: .thread(id: "$old"))
        await store.settle()
        
        #expect(viewModel.context.viewState.threads == [ChatBarThread(id: "$t1", name: "Root of $t1", isArchived: false),
                                                        ChatBarThread(id: "$old", name: "Venue shortlist", isArchived: true)])
        #expect(viewModel.context.viewState.threadName == "Venue shortlist")
    }
    
    @Test
    func anUnreadableNameShowsTheFallbackAndTheWarning() async {
        let fixture = MatchaRoomFixture(threads: [aThreadListItem("$t1", isRootUnreadable: true, rootUTDCause: .unknown)])
        let (viewModel, store, _) = makeViewModel(fixture)
        await store.settle()
        
        #expect(viewModel.context.viewState.threads == [ChatBarThread(id: "$t1", name: nil, isArchived: false)])
        #expect(viewModel.context.viewState.warning == .undecryptable)
    }
    
    @Test
    func tappingAChipNavigatesAndTappingTheSelectedOneDoesNothing() async {
        let (viewModel, store, _) = makeViewModel(MatchaRoomFixture(threads: [aThreadListItem("$t1")]), selection: .thread(id: "$t1"))
        await store.settle()
        var routes = [ChatBarRoute]()
        let cancellable = viewModel.actions.sink { routes.append($0) }
        
        viewModel.context.send(viewAction: .select(.thread(id: "$t1")))
        viewModel.context.send(viewAction: .select(.general))
        viewModel.context.send(viewAction: .allThreads)
        viewModel.context.send(viewAction: .board)
        viewModel.context.send(viewAction: .viewTask(threadID: "$t1"))
        
        #expect(routes == [.general, .allThreads, .board(threadID: nil), .board(threadID: "$t1")])
        cancellable.cancel()
    }
    
    @Test
    func remindMeIsAboutTheThreadAskedForElseTheOpenOneAndSpaceNotesOpenTheSpace() async {
        let (viewModel, store, _) = makeViewModel(MatchaRoomFixture(threads: [aThreadListItem("$t1")]), selection: .thread(id: "$t1"))
        await store.settle()
        #expect(viewModel.context.viewState.canRemind)
        var routes = [ChatBarRoute]()
        let cancellable = viewModel.actions.sink { routes.append($0) }
        
        viewModel.context.send(viewAction: .remindMe(threadID: nil))
        viewModel.context.send(viewAction: .remindMe(threadID: "$t2"))
        viewModel.context.send(viewAction: .openSpaceNotes(spaceID: "!space:x"))
        
        #expect(routes == [.remindMe(threadID: "$t1"), .remindMe(threadID: "$t2"), .spaceNotes(spaceID: "!space:x")])
        cancellable.cancel()
    }
    
    @Test
    func stickersGoToTheOpenThreadElseTheRoom() {
        var routes = [ChatBarRoute]()
        let (thread, _, _) = makeViewModel(MatchaRoomFixture(), selection: .thread(id: "$t1"))
        let (general, _, _) = makeViewModel(MatchaRoomFixture())
        let cancellables = [thread.actions.sink { routes.append($0) }, general.actions.sink { routes.append($0) }]
        
        thread.context.send(viewAction: .stickers)
        general.context.send(viewAction: .stickers)
        
        #expect(routes == [.stickers(threadID: "$t1"), .stickers(threadID: nil)])
        cancellables.forEach { $0.cancel() }
    }
    
    @Test
    func remindMeShowsInADirectChatOnceTheReminderBotsMembershipLoads() async {
        let fixture = MatchaRoomFixture(isDirect: true, heroes: ["@friend:x"])
        fixture.roomInfo.isDM = true
        // A room's members load after it opens, maybe after the store's last snapshot.
        let members = CurrentValueSubject<[RoomMemberProxyProtocol], Never>([])
        fixture.room.membersPublisher = members.asCurrentValuePublisher()
        let (viewModel, store, _) = makeViewModel(fixture)
        await store.settle()
        #expect(!viewModel.context.viewState.canRemind)
        
        members.send([RoomMemberProxyMock(with: .init(userID: MatchaConfig.reminderBotUserID(sessionUserID: matchaUser), membership: .join))])
        #expect(viewModel.context.viewState.canRemind)
    }
    
    @Test
    func creatingAThreadSendsTheRootThenNamesItAndOpensIt() async throws {
        let fixture = MatchaRoomFixture()
        fixture.sendResult = { type, _ in .success(type == "m.room.message" ? "$root" : "$meta") }
        let (viewModel, store, chat) = makeViewModel(fixture)
        await store.settle()
        var routes = [ChatBarRoute]()
        let cancellable = viewModel.actions.sink { routes.append($0) }
        
        viewModel.context.send(viewAction: .newThread)
        viewModel.context.send(viewAction: .updateThreadName("  Launch plan "))
        viewModel.context.send(viewAction: .submitThreadName)
        #expect(viewModel.context.threadNameSheet?.isSending == true)
        
        await eventually { routes == [.thread(id: "$root")] }
        #expect(viewModel.context.threadNameSheet == nil)
        #expect(fixture.sent.map(\.type) == ["m.room.message", MatchaConfig.eventThreadMetadata])
        #expect(try fixture.sent.first?.content == ThreadMetadataProtocol.rootMessageContent(name: "Launch plan"))
        #expect(try fixture.sent.last?.content == ThreadMetadataProtocol.bootstrapReplyContent(rootID: "$root", name: "Launch plan"))
        #expect(chat.banner == nil)
        cancellable.cancel()
    }
    
    @Test
    func aThreadThatCouldNotBeSetUpOpensAnywayAndOffersToFinishSettingItUp() async throws {
        let fixture = MatchaRoomFixture()
        var isSetUpFailing = true
        fixture.sendResult = { type, _ in
            if type == "m.room.message" {
                return .success("$root")
            }
            return isSetUpFailing ? .failure(.sdkError(RoomProxyMockError.generic)) : .success("$meta")
        }
        let (viewModel, store, chat) = makeViewModel(fixture)
        await store.settle()
        var routes = [ChatBarRoute]()
        let cancellable = viewModel.actions.sink { routes.append($0) }
        
        viewModel.context.send(viewAction: .newThread)
        viewModel.context.send(viewAction: .updateThreadName("Launch plan"))
        viewModel.context.send(viewAction: .submitThreadName)
        await eventually { routes == [.thread(id: "$root")] }
        #expect(chat.banner?.message == UntranslatedL10n.screenMatchaThreadsSetupFailed)
        #expect(fixture.sent.map(\.type) == ["m.room.message"])
        
        isSetUpFailing = false
        chat.banner?.action()
        await eventually { fixture.sent.count == 2 }
        #expect(try fixture.sent.last?.content == ThreadMetadataProtocol.bootstrapReplyContent(rootID: "$root", name: "Launch plan"))
        #expect(chat.banner == nil)
        cancellable.cancel()
    }
    
    @Test
    func aThreadCreatedFromAScreenThatIsGoneDoesntOpen() async throws {
        let fixture = MatchaRoomFixture()
        fixture.sendResult = { type, _ in .success(type == "m.room.message" ? "$root" : "$meta") }
        let gate = Gate()
        let send = try #require(fixture.room.sendRawEventTypeContentJSONClosure)
        fixture.room.sendRawEventTypeContentJSONClosure = { type, content in
            await gate.wait()
            return await send(type, content)
        }
        let store = fixture.store()
        await store.settle()
        var viewModel: ChatBarViewModel? = ChatBarViewModel(chat: MatchaChat(store: store), selection: .thread(id: "$t1"))
        var routes = [ChatBarRoute]()
        let cancellable = viewModel?.actions.sink { routes.append($0) }
        
        viewModel?.context.send(viewAction: .newThread)
        viewModel?.context.send(viewAction: .updateThreadName("Launch plan"))
        viewModel?.context.send(viewAction: .submitThreadName)
        // The user goes back from the thread while the thread is still being created; its screen lets go of the bar.
        weak let goneViewModel = viewModel
        viewModel = nil
        #expect(goneViewModel == nil)
        
        // As on Android, the thread is still created, but only a bar that is still shown opens it.
        gate.open()
        await eventually { fixture.sent.count == 2 }
        await store.settle()
        #expect(routes.isEmpty)
        cancellable?.cancel()
    }
    
    @Test
    func aFailedCreateKeepsTheSheetOpenWithAnError() async {
        let fixture = MatchaRoomFixture()
        fixture.sendResult = { _, _ in .failure(.sdkError(RoomProxyMockError.generic)) }
        let (viewModel, store, _) = makeViewModel(fixture)
        await store.settle()
        
        viewModel.context.send(viewAction: .newThread)
        viewModel.context.send(viewAction: .updateThreadName("Launch plan"))
        viewModel.context.send(viewAction: .submitThreadName)
        
        await eventually { viewModel.context.threadNameSheet?.error == .createFailed }
        #expect(viewModel.context.threadNameSheet?.name == "Launch plan")
        #expect(viewModel.context.threadNameSheet?.isSending == false)
    }
    
    @Test
    func threadNamesAreValidated() async {
        let fixture = MatchaRoomFixture()
        let (viewModel, store, _) = makeViewModel(fixture)
        await store.settle()
        viewModel.context.send(viewAction: .newThread)
        
        // An empty name is only an error once the user tries to save.
        viewModel.context.send(viewAction: .updateThreadName("   "))
        #expect(viewModel.context.threadNameSheet?.error == nil)
        viewModel.context.send(viewAction: .submitThreadName)
        #expect(viewModel.context.threadNameSheet?.error == .empty)
        
        viewModel.context.send(viewAction: .updateThreadName(String(repeating: "a", count: MatchaConfig.threadNameMaxLength + 1)))
        #expect(viewModel.context.threadNameSheet?.error == .tooLong)
        viewModel.context.send(viewAction: .submitThreadName)
        #expect(viewModel.context.threadNameSheet?.error == .tooLong)
        
        viewModel.context.send(viewAction: .updateThreadName(String(repeating: "a", count: MatchaConfig.threadNameMaxLength)))
        #expect(viewModel.context.threadNameSheet?.error == nil)
        #expect(fixture.sent.isEmpty)
    }
    
    @Test
    func namesAreTrimmedLikeTheProtocolTrimsThem() async throws {
        let fixture = MatchaRoomFixture()
        fixture.sendResult = { type, _ in .success(type == "m.room.message" ? "$root" : "$meta") }
        let (viewModel, store, _) = makeViewModel(fixture)
        await store.settle()
        viewModel.context.send(viewAction: .newThread)
        
        // Kotlin's trim() drops U+001C–U+001F too, which Foundation keeps: a name of only those is empty, not too long.
        viewModel.context.send(viewAction: .updateThreadName("\u{1C}\u{1F}"))
        #expect(viewModel.context.threadNameSheet?.error == nil)
        viewModel.context.send(viewAction: .submitThreadName)
        #expect(viewModel.context.threadNameSheet?.error == .empty)
        
        viewModel.context.send(viewAction: .updateThreadName("\u{1C}Launch plan\u{1F}"))
        viewModel.context.send(viewAction: .submitThreadName)
        await eventually { fixture.sent.count == 2 }
        #expect(try fixture.sent.last?.content == ThreadMetadataProtocol.bootstrapReplyContent(rootID: "$root", name: "Launch plan"))
    }
    
    @Test
    func renamingSendsANamePatchAndAnUnchangedNameSendsNothing() async throws {
        let fixture = try MatchaRoomFixture(items: [aThreadPatchItem(1, threadID: "$t1", name: "Plan")], threads: [aThreadListItem("$t1")])
        let (viewModel, store, _) = makeViewModel(fixture)
        await store.settle()
        
        viewModel.context.send(viewAction: .renameThread(id: "$t1"))
        #expect(viewModel.context.threadNameSheet == ThreadNameSheet(threadID: "$t1", name: "Plan"))
        viewModel.context.send(viewAction: .submitThreadName)
        await eventually { viewModel.context.threadNameSheet == nil }
        #expect(fixture.sent.isEmpty)
        
        viewModel.context.send(viewAction: .renameThread(id: "$t1"))
        viewModel.context.send(viewAction: .updateThreadName("Launch plan"))
        viewModel.context.send(viewAction: .submitThreadName)
        await eventually { viewModel.context.threadNameSheet == nil }
        #expect(try fixture.sent.map(\.content) == [ThreadMetadataProtocol.patchContent(rootID: "$t1", name: "Launch plan")])
    }
    
    @Test
    func aFailedRenameBringsTheSheetBackWithItsError() async throws {
        let fixture = try MatchaRoomFixture(items: [aThreadPatchItem(1, threadID: "$t1", name: "Plan")], threads: [aThreadListItem("$t1")])
        fixture.sendResult = { _, _ in .failure(.sdkError(RoomProxyMockError.generic)) }
        let (viewModel, store, _) = makeViewModel(fixture)
        await store.settle()
        
        viewModel.context.send(viewAction: .renameThread(id: "$t1"))
        viewModel.context.send(viewAction: .updateThreadName("Launch plan"))
        viewModel.context.send(viewAction: .submitThreadName)
        // Dismissed while sending: the failure brings it back.
        viewModel.context.threadNameSheet = nil
        
        await eventually { viewModel.context.threadNameSheet?.error == .renameFailed }
        #expect(viewModel.context.threadNameSheet?.name == "Launch plan")
    }
    
    @Test
    func archivingTheOpenThreadReturnsToGeneralAndOffersUndo() async throws {
        let fixture = try MatchaRoomFixture(items: [aThreadPatchItem(1, threadID: "$t1", name: "Plan")], threads: [aThreadListItem("$t1")])
        let (viewModel, store, chat) = makeViewModel(fixture, selection: .thread(id: "$t1"))
        await store.settle()
        var routes = [ChatBarRoute]()
        let cancellable = viewModel.actions.sink { routes.append($0) }
        
        viewModel.context.send(viewAction: .setArchived(threadID: "$t1", archived: true))
        await eventually { routes == [.general] }
        #expect(try fixture.sent.map(\.content) == [ThreadMetadataProtocol.patchContent(rootID: "$t1", archived: true)])
        #expect(chat.banner?.message == UntranslatedL10n.screenMatchaThreadsArchivedSnackbar)
        #expect(chat.banner?.actionTitle == UntranslatedL10n.actionMatchaUndo)
        
        chat.banner?.action()
        await eventually { fixture.sent.count == 2 }
        #expect(try fixture.sent.last?.content == ThreadMetadataProtocol.patchContent(rootID: "$t1", archived: false))
        // Undoing doesn't offer to undo again.
        #expect(chat.banner == nil)
        cancellable.cancel()
    }
    
    @Test
    func aFailedArchiveOffersToRetryAndUnarchivingOffersUndo() async throws {
        let fixture = try MatchaRoomFixture(items: [aThreadPatchItem(1, threadID: "$t1", name: "Plan")], threads: [aThreadListItem("$t1")])
        fixture.sendResult = { _, _ in .failure(.sdkError(RoomProxyMockError.generic)) }
        let (viewModel, store, chat) = makeViewModel(fixture, selection: .thread(id: "$t1"))
        await store.settle()
        var routes = [ChatBarRoute]()
        let cancellable = viewModel.actions.sink { routes.append($0) }
        
        viewModel.context.send(viewAction: .setArchived(threadID: "$t1", archived: false))
        await eventually { chat.banner?.message == UntranslatedL10n.commonMatchaWriteFailed }
        #expect(chat.banner?.actionTitle == L10n.actionRetry)
        
        fixture.sendResult = { _, _ in .success("$patch") }
        chat.banner?.action()
        await eventually { chat.banner?.message == UntranslatedL10n.screenMatchaThreadsUnarchivedSnackbar }
        #expect(try fixture.sent.map(\.content) == [ThreadMetadataProtocol.patchContent(rootID: "$t1", archived: false)])
        #expect(routes.isEmpty)
        cancellable.cancel()
    }
    
    @Test
    func theBarShowsOnceTheChatHasANamedThreadAndAlwaysOnTheBoard() async throws {
        let fixture = MatchaRoomFixture(threads: [aThreadListItem("$t1")])
        let (viewModel, store, _) = makeViewModel(fixture)
        let (boardViewModel, _, _) = makeViewModel(fixture, store: store, selection: .board)
        await store.settle()
        #expect(!viewModel.context.viewState.showsBar)
        #expect(boardViewModel.context.viewState.showsBar)
        
        try fixture.sendLiveEvent(aMatchaEvent(5, type: MatchaConfig.eventThreadMetadata, content: ThreadMetadataProtocol.patchContent(rootID: "$t1", name: "Plan")))
        await eventually { viewModel.context.viewState.showsBar }
    }
    
    @Test
    func theBarGivesWayToALandscapePhoneAndToTheKeyboardOnANarrowWindow() {
        // A phone in portrait, before and while typing; spec §4a and Android's ChatBarView.
        #expect(ChatBarView.showsChips(showsBar: true, verticalSizeClass: .regular, horizontalSizeClass: .compact, isKeyboardShown: false))
        #expect(!ChatBarView.showsChips(showsBar: true, verticalSizeClass: .regular, horizontalSizeClass: .compact, isKeyboardShown: true))
        // A phone in landscape.
        #expect(!ChatBarView.showsChips(showsBar: true, verticalSizeClass: .compact, horizontalSizeClass: .regular, isKeyboardShown: false))
        // An iPad keeps the bar while typing.
        #expect(ChatBarView.showsChips(showsBar: true, verticalSizeClass: .regular, horizontalSizeClass: .regular, isKeyboardShown: true))
        #expect(!ChatBarView.showsChips(showsBar: false, verticalSizeClass: .regular, horizontalSizeClass: .regular, isKeyboardShown: false))
    }
    
    @Test
    func withoutPermissionThreadsCannotBeCreatedOrManaged() async throws {
        let fixture = try MatchaRoomFixture(items: [aThreadPatchItem(1, threadID: "$t1", name: "Plan")], threads: [aThreadListItem("$t1")])
        fixture.roomInfo.powerLevels = RoomPowerLevelsProxyMock(.init(canUserSendMessage: false))
        let (viewModel, store, _) = makeViewModel(fixture)
        await store.settle()
        
        #expect(!viewModel.context.viewState.canCreateThread)
        #expect(!viewModel.context.viewState.canManageThreads)
        #expect(!viewModel.context.viewState.canRemind)
        var routes = [ChatBarRoute]()
        let cancellable = viewModel.actions.sink { routes.append($0) }
        viewModel.context.send(viewAction: .remindMe(threadID: "$t1"))
        #expect(routes.isEmpty)
        cancellable.cancel()
        viewModel.context.send(viewAction: .newThread)
        viewModel.context.send(viewAction: .renameThread(id: "$t1"))
        viewModel.context.send(viewAction: .setArchived(threadID: "$t1", archived: true))
        #expect(viewModel.context.threadNameSheet == nil)
        await store.settle()
        #expect(fixture.sent.isEmpty)
    }
    
    @Test
    func theBoardButtonCountsTheOpenTasksTheUserSees() async throws {
        let fixture = try MatchaRoomFixture(items: [aCardItem(1, id: "c-todo", title: "To do"),
                                                    aCardItem(2, id: "c-doing", title: "Doing", status: .doing),
                                                    aCardItem(3, id: "c-done", title: "Done", status: .done),
                                                    aCardItem(4, id: "c-hidden", title: "Someone else's", showToRoom: false)])
        fixture.boardPointer = .success(aBoardRoot)
        let (viewModel, store, _) = makeViewModel(fixture)
        await store.settle()
        
        #expect(viewModel.context.viewState.openTaskCount == 2)
    }
    
    @Test
    func theTopBarSaysWhoIsTypingElseHowManyMembersAGroupHas() {
        let fixture = MatchaRoomFixture()
        fixture.roomInfo.joinedMembersCount = 3
        let (viewModel, _, _) = makeViewModel(fixture)
        let group = viewModel.context.viewState.subtitle
        #expect(group == MatchaChatSubtitle(joinedMemberCount: 3))
        
        #expect(group.room(typingMembers: [])?.text == "3 members")
        #expect(group.room(typingMembers: [])?.isTyping == false)
        #expect(group.room(typingMembers: ["Alice"])?.text == "Alice is typing…")
        #expect(group.room(typingMembers: ["Alice"])?.isTyping == true)
        #expect(group.room(typingMembers: ["Alice", "Bob", "Carol", "Dan"])?.text == "Alice, Bob and 2 others are typing…")
        
        let dm = MatchaChatSubtitle(isDM: true, joinedMemberCount: 2)
        #expect(dm.room(typingMembers: []) == nil)
        #expect(dm.room(typingMembers: ["Bob"])?.text == "typing…")
        #expect(MatchaChatSubtitle(isTombstoned: true, joinedMemberCount: 3).room(typingMembers: ["Alice"]) == nil)
        
        // In a thread, typing wins over the thread's name.
        #expect(group.thread(name: "Venue", typingMembers: []) == ("Venue", false))
        #expect(group.thread(name: nil, typingMembers: []).text == "Untitled thread")
        #expect(group.thread(name: "Venue", typingMembers: ["Alice", "Bob"]) == ("Alice and Bob are typing…", true))
    }
    
    // MARK: - Helpers
    
    // swiftlint:disable large_tuple
    private func makeViewModel(_ fixture: MatchaRoomFixture,
                               store: MatchaRoomStore? = nil,
                               selection: ChatBarSelection = .general) -> (ChatBarViewModel, MatchaRoomStore, MatchaChat) {
        let store = store ?? fixture.store()
        let chat = MatchaChat(store: store)
        return (ChatBarViewModel(chat: chat, selection: selection), store, chat)
    }
    // swiftlint:enable large_tuple
}
