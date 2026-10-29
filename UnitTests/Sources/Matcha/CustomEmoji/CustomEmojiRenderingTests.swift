//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import MatchaProtocol
import MatrixRustSDK
import SwiftUI
import Testing

@MainActor
struct CustomEmojiRenderingTests {
    private let wave = ImagePacks.emoticonHTML(url: "mxc://example.org/wave", shortcode: "wave")
    
    // MARK: - Plain text
    
    @Test
    func plainTextReadsACustomEmojiAsItsAltText() throws {
        #expect(try plainText("Hi \(wave) there") == "Hi :wave: there")
        #expect(try plainText(#"<img data-mx-emoticon src="mxc://example.org/a" title=":title:">"#) == ":title:")
        #expect(try plainText(#"<img data-mx-emoticon src="mxc://example.org/a">"#) == "[img]")
    }
    
    @Test
    func otherImagesKeepTodaysText() throws {
        #expect(try plainText(#"<img data-mx-emoticon src="https://example.org/a.png" alt=":a:">"#) == "[img: :a:]")
        #expect(try plainText(#"<img src="mxc://example.org/a" alt="photo">"#) == "[img: photo]")
        #expect(try plainText(#"<img src="mxc://example.org/a" alt=":a photo:">"#) == "[img: :a photo:]")
        #expect(try plainText(#"<img src="https://example.org/a.png" alt=":a:">"#) == "[img: :a:]")
    }
    
