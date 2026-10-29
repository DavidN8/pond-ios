//
// Copyright 2025 Element Creations Ltd.
// Copyright 2024-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

extension View {
    /// - Parameters:
    ///   - isOutgoing: rounds the corners according to the side it shows on, defaults to true
    ///   - insets: defaults to what we use for file timeline items, text uses custom values
    ///   - color: self explanatory, defaults to subtle secondary
    ///   - borderColor: an optional colour for a border around the bubble
    func bubbleBackground(isOutgoing: Bool = true,
                          insets: EdgeInsets = .init(top: 8, leading: 12, bottom: 8, trailing: 12),
                          color: @autoclosure @MainActor () -> Color? = .compound.bgSubtleSecondary,
                          borderColor: @autoclosure @MainActor () -> Color? = nil) -> some View {
        modifier(TimelineItemBubbleBackgroundModifier(isOutgoing: isOutgoing,
                                                      insets: insets,
                                                      color: color(),
                                                      borderColor: borderColor()))
    }
}

private struct TimelineItemBubbleBackgroundModifier: ViewModifier {
    let isOutgoing: Bool
    let insets: EdgeInsets
    var color: Color?
    var borderColor: Color?
    /// matcha: every corner rounded, as Android's bubbles; the tail squares the top outer one of a run's first bubble.
    private let roundedCorners: UIRectCorner = .allCorners
    
    func body(content: Content) -> some View {
        content
            .padding(insets)
            .background(color)
            .cornerRadius(12, corners: roundedCorners)
            .overlay {
                if let borderColor {
                    RoundedCornerShape(radius: 12, corners: roundedCorners)
                        .stroke(borderColor)
                }
            }
    }
}
