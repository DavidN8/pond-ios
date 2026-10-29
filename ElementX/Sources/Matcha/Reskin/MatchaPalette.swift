//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import CompoundDesignTokens
import SwiftUI

/// Gives Compound's semantic tokens the Matcha values of Android's `MatchaColors.kt`, light and dark (`WHATSAPP_DESIGN.md` §2.2).
/// Applied by `AppHooks.setUp()`, so tests, previews and snapshots keep Compound's own colours.
struct MatchaCompoundHook: CompoundHookProtocol {
    func override(colors: CompoundColors, uiColors: CompoundUIColors) {
        for role in MatchaPalette.roles {
            colors.override(role.color, with: Color(uiColor: role.value))
            uiColors.override(role.uiColor, with: role.value)
        }
    }
}

/// Nonisolated: UIKit and SwiftUI resolve a dynamic colour on their render threads, and a closure made on the main actor traps there.
nonisolated enum MatchaPalette {
    struct Role {
        let color: KeyPath<CompoundColorTokens, Color> & Sendable
        let uiColor: KeyPath<CompoundUIColorTokens, UIColor> & Sendable
        let value: UIColor
        
        init(_ color: KeyPath<CompoundColorTokens, Color> & Sendable, _ uiColor: KeyPath<CompoundUIColorTokens, UIColor> & Sendable, _ light: UIColor, _ dark: UIColor) {
            self.color = color
            self.uiColor = uiColor
            value = UIColor { $0.userInterfaceStyle == .dark ? dark : light }
        }
    }
    
    // Greens: one that carries icons only (white on it is 3:1) and one that carries text (4.5:1).
    static let green = rgb(0x1DAA61)
    static let greenHovered = rgb(0x1A9A58)
    static let greenPressed = rgb(0x178C50)
    static let greenDark = rgb(0x21C063)
    static let greenDarkHovered = rgb(0x1EB05B)
    static let greenDarkPressed = rgb(0x1C9F52)
    static let greenText = rgb(0x1B8755)
    static let greenTextHovered = rgb(0x187A4C)
    static let greenTextPressed = rgb(0x156B43)
    static let greenPositiveDark = rgb(0x71EB85)
    static let greenDeep = rgb(0x15603E)
    static let greenTint = rgb(0xD9FDD3)
    static let greenTintDark = rgb(0x103529)
    
    static let ink = rgb(0x0A1014)
    static let inkSecondary = rgb(0x5B6368)
    static let inkTertiary = rgb(0x8D9599)
    static let inkDisabled = rgb(0xB3B9BD)
    static let paper = rgb(0xFFFFFF)
    static let paperRaised = rgb(0xF7F5F3)
    static let paperPressed = rgb(0xEFECE9)
    static let paperSubtle = rgb(0xFAF9F8)
    static let lineLight = rgb(0xE7E8E9)
    static let dividerLight = rgb(0x111B21, alpha: 0.1)
    
    static let night = rgb(0x0A1014)
    static let nightRaised = rgb(0x12181C)
    static let nightElevated = rgb(0x20272B)
    static let nightPressed = rgb(0x2A3236)
    static let snow = rgb(0xF7F8FA)
    static let snowSecondary = rgb(0x8D9599)
    static let snowTertiary = rgb(0x6B7478)
    static let snowDisabled = rgb(0x3E474D)
    static let lineDark = rgb(0x22292D)
    static let dividerDark = rgb(0xFFFFFF, alpha: 0.1)
    
    static let red = rgb(0xEA0038)
    static let redDark = rgb(0xFB5061)
    static let redTint = rgb(0xFFE5EA)
    static let redTintDark = rgb(0x3A1820)
    static let amber = rgb(0xB37A00)
    static let amberDark = rgb(0xFFD279)
    static let amberText = rgb(0x8A5A00)
    static let amberTint = rgb(0xFFF0D4)
    static let amberTintDark = rgb(0x3A2A08)
    static let amberOnDark = rgb(0xFFBE4D)
    static let blueLink = rgb(0x006BA6)
    static let blueLinkDark = rgb(0x53BDEB)
    static let blueTint = rgb(0xD2E8FE)
    static let blueTintDark = rgb(0x092642)
    
    /// Every token Android's palette overrides, in `MatchaColors.kt` order. The decorative pairs are `MatchaColors.decorativeColor(for:)`:
    /// Compound reads them once, before any override.
    static let roles: [Role] = [
        .init(\.bgAccentRest, \.bgAccentRest, green, greenDark),
        .init(\.bgAccentHovered, \.bgAccentHovered, greenHovered, greenDarkHovered),
        .init(\.bgAccentPressed, \.bgAccentPressed, greenPressed, greenDarkPressed),
        .init(\.bgAccentSelected, \.bgAccentSelected, greenTint, greenTintDark),
        .init(\.bgAccentSubtle, \.bgAccentSubtle, greenTint, greenTintDark),
        // Filled buttons carry labels, so they use the text green.
        .init(\.bgActionPrimaryRest, \.bgActionPrimaryRest, greenText, greenDark),
        .init(\.bgActionPrimaryHovered, \.bgActionPrimaryHovered, greenTextHovered, greenDarkHovered),
        .init(\.bgActionPrimaryPressed, \.bgActionPrimaryPressed, greenTextPressed, greenDarkPressed),
        .init(\.bgActionPrimaryDisabled, \.bgActionPrimaryDisabled, inkDisabled, snowDisabled),
        .init(\.bgActionSecondaryRest, \.bgActionSecondaryRest, paper, night),
        .init(\.bgActionTertiaryRest, \.bgActionTertiaryRest, paper, night),
        .init(\.bgActionTertiaryHovered, \.bgActionTertiaryHovered, paperRaised, nightRaised),
        .init(\.bgActionTertiarySelected, \.bgActionTertiarySelected, greenTint, greenTintDark),
        .init(\.bgBadgeAccent, \.bgBadgeAccent, greenTint, greenTintDark),
        .init(\.bgBadgePrimary, \.bgBadgePrimary, ink, snow),
        .init(\.bgBadgeSecondary, \.bgBadgeSecondary, paperPressed, nightPressed),
        .init(\.bgCanvasDefault, \.bgCanvasDefault, paper, night),
        // iOS draws grouped lists as Level1 rows on SubtleSecondaryLevel0: in dark, raised rows on the night canvas (Android's
        // dark values would put the rows below their background).
        .init(\.bgCanvasDefaultLevel1, \.bgCanvasDefaultLevel1, paper, nightElevated),
        .init(\.bgCanvasDisabled, \.bgCanvasDisabled, paperRaised, nightRaised),
        .init(\.bgCriticalPrimary, \.bgCriticalPrimary, red, redDark),
        .init(\.bgCriticalHovered, \.bgCriticalHovered, rgb(0xC4002F), red),
        .init(\.bgCriticalSubtle, \.bgCriticalSubtle, redTint, redTintDark),
        .init(\.bgCriticalSubtleHovered, \.bgCriticalSubtleHovered, rgb(0xFFCCD6), rgb(0x4A1F29)),
        .init(\.bgInfoSubtle, \.bgInfoSubtle, blueTint, blueTintDark),
        .init(\.bgSubtlePrimary, \.bgSubtlePrimary, paperPressed, nightPressed),
        .init(\.bgSubtleSecondary, \.bgSubtleSecondary, paperRaised, nightElevated),
        .init(\.bgSubtleSecondaryLevel0, \.bgSubtleSecondaryLevel0, paperRaised, night),
        .init(\.bgSubtleTertiary, \.bgSubtleTertiary, paperSubtle, nightRaised),
        .init(\.bgSuccessRest, \.bgSuccessRest, green, greenDark),
        .init(\.bgSuccessHovered, \.bgSuccessHovered, greenHovered, greenDarkHovered),
        .init(\.bgSuccessPressed, \.bgSuccessPressed, greenPressed, greenDarkPressed),
        .init(\.bgSuccessSubtle, \.bgSuccessSubtle, greenTint, greenTintDark),
        .init(\.borderAccentPrimary, \.borderAccentPrimary, green, greenDark),
        .init(\.borderAccentSubtle, \.borderAccentSubtle, greenTint, greenTintDark),
        .init(\.borderCriticalPrimary, \.borderCriticalPrimary, red, redDark),
        .init(\.borderDisabled, \.borderDisabled, lineLight, lineDark),
        .init(\.borderFocused, \.borderFocused, green, greenDark),
        .init(\.borderInteractivePrimary, \.borderInteractivePrimary, inkTertiary, snowTertiary),
        .init(\.borderInteractiveSecondary, \.borderInteractiveSecondary, lineLight, lineDark),
        .init(\.borderInteractiveHovered, \.borderInteractiveHovered, inkSecondary, snowSecondary),
        .init(\.borderSuccessPrimary, \.borderSuccessPrimary, green, greenDark),
        .init(\.borderSuccessSubtle, \.borderSuccessSubtle, greenTint, greenTintDark),
        // Flat headers: no coloured wash behind the toolbar.
        .init(\.gradientSubtleStop1, \.gradientSubtleStop1, .clear, .clear),
        .init(\.gradientSubtleStop2, \.gradientSubtleStop2, .clear, .clear),
        .init(\.gradientSubtleStop3, \.gradientSubtleStop3, .clear, .clear),
        .init(\.gradientSubtleStop4, \.gradientSubtleStop4, .clear, .clear),
        .init(\.gradientSubtleStop5, \.gradientSubtleStop5, .clear, .clear),
        .init(\.gradientSubtleStop6, \.gradientSubtleStop6, .clear, .clear),
        // Composer alerts (identity change, upgraded room) are flat strips.
        .init(\.gradientInfoStop1, \.gradientInfoStop1, amberTint, nightElevated),
        .init(\.gradientInfoStop2, \.gradientInfoStop2, amberTint, nightElevated),
        .init(\.gradientCriticalStop1, \.gradientCriticalStop1, redTint, redTintDark),
        .init(\.gradientCriticalStop2, \.gradientCriticalStop2, redTint, redTintDark),
        .init(\.gradientActionStop1, \.gradientActionStop1, green, greenDark),
        .init(\.gradientActionStop2, \.gradientActionStop2, green, greenDark),
        .init(\.gradientActionStop3, \.gradientActionStop3, greenText, green),
        .init(\.gradientActionStop4, \.gradientActionStop4, greenDeep, greenText),
        // Badges carry digits, so they use the text green.
        .init(\.iconAccentPrimary, \.iconAccentPrimary, greenText, greenDark),
        .init(\.iconAccentTertiary, \.iconAccentTertiary, green, greenDark),
        .init(\.iconCriticalPrimary, \.iconCriticalPrimary, red, redDark),
        .init(\.iconDisabled, \.iconDisabled, inkDisabled, snowDisabled),
        // On green, dark mode uses dark icons and labels.
        .init(\.iconOnSolidPrimary, \.iconOnSolidPrimary, paper, night),
        .init(\.iconPrimary, \.iconPrimary, ink, snow),
        .init(\.iconPrimaryAlpha, \.iconPrimaryAlpha, ink, snow),
        .init(\.iconSecondary, \.iconSecondary, inkSecondary, snowSecondary),
        .init(\.iconSecondaryAlpha, \.iconSecondaryAlpha, inkSecondary, snowSecondary),
        .init(\.iconTertiary, \.iconTertiary, inkTertiary, snowTertiary),
        .init(\.iconTertiaryAlpha, \.iconTertiaryAlpha, inkTertiary, snowTertiary),
        .init(\.iconQuaternary, \.iconQuaternary, inkDisabled, snowDisabled),
        .init(\.iconQuaternaryAlpha, \.iconQuaternaryAlpha, inkDisabled, snowDisabled),
        .init(\.iconSuccessPrimary, \.iconSuccessPrimary, green, greenDark),
        .init(\.iconWarningPrimary, \.iconWarningPrimary, amber, amberDark),
        .init(\.separatorPrimary, \.separatorPrimary, dividerLight, dividerDark),
        .init(\.separatorSecondary, \.separatorSecondary, dividerLight, dividerDark),
        .init(\.textActionAccent, \.textActionAccent, greenText, greenDark),
        .init(\.textActionPrimary, \.textActionPrimary, ink, snow),
        .init(\.textActionSuccess, \.textActionSuccess, greenText, greenDark),
        .init(\.textBadgeAccent, \.textBadgeAccent, greenDeep, greenTint),
        .init(\.textCriticalPrimary, \.textCriticalPrimary, red, redDark),
        .init(\.textDisabled, \.textDisabled, inkDisabled, snowDisabled),
        .init(\.textLinkExternal, \.textLinkExternal, blueLink, blueLinkDark),
        .init(\.textOnSolidPrimary, \.textOnSolidPrimary, paper, night),
        .init(\.textPrimary, \.textPrimary, ink, snow),
        .init(\.textSecondary, \.textSecondary, inkSecondary, snowSecondary),
        .init(\.textSuccessPrimary, \.textSuccessPrimary, greenText, greenPositiveDark),
        .init(\.textWarningPrimary, \.textWarningPrimary, amberText, amberDark)
    ]
    
    static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }
}

