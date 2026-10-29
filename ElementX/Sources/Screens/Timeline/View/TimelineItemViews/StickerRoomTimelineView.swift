//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import SwiftUI

struct StickerRoomTimelineView: View {
    @Environment(\.timelineContext) private var context
    let timelineItem: StickerRoomTimelineItem
    
    @ScaledMetric private var stickerSize = 160 // matcha: chat-app sized, not as wide as a photo
    
    var body: some View {
        TimelineStyler(timelineItem: timelineItem) {
            ContentScanningView(contentScannerService: context?.contentScannerService,
                                mediaSource: timelineItem.imageInfo.source) {
                LoadableImage(mediaSource: timelineItem.imageInfo.source,
                              mediaType: .timelineItem(uniqueID: timelineItem.id.uniqueID),
                              blurhash: timelineItem.blurhash,
                              size: nil, // matcha: the original keeps its transparency; the server's thumbnail is a JPEG
                              mediaProvider: context?.mediaProvider) {
                    placeholder
                }
                .aspectRatio(timelineItem.imageInfo.aspectRatio, contentMode: .fit) // matcha
                .frame(maxWidth: stickerSize, maxHeight: stickerSize) // matcha
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(L10n.commonSticker), \(timelineItem.body)")
                .onTapGesture {
                    context?.send(viewAction: .mediaTapped(itemID: timelineItem.id))
                }
            } scanningContent: {
                placeholder
                    .overlay { ProgressView() }
                    .aspectRatio(timelineItem.imageInfo.aspectRatio, contentMode: .fit) // matcha
                    .frame(maxWidth: stickerSize, maxHeight: stickerSize) // matcha
            } unsafeContent: { failure in
                ContentScanningFailureView(failure: failure)
            }
        }
    }
    
    private var placeholder: some View {
        Rectangle()
            .foregroundColor(timelineItem.isOutgoing ? MatchaColors.bubbleOutgoing : MatchaColors.bubbleIncoming) // matcha
            .opacity(0.3)
    }
}

struct StickerRoomTimelineView_Previews: PreviewProvider, TestablePreview {
    static let viewModel = TimelineViewModel.mock
    static let scanningViewModel = TimelineViewModel.mock(contentScannerService: ContentScannerServiceMock(.init(scanResult: nil)))
    static let unsafeViewModel = TimelineViewModel.mock(contentScannerService: ContentScannerServiceMock(.init(scanResult: false)))
    
    static var previews: some View {
        VStack(spacing: 20.0) {
            StickerRoomTimelineView(timelineItem: makeTimelineItem(body: "Some image"))
            
            StickerRoomTimelineView(timelineItem: makeTimelineItem(body: "Blurhashed image",
                                                                   blurhash: "L%KUc%kqS$RP?Ks,WEf8OlrqaekW"))
        }
        .environmentObject(viewModel.context)
        .environment(\.timelineContext, viewModel.context)
        
        VStack(spacing: 20.0) {
            StickerRoomTimelineView(timelineItem: makeTimelineItem(body: "Scanning image"))
                .environmentObject(scanningViewModel.context)
                .environment(\.timelineContext, scanningViewModel.context)
            
            StickerRoomTimelineView(timelineItem: makeTimelineItem(body: "Unsafe image"))
                .environmentObject(unsafeViewModel.context)
                .environment(\.timelineContext, unsafeViewModel.context)
        }
        .environmentObject(viewModel.context)
        .previewDisplayName("Content Scanner")
    }
    
    private static func makeTimelineItem(body: String, blurhash: String? = nil) -> StickerRoomTimelineItem {
        StickerRoomTimelineItem(id: .randomEvent,
                                body: body,
                                timestamp: .mock,
                                isOutgoing: false,
                                isEditable: false,
                                canBeRepliedTo: true,
                                sender: .init(id: "Bob"),
                                imageInfo: .mockImage,
                                blurhash: blurhash)
    }
}
