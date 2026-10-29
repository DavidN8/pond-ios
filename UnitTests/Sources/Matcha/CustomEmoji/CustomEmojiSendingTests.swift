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
import WysiwygComposer

/// Sending custom emoji (MSC2545, MSC4027): typed `:code:` on send and edit, the composer's suggestions, the reaction picker
/// and reactions, with the cases of the web client's `serialize.test.ts`.
@MainActor
struct CustomEmojiSendingTests {
    private static let party = CustomEmoji(shortcode: "party", url: "mxc://example.org/party")
    private static let parrot = CustomEmoji(shortcode: "party_parrot", url: "mxc://example.org/parrot")
    private let packs = [EmojiPack(id: "user", kind: .user, name: "Your emoji", emojis: [Self.party, Self.parrot])]
    // SwiftSoup writes the image as the web client's `emoticonHtml` does.
    private let partyHTML = ImagePacks.emoticonHTML(url: Self.party.url, shortcode: "party")
    
    // MARK: - Typed shortcodes
    
    @Test
    func sendsTypedEmojiAsImagesInlineWithText() {
        #expect(formattedBody("hi :party: there") == "hi \(partyHTML) there")
        #expect(formattedBody(":party:") == partyHTML)
    }
    
    @Test
    func leavesUnknownShortcodesButLetsTheirClosingColonOpenAKnownOne() {
        #expect(formattedBody(":nope: :x:party:") == ":nope: :x\(partyHTML)")
    }
    
    @Test
    func takesTheUsualPathWithoutAKnownShortcode() {
        #expect(formattedBody("hello :nope: **you**") == nil)
        #expect(formattedBody("hello") == nil)
    }
    
    @Test
    func keepsMarkdownAroundEmoji() {
        #expect(formattedBody("**bold** :party:\n_it_ :party:") == "<strong>bold</strong> \(partyHTML)<br /><em>it</em> \(partyHTML)")
    }
    
    @Test
    func keepsTheShortcodeInCode() {
        #expect(formattedBody("`x :party:` :party:") == "<code>x :party:</code> \(partyHTML)")
        let block = formattedBody("```\n:party:\n```\n:party:")
        #expect(block?.contains("<code>:party:") == true)
        #expect(block?.components(separatedBy: "<img").count == 2)
    }
    
    @Test
    func keepsTheShortcodeInLinkTargets() {
        #expect(formattedBody("[x](https://a.b/:party:) :party:") == #"<a href="https://a.b/:party:">x</a> "# + partyHTML)
    }
    
    @Test
    func keepsMentionsAndEmotes() {
        #expect(formattedBody("[Alice](https://matrix.to/#/@alice:matrix.org) :party:")
            == #"<a href="https://matrix.to/#/@alice:matrix.org">Alice</a> "# + partyHTML)
        // The timeline takes "/me " off both bodies.
        #expect(formattedBody("/me waves :party:") == "/me waves \(partyHTML)")
    }
    
