//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import MatchaProtocol
import Testing

struct JSONValueTests {
    @Test(arguments: [
        (#"{"a": 1}"#, JSONValue.object(["a": .integer(1)])),
        (#" [1.0, -0, 1e3, 9223372036854775808] "#, .array([.number(1), .integer(0), .number(1000), .number(9_223_372_036_854_775_808)])),
        (#"[true, false, null]"#, .array([.bool(true), .bool(false), .null])),
        (#""﻿x""#, .string("\u{FEFF}x")),
        ("\"\u{FEFF}\"", .string("\u{FEFF}")),
        (#""é🚀\n\"\\\/""#, .string("é🚀\n\"\\/")),
        (#""\ud800x""#, .string("\u{FFFD}x")),
        (#"{"a": 1, "a": 2}"#, .object(["a": .integer(2)]))
    ])
    func readsJSONLikeTheOtherClients(json: String, value: JSONValue) {
        #expect(JSONValue(json: json) == value)
    }
    
    @Test(arguments: ["", "01", "1.", ".5", "+1", "[1,]", #"{"a" 1}"#, "{'a': 1}", "tru", "[1] x", "\"a\u{01}\"", #""\u12G4""#, #""\u+fff""#, "\u{FEFF}{}"])
    func refusesWhatIsNotJSON(json: String) {
        #expect(JSONValue(json: json) == nil)
    }
    
    @Test
    func refusesDeepNesting() {
        #expect(JSONValue(json: String(repeating: "[", count: 100) + String(repeating: "]", count: 100)) != nil)
        #expect(JSONValue(json: String(repeating: "[", count: 101) + String(repeating: "]", count: 101)) == nil)
        #expect(JSONValue(json: String(repeating: "[", count: 100_000)) == nil)
    }
    
    @Test
    func writesCompactJSONWithSortedKeysThatReadsBack() {
        let value = JSONValue.object(["b": .array([.integer(-1), .number(1.5), .null]), "a": .string("\"\u{01}\u{FEFF}é🚀/\n")])
        #expect(value.jsonString == #"{"a":"\"\u0001\#u{FEFF}é🚀/\n","b":[-1,1.5,null]}"#)
        #expect(JSONValue(json: value.jsonString) == value)
    }
}
