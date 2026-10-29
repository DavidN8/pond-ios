//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import MatchaProtocol
import Testing

/// The upload rules of the web client's `EmojiPackSettingsViewModel.test.ts`.
struct EmojiPackUploadsTests {
    @Test
    func acceptsPNGGIFWebPAndJPEGUpTo512KiBAnd1024Pixels() {
        for mimeType in ["image/png", "image/gif", "image/webp", "image/jpeg"] {
            #expect(ImagePacks.uploadProblem(mimeType: mimeType, byteCount: 512 * 1024, pixelSize: (1024, 1024)) == nil)
        }
    }
    
    @Test
    func checksTheTypeThenTheSizeThenTheDimensions() {
        #expect(ImagePacks.uploadProblem(mimeType: "text/plain", byteCount: 10, pixelSize: (64, 32)) == .type)
        #expect(ImagePacks.uploadProblem(mimeType: "image/heic", byteCount: 10, pixelSize: (64, 32)) == .type)
        #expect(ImagePacks.uploadProblem(mimeType: nil, byteCount: 10_000_000, pixelSize: nil) == .type)
        #expect(ImagePacks.uploadProblem(mimeType: "image/png", byteCount: 512 * 1024 + 1, pixelSize: (2000, 2000)) == .size)
        // A file that doesn't read as an image isn't really an image of its type.
        #expect(ImagePacks.uploadProblem(mimeType: "image/png", byteCount: 10, pixelSize: nil) == .type)
        #expect(ImagePacks.uploadProblem(mimeType: "image/png", byteCount: 10, pixelSize: (1025, 64)) == .dimensions)
        #expect(ImagePacks.uploadProblem(mimeType: "image/png", byteCount: 10, pixelSize: (64, 1025)) == .dimensions)
    }
    
    @Test
    func refusesUploadsThatWouldOverflowAPack() {
        let full = ImagePacks.packBytes(json(#"{"images": {"big": {"url": "mxc://server/big", "body": "\#(String(repeating: "x", count: 59800))"}}}"#))
        #expect(ImagePacks.isPackFull(packBytes: full, adding: 1))
        #expect(!ImagePacks.isPackFull(packBytes: ImagePacks.packBytes(nil), adding: 1))
        #expect(ImagePacks.packBytes(nil) == 2)
        #expect(ImagePacks.isPackFull(packBytes: 2, adding: 300))
    }
    
    @Test
    func addsUploadsWithInfoAndUniqueShortcodesKeepingEverythingElse() {
        let content = json(#"""
        {"pack": {"display_name": "Crew", "custom": 1}, "other_client_field": true,
         "images": {"wave": {"url": "mxc://server/wave"}, "hidden": {"url": "mxc://server/hidden", "usage": ["sticker"]},
                    "broken": {"url": "https://example.org/broken.png"}}}
        """#)
        
        let result = ImagePacks.withUploadedEmojis(content, [upload("wave.gif", "wavegif", mimeType: "image/gif", size: 300),
                                                             upload("wave.gif", "wavegif2", mimeType: "image/gif", size: 400),
                                                             upload("hidden!.webp", "hidden", mimeType: "image/webp")])
        
        #expect(result == json(#"""
        {"pack": {"display_name": "Crew", "custom": 1}, "other_client_field": true,
         "images": {"wave": {"url": "mxc://server/wave"}, "hidden": {"url": "mxc://server/hidden", "usage": ["sticker"]},
                    "broken": {"url": "https://example.org/broken.png"},
                    "wave_2": {"url": "mxc://server/wavegif", "info": {"w": 64, "h": 32, "mimetype": "image/gif", "size": 300}, "usage": ["emoticon"]},
                    "wave_3": {"url": "mxc://server/wavegif2", "info": {"w": 64, "h": 32, "mimetype": "image/gif", "size": 400}, "usage": ["emoticon"]},
                    "hidden_2": {"url": "mxc://server/hidden", "info": {"w": 64, "h": 32, "mimetype": "image/webp", "size": 10}, "usage": ["emoticon"]}}}
        """#))
    }
    
    @Test(arguments: [#"{"usage": ["sticker"]}"#, #"{"usage": ["sticker", "emoticon"]}"#, #"{"usage": []}"#, "{}"])
    func marksNewEmojiAsEmoticonsWhateverThePackSays(pack: String) {
        let content = json(#"{"images": {"both": {"url": "mxc://server/both"}}, "pack": \#(pack)}"#)
        
        let result = ImagePacks.withUploadedEmojis(content, [upload("cat.png", "cat")])
        
        #expect(result.objectValue?.object("images")?["cat"]?.objectValue?["usage"] == json(#"["emoticon"]"#))
        #expect(result.objectValue?.object("images")?["both"] == json(#"{"url": "mxc://server/both"}"#))
        #expect(ImagePacks.parseEmojiImages(result).map(\.shortcode).contains("cat"))
        #expect(!ImagePacks.parseImages(result, usage: .sticker).map(\.shortcode).contains("cat"))
    }
    
    @Test(arguments: [#"{"usage": ["emoticon"]}"#, "{}"])
    func marksNewStickersAsStickersWhateverThePackSays(pack: String) {
        let content = json(#"{"pack": \#(pack)}"#)
        
        let result = ImagePacks.withUploadedEmojis(content, [upload("pepe_happy.webp", "pepe", mimeType: "image/webp")], usage: .sticker)
        
        #expect(result.objectValue?.object("images")?["pepe_happy"]?.objectValue?["usage"] == json(#"["sticker"]"#))
        #expect(ImagePacks.parseImages(result, usage: .sticker) == [CustomEmoji(shortcode: "pepe_happy", url: "mxc://server/pepe",
                                                                                info: .init(width: 64, height: 32, mimeType: "image/webp", size: 10))])
        #expect(ImagePacks.parseEmojiImages(result) == [])
    }
    
    @Test
    func startsAPackFromNothing() {
        #expect(ImagePacks.withUploadedEmojis(nil, [upload("smile.png", "smilepng")]) == json(#"""
        {"images": {"smile": {"url": "mxc://server/smilepng", "info": {"w": 64, "h": 32, "mimetype": "image/png", "size": 10}, "usage": ["emoticon"]}}}
        """#))
    }
    
    // MARK: - Helpers
    
    private func upload(_ fileName: String, _ mediaID: String, mimeType: String = "image/png", size: Int = 10) -> UploadedEmoji {
        UploadedEmoji(fileName: fileName, url: "mxc://server/\(mediaID)", width: 64, height: 32, mimeType: mimeType, size: size)
    }
}

private func json(_ text: String) -> JSONValue {
    guard let value = JSONValue(json: text) else {
        Issue.record("Invalid JSON in a test: \(text)")
        return .null
    }
    return value
}
