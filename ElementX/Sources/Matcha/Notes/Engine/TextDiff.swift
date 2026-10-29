//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// Turns a text field's edits into the smallest Yjs text changes, so characters other people may be editing keep their identity.
/// Everything is in UTF-16 code units, as in JavaScript and `NSString`.
///
/// ponytail: a common prefix and suffix, plus the split of a wrap (text kept between two insertions, as the formatting buttons do).
/// Edits that touch several separate places at once (prefixing many list lines) become one replacement; a character diff would
/// keep those identities too, if concurrent edits of reformatted lines turn out to matter.
nonisolated enum TextDiff {
    static func changes(from before: String, to after: String) -> [TextChange] {
        guard before != after else { return [] }
        let old = Array(before.utf16)
        let new = Array(after.utf16)
        let common = min(old.count, new.count)
        var prefix = 0
        while prefix < common, old[prefix] == new[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < common - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }
        // Never split a surrogate pair.
        if prefix > 0, UTF16.isLeadSurrogate(old[prefix - 1]) {
            prefix -= 1
        }
        if suffix > 0, UTF16.isTrailSurrogate(old[old.count - suffix]) {
            suffix -= 1
        }
        let removed = Array(old[prefix..<(old.count - suffix)])
        let inserted = Array(new[prefix..<(new.count - suffix)])
        if !removed.isEmpty, let kept = inserted.firstRange(of: removed)?.lowerBound {
            // A wrap: insert around the existing text instead of replacing it.
            let before = inserted[..<kept]
            let after = inserted[(kept + removed.count)...]
            return [before.isEmpty ? nil : TextChange(index: prefix, remove: 0, insert: string(before)),
                    after.isEmpty ? nil : TextChange(index: prefix + removed.count, remove: 0, insert: string(after))].compactMap { $0 }
        }
        return [TextChange(index: prefix, remove: removed.count, insert: string(inserted))]
    }
    
    /// Applies non-overlapping changes made against `text`.
    static func apply(_ changes: [TextChange], to text: String) -> String {
        let result = NSMutableString(string: text)
        for change in changes.sorted(by: { $0.index > $1.index }) {
            result.replaceCharacters(in: NSRange(location: change.index, length: change.remove), with: change.insert)
        }
        return result as String
    }
    
    /// Moves changes the user made against `base` onto `current`, which also contains edits that arrived meanwhile. A change that
    /// overlaps those edits is dropped: the remote edit wins and the field shows the merged text.
    static func rebase(_ changes: [TextChange], from base: String, onto current: String) -> [TextChange] {
        guard base != current else { return changes }
        let remote = self.changes(from: base, to: current)
        return changes.compactMap { change in
            var index = change.index
            for other in remote {
                if change.index + change.remove <= other.index {
                    continue
                } else if change.index >= other.index + other.remove {
                    index += other.insert.utf16.count - other.remove
                } else {
                    return nil
                }
            }
            var rebased = change
            rebased.index = index
            return rebased
        }
    }
    
    /// Where `offset` of the old text ends up after `changes`: a cursor at a remote insertion stays before it.
    static func mapOffset(_ offset: Int, through changes: [TextChange]) -> Int {
        var shift = 0
        for change in changes.sorted(by: { $0.index < $1.index }) {
            let isAtInsertion = change.remove == 0 && offset == change.index
            if offset < change.index || isAtInsertion {
                return offset + shift
            } else if offset >= change.index + change.remove {
                shift += change.insert.utf16.count - change.remove
            } else {
                return change.index + shift + change.insert.utf16.count
            }
        }
        return offset + shift
    }
    
    private static func string(_ units: some Collection<UTF16.CodeUnit>) -> String {
        String(utf16CodeUnits: Array(units), count: units.count)
    }
}