// MARK: - Previews

/// The palette itself, for review: previews don't run the hook, so other previews show Compound's colours.
struct MatchaPalette_Previews: PreviewProvider, TestablePreview {
    static let swatches: [(String, Color)] = [
        ("Accent", Color(uiColor: MatchaPalette.roles.value(of: \.bgAccentRest))),
        ("Filled button", Color(uiColor: MatchaPalette.roles.value(of: \.bgActionPrimaryRest))),
        ("Tonal green", Color(uiColor: MatchaPalette.roles.value(of: \.bgAccentSubtle))),
        ("Canvas", Color(uiColor: MatchaPalette.roles.value(of: \.bgCanvasDefault))),
        ("Raised", Color(uiColor: MatchaPalette.roles.value(of: \.bgCanvasDefaultLevel1))),
        ("Filled field", Color(uiColor: MatchaPalette.roles.value(of: \.bgSubtleSecondary))),
        ("Text", Color(uiColor: MatchaPalette.roles.value(of: \.textPrimary))),
        ("Secondary text", Color(uiColor: MatchaPalette.roles.value(of: \.textSecondary))),
        ("Critical", Color(uiColor: MatchaPalette.roles.value(of: \.textCriticalPrimary))),
        ("Wallpaper", MatchaColors.chatWallpaper),
        ("Own bubble", MatchaColors.bubbleOutgoing),
        ("Other bubble", MatchaColors.bubbleIncoming),
        ("Read tick", MatchaColors.readTick)
    ]
    
    static var previews: some View {
        ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
            VStack(alignment: .leading, spacing: 4) {
                ForEach(swatches, id: \.0) { name, color in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(color)
                            .stroke(.gray.opacity(0.3))
                            .frame(width: 44, height: 24)
                        Text(name)
                            .font(.compound.bodySM)
                            .foregroundStyle(Color(uiColor: MatchaPalette.roles.value(of: \.textPrimary)))
                    }
                }
            }
            .padding()
            .background(Color(uiColor: MatchaPalette.roles.value(of: \.bgCanvasDefault)))
            .environment(\.colorScheme, scheme)
            .previewDisplayName(scheme == .light ? "Light" : "Dark")
        }
    }
}

private extension [MatchaPalette.Role] {
    func value(of token: KeyPath<CompoundColorTokens, Color>) -> UIColor {
        first { $0.color == token }?.value ?? .clear
    }
}
