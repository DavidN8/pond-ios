#!/usr/bin/env bash
# Builds the Matcha-patched Rust SDK for iOS and points element-x-ios at it by local path
# (MATCHA_PLATFORMS_PLAN.md 3.1, decision 7: local path now, version tags later).
#
#   ./build-ios-sdk.sh --check-only   no Xcode needed: preflight, host build, binding check
#   ./build-ios-sdk.sh                needs Xcode 27 (xcodebuild, iOS SDKs), xcodegen and sourcery
#
# While Xcode is unusable, run the check with the Command Line Tools:
#   DEVELOPER_DIR=/Library/Developer/CommandLineTools SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk \
#     ./build-ios-sdk.sh --check-only
#
# Layout (this directory):
#   matrix-rust-sdk/                branch matcha/26.10.24 = 8de215a0aa + element-x-android's
#                                   docs/matcha/rust-sdk/matcha-ffi-relations-json.patch
#   matrix-rust-components-swift/   tag 26.10.24; the directory name is the SwiftPM package identity,
#                                   so the local package overrides the released one for ElementCall too
#
# Undo the iOS side (back to the released 26.10.24 package):
#   rm "$IOS/matrix-rust-components-swift" && git -C "$IOS" checkout project.yml ElementX.xcodeproj Components/SDKMocks
#   git -C matrix-rust-components-swift checkout . && rm -rf matrix-rust-components-swift/MatrixSDKFFI.xcframework
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
SDK=$ROOT/matrix-rust-sdk
COMPONENTS=$ROOT/matrix-rust-components-swift
IOS=${IOS:-$(cd "$ROOT/../element-x-ios" && pwd)}
PIN=26.10.24
SDK_BRANCH=matcha/$PIN
SDK_BASE=8de215a0aa0026afa5754ae5f05a6d168d1a1d60
# small-release is what upstream's components release builds (Release.swift: build-framework --release). Don't use
# Android's small-release-stripped (LTO): it inlines rusqlite into other crates, which xtask's SQLite symbol
# localisation doesn't merge, and the app then fails to link with undefined _sqlite3_* symbols.
PROFILE=${PROFILE:-small-release}
TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim)

step() { printf '\n== %s\n' "$*"; }

# Upstream's API must come through untouched; the patch only adds the two Room methods and RelationsJsonPage.
check_bindings() { # $1: a directory of generated Swift. Test: ./test-check-bindings.sh
  local f s files removed=0
  files=$(git -C "$COMPONENTS" ls-tree --name-only "$PIN" Sources/MatrixRustSDK/) && [ -n "$files" ] ||
    { echo "error: no $PIN bindings in $COMPONENTS" >&2; exit 1; }
  for f in $files; do
    [ -f "$1/${f##*/}" ] || { echo "error: $1 has no ${f##*/}, which $PIN ships" >&2; exit 1; }
    removed=$((removed + $(diff <(git -C "$COMPONENTS" show "$PIN:$f") "$1/${f##*/}" | grep -c '^<' || true)))
  done
  [ "$removed" -eq 0 ] || { echo "error: $removed line(s) of the $PIN bindings changed or vanished" >&2; exit 1; }
  for s in 'func fetchRelationsJson(eventId: String, relationType: RelationType, from: String?, limit: UInt32)' \
    'func fetchStateEventContentJson(eventType: String, stateKey: String)' 'public struct RelationsJsonPage'; do
    grep -qF "$s" "$1/matrix_sdk_ffi.swift" || { echo "error: $1/matrix_sdk_ffi.swift lacks: $s" >&2; exit 1; }
  done
  echo "bindings OK: $PIN API unchanged, Matcha methods present"
}

step "Preflight"
[ "$(git -C "$SDK" rev-parse --abbrev-ref HEAD)" = "$SDK_BRANCH" ] || { echo "error: $SDK is not on $SDK_BRANCH" >&2; exit 1; }
git -C "$SDK" merge-base --is-ancestor "$SDK_BASE" HEAD || { echo "error: $SDK_BRANCH is not cut from $SDK_BASE" >&2; exit 1; }
# Release.swift records HEAD and the branch, so build only committed trees.
git -C "$SDK" diff --quiet HEAD ||{ echo "error: uncommitted changes in $SDK" >&2; exit 1; }
installed=$(rustup target list --installed)
for t in "${TARGETS[@]}"; do
  grep -qx "$t" <<<"$installed" || { echo "error: run rustup target add ${TARGETS[*]}" >&2; exit 1; }
