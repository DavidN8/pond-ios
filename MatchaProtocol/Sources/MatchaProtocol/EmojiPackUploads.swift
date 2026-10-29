//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// Why an image can't become a custom emoji, in the order the web client's `EmojiPackSettingsViewModel` checks.
public enum EmojiUploadProblem: Error, Equatable, Sendable {
    /// Not a PNG, GIF, WebP or JPEG image, or not readable as one.
    case type
    /// Over 512 KiB.
    case size
    /// Wider or taller than 1024 pixels.
    case dimensions
}

/// An image uploaded for a pack, to be added under a shortcode made from its file name.
public struct UploadedEmoji: Sendable, Equatable {
    public let fileName: String
    /// The mxc URL of the upload.
    public let url: String
    public let width: Int
    public let height: Int
    public let mimeType: String
    /// The uploaded bytes, which differ from the file's for a redrawn JPEG.
    public let size: Int
    
    public init(fileName: String, url: String, width: Int, height: Int, mimeType: String, size: Int) {
        self.fileName = fileName
        self.url = url
        self.width = width
        self.height = height
        self.mimeType = mimeType
        self.size = size
    }
}

/// The upload rules of the web client's `EmojiPackSettingsViewModel.ts`.
public extension ImagePacks {
    static let acceptedEmojiMimeTypes: Set = ["image/png", "image/gif", "image/webp", "image/jpeg"]
    static let maxEmojiFileSize = 512 * 1024
    /// Widest or tallest image Matcha uploads: every viewer decodes the full image.
    static let maxEmojiDimension = 1024
    /// Room state events are limited to 64 KiB; this leaves room for the rest of the event.
    static let maxPackBytes = 60000
    /// A generous size for one more image entry with its info, to refuse uploads into a full pack before uploading.
    static let imageEntryBytes = 200
    
    /// The first rule an image breaks, if any.
    /// - Parameter pixelSize: the image's width and height, or nil when it can't be read as an image.
    static func uploadProblem(mimeType: String?, byteCount: Int, pixelSize: (width: Int, height: Int)?) -> EmojiUploadProblem? {
        guard let mimeType, acceptedEmojiMimeTypes.contains(mimeType) else { return .type }
        guard byteCount <= maxEmojiFileSize else { return .size }
        guard let pixelSize else { return .type }
        guard pixelSize.width <= maxEmojiDimension, pixelSize.height <= maxEmojiDimension else { return .dimensions }
        return nil
    }
    
    /// The size of pack content as JSON, as the web client estimates it.
    static func packBytes(_ content: JSONValue?) -> Int {
        (content ?? .object([:])).jsonString.utf8.count
    }
    
    /// Whether a room pack of `packBytes` has no room for `count` more images. Account data packs aren't capped, as on web.
    static func isPackFull(packBytes: Int, adding count: Int) -> Bool {
        packBytes + count * imageEntryBytes > maxPackBytes
    }
    
    /// Pack content with the uploads added under new shortcodes made from their file names, never replacing an image. Each new
    /// image says what it is for, as the web client writes it, so an emoji upload never shows as a sticker and the reverse.
    static func withUploadedEmojis(_ content: JSONValue?, _ uploads: [UploadedEmoji], usage: ImageUsage = .emoticon) -> JSONValue {
        var result = content ?? .object([:])
        var taken = Set((result.objectValue?.object("images") ?? [:]).keys)
        for upload in uploads {
            let shortcode = shortcodeFromFileName(upload.fileName, taken: taken)
            taken.insert(shortcode)
            let image: JSONObject = ["url": .string(upload.url),
                                     "info": .object(["w": .integer(Int64(upload.width)),
                                                      "h": .integer(Int64(upload.height)),
                                                      "mimetype": .string(upload.mimeType),
                                                      "size": .integer(Int64(upload.size))]),
                                     "usage": .array([.string(usage.rawValue)])]
            result = withImage(result, shortcode: shortcode, image: .object(image))
        }
        return result
    }
}
