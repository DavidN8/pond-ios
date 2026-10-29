//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import MatchaProtocol
import SwiftUI

/// An inline custom emoji (MSC2545) in a message. It reads as its alt text until its image shows, then takes a square of its
/// line's height. `PillAttachmentViewProvider` draws it, as the attachment shares the pills' file type.
final nonisolated class EmoticonTextAttachment: NSTextAttachment {
    let url: URL
    let altText: String
    /// Set once the image shows. Attachments are shared by every text built from the same cached HTML, so one load serves all.
    var isImageShown = false
    /// The texts that laid the attachment out at its alt text's size, which make room for the image once it shows.
    let altTextLayouts = NSHashTable<NSTextContainer>.weakObjects()
    /// The font of the attachment's line when last laid out: the body font, or the big emoji font.
    private(set) var lineFont = UIFont.preferredFont(forTextStyle: .body)
    
    init(url: URL, altText: String) {
        self.url = url
        self.altText = altText
        super.init(data: nil, ofType: InfoPlistReader.main.pillsUTType)
        accessibilityLabel = altText
    }
    
    required init?(coder: NSCoder) {
        nil
    }
    
    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect, glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        if let font = textContainer?.layoutManager?.textStorage?.attribute(.font, at: charIndex, effectiveRange: nil) as? UIFont {
            lineFont = font
        }
        if !isImageShown, let textContainer {
            altTextLayouts.add(textContainer)
        }
        let size = isImageShown ? CGSize(width: lineFont.lineHeight, height: lineFont.lineHeight) : (altText as NSString).size(withAttributes: [.font: lineFont])
        return CGRect(x: 0, y: lineFont.descender, width: min(ceil(size.width), lineFrag.width), height: ceil(size.height))
    }
}

extension EmoticonTextAttachment {
    /// The view that draws the emoji in `textView`, which lays its text out again once the image shows.
    func makeView(in textView: PillAttachmentViewProviderDelegate?) -> UIView {
        let rootView = EmoticonAttachmentView(url: url,
                                              altText: altText,
                                              font: lineFont,
                                              mediaProvider: textView?.timelineContext?.mediaProvider) { [weak self, weak textView] in
            guard let self else { return }
            isImageShown = true
            guard let textView = textView as? MessageTextView else { return }
            // Every text showing this attachment that laid it out at its alt text's size, not just the first.
            let needsLayout = altTextLayouts.contains(textView.textContainer)
            altTextLayouts.remove(textView.textContainer)
            EmoticonRelayout.schedule(textView, needsLayout: needsLayout)
        }
        let view = UIHostingController(rootView: rootView).view ?? UIView()
        view.backgroundColor = .clear
        // Taps go to the message, as with pills.
        view.isUserInteractionEnabled = false
        textView?.registerPillView(view)
        return view
    }
}

nonisolated extension MentionBuilder {
    func handleEmoticon(for attributedString: NSMutableAttributedString, in range: NSRange, url: URL, altText: String) {
        let emoticon = NSMutableAttributedString(attachment: EmoticonTextAttachment(url: url, altText: altText))
        emoticon.addAttribute(NSAttributedString.Key(EmoticonAttribute.name), value: altText, range: NSRange(location: 0, length: emoticon.length))
        attributedString.replaceCharacters(in: range, with: emoticon)
    }
}

/// Draws each text whose custom emoji showed again, and lays it out again when one of them took its alt text's size, once for
/// all those that showed together: a message of many emoji would otherwise be laid out, and its text copied, once per emoji.
/// The drawing is needed every time: TextKit 1 leaves an attachment's view hidden until its text is drawn again after the view
/// loaded (pills draw their text again for the same reason), which left most emoji of a message blank.
private enum EmoticonRelayout {
    private static let pending = NSHashTable<MessageTextView>.weakObjects()
    private static let pendingLayout = NSHashTable<MessageTextView>.weakObjects()
    
