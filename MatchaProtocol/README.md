# MatchaProtocol

The Matcha wire protocol in Swift, translated from the Android fork's `features/matcha/impl/.../protocol` and
`docs/DocsProtocol.kt`: thread metadata and the bootstrap reply, board pointers, card revisions and the board projection, task
participants and visibility, a room's threads and board as the store projects them (`RoomProjection`, which the board fixtures run,
like Android's `projectThreadsAndBoard`), reminder commands and local times, document frames, packet assembly and the catalog. Value types,
Swift 6 strict concurrency, Foundation and CryptoKit only: no UIKit, SwiftUI or Matrix SDK.

Event content is read with `JSONValue`, a strict JSON reader that drops invalid fields one by one like the other clients.
Foundation's readers would differ from them: `JSONSerialization` drops a leading U+FEFF from strings and `JSONDecoder` reads
`1.0` as an integer.

## Tests

```bash
swift test --package-path MatchaProtocol
```

Builds for macOS with the Command Line Tools' Swift 6.1 or Xcode. `FixtureTests` runs every protocol conformance fixture of
element-x-android `docs/matcha/fixtures` (copied to `Tests/MatchaProtocolTests/Fixtures`; their README explains the format) and
checks the copy against its `SHA256SUMS`. When an element-x-android checkout sits next to this repository or one of its
parent directories (so a worktree kept elsewhere finds it too), or `MATCHA_FIXTURES_SOURCE` names its fixtures directory, it
also checks that the copy is current; `Scripts/sync-fixtures.sh` looks in the same places.

After the fixtures change on Android, copy them again (`--check` only compares):

```bash
MatchaProtocol/Scripts/sync-fixtures.sh
```

For CI, a drift check that needs no Android checkout:
`curl -fsSL https://raw.githubusercontent.com/DavidN8/element-x-android/matcha/docs/matcha/fixtures/SHA256SUMS | diff - MatchaProtocol/Tests/MatchaProtocolTests/Fixtures/SHA256SUMS`.

## Using it in the app

`project.yml` lists the package next to `Compound` and the `ElementX` target depends on it, so the app and `UnitTests` can
`import MatchaProtocol`. `UnitTests.xctestplan` runs `MatchaProtocolTests` with the app's unit tests on the simulator; `swift test
--package-path MatchaProtocol` still runs them on macOS. The event types, limits and the reminder bot's localpart live in
`MatchaConfig` here; the app adds only its page sizes and timeouts (`ElementX/Sources/Matcha/MatchaConfig.swift`).
