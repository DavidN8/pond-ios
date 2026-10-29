//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

/// A button revealed by swiping a row, for rows in a `ScrollView` (a `List` row should use SwiftUI's own `swipeActions`).
struct MatchaSwipeAction: Identifiable {
    let title: String
    let icon: KeyPath<CompoundIcons, Image>
    let tint: Color
    let action: () -> Void
    
    var id: String {
        title
    }
}

extension View {
    /// Swipe towards the trailing edge to reveal `leading`, towards the leading edge to reveal `trailing`, as in iOS chat lists.
    /// VoiceOver gets the same actions as accessibility actions. The row's content must have an opaque background.
    func matchaSwipeActions(leading: [MatchaSwipeAction] = [], trailing: [MatchaSwipeAction] = []) -> some View {
        modifier(MatchaSwipeActionsModifier(leading: leading, trailing: trailing))
    }
}

enum MatchaSwipe {
    static let buttonWidth: CGFloat = 76
    
    /// Where a released row comes to rest: open on a side once dragged (or flung) past half its buttons, otherwise closed. A row never
    /// jumps from one side to the other. Offsets are in the layout direction: positive reveals the leading buttons.
    static func restingOffset(offset: CGFloat, velocity: CGFloat, leadingWidth: CGFloat, trailingWidth: CGFloat) -> CGFloat {
        let projected = offset + velocity * 0.1
        let side = offset != 0 ? offset : projected
        if side > 0 {
            return leadingWidth > 0 && projected > leadingWidth / 2 ? leadingWidth : 0
        } else if side < 0 {
            return trailingWidth > 0 && projected < -trailingWidth / 2 ? -trailingWidth : 0
        } else {
            return 0
        }
    }
}

// ponytail: rows open independently and stay open while the list scrolls; share an open-row ID if that bothers anyone.
private struct MatchaSwipeActionsModifier: ViewModifier {
    @Environment(\.layoutDirection) private var layoutDirection
    
    let leading: [MatchaSwipeAction]
    let trailing: [MatchaSwipeAction]
    
    @State private var offset: CGFloat
    @State private var offsetAtStart: CGFloat?
    
    /// - Parameter offset: how far the row starts open, for previews.
    init(leading: [MatchaSwipeAction], trailing: [MatchaSwipeAction], offset: CGFloat = 0) {
        self.leading = leading
        self.trailing = trailing
        _offset = State(initialValue: offset)
    }
    
    private var leadingWidth: CGFloat {
        CGFloat(leading.count) * MatchaSwipe.buttonWidth
    }
    
    private var trailingWidth: CGFloat {
        CGFloat(trailing.count) * MatchaSwipe.buttonWidth
    }
    
    func body(content: Content) -> some View {
        content
            .overlay {
                if offset != 0 {
                    // While open, a tap on the row closes it instead of opening it.
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture { close() }
                }
            }
            .offset(x: offset)
            .background(alignment: .leading) {
                if offset > 0 {
                    buttons(leading)
                }
            }
            .background(alignment: .trailing) {
                if offset < 0 {
                    buttons(trailing)
                }
            }
            .clipped()
            .gesture(PanGestureRepresentable(handle: handlePan))
            .accessibilityActions {
                ForEach(leading + trailing) { action in
                    Button(action.title, action: action.action)
                }
            }
    }
    
    private func buttons(_ actions: [MatchaSwipeAction]) -> some View {
        HStack(spacing: 0) {
            ForEach(actions) { action in
                Button {
                    close()
                    action.action()
                } label: {
                    VStack(spacing: 4) {
                        CompoundIcon(action.icon, size: .medium, relativeTo: .compound.bodyMD)
                        Text(action.title)
                            .font(.compound.bodyXSSemibold)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(.compound.textOnSolidPrimary)
                    .padding(.horizontal, 4)
                    .frame(width: MatchaSwipe.buttonWidth)
                    .frame(maxHeight: .infinity)
                    .background(action.tint)
                }
                .accessibilityHidden(true) // The row's accessibility actions carry them.
            }
        }
    }
    
    private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        // The window's x grows to the right whatever the layout direction.
        let direction: CGFloat = layoutDirection == .rightToLeft ? -1 : 1
        switch recognizer.state {
        case .began:
            offsetAtStart = offset
        case .changed:
            let translation = recognizer.translation(in: nil).x * direction
            offset = min(max((offsetAtStart ?? 0) + translation, -trailingWidth), leadingWidth)
        case .ended, .cancelled, .failed:
            let velocity = recognizer.state == .ended ? recognizer.velocity(in: nil).x * direction : 0
            let resting = MatchaSwipe.restingOffset(offset: offset, velocity: velocity, leadingWidth: leadingWidth, trailingWidth: trailingWidth)
            withAnimation(.interactiveSpring) { offset = resting }
            offsetAtStart = nil
        default:
            break
        }
    }
    
    private func close() {
        withAnimation(.interactiveSpring) { offset = 0 }
    }
}

// MARK: - Previews

struct MatchaSwipeActions_Previews: PreviewProvider, TestablePreview {
    static let leading = [MatchaSwipeAction(title: "Mark as unread", icon: \.markAsUnread, tint: .compound.iconInfoPrimary) { },
                          MatchaSwipeAction(title: "Favourite", icon: \.favourite, tint: .compound.iconSecondary) { }]
    static let trailing = [MatchaSwipeAction(title: "Leave", icon: \.leave, tint: .compound.bgCriticalPrimary) { }]
    
    static var previews: some View {
        VStack(spacing: 0) {
            row("Closed", offset: 0)
            row("Leading open", offset: 2 * MatchaSwipe.buttonWidth)
            row("Trailing open", offset: -MatchaSwipe.buttonWidth)
        }
    }
    
    static func row(_ title: String, offset: CGFloat) -> some View {
        Text(title)
            .font(.compound.bodyLGSemibold)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .padding(.horizontal, 16)
            .background(.compound.bgCanvasDefault)
            .modifier(MatchaSwipeActionsModifier(leading: leading, trailing: trailing, offset: offset))
    }
}
