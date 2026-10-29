#!/bin/bash
# Copies the Matcha protocol conformance fixtures from the Android fork into this package's test resources; --check only compares.
# The source is MATCHA_FIXTURES_SOURCE, or the element-x-android checkout next to this repository or one of its parent
# directories, so a worktree kept elsewhere finds it too.
set -euo pipefail

package="$(cd "$(dirname "$0")/.." && pwd)"
source="${MATCHA_FIXTURES_SOURCE:-}"
directory="$package"
while [[ -z "$source" && "$directory" != "/" ]]; do
    directory="$(dirname "$directory")"
    [[ -f "$directory/element-x-android/docs/matcha/fixtures/SHA256SUMS" ]] && source="$directory/element-x-android/docs/matcha/fixtures"
done
[[ -n "$source" ]] || { echo "No element-x-android/docs/matcha/fixtures found; set MATCHA_FIXTURES_SOURCE" >&2; exit 1; }
target="$package/Tests/MatchaProtocolTests/Fixtures"

(cd "$source" && shasum -a 256 -c --quiet SHA256SUMS)
if [[ "${1:-}" == "--check" ]]; then
    diff -r "$source" "$target"
    echo "The fixtures match $source"
else
    rm -rf "$target"
    cp -R "$source" "$target"
    echo "Copied the fixtures from $source"
fi
