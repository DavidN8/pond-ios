//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

/// Tells the editor's own edits coming back from the document apart from changes made elsewhere. The editor sees the document a
/// moment late, so while someone types fast the document text lags behind the field.
struct EditEchoes {
    private var confirmed: String
    private var pending: [String] = []
    
    init(_ confirmed: String) {
        self.confirmed = confirmed
    }
    
    /// The field now shows `text` and sent the edit that leads to it.
    mutating func sent(_ text: String) {
        pending.append(text)
    }
    
    /// True when `documentText` only confirms edits the field already shows, while newer ones are still on their way.
    mutating func isBehindField(_ documentText: String) -> Bool {
        if let index = pending.firstIndex(of: documentText) {
            pending.removeFirst(index + 1)
            confirmed = documentText
        }
        return !pending.isEmpty && documentText == confirmed
    }
    
    /// The field takes the document text as it is.
    mutating func reset(_ documentText: String) {
        pending = []
        confirmed = documentText
    }
}
