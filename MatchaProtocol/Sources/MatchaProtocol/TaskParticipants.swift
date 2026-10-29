//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

/// Who a task involves, as on the web client: a thread's task involves the thread's root sender and everyone who replied in it; an
/// older standalone card involves the authors of its revisions. In a direct chat its members are involved in every task.
public enum TaskParticipants {
    /// The senders of the thread replies among `events`, by thread root id. Redacted replies don't count.
    public static func repliers(_ events: [RawEvent]) -> [String: Set<String>] {
        repliers(events, by: \.self).mapValues(Set.init)
    }
    
    /// `repliers(_:)` by `key(rootID)`, each once in the order of `events`.
    static func repliers<Key: Hashable>(_ events: [RawEvent], by key: (String) -> Key) -> [Key: [String]] {
        events.reduce(into: [:]) { result, event in
            // A relation stays readable in an event that can't be decrypted.
            guard !event.isRedacted,
                  let rootID = event.content.relationTarget(MatchaConfig.relationTypeThread),
                  let sender = event.validSenderID else { return }
            result[key(rootID), default: []].appendNew(sender)
        }
    }
    
    /// The authors of each card's revisions that have no thread, by card id, each once in the order of `events`: an older standalone
    /// card's participants.
    public static func standaloneAuthors(_ events: [RawEvent], rootID: String) -> [String: [String]] {
        events.reduce(into: [:]) { result, event in
            guard let card = KanbanProtocol.parseCard(event, rootID: rootID), card.threadID == nil, let sender = event.validSenderID else { return }
            result[card.cardID, default: []].appendNew(sender)
        }
    }
    
    /// The participants of `card`.
    ///
    /// - Parameters:
    ///   - threadParticipants: each thread's root sender and repliers, by thread root id.
    ///   - standaloneAuthors: see `standaloneAuthors(_:rootID:)`.
    ///   - directMembers: the current user and the other members of a direct chat, or empty in any other chat; those the task doesn't
    ///     involve otherwise come last, in id order.
    static func participants(of card: ProjectedCard,
                             threadParticipants: [CodePointKey: [String]],
                             standaloneAuthors: [String: [String]],
                             directMembers: Set<String>) -> [String] {
        let own = if let threadID = card.threadID {
            threadParticipants[CodePointKey(threadID)]
        } else {
            standaloneAuthors[card.id]
        }
        return (own ?? []).appendingNew(directMembers.sorted())
    }
    
    /// Matrix user ids as the Android client accepts them: `@`, a localpart without ASCII whitespace, `:`, a host of
    /// `[A-Za-z0-9.-]`, an optional port of 2 to 5 digits, at most 255 UTF-16 code units in all.
    static func isUserID(_ value: String) -> Bool {
        guard value.unicodeScalars.first == "@", value.utf16Length <= 255 else { return false }
        let scalars = Array(value.unicodeScalars.dropFirst())
        // The localpart may hold colons itself, so any colon can start the server name.
        for (index, scalar) in scalars.enumerated() where scalar == ":" {
            if scalars[..<index].contains(where: \.isASCIIWhitespace) {
                return false
            }
            if isServerName(scalars[(index + 1)...]) {
                return true
            }
        }
        return false
    }
    
    private static func isServerName(_ scalars: ArraySlice<Unicode.Scalar>) -> Bool {
        let parts = scalars.split(separator: ":", omittingEmptySubsequences: false)
        guard let host = parts.first, !host.isEmpty, host.allSatisfy({ $0.isASCIIAlphanumeric || $0 == "." || $0 == "-" }) else { return false }
        switch parts.count {
        case 1: return true
        case 2: return (2...5).contains(parts[1].count) && parts[1].allSatisfy { ("0"..."9").contains($0) }
        default: return false
        }
    }
}

public extension ProjectedCard {
    /// On a chat's board, a task shared with the chat is shown to everyone, any other only to the people it involves.
    func isShownOnBoard(userID: String) -> Bool {
        showToRoom || orderedParticipants.contains(userID)
    }
}

// ponytail: a linear search, so quadratic in a thread's repliers; keep a set beside the array if threads reach thousands of them.
extension Array where Element: Equatable {
    /// Appends `element` unless it is there already.
    mutating func appendNew(_ element: Element) {
        if !contains(element) {
            append(element)
        }
    }
    
    /// These elements, then those of `elements` not among them yet, each once.
    func appendingNew(_ elements: some Sequence<Element>) -> Self {
        elements.reduce(into: self) { $0.appendNew($1) }
    }
}

private extension RawEvent {
    var validSenderID: String? {
        senderID.flatMap { TaskParticipants.isUserID($0) ? $0 : nil }
    }
}
