//
// Copyright 2025 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

/// A floating badge that displays the date of the topmost visible timeline item
/// while the user is scrolling the timeline. It fades in when scrolling starts and
/// fades out shortly after scrolling stops.
struct FloatingDateBadge: View {
    let dateText: String?
    var onTap: (() -> Void)?
    
    var body: some View {
        ZStack {
            if let dateText {
                Button { onTap?() } label: {
                    Text(dateText)
                        .matchaDatePill() // matcha: the day separator's pill
                }
                .buttonStyle(.plain)
                .disabled(onTap == nil)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15).disabledDuringTests(), value: dateText)
    }
}

// MARK: - Previews

struct FloatingDateBadge_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        VStack(spacing: 20) {
            FloatingDateBadge(dateText: "Today")
            FloatingDateBadge(dateText: "Yesterday")
            FloatingDateBadge(dateText: "Tuesday, January 9, 2007")
        }
        .padding()
        .previewLayout(.sizeThatFits)
    }
}
