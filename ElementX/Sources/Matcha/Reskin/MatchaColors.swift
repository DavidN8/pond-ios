//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

/// The chat colours Compound has no token for, Android's `ColorAliases.kt` (`WHATSAPP_DESIGN.md` §2.3), and the avatar pairs. Unlike
/// `MatchaPalette` they don't wait for the hook, so previews show them too. The NSE compiles this file for notification avatars.
/// Nonisolated like `MatchaPalette`, as their dynamic colours resolve off the main thread.
nonisolated enum MatchaColors {
    /// Your own bubble.
    static let bubbleOutgoing = color(light: 0xD9FDD3, dark: 0x144D37)
    /// Everyone else's bubble: the plain surface in light, a raised tone in dark.
    static let bubbleIncoming = color(light: 0xFFFFFF, dark: 0x20272B)
    /// The plain fill behind every timeline (no doodles: brand rule).
    static let chatWallpaperUIColor = uiColor(light: 0xF5F1EB, dark: 0x0A1014)
    static let chatWallpaper = Color(uiColor: chatWallpaperUIColor)
    /// Time, "Edited" and the ticks inside a bubble.
    static let bubbleMetaText = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .white.withAlphaComponent(0.6) : .black.withAlphaComponent(0.6) })
    /// All other secondary text inside a bubble: reply quotes, file sizes, voice message times, removed and undecryptable messages,
    /// thread summaries. Compound's `textSecondary` is too faint on the dark own bubble (§7.2).
    static let bubbleSecondaryTextUIColor = UIColor { $0.userInterfaceStyle == .dark ? .white.withAlphaComponent(0.7) : .black.withAlphaComponent(0.6) }
    static let bubbleSecondaryText = Color(uiColor: bubbleSecondaryTextUIColor)
    /// The double tick once everyone has read your message.
    static let readTick = color(light: 0x007BFC, dark: 0x53BDEB)
    /// Warning strips under a bar, and encryption notices (Android's `noticePillBackground` and `noticePillText`).
    static let noticePillBackground = color(light: 0xFFF0D4, dark: 0x20272B)
    static let noticePillText = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? rgb(0xFFD279) : .black.withAlphaComponent(0.6) })
    /// Day separators and system events.
    static let systemPillBackground = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? rgb(0x20272B) : .white.withAlphaComponent(0.9) })
    /// The 1 pt shadow under bubbles and pills, in light mode only: dark mode separates surfaces by tone (§2.7).
    static let surfaceShadow = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .clear : rgb(0x0B141A, alpha: 0.1) })
    
    struct DecorativeColor {
        let background: Color
        let text: Color
    }
    
    /// Avatar fills and initials, and group sender names: WhatsApp's pairs with amber in place of green (green is never decorative).
    static let decorativeColors: [DecorativeColor] = [
        .init(background: color(light: 0xFFF0D4, dark: 0x3A2A08), text: color(light: 0x8A5A00, dark: 0xFFBE4D)),
        .init(background: color(light: 0xD2E8FE, dark: 0x092642), text: color(light: 0x0063CB, dark: 0x53A6FD)),
        .init(background: color(light: 0xFFDAE7, dark: 0x36192A), text: color(light: 0xD42A66, dark: 0xFF72A1)),
        .init(background: color(light: 0xE8E0FF, dark: 0x242447), text: color(light: 0x5E47DE, dark: 0xA791FF)),
        .init(background: color(light: 0xFEE2D8, dark: 0x35221E), text: color(light: 0xC4532D, dark: 0xFC9775)),
        .init(background: color(light: 0xCBF2EE, dark: 0x092D2F), text: color(light: 0x028377, dark: 0x42C7B8))
    ]
    
    /// Compound's `decorativeColor(for:)` with the Matcha pairs: the same hash as Element Web, so a user keeps their slot.
    static func decorativeColor(for contentID: String) -> DecorativeColor {
        let sum = contentID.reduce(0) { $0 + Int($1.unicodeScalars.first?.value ?? 0) }
        return decorativeColors[sum % decorativeColors.count]
    }
    
    private static func color(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: uiColor(light: light, dark: dark))
    }
    
    private static func uiColor(light: UInt32, dark: UInt32) -> UIColor {
        let light = rgb(light)
        let dark = rgb(dark)
        return UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }
    
    static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }
}
