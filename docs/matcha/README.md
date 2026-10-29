# Building POND's Rust SDK

POND (this `matcha` branch) links a patched matrix-rust-sdk. `matrix-rust-sdk-matcha.patch` is that patch: matrix-rust-sdk
commit `8de215a0aa0026afa5754ae5f05a6d168d1a1d60` plus two FFI `Room` methods that read raw relations and state events
(`fetchRelationsJson`, `fetchStateEventContentJson`). `build-ios-sdk.sh` builds `MatrixSDKFFI.xcframework` from it into a
local matrix-rust-components-swift (tag 26.10.24) and points this project at it. See MATCHA_IOS.md for the rest of the build.
