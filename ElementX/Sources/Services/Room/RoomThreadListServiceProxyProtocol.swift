//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation

// sourcery: AutoMockable
protocol RoomThreadListServiceProxyProtocol {
    var itemsPublisher: CurrentValuePublisher<[RoomThreadListItem], Never> { get }
    
    var paginationStatePublisher: CurrentValuePublisher<RoomThreadListPaginationState, Never> { get }
    
    func paginate() async -> Result<Void, RoomProxyError>
}

struct RoomThreadListItem: Identifiable {
    struct MessageDetails {
        let sender: TimelineItemSender
        let timestamp: Date
        let message: AttributedString?
    }
    
    let id: String
    
    let rootMessageDetails: MessageDetails
    let latestMessageDetails: MessageDetails?
    
    let numberOfReplies: UInt
    
    /// matcha: what the Matcha room store reads of the thread; nil for items not built from the SDK.
    var matcha: MatchaListedThread?
}

enum RoomThreadListPaginationState: Equatable {
    case idle(endReached: Bool)
    case loading
}
