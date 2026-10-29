//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

// The Matcha icons Compound lacks, ported from Android's `ic_matcha_*.xml` as template vectors in `Assets.xcassets/images/matcha`:
// `Asset.Images.matchaNotes`/`matchaNotesSolid` (a note, the Notes tab), `matchaBoard`/`matchaBoardSolid` (a task board),
// `matchaDoneAll` (the read tick and "Seen by") and `matchaArchive`. Use them like Compound's: `CompoundIcon(asset: Asset.Images.matchaBoard)`.

extension CompoundIcon {
    init(asset: ImageAsset, size: Size, relativeTo font: Font) {
        self.init(customImage: asset.swiftUIImage, size: size, relativeTo: font)
    }
}

// MARK: - Previews

struct MatchaIcons_Previews: PreviewProvider, TestablePreview {
    struct Icon {
        let name: String
        let outline: ImageAsset
        var solid: ImageAsset?
    }
    
    static let icons = [Icon(name: "Notes", outline: Asset.Images.matchaNotes, solid: Asset.Images.matchaNotesSolid),
                        Icon(name: "Board", outline: Asset.Images.matchaBoard, solid: Asset.Images.matchaBoardSolid),
                        Icon(name: "Read", outline: Asset.Images.matchaDoneAll),
                        Icon(name: "Archive", outline: Asset.Images.matchaArchive)]
    
    static var previews: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(icons, id: \.name) { icon in
                HStack(spacing: 16) {
                    CompoundIcon(asset: icon.outline)
                    if let solid = icon.solid {
                        CompoundIcon(asset: solid)
                    }
                    CompoundIcon(asset: icon.outline, size: .xSmall, relativeTo: .compound.bodySM)
                    Text(icon.name)
                        .font(.compound.bodyMD)
                }
                .foregroundStyle(.compound.iconPrimary)
            }
        }
        .padding()
    }
}