    /// The SDK's timeline sanitizes formatted bodies, which drops `data-mx-emoticon`: as sent, the timeline, the room list and
    /// edits showed `[img: :wave:]` and lost the image.
    @Test
    func aCustomEmojiStillShowsOnceTheSDKDroppedItsMarker() throws {
        let sanitizedWave = sanitized(wave)
        #expect(!sanitizedWave.contains("data-mx-emoticon"))
        
        #expect(try plainText("Hi \(sanitizedWave) there") == "Hi :wave: there")
        let builder = AttributedStringBuilder(cacheKey: UUID().uuidString, mentionBuilder: MentionBuilder())
        let string = try NSAttributedString(#require(builder.fromHTML("Hi \(sanitizedWave)")), including: \.elementX)
        #expect((string.attribute(.attachment, at: 3, effectiveRange: nil) as? EmoticonTextAttachment)?.altText == ":wave:")
        #expect(Emoticons.isEmoticonsOnly(html: "\(sanitizedWave) \(sanitized(ImagePacks.emoticonHTML(url: "mxc://x/b", shortcode: "b")))"))
    }
    
    @Test
    func roomListAndNotificationsReadACustomEmojiAsItsAltText() {
        let builder = RoomMessageEventStringBuilder(attributedStringBuilder: AttributedStringBuilder(cacheKey: UUID().uuidString, mentionBuilder: PlainMentionBuilder()),
                                                    style: .senderPrefixed)
        let message = MessageType.text(content: .init(body: "Hi :wave:", formatted: .init(format: .html, body: "Hi \(wave)")))
        
        #expect(builder.buildAttributedString(for: message, senderDisplayName: "Bob", isOutgoing: false).string == "Bob: Hi :wave:")
    }
    
    // MARK: - Timeline
    
    @Test
    func theTimelineDrawsACustomEmojiAsAnAttachment() throws {
        let builder = AttributedStringBuilder(cacheKey: UUID().uuidString, mentionBuilder: MentionBuilder())
        let attributedString = try #require(builder.fromHTML("Hi <b>\(wave)</b> there"))
        
        #expect(String(attributedString.characters) == "Hi \u{FFFC} there")
        let string = try NSAttributedString(attributedString, including: \.elementX)
        let attachment = try #require(string.attribute(.attachment, at: 3, effectiveRange: nil) as? EmoticonTextAttachment)
        #expect(attachment.url == URL(string: "mxc://example.org/wave"))
        #expect(attachment.altText == ":wave:")
        // VoiceOver and reply quotes read it as its alt text.
        #expect(String(attributedString.replacingEmoticonsWithAltText.characters) == "Hi :wave: there")
        #expect(TimelineViewModel.mock().context.viewState.buildMessagePreview(formattedBody: attributedString, plainBody: "") == "Hi :wave: there")
    }
    
    @Test
    func aCustomEmojiTakesItsAltTextsWidthThenASquareOfItsLinesHeight() throws {
        let font = UIFont.preferredFont(forTextStyle: .body)
        let attachment = try EmoticonTextAttachment(url: #require(URL(string: "mxc://example.org/wave")), altText: ":wave:")
        // The layout manager holds its text storage weakly, so the test keeps it.
        let (textStorage, container) = layOut(attachment, font: font)
        let altTextWidth = ceil((":wave:" as NSString).size(withAttributes: [.font: font]).width)
        
        #expect(bounds(of: attachment, in: container).width == altTextWidth)
        attachment.isImageShown = true
        #expect(bounds(of: attachment, in: container) == CGRect(x: 0, y: font.descender, width: ceil(font.lineHeight), height: ceil(font.lineHeight)))
        
        // A message of only emoji is drawn big, and its custom emoji with it.
        let bigFont = UIFont.systemFont(ofSize: 48)
        textStorage.addAttribute(.font, value: bigFont, range: NSRange(location: 0, length: textStorage.length))
        #expect(bounds(of: attachment, in: container).height == ceil(bigFont.lineHeight))
    }
    
    @Test(arguments: [("<img data-mx-emoticon src=\"mxc://x/a\" alt=\":a:\">", true),
                      ("<img data-mx-emoticon src=\"mxc://x/a\" alt=\":a:\"> 😀 <br><img data-mx-emoticon src=\"mxc://x/b\" alt=\":b:\">&nbsp;1️⃣", true),
                      ("<img data-mx-emoticon src=\"mxc://x/a\" alt=\":a:\"> hi", false),
                      ("<b><img data-mx-emoticon src=\"mxc://x/a\" alt=\":a:\"></b>", false),
                      ("<img data-mx-emoticon src=\"mxc://x/a\" alt=\":a:\"><img src=\"mxc://x/p\" alt=\"photo\">", false),
                      ("<img data-mx-emoticon src=\"https://x/a.png\" alt=\":a:\">", false),
                      ("😀", false),
                      ("", false)])
    func onlyCustomEmojiAndEmojiAreDrawnBig(html: String, isBig: Bool) {
        #expect(Emoticons.isEmoticonsOnly(html: html) == isBig)
    }
    
    @Test
    func theTimelineDrawsAMessageOfOnlyCustomEmojiBig() throws {
        let factory = RoomTimelineItemFactory(userID: "@alice:matrix.org",
                                              attributedStringBuilder: AttributedStringBuilder(cacheKey: UUID().uuidString, mentionBuilder: MentionBuilder()),
                                              stateEventStringBuilder: RoomStateEventStringBuilder(userID: "@alice:matrix.org"))
        // As the SDK hands it over, without `data-mx-emoticon`.
        let messageType = MessageType.text(content: .init(body: ":wave:", formatted: .init(format: .html, body: sanitized(wave))))
        let content = TimelineItemContent.msgLike(content: .init(kind: .message(content: .init(msgType: messageType, body: ":wave:", isEdited: false, mentions: nil)),
                                                                 inReplyTo: nil,
                                                                 threadRoot: nil,
                                                                 threadSummary: nil))
        let proxy = EventTimelineItemProxy(item: EventTimelineItem(configuration: .init(sender: "@bob:matrix.org", content: content)), uniqueID: .init("0"))
        
        // The SDK finds no emoji in the body, `:wave:`.
        let item = try #require(factory.buildTimelineItem(for: proxy, isDM: false) as? TextRoomTimelineItem)
        #expect(item.shouldBoost)
    }
    
    @Test
    func aMessageTextViewDrawsTheAltTextUntilTheImageShows() async throws {
        let font = UIFont.preferredFont(forTextStyle: .body)
        let altTextSize = (":wave:" as NSString).size(withAttributes: [.font: font])
        
        // Without a media provider nothing loads, so the alt text stays.
        let (altTextView, altTextWindow) = try show("Hi \(wave) there", font: font, timelineContext: nil)
        try await waitForEmoticonView(in: altTextView) { $0.size == CGSize(width: ceil(altTextSize.width), height: ceil(altTextSize.height)) }
        
        // The image takes a square of the line's height once it shows.
        let (imageView, imageWindow) = try show("Hi \(wave) there", font: font, timelineContext: TimelineViewModel.mock.context)
        try await waitForEmoticonView(in: imageView) { $0.size == CGSize(width: ceil(font.lineHeight), height: ceil(font.lineHeight)) }
        withExtendedLifetime((altTextWindow, imageWindow)) { }
    }
    
    @Test
    func everyTextShowingTheSameCachedEmojiMakesRoomForItsImage() async throws {
        let font = UIFont.preferredFont(forTextStyle: .body)
        let square = CGSize(width: ceil(font.lineHeight), height: ceil(font.lineHeight))
        // Messages with the same HTML share the builder's cached string, and so its attachment, both laid out before it loads.
        let builder = AttributedStringBuilder(cacheKey: UUID().uuidString, mentionBuilder: MentionBuilder())
        let (first, firstWindow) = try show("Hi \(wave) there", font: font, timelineContext: TimelineViewModel.mock.context, builder: builder)
        let (second, secondWindow) = try show("Hi \(wave) there", font: font, timelineContext: TimelineViewModel.mock.context, builder: builder)
        
        try await waitForEmoticonView(in: first) { $0.size == square }
        try await waitForEmoticonView(in: second) { $0.size == square }
        withExtendedLifetime((firstWindow, secondWindow)) { }
    }
    
    // MARK: - Reactions
    
    @Test
    func customEmojiReactionsReadAsTheirShortcodeFromTheRoomsPacks() {
        let packs = [EmojiPack(id: "user", kind: .user, name: "Your emoji", emojis: [CustomEmoji(shortcode: "party", url: "mxc://example.org/party")])]
        let labels = CustomEmojiReactions.labels(for: ["mxc://example.org/party", "mxc://example.org/unknown"], in: packs)
        
        #expect(labels == ["mxc://example.org/party": ":party:", "mxc://example.org/unknown": UntranslatedL10n.a11yMatchaCustomReaction])
        #expect(reaction("mxc://example.org/party").spokenKey(labels: labels) == ":party:")
        #expect(reaction("mxc://example.org/other").spokenKey(labels: labels) == UntranslatedL10n.a11yMatchaCustomReaction)
        #expect(reaction("👍").spokenKey(labels: labels) == "👍")
    }
    
    @Test
    func theTimelineLooksUpItsCustomEmojiReactionsInTheRoomsPacks() async throws {
        let clientProxy = ClientProxyMock(.init())
        clientProxy.accountDataJSONTypeClosure = { type in
            .success(type == ImagePacks.userEmotesEventType ? #"{"images": {"party": {"url": "mxc://example.org/party"}}}"# : nil)
        }
        clientProxy.stateEventsJSONRoomIDTypeReturnValue = .success([:])
        clientProxy.fetchStateEventContentJSONRoomIDTypeStateKeyReturnValue = .success(nil)
        let roomProxy = JoinedRoomProxyMock(.init(name: "General"))
        let message = TextRoomTimelineItem(id: .randomEvent, timestamp: .mock, isOutgoing: false, isEditable: false, canBeRepliedTo: true,
                                           sender: .init(id: "@bob:example.org"), content: .init(body: "Hi"),
                                           properties: RoomTimelineItemProperties(reactions: [reaction("mxc://example.org/party"), reaction("👍")]))
        let viewModel = TimelineViewModel(roomProxy: roomProxy,
                                          timelineController: TimelineControllerMock(.init(roomProxy: roomProxy, timelineItems: [message])),
                                          userSession: UserSessionMock(.init(clientProxy: clientProxy)),
                                          mediaPlayerProvider: MediaPlayerProviderMock(),
                                          userIndicatorController: UserIndicatorControllerMock(),
                                          appMediator: AppMediatorMock(.init()),
                                          analyticsService: AnalyticsServiceMock(.init()),
                                          emojiProvider: EmojiProvider(userSettings: .mock()),
                                          linkMetadataProvider: LinkMetadataProvider(),
                                          timelineControllerFactory: TimelineControllerFactoryMock(.init()))
        
        let deferred = deferFulfillment(viewModel.context.$viewState) { !$0.customEmojiReactionLabels.isEmpty }
        try await deferred.fulfill()
        
        #expect(viewModel.context.viewState.customEmojiReactionLabels == ["mxc://example.org/party": ":party:"])
    }
    
    // MARK: - Helpers
    
    /// A custom emoji as the SDK's sanitizer leaves it: ruma-html keeps only width, height, alt, title and src on an image.
    private func sanitized(_ html: String) -> String {
        html.replacingOccurrences(of: "data-mx-emoticon ", with: "")
    }
    
    private func plainText(_ html: String) throws -> String {
        let builder = AttributedStringBuilder(cacheKey: UUID().uuidString, mentionBuilder: PlainMentionBuilder())
        return try String(#require(builder.fromHTML(html)).characters)
    }
    
    /// "Hi " and the attachment in a text container, as a message text view lays it out.
    private func layOut(_ attachment: EmoticonTextAttachment, font: UIFont) -> (NSTextStorage, NSTextContainer) {
        let text = NSMutableAttributedString(string: "Hi ", attributes: [.font: font])
        text.append(NSAttributedString(attachment: attachment))
        text.addAttribute(.font, value: font, range: NSRange(location: 0, length: text.length))
        let textStorage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 300, height: 1000))
        layoutManager.addTextContainer(container)
        textStorage.addLayoutManager(layoutManager)
        return (textStorage, container)
    }
    
    private func bounds(of attachment: EmoticonTextAttachment, in container: NSTextContainer) -> CGRect {
        attachment.attachmentBounds(for: container, proposedLineFragment: CGRect(x: 0, y: 0, width: 300, height: 30), glyphPosition: .zero, characterIndex: 3)
    }
    
    @Test
    func aBubbleKeepsOneReservedSpaceForItsTimestampOnceTheImageShows() async throws {
        NSTextAttachment.registerViewProviderClass(PillAttachmentViewProvider.self, forFileType: InfoPlistReader.main.pillsUTType)
        let builder = AttributedStringBuilder(cacheKey: UUID().uuidString, mentionBuilder: MentionBuilder())
        let attributedString = try #require(builder.fromHTML("Hi \(wave) there"))
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: FormattedBodyText(attributedString: attributedString, trailingReservedSize: CGSize(width: 40, height: 10))
            .environment(\.timelineContext, TimelineViewModel.mock.context))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        
        var attachments = [String]()
        for _ in 0..<20 where attachments != ["EmoticonTextAttachment", "TransparentTextAttachment"] || !hasShownImage(attributedString) {
            try await Task.sleep(for: .milliseconds(100))
            attachments = allSubviews(of: controller.view).compactMap { $0 as? MessageTextView }.flatMap(attachmentTypes)
        }
        
        #expect(hasShownImage(attributedString))
        // Updating the text for the emoji's new size used to append the timestamp's space a second time.
        try await Task.sleep(for: .milliseconds(300))
        #expect(allSubviews(of: controller.view).compactMap { $0 as? MessageTextView }.flatMap(attachmentTypes) == ["EmoticonTextAttachment", "TransparentTextAttachment"])
    }
    
    private func hasShownImage(_ attributedString: AttributedString) -> Bool {
        guard let string = try? NSAttributedString(attributedString, including: \.elementX) else { return false }
        return (string.attribute(.attachment, at: 3, effectiveRange: nil) as? EmoticonTextAttachment)?.isImageShown == true
    }
    
    private func attachmentTypes(in textView: MessageTextView) -> [String] {
        var types = [String]()
        textView.attributedText.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textView.attributedText.length)) { value, _, _ in
            if let value {
                types.append(String(describing: type(of: value)))
            }
        }
        return types
    }
    
    /// A message text view showing `html` on screen, as the timeline does.
    private func show(_ html: String,
                      font: UIFont,
                      timelineContext: TimelineViewModel.Context?,
                      builder: AttributedStringBuilder = AttributedStringBuilder(cacheKey: UUID().uuidString, mentionBuilder: MentionBuilder())) throws -> (MessageTextView, UIWindow) {
        NSTextAttachment.registerViewProviderClass(PillAttachmentViewProvider.self, forFileType: InfoPlistReader.main.pillsUTType)
        let text = try NSMutableAttributedString(#require(builder.fromHTML(html)), including: \.elementX)
        text.addAttribute(.font, value: font, range: NSRange(location: 0, length: text.length))
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let textView = MessageTextView(usingTextLayoutManager: false)
        textView.timelineContext = timelineContext
        textView.frame = CGRect(x: 0, y: 0, width: 300, height: 100)
        window.addSubview(textView)
        window.makeKeyAndVisible()
        textView.attributedText = text
        return (textView, window)
    }
    
    /// Waits up to 2 s for the text view to draw one custom emoji whose frame passes `check`.
    private func waitForEmoticonView(in textView: MessageTextView, check: (CGRect) -> Bool) async throws {
        var frames = [CGRect]()
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(100))
            frames = allSubviews(of: textView).filter { String(describing: type(of: $0)).contains("EmoticonAttachmentView") }.map(\.frame)
            if frames.count == 1, frames.allSatisfy(check) {
                return
            }
        }
        Issue.record("The custom emoji views had the frames \(frames)")
    }
    
    private func allSubviews(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(allSubviews)
    }
    
    private func reaction(_ key: String) -> AggregatedReaction {
        AggregatedReaction(accountOwnerID: "@alice:example.org", key: key, senders: [ReactionSender(id: "@bob:example.org", timestamp: .mock)])
    }
}
