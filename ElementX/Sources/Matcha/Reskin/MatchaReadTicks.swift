//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import MatchaProtocol
import SwiftUI

/// The read state of your own messages, Android's `TimelineReadStates.kt`: the double tick replaces the read receipt avatars under bubbles.
enum MatchaReadTicks {
    /// Rooms with more joined members than this never show the read tick: it stops at "sent".
    static let maxMembers = 32
    
    /// Your own messages that every other joined member has read, through a receipt on them or on a newer item. Members who send no
    /// receipts aren't waited for: service members (MSC4171) and the reminder bot of any homeserver.
    /// - Parameter items: the timeline, oldest first.
    static func readItemIDs(in items: [RoomTimelineItemProtocol],
                            members: [RoomMemberProxyProtocol],
                            ownUserID: String) -> Set<TimelineItemIdentifier.UniqueID> {
        // One past the cap is enough to know, which keeps large rooms cheap on the main actor.
        let readers = Set(members.lazy
            .filter { $0.membership == .join && $0.userID != ownUserID && !isReminderBot($0.userID) && !$0.isServiceMember }
            .map(\.userID)
            .prefix(maxMembers + 1))
        guard !readers.isEmpty, readers.count <= maxMembers else { return [] }
        
        var hasRead = Set<String>()
        var readIDs = Set<TimelineItemIdentifier.UniqueID>()
        for item in items.reversed() {
            hasRead.formUnion(receipts(of: item).map(\.userID))
            if let event = item as? EventBasedTimelineItemProtocol, event.isOutgoing, readers.isSubset(of: hasRead) {
                readIDs.insert(item.id.uniqueID)
            }
        }
        return readIDs
    }
    
    /// Everyone who has read the item, through a receipt on it or on a newer one: what "Seen by" lists.
    static func readReceipts(upTo itemID: TimelineItemIdentifier, in items: [RoomTimelineItemProtocol], ownUserID: String) -> [ReadReceipt] {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return [] }
        
        var seen = Set<String>()
        return items[index...].reversed().flatMap(receipts).filter { $0.userID != ownUserID && seen.insert($0.userID).inserted }
    }
    
    private static func receipts(of item: RoomTimelineItemProtocol) -> [ReadReceipt] {
        switch item {
        case let event as EventBasedTimelineItemProtocol:
            event.properties.orderedReadReceipts
        case let collapsible as CollapsibleTimelineItem:
            collapsible.items.flatMap(receipts)
        default:
            []
        }
    }
    
    private static func isReminderBot(_ userID: String) -> Bool {
        userID.dropFirst().split(separator: ":", maxSplits: 1).first == Substring(MatchaConfig.reminderBotLocalpart)
    }
}

extension TimelineViewState {
    /// Whether your own message shows the read tick. Never in the pinned list, which lacks the newer receipts, nor while you don't
    /// share your own receipts (Share presence), as on Android and as upstream hid the receipt avatars.
    func matchaIsRead(_ itemID: TimelineItemIdentifier) -> Bool {
        showReadReceipts && timelineKind != .pinned && timelineState.matchaReadUniqueIDs.contains(itemID.uniqueID)
    }
}

/// The tick after the time of your own message. There is no "delivered" state: Matrix has no delivery receipts.
enum MatchaTick: Hashable {
    case sending
    case sent
    case read
    
    /// From the message's own send state, as on Android. Nil for others' messages and for a failed send, whose error icon shows instead.
    /// - Parameter deliveryStatus: upstream's, which for a sent message is that of our pending edit or redaction, or a failed
    ///   reaction, on it. Only a local echo (a transaction ID, no event ID yet) has a send state of its own.
    init?(timelineItem: EventBasedTimelineItemProtocol, deliveryStatus: TimelineItemDeliveryStatus?, isRead: Bool) {
        guard timelineItem.isOutgoing else { return nil }
        switch timelineItem.id.transactionID != nil ? deliveryStatus : nil {
        case .sending: self = .sending
        case .sendingFailed: return nil
        case .sent, .none: self = isRead ? .read : .sent
        }
    }
}

struct MatchaTickIcon: View {
    let tick: MatchaTick
    
    var body: some View {
        switch tick {
        case .sending:
            CompoundIcon(\.time, size: .xSmall, relativeTo: .compound.bodyXS)
                .accessibilityLabel(L10n.commonSending)
        case .sent:
            CompoundIcon(\.check, size: .xSmall, relativeTo: .compound.bodyXS)
                .accessibilityLabel(L10n.commonSent)
        case .read:
            CompoundIcon(asset: Asset.Images.matchaDoneAll, size: .xSmall, relativeTo: .compound.bodyXS)
                .foregroundStyle(MatchaColors.readTick)
                .accessibilityLabel(UntranslatedL10n.a11yMatchaMessageRead)
        }
    }
}
