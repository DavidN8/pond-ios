# Matcha protocol conformance fixtures

Golden cases for the Matcha wire protocol, run by every client: Android (here), iOS (`MatchaProtocol` in the iOS fork) and,
later, web. They cover named-thread metadata and the hidden bootstrap reply, the kanban board pointer, card revisions and the
board projection (columns, archive, deadlines, `show_to_room`, participants), reminder commands and local times, and the documents
protocol (frames, chunk and commit rules, dedupe keys, the catalog), with malformed and edge cases.

## Format

Each `*.json` file tests one operation:

```json
{
    "op": "kanban.parse_card",
    "description": "What the operation computes, its inputs and its output.",
    "cases": [
        { "name": "a valid card with defaults", "input": { "rootId": "$board", "event": { "type": "…" } }, "expect": { "…": "…" } },
        { "name": "a blank title is refused", "input": { "…": "…" }, "error": "invalid_argument" }
    ]
}
```

- A case has either `expect` (the value computed, `null` included) or `error` (`invalid_argument`, `too_large`,
  `invalid_update`, `decrypt_error`). An optional `note` explains a case, for example a known disagreement with the web client.
- Events are raw Matrix events as the SDK hands them over: `type`, `event_id`, `sender`, `origin_server_ts`, `content`, and
  `unsigned.redacted_because` when redacted. A JSON object without a string `type` is not an event and is dropped.
- Event lists are newest first, as the room store holds them, except `docs.assemble`, which is oldest first.
- Lengths count UTF-16 code units. Trimming removes Unicode space separators, line and paragraph separators, and U+0009–U+000D
  and U+001C–U+001F (Kotlin's `trim()`); collapsing whitespace in a fallback thread name only collapses ASCII whitespace
  (`[ \t\n\x0B\f\r]`). Integers are JSON numbers without a fraction or exponent; `1.0` is not an integer.
- Sets (participants) are sorted. Objects compare as JSON values, so key order does not matter.

## Changing the protocol

Fixture first, then web, Android, iOS:

1. Add or change cases here, with the expected values the protocol should give.
2. Change the Android code until `MatchaFixturesTest` passes, or, for a change the Android code already makes, regenerate the
   expected values from it and review the diff:
   `MATCHA_FIXTURES_WRITE=1 ./gradlew :features:matcha:impl:testDebugUnitTest --tests '*MatchaFixturesTest*' --rerun`.
   This also rewrites `SHA256SUMS`, which `MatchaFixturesTest` checks too.
3. Copy the files to the other clients and make their runners pass: iOS runs
   `MatchaProtocol/Scripts/sync-fixtures.sh` in the iOS fork; web copies them to `apps/web/test/matcha-fixtures/`.

Copies check themselves with `shasum -a 256 -c SHA256SUMS`, and against this directory by comparing `SHA256SUMS`.