    @Test
    func convertsTheRichTextEditorsHTMLOutsideCode() {
        let html = "<p>hi :party: <code>:party:</code></p><pre><code>:party:</code></pre>"
        #expect(CustomEmojiMessages.formattedBody(markdown: "", html: html, packs: packs)
            == "<p>hi \(partyHTML) <code>:party:</code></p><pre><code>:party:</code></pre>")
        #expect(CustomEmojiMessages.formattedBody(markdown: "", html: "<p>hi :nope:</p>", packs: packs) == nil)
    }
    
    @Test
    func editsCustomEmojiAsTheirShortcodeInTheRichTextEditor() throws {
        let html = CustomEmojiMessages.editableHTML("a \(ImagePacks.emoticonHTML(url: Self.party.url, shortcode: "party")) <b>b</b>")
        #expect(html == "a :party: <b>b</b>")
        // The title holds the shortcode (MSC2545), the alt text maybe a description, as the web client's editor reads them.
        #expect(CustomEmojiMessages.editableHTML(#"<img data-mx-emoticon src="mxc://x/p" alt="Party parrot" title=":party_parrot:">"#) == ":party_parrot:")
        // As the SDK hands it over, without `data-mx-emoticon`.
        #expect(CustomEmojiMessages.editableHTML(#"a <img src="mxc://x/p" alt=":party:" title=":party:" height="32">"#) == "a :party:")
        
        let model = newComposerModel()
        _ = try model.setContentFromHtml(html: html)
        #expect(model.getContentAsMessageHtml().contains(":party:"))
    }
    
    // MARK: - Sending through the timeline
    
    @Test
    func sendsAndEditsTypedEmojiThroughTheTimeline() async {
        let (viewModel, timelineController) = await makeTimeline()
        
        let sent = await sentHTML(of: "hi :party:", mode: .default, viewModel, timelineController)
        #expect(sent.message == "hi :party:")
        #expect(sent.html?.contains(#"src="mxc://example.org/party""#) == true)
        
        let reply = await sentHTML(of: ":party:", mode: .reply(eventID: "$reply", replyDetails: .loading(eventID: "$reply"), isThread: false), viewModel, timelineController)
        #expect(reply.html?.contains("<img") == true)
        #expect(timelineController.sendMessageHtmlInReplyToEventIDIntentionalMentionsReceivedArguments?.inReplyToEventID == "$reply")
        
        await waitForConfirmation { confirm in
            timelineController.editMessageHtmlIntentionalMentionsClosure = { _, message, html, _ in
                #expect(message == "now :party:")
                #expect(html?.contains("<img") == true)
                confirm()
            }
            viewModel.process(composerAction: .sendMessage(plain: "now :party:", html: nil, mode: .edit(originalEventOrTransactionID: .eventID("$e"), type: .default),
                                                           intentionalMentions: .empty))
        }
        
        await waitForConfirmation { confirm in
            timelineController.editCaptionMessageHtmlIntentionalMentionsClosure = { _, message, html, _ in
                #expect(message == "caption :party:")
                #expect(html?.contains("<img") == true)
                confirm()
            }
            viewModel.process(composerAction: .sendMessage(plain: "caption :party:", html: nil, mode: .edit(originalEventOrTransactionID: .eventID("$e"), type: .editCaption),
                                                           intentionalMentions: .empty))
        }
        
        #expect(await sentHTML(of: "hi", mode: .default, viewModel, timelineController).html == nil)
    }
    
    @Test
    func editingInTheRichTextEditorLoadsCustomEmojiAsTheirShortcode() async throws {
        let message = TextRoomTimelineItem(id: .event(uniqueID: .init("u"), eventOrTransactionID: .eventID("$e")), timestamp: .mock, isOutgoing: true,
                                           isEditable: true, canBeRepliedTo: true, sender: .init(id: "@me:example.org"),
                                           content: .init(body: "hi :party:", formattedBodyHTMLString: "hi \(partyHTML)"))
        let handler = await makeInteractionHandler(timelineController: TimelineControllerMock(.init(timelineItems: [message])))
        
        let deferred = deferFulfillment(handler.actions) { action in
            if case .composer(.setText) = action {
                true
            } else {
                false
            }
        }
        handler.handleTimelineItemMenuAction(.edit, itemID: message.id)
        
        guard case .composer(.setText(let plainText, let htmlText)) = try await deferred.fulfill() else { Issue.record("No text was set"); return }
        #expect(plainText == "hi :party:")
        #expect(htmlText == "hi :party:")
    }
    
    @Test
    func sendsTypedShortcodesAsTextWhileCustomEmojiAreOff() async {
        let (viewModel, timelineController) = await makeTimeline(isEnabled: false)
        #expect(await sentHTML(of: "hi :party:", mode: .default, viewModel, timelineController).html == nil)
    }
    
    @Test
    func sendingNeverWaitsForTheServer() async throws {
        let clientProxy = makeClientProxy()
        let userSession = UserSessionMock(.init(clientProxy: clientProxy))
        let (viewModel, timelineController) = await makeTimeline(userSession: userSession)
        // The suggestions read the packs again, and the server doesn't answer.
        clientProxy.fetchStateEventContentJSONRoomIDTypeStateKeyClosure = { _, _, _ in
            try? await Task.sleep(for: .seconds(10))
            return .success(nil)
        }
        Task { _ = await userSession.matchaService.customEmojiPacks.refresh(roomID: "!room:x") }
        
        // Sent at once, with the packs last read.
        let sent = try await sentPromptly("hi :party:", viewModel, timelineController)
        #expect(sent?.html?.contains("<img") == true)
        
        // Before any read, as typed.
        let (coldViewModel, coldTimelineController) = await makeTimeline(userSession: userSession, readsPacks: false)
        let cold = try await sentPromptly("meet at 10:30:00 :party:", coldViewModel, coldTimelineController)
        #expect(cold?.message == "meet at 10:30:00 :party:")
        #expect(cold?.html == nil)
    }
    
    @Test
    func anEditKeepsTheImagesItsMessageHad() async {
        // The message shows an emoji the room's packs no longer have, and one whose shortcode now names another image.
        let wave = ImagePacks.emoticonHTML(url: "mxc://example.org/old-wave", shortcode: "wave")
        let oldParty = ImagePacks.emoticonHTML(url: "mxc://example.org/old-party", shortcode: "party")
        let message = TextRoomTimelineItem(id: .event(uniqueID: .init("u"), eventOrTransactionID: .eventID("$e")), timestamp: .mock, isOutgoing: true,
                                           isEditable: true, canBeRepliedTo: true, sender: .init(id: "@me:example.org"),
                                           // As the SDK hands it over, its sanitizer having dropped `data-mx-emoticon`.
                                           content: .init(body: "hi :wave: :party:",
                                                          formattedBodyHTMLString: "hi \(wave) \(oldParty)".replacingOccurrences(of: "data-mx-emoticon ", with: "")))
        let (viewModel, timelineController) = await makeTimeline(timelineItems: [message])
        
        await waitForConfirmation { confirm in
            timelineController.editMessageHtmlIntentionalMentionsClosure = { _, _, html, _ in
                #expect(html == "hey \(wave) \(oldParty)")
                confirm()
            }
            viewModel.process(composerAction: .sendMessage(plain: "hey :wave: :party:", html: nil,
                                                           mode: .edit(originalEventOrTransactionID: .eventID("$e"), type: .default), intentionalMentions: .empty))
        }
    }
    
    @Test
    func threadsEmotesAndMentionsKeepWorking() async {
        let (threadViewModel, threadTimelineController) = await makeTimeline(timelineKind: .thread(rootEventID: "$root"))
        let thread = await sentHTML(of: "in thread :party:", mode: .default, threadViewModel, threadTimelineController)
        #expect(thread.html == "in thread \(partyHTML)")
        
        let (viewModel, timelineController) = await makeTimeline()
        let mention = IntentionalMentions(userIDs: ["@alice:matrix.org"], atRoom: false)
        await waitForConfirmation { confirm in
            timelineController.sendMessageHtmlInReplyToEventIDIntentionalMentionsClosure = { message, html, _, intentionalMentions in
                #expect(message == "/me waves :party: at [Alice](https://matrix.to/#/@alice:matrix.org)")
                #expect(html == #"/me waves \#(partyHTML) at <a href="https://matrix.to/#/@alice:matrix.org">Alice</a>"#)
                #expect(intentionalMentions == mention)
                confirm()
            }
            viewModel.process(composerAction: .sendMessage(plain: "/me waves :party: at [Alice](https://matrix.to/#/@alice:matrix.org)", html: nil, mode: .default,
                                                           intentionalMentions: mention))
        }
    }
    
    // MARK: - Reactions
    
    @Test
    func customEmojiReactionsCarryTheirShortcodeAndStayOutOfFrequentlyUsed() async {
        let emojiProvider = EmojiProvider(userSettings: .mock())
        let (viewModel, timelineController) = await makeTimeline(emojiProvider: emojiProvider)
        let itemID = TimelineItemIdentifier.event(uniqueID: .init("u"), eventOrTransactionID: .eventID("$e"))
        
        await waitForConfirmation { confirm in
            timelineController.toggleReactionToShortcodeClosure = { key, _, shortcode in
                #expect(key == Self.party.url)
                #expect(shortcode == ":party:")
                confirm()
            }
            viewModel.process(viewAction: .toggleReaction(key: Self.party.url, itemID: itemID))
        }
        await waitForConfirmation { confirm in
            timelineController.toggleReactionToClosure = { key, _ in
                #expect(key == "👍")
                confirm()
            }
            viewModel.process(viewAction: .toggleReaction(key: "👍", itemID: itemID))
        }
        
        #expect(emojiProvider.frequentlyUsedSystemEmojis() == ["👍"])
    }
    
    @Test
    func customEmojiReactionsKeepTheirURLOutOfTheLogsWhileCustomEmojiAreOff() async {
        let (viewModel, timelineController) = await makeTimeline(isEnabled: false)
        
        // The upstream toggle logs the key.
        await waitForConfirmation { confirm in
            timelineController.toggleReactionToShortcodeClosure = { key, _, shortcode in
                #expect(key == Self.party.url)
                #expect(shortcode == nil)
                confirm()
            }
            viewModel.process(viewAction: .toggleReaction(key: Self.party.url, itemID: .event(uniqueID: .init("u"), eventOrTransactionID: .eventID("$e"))))
        }
        #expect(!timelineController.toggleReactionToCalled)
    }
    
    @Test
    func aCustomEmojiChosenInTheReactionPickerCarriesItsShortcode() async throws {
        let message = TextRoomTimelineItem(id: .event(uniqueID: .init("u"), eventOrTransactionID: .eventID("$e")), timestamp: .mock, isOutgoing: false,
                                           isEditable: false, canBeRepliedTo: true, sender: .init(id: "@bob:example.org"), content: .init(body: "Hi"))
        let timelineController = TimelineControllerMock(.init(timelineItems: [message]))
        let handler = await makeInteractionHandler(timelineController: timelineController)
        
        let deferred = deferFulfillment(handler.actions) { action in
            if case .displayEmojiPicker = action {
                true
            } else {
                false
            }
        }
        handler.displayEmojiPicker(for: message.id)
        guard case .displayEmojiPicker(_, let continuation) = try await deferred.fulfill() else { Issue.record("No picker"); return }
        
        await waitForConfirmation { confirm in
            timelineController.toggleReactionToShortcodeClosure = { key, eventOrTransactionID, shortcode in
                #expect(key == Self.party.url)
                #expect(eventOrTransactionID == .eventID("$e"))
                #expect(shortcode == ":party:")
                confirm()
            }
            continuation.yield(Self.party.url)
            continuation.finish()
        }
    }
    
    @Test
    func theTimelineSendsACustomEmojiReactionsShortcodeUnderBothKeys() async throws {
        let provider = TimelineItemProviderMock()
        provider.kind = .live
        provider.paginationState = TimelinePaginationState(backward: .idle, forward: .endReached)
        provider.membershipChangePublisher = PassthroughSubject().eraseToAnyPublisher()
        provider.updatePublisher = CurrentValueSubject(([], provider.paginationState)).eraseToAnyPublisher()
        let timelineProxy = TimelineProxyMock(.init(timelineItemProvider: provider))
        timelineProxy.toggleReactionToExtraContentJSONReturnValue = .success(())
        let controller = TimelineController(roomProxy: JoinedRoomProxyMock(.init()),
                                            timelineProxy: timelineProxy,
                                            initialFocussedEventID: nil,
                                            timelineItemFactory: RoomTimelineItemFactory(userID: "@alice:matrix.org",
                                                                                         attributedStringBuilder: AttributedStringBuilder(mentionBuilder: MentionBuilder()),
                                                                                         stateEventStringBuilder: RoomStateEventStringBuilder(userID: "@alice:matrix.org")),
                                            mediaProvider: MediaProviderMock(.init()),
                                            userSettings: .mock())
        
        await controller.toggleReaction(Self.party.url, to: .eventID("$e"), shortcode: ":party:")
        
        let arguments = try #require(timelineProxy.toggleReactionToExtraContentJSONReceivedArguments)
        #expect(arguments.reaction == Self.party.url)
        #expect(arguments.extraContentJSON.flatMap(JSONValue.init(json:)) == ImagePacks.reactionShortcodeContent(":party:"))
    }
    
    // MARK: - Reaction picker
    
    @Test
    func thePickerOffersEachPackAfterFrequentlyUsedEmoji() async throws {
        let emojiProvider = EmojiProvider(userSettings: .mock())
        emojiProvider.markEmojiAsFrequentlyUsed("😀")
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let viewModel = EmojiPickerScreenViewModel(selectedEmojis: [], emojiProvider: emojiProvider, continuation: continuation) { [packs] in packs }
        
        let deferred = deferFulfillment(viewModel.context.observe(\.viewState.categories)) { $0.contains { $0.packName != nil } && $0.count > 2 }
        try await deferred.fulfill()
        
        let categories = viewModel.context.viewState.categories
        #expect(categories.map(\.id).prefix(3) == [EmojiCategory.frequentlyUsedCategoryIdentifier, "custom:user", "people"])
        #expect(categories[1].name == "Your emoji")
        #expect(categories[1].emojis.map(\.value) == [Self.party.url, Self.parrot.url])
        
        let searched = deferFulfillment(viewModel.context.observe(\.viewState.categories)) { $0.first?.id == "custom:user" }
        viewModel.context.send(viewAction: .search(searchString: "PARROT"))
        try await searched.fulfill()
        #expect(viewModel.context.viewState.categories.first?.emojis.map(\.customEmojiName) == [":party_parrot:"])
        
        // Choosing one yields its key, the mxc URL, and doesn't make it frequently used.
        viewModel.context.send(viewAction: .emojiTapped(emoji: categories[1].emojis[0]))
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == Self.party.url)
        #expect(emojiProvider.frequentlyUsedSystemEmojis() == ["😀"])
    }
    
    // MARK: - Composer suggestions
    
    @Test
    func suggestsCustomEmojiForATypedColonCode() async throws {
        var loads = 0
        let service = makeSuggestionService { [packs] in
            loads += 1
            return packs
        }
        
        let deferred = deferFulfillment(service.suggestionsPublisher) { $0.count == 2 }
        service.processTextMessage("hi :par", selectedRange: NSRange(location: 7, length: 0))
        let suggestions = try await deferred.fulfill()
        
        #expect(suggestions.map(\.suggestionType) == [.customEmoji(Self.party), .customEmoji(Self.parrot)])
        #expect(suggestions.first?.range == NSRange(location: 3, length: 4))
        
        let exact = deferFulfillment(service.suggestionsPublisher) { $0.count == 1 }
        service.processTextMessage("hi :party:", selectedRange: NSRange(location: 10, length: 0))
        try await exact.fulfill()
        // The packs are read again only when suggestions open again.
        #expect(loads == 1)
    }
    
    @Test(arguments: [("a:par", 5), (":", 1), ("hi :par more", 12)])
    func offersNoCustomEmojiOutsideATypedCode(text: String, caret: Int) async {
        let service = makeSuggestionService { [packs] in packs }
        // The suggestions are live: a typed code is offered its emoji.
        #expect(await settledSuggestions(service) { service.processTextMessage(":par", selectedRange: NSRange(location: 4, length: 0)) }.count == 2)
        #expect(await settledSuggestions(service) { service.processTextMessage(text, selectedRange: NSRange(location: caret, length: 0)) }.isEmpty)
    }
    
    @Test
    func offersNoCustomEmojiWhileTheyAreOff() async {
        let service = makeSuggestionService(nil)
        // The suggestions are live: a mention is offered its member.
        #expect(await !settledSuggestions(service) { service.processTextMessage("@ali", selectedRange: NSRange(location: 4, length: 0)) }.isEmpty)
        #expect(await settledSuggestions(service) { service.processTextMessage(":par", selectedRange: NSRange(location: 4, length: 0)) }.isEmpty)
        #expect(await settledSuggestions(service) { service.setSuggestionTrigger(.init(type: .customEmoji, text: "par", range: .init())) }.isEmpty)
    }
    
    @Test
    func choosingASuggestionInsertsItsShortcode() {
        let viewModel = makeComposer()
        viewModel.context.composerFormattingEnabled = false
        viewModel.context.plainComposerText = NSAttributedString(string: "hi :par")
        viewModel.state.bindings.selectedRange = NSRange(location: 7, length: 0)
        
        viewModel.process(viewAction: .selectedSuggestion(.init(suggestionType: .customEmoji(Self.party), range: NSRange(location: 3, length: 4), rawSuggestionText: "par")))
        
        #expect(viewModel.context.plainComposerText.string == "hi :party: ")
        #expect(viewModel.state.bindings.selectedRange == NSRange(location: 11, length: 0))
    }
    
    @Test
    func choosingASuggestionInTheRichTextEditorInsertsItsShortcode() async throws {
        let wysiwygViewModel = WysiwygComposerViewModel()
        let viewModel = makeComposer(wysiwygViewModel: wysiwygViewModel)
        viewModel.context.composerFormattingEnabled = true
        
        let deferred = deferFulfillment(wysiwygViewModel.$suggestionPattern) { $0?.key == .colon }
        wysiwygViewModel.setMarkdownContent("hi :par")
        try await deferred.fulfill()
        #expect(wysiwygViewModel.suggestionPattern?.toElementPattern == SuggestionTrigger(type: .customEmoji, text: "par", range: NSRange(location: 3, length: 4)))
        
        viewModel.process(viewAction: .selectedSuggestion(.init(suggestionType: .customEmoji(Self.party), range: .init(), rawSuggestionText: "par")))
        
        #expect(wysiwygViewModel.content.markdown.trimmingCharacters(in: .whitespaces) == "hi :party:")
    }
    
    // MARK: - Helpers
    
    private func formattedBody(_ markdown: String) -> String? {
        CustomEmojiMessages.formattedBody(markdown: markdown, html: nil, packs: packs)
    }
    
    /// A timeline whose room's packs were read, as when it opens, unless `readsPacks` is false.
    private func makeTimeline(isEnabled: Bool = true,
                              userSession: UserSessionMock? = nil,
                              readsPacks: Bool = true,
                              timelineKind: TimelineKind = .live,
                              timelineItems: [RoomTimelineItemProtocol] = [],
                              emojiProvider: EmojiProviderProtocol = EmojiProvider(userSettings: .mock())) async -> (TimelineViewModel, TimelineControllerMock) {
        let userSettings = UserSettings.mock()
        userSettings.app.matchaWorkspacesEnabled = isEnabled
        let roomProxy = JoinedRoomProxyMock(.init(id: readsPacks ? "!room:x" : "!cold:x", name: "General"))
        let timelineController = TimelineControllerMock(.init(roomProxy: roomProxy, timelineKind: timelineKind, timelineItems: timelineItems))
        let userSession = userSession ?? UserSessionMock(.init(clientProxy: makeClientProxy(), userSettings: userSettings))
        if readsPacks {
            _ = await userSession.matchaService.customEmojiPacks.packs(roomID: roomProxy.id)
        }
        let viewModel = TimelineViewModel(roomProxy: roomProxy,
                                          timelineController: timelineController,
                                          userSession: userSession,
                                          mediaPlayerProvider: MediaPlayerProviderMock(),
                                          userIndicatorController: UserIndicatorControllerMock(),
                                          appMediator: AppMediatorMock(.init()),
                                          analyticsService: AnalyticsServiceMock(.init()),
                                          emojiProvider: emojiProvider,
                                          linkMetadataProvider: LinkMetadataProvider(),
                                          timelineControllerFactory: TimelineControllerFactoryMock(.init()))
        return (viewModel, timelineController)
    }
    
    /// A timeline's interaction handler, its room's packs read as the reaction picker reads them when it opens.
    private func makeInteractionHandler(timelineController: TimelineControllerMock) async -> TimelineInteractionHandler {
        let roomProxy = JoinedRoomProxyMock(.init(name: "General"))
        let userSession = UserSessionMock(.init(clientProxy: makeClientProxy()))
        _ = await userSession.matchaService.customEmojiPacks.refresh(roomID: roomProxy.id)
        return TimelineInteractionHandler(roomProxy: roomProxy,
                                          timelineController: timelineController,
                                          userSession: userSession,
                                          mediaPlayerProvider: MediaPlayerProviderMock(),
                                          voiceMessageRecorder: VoiceMessageRecorderMock(),
                                          userIndicatorController: UserIndicatorControllerMock(),
                                          appMediator: AppMediatorMock(.init()),
                                          analyticsService: AnalyticsServiceMock(.init()),
                                          emojiProvider: EmojiProvider(userSettings: .mock()),
                                          linkMetadataProvider: LinkMetadataProvider(),
                                          timelineControllerFactory: TimelineControllerFactoryMock(.init()))
    }
    
    /// A session whose personal pack has `:party:`.
    private func makeClientProxy() -> ClientProxyMock {
        let clientProxy = ClientProxyMock(.init())
        clientProxy.accountDataJSONTypeClosure = { type in
            .success(type == ImagePacks.userEmotesEventType ? #"{"images": {"party": {"url": "mxc://example.org/party"}}}"# : nil)
        }
        clientProxy.stateEventsJSONRoomIDTypeReturnValue = .success([:])
        clientProxy.fetchStateEventContentJSONRoomIDTypeStateKeyReturnValue = .success(nil)
        return clientProxy
    }
    
    /// What the timeline was asked to send for a composer message.
    private func sentHTML(of message: String,
                          mode: ComposerMode,
                          _ viewModel: TimelineViewModel,
                          _ timelineController: TimelineControllerMock) async -> (message: String, html: String?) {
        var sent: (message: String, html: String?) = ("", nil)
        await waitForConfirmation { confirm in
            timelineController.sendMessageHtmlInReplyToEventIDIntentionalMentionsClosure = { message, html, _, _ in
                sent = (message, html)
                confirm()
            }
            viewModel.process(composerAction: .sendMessage(plain: message, html: nil, mode: mode, intentionalMentions: .empty))
        }
        return sent
    }
    
    /// What the timeline was asked to send within a second, without waiting for anything.
    private func sentPromptly(_ message: String,
                              _ viewModel: TimelineViewModel,
                              _ timelineController: TimelineControllerMock) async throws -> (message: String, html: String?)? {
        viewModel.process(composerAction: .sendMessage(plain: message, html: nil, mode: .default, intentionalMentions: .empty))
        for _ in 0..<10 where !timelineController.sendMessageHtmlInReplyToEventIDIntentionalMentionsCalled {
            try await Task.sleep(for: .milliseconds(100))
        }
        return timelineController.sendMessageHtmlInReplyToEventIDIntentionalMentionsReceivedArguments.map { ($0.message, $0.html) }
    }
    
    private func makeSuggestionService(_ loadCustomEmojiPacks: CustomEmojiPacksLoader?) -> CompletionSuggestionService {
        CompletionSuggestionService(roomProxy: JoinedRoomProxyMock(.init(name: "General")),
                                    roomListPublisher: Just([]).eraseToAnyPublisher(),
                                    loadCustomEmojiPacks: loadCustomEmojiPacks)
    }
    
    /// The suggestions once the service has settled after `change`: it debounces triggers by half a second.
    private func settledSuggestions(_ service: CompletionSuggestionService, after change: () -> Void) async -> [SuggestionItem] {
        var suggestions = [SuggestionItem]()
        let cancellable = service.suggestionsPublisher.sink { suggestions = $0 }
        change()
        try? await Task.sleep(for: .milliseconds(800))
        cancellable.cancel()
        return suggestions
    }
    
    private func makeComposer(wysiwygViewModel: WysiwygComposerViewModel = WysiwygComposerViewModel()) -> ComposerToolbarViewModel {
        ComposerToolbarViewModel(roomProxy: JoinedRoomProxyMock(.init()),
                                 wysiwygViewModel: wysiwygViewModel,
                                 completionSuggestionService: CompletionSuggestionServiceMock(configuration: .init()),
                                 mediaProvider: MediaProviderMock(.init()),
                                 mentionDisplayHelper: ComposerMentionDisplayHelper.mock,
                                 userSettings: .mock(),
                                 analyticsService: AnalyticsServiceMock(.init()),
                                 composerDraftService: ComposerDraftServiceMock(.init()))
    }
}
