//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import MatchaProtocol

protocol EmojiPackScreenViewModelProtocol {
    var actionsPublisher: AnyPublisher<EmojiPackScreenViewModelAction, Never> { get }
    var context: EmojiPackScreenViewModelType.Context { get }
    
    /// Adds the picked images to the pack as emoji or stickers, skipping and reporting those the upload rules refuse.
    func upload(urls: [URL], usage: ImageUsage)
}