done
echo "SDK $(git -C "$SDK" rev-parse HEAD) on $SDK_BRANCH, profile $PROFILE, iOS fork $IOS"

if [ "${1:-}" = "--check-only" ]; then
  step "Host build of matrix-sdk-ffi and Swift bindings (dev profile, no Xcode)"
  (cd "$SDK" && cargo xtask swift build-library)
  check_bindings "$SDK/bindings/apple/generated/swift"
  exit 0
fi

step "Build MatrixSDKFFI.xcframework into $COMPONENTS (cold: about 30-60 min for both targets)"
# unset SDKROOT: as upstream's Release.swift and build-sdk, a macOS SDKROOT breaks the iOS cross-builds.
(cd "$SDK" && env -u SDKROOT cargo xtask swift build-framework --profile "$PROFILE" \
  --target "${TARGETS[0]}" --target "${TARGETS[1]}" --components-path "$COMPONENTS")
check_bindings "$COMPONENTS/Sources/MatrixRustSDK"

step "Use the local xcframework in the components package"
# ponytail: working-tree edit only; Release.swift (version tags later) rewrites just the version and checksum lines.
sed -i '' 's|\.binaryTarget(name: "MatrixSDKFFI", url: url, checksum: checksum)|.binaryTarget(name: "MatrixSDKFFI", path: "MatrixSDKFFI.xcframework")|' \
  "$COMPONENTS/Package.swift"
grep -q 'path: "MatrixSDKFFI.xcframework"' "$COMPONENTS/Package.swift" ||
  { echo "error: could not point $COMPONENTS/Package.swift at the local xcframework" >&2; exit 1; }
grep -qx 'MatrixSDKFFI.xcframework' "$COMPONENTS/.git/info/exclude" || echo 'MatrixSDKFFI.xcframework' >>"$COMPONENTS/.git/info/exclude"

step "Point element-x-ios at it by local path"
link=$IOS/matrix-rust-components-swift # ignored by element-x-ios/.gitignore
if [ -L "$link" ] || [ ! -e "$link" ]; then ln -sfn "$COMPONENTS" "$link"; else echo "error: $link exists and is not a symlink" >&2; exit 1; fi
perl -0pi -e 's|(  MatrixRustSDK:\n)    url: https://github.com/element-hq/matrix-rust-components-swift\n    exactVersion: [^\n]+\n|${1}    path: matrix-rust-components-swift\n|' \
  "$IOS/project.yml"
grep -A1 '^  MatrixRustSDK:' "$IOS/project.yml" | grep -q 'path: matrix-rust-components-swift' ||
  { echo "error: $IOS/project.yml's MatrixRustSDK is neither element-hq's url/exactVersion nor the local path" >&2; exit 1; }
(cd "$IOS" && xcodegen)
(cd "$IOS" && sourcery --sources "$COMPONENTS/Sources/MatrixRustSDK" --templates Tools/Sourcery/SDKAutoMockable.stencil \
  --output Components/SDKMocks/Sources/Generated/SDKGeneratedMocks.swift)

step "Resolve packages (spike S3: one matrix-rust-components-swift, the local one)"
(cd "$IOS" && xcodebuild -resolvePackageDependencies -project ElementX.xcodeproj -scheme ElementX)
if grep -q 'element-hq/matrix-rust-components-swift' "$IOS/ElementX.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"; then
  echo "warning: Package.resolved still pins the released components package" >&2
fi

step "Sizes"
du -sh "$COMPONENTS/MatrixSDKFFI.xcframework" "$COMPONENTS"/MatrixSDKFFI.xcframework/*/libmatrix_sdk_ffi.a
echo "Done. Commit project.yml, ElementX.xcodeproj and Components/SDKMocks in $IOS when they look right."
