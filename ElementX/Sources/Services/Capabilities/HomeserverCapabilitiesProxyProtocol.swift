//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

// sourcery: AutoMockable
protocol HomeserverCapabilitiesProxyProtocol {
    func refresh() async
    func canChangeAvatar() async -> Bool
    func canChangeDisplayName() async -> Bool
    /// matcha: whether the server lets the account change its password (`m.change_password`); false when it can't say.
    func canChangePassword() async -> Bool
}
