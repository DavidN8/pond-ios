//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

extension View {
    /// The tail on the top outer corner of the first bubble of a run and the 1 pt light-mode shadow, as Android's `MessageEventBubble`.
    /// A bubble without a fill (media) has neither.
    func matchaBubbleTail(isOutgoing: Bool, color: Color?) -> some View {
        modifier(MatchaBubbleTailModifier(isOutgoing: isOutgoing, color: color))
    }
}

private struct MatchaBubbleTailModifier: ViewModifier {
    @Environment(\.timelineGroupStyle) private var timelineGroupStyle
    
    let isOutgoing: Bool
    let color: Color?
    
    /// The bubble's corner radius, which the tail's body covers.
    private let cornerRadius: CGFloat = 12
    /// How far the tip sticks out past the bubble (Android's `BUBBLE_TAIL_WIDTH`).
    private let tipWidth: CGFloat = 8
    
    func body(content: Content) -> some View {
        if let color {
            content
                .background(alignment: isOutgoing ? .topTrailing : .topLeading) {
                    if timelineGroupStyle == .single || timelineGroupStyle == .first {
                        MatchaBubbleTailShape(tipWidth: tipWidth)
                            .fill(color)
                            .scaleEffect(x: isOutgoing ? 1 : -1)
                            .frame(width: cornerRadius + tipWidth, height: cornerRadius)
                            .offset(x: isOutgoing ? tipWidth : -tipWidth)
                            .flipsForRightToLeftLayoutDirection(true)
                            .accessibilityHidden(true)
                    }
                }
                .compositingGroup()
                .shadow(color: MatchaColors.surfaceShadow, radius: 0, y: 1)
        } else {
            content
        }
    }
}

/// Fills the bubble's top trailing corner square and runs its top edge out to a slightly rounded tip past the trailing edge, from
/// which it slopes back to the bubble's edge at the bottom of the square.
nonisolated struct MatchaBubbleTailShape: Shape {
    let tipWidth: CGFloat
    
    func path(in rect: CGRect) -> Path {
        let edge = rect.maxX - tipWidth // The bubble's trailing edge.
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tipWidth / 4, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - tipWidth / 4, y: rect.minY + rect.height / 4), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: edge, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Previews

struct MatchaBubbleTail_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        VStack(spacing: 2) {
            bubble("First of the run has the tail", isOutgoing: false, style: .first)
            bubble("Run of two", isOutgoing: false, style: .last)
            bubble("Mine, on its own", isOutgoing: true, style: .single)
                .padding(.top, 8)
        }
        .padding(16)
        .background(MatchaColors.chatWallpaper)
    }
    
    static func bubble(_ text: String, isOutgoing: Bool, style: TimelineGroupStyle) -> some View {
        let color = isOutgoing ? MatchaColors.bubbleOutgoing : MatchaColors.bubbleIncoming
        return Text(text)
            .bubbleBackground(isOutgoing: isOutgoing, color: color)
            .matchaBubbleTail(isOutgoing: isOutgoing, color: color)
            .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
            .environment(\.timelineGroupStyle, style)
    }
}