    static func schedule(_ textView: MessageTextView, needsLayout: Bool) {
        if needsLayout {
            pendingLayout.add(textView)
        }
        guard !pending.contains(textView) else { return }
        pending.add(textView)
        DispatchQueue.main.async { [weak textView] in
            guard let textView else { return }
            pending.remove(textView)
            let range = NSRange(location: 0, length: textView.textStorage.length)
            guard pendingLayout.contains(textView) else {
                return textView.layoutManager.invalidateDisplay(forCharacterRange: range)
            }
            pendingLayout.remove(textView)
            textView.layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            textView.layoutManager.invalidateDisplay(forCharacterRange: range)
            // Clears the text's cached sizes.
            textView.updateClosure?()
        }
    }
}

/// ponytail: the full image through the media cache, so an animated GIF shows its first frame. Animating would need its data
/// sniffed and an animated image view, as `LoadableImage` only animates sources it is told are GIFs.
private struct EmoticonAttachmentView: View {
    let url: URL
    let altText: String
    let font: UIFont
    let mediaProvider: MediaProviderProtocol?
    let onImageShown: () -> Void
    
    var body: some View {
        if let mediaProvider {
            LoadableImage(url: url, mediaProvider: mediaProvider) { image in
                image
                    .scaledToFit()
                    .onAppear(perform: onImageShown)
            } placeholder: {
                altTextView
            }
        } else {
            altTextView
        }
    }
    
    private var altTextView: some View {
        Text(altText)
            .font(Font(font))
            .foregroundStyle(.compound.textPrimary)
            .lineLimit(1)
            // Fits the square of an emoji that showed before and was dropped from the cache since.
            .minimumScaleFactor(0.1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Accessibility and plain text

extension NSMutableAttributedString {
    /// Replaces each custom emoji with its alt text, for VoiceOver and reply quotes.
    func replaceEmoticonsWithAltText() {
        enumerateAttribute(.attachment, in: NSRange(location: 0, length: length), options: .reverse) { value, range, _ in
            guard let emoticon = value as? EmoticonTextAttachment else { return }
            var attributes = attributes(at: range.location, effectiveRange: nil)
            attributes[.attachment] = nil
            attributes[NSAttributedString.Key(EmoticonAttribute.name)] = nil
            replaceCharacters(in: range, with: NSAttributedString(string: emoticon.altText, attributes: attributes))
        }
    }
}

extension AttributedString {
    /// The string with each custom emoji replaced by its alt text.
    var replacingEmoticonsWithAltText: AttributedString {
        // Most messages have none to replace, mention pills being attachments too.
        guard runs[EmoticonAttribute.self].contains(where: { $0.0 != nil }),
              let string = try? NSMutableAttributedString(self, including: \.elementX) else {
            return self
        }
        string.replaceEmoticonsWithAltText()
        return (try? AttributedString(string, including: \.elementX)) ?? self
    }
}

// MARK: - Previews

struct CustomEmoji_Previews: PreviewProvider, TestablePreview {
    private static let builder = AttributedStringBuilder(cacheKey: "CustomEmoji_Previews", mentionBuilder: MentionBuilder())
    private static let wave = ImagePacks.emoticonHTML(url: "mxc://example.org/wave", shortcode: "wave")
    private static let party = AggregatedReaction(accountOwnerID: "@alice:matrix.org",
                                                  key: "mxc://example.org/party",
                                                  senders: [ReactionSender(id: "@bob:matrix.org", timestamp: .mock)])
    
    static var previews: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let message = builder.fromHTML("Hello \(wave) everyone") {
                FormattedBodyText(attributedString: message)
            }
            if let emojiOnly = builder.fromHTML("\(wave) 😀") {
                FormattedBodyText(attributedString: emojiOnly, boostFontSize: true)
            }
            TimelineReactionButton(reaction: party) { _ in } showReactionSummary: { _ in }
        }
        .padding()
        .environment(\.timelineContext, TimelineViewModel.mock.context)
    }
}
