//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
@testable import ElementX
import SwiftUI
import Testing

struct MatchaPaletteTests {
    @Test
    func hookGivesCompoundTheMatchaColoursInLightAndDark() {
        MatchaCompoundHook().override(colors: Color.compound, uiColors: UIColor.compound)
        defer { removeOverrides() }
        
        #expect(hex(UIColor.compound.bgAccentRest, .light) == 0x1DAA61)
        #expect(hex(UIColor.compound.bgAccentRest, .dark) == 0x21C063)
        #expect(hex(UIColor(Color.compound.bgActionPrimaryRest), .light) == 0x1B8755)
        #expect(hex(UIColor(Color.compound.textPrimary), .dark) == 0xF7F8FA)
        // Grouped rows sit above their background in dark mode.
        #expect(hex(UIColor(Color.compound.bgCanvasDefaultLevel1), .dark) == 0x20272B)
        #expect(hex(UIColor(Color.compound.bgSubtleSecondaryLevel0), .dark) == 0x0A1014)
    }
    
    @Test
    func theAppAppliesThePalette() {
        let appHooks = AppHooks()
        appHooks.setUp()
        
        #expect(appHooks.compoundHook is MatchaCompoundHook)
    }
    
    @Test
    func everyTokenIsOverriddenOnce() {
        let tokens = MatchaPalette.roles.map(\.color)
        #expect(Set(tokens).count == tokens.count)
    }
    
    @Test
    func theColoursResolveOffTheMainThread() async {
        // SwiftUI resolves them on its render thread: a dynamic colour made on the main actor trapped there in the running app.
        let colors = MatchaPalette.roles.map(\.value) + [MatchaColors.chatWallpaperUIColor, MatchaColors.bubbleSecondaryTextUIColor]
        let resolved = await Task.detached {
            colors.map { $0.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)) }.count
        }.value
        #expect(resolved == colors.count)
    }
    
    @Test
    func avatarColoursUseElementsHashAndNoGreen() {
        // "a" is 97, 97 % 6 == 1: the second pair (blue), as on Element Web and Android.
        #expect(hex(UIColor(MatchaColors.decorativeColor(for: "a").text), .light) == 0x0063CB)
        #expect(hex(UIColor(MatchaColors.decorativeColor(for: "aa").text), .dark) == 0xFF72A1) // 194 % 6 == 2
        #expect(MatchaColors.decorativeColors.allSatisfy { hex(UIColor($0.background), .light) != 0xD9FDD3 })
    }
    
    @Test
    func secondaryTextInsideBubblesReachesTextContrast() {
        // WHATSAPP_DESIGN §7.2: 5.58 / 5.74 in light, 4.65 / 6.40 in dark. The palette's textSecondary on the dark own bubble is 3.21.
        for style in [UIUserInterfaceStyle.light, .dark] {
            for bubble in [MatchaColors.bubbleOutgoing, MatchaColors.bubbleIncoming] {
                #expect(contrast(UIColor(MatchaColors.bubbleMetaText), on: UIColor(bubble), style) >= 4.5, "\(style.rawValue)")
                // Quotes, file sizes, placeholders and thread summaries.
                #expect(contrast(MatchaColors.bubbleSecondaryTextUIColor, on: UIColor(bubble), style) >= 4.5, "\(style.rawValue)")
            }
        }
    }
    
    // MARK: - Helpers
    
    /// The WCAG ratio of a colour composited over an opaque background.
    private func contrast(_ foreground: UIColor, on background: UIColor, _ style: UIUserInterfaceStyle) -> CGFloat {
        func components(_ color: UIColor) -> [CGFloat] {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return [red, green, blue, alpha]
        }
        let fore = components(foreground), back = components(background)
        func luminance(_ rgb: [CGFloat]) -> CGFloat {
            let linear = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
        }
        let composited = (0..<3).map { fore[$0] * fore[3] + back[$0] * (1 - fore[3]) }
        let (lighter, darker) = (max(luminance(composited), luminance(back)), min(luminance(composited), luminance(back)))
        return (lighter + 0.05) / (darker + 0.05)
    }
    
    private func removeOverrides() {
        for role in MatchaPalette.roles {
            Color.compound.override(role.color, with: nil)
            UIColor.compound.override(role.uiColor, with: nil)
        }
    }
    
    private func hex(_ color: UIColor, _ style: UIUserInterfaceStyle) -> UInt32 {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return UInt32((red * 255).rounded()) << 16 | UInt32((green * 255).rounded()) << 8 | UInt32((blue * 255).rounded())
    }
}
