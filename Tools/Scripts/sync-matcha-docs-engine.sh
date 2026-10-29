#!/bin/bash
# Copies the Matcha notes engine (engine.html, engine.js) from the Android fork into ElementX/Resources/MatchaDocs and records
# their checksums in MatchaDocsEngine.sha256.txt, which WebViewYjsEngineTests checks the app bundle against. --check only compares.
# The source is the sibling element-x-android checkout of this repository, or MATCHA_DOCS_ENGINE_SOURCE.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
source="${MATCHA_DOCS_ENGINE_SOURCE:-$root/../element-x-android/features/matcha/impl/src/main/assets/matcha-docs}"
target="$root/ElementX/Resources/MatchaDocs"

if [[ "${1:-}" == "--check" ]]; then
    for file in engine.html engine.js; do
        cmp "$source/$file" "$target/$file"
    done
    (cd "$target" && shasum -a 256 -c --quiet MatchaDocsEngine.sha256.txt)
    echo "The engine matches $source"
else
    cp "$source/engine.html" "$source/engine.js" "$target/"
    (cd "$target" && shasum -a 256 engine.html engine.js > MatchaDocsEngine.sha256.txt)
    echo "Copied the engine from $source"
fi
