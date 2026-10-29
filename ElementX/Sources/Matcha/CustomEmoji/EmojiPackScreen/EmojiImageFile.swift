//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ImageIO
import UniformTypeIdentifiers

/// A picked image as the emoji upload rules see it, read from the file's header without decoding it: an image's pixels can take far
/// more memory than its file.
nonisolated struct EmojiImageFile {
    let url: URL
    /// The type the content says it is, whatever the file's extension.
    let mimeType: String?
    let byteCount: Int
    /// The width and height as displayed, or nil when the file doesn't read as an image.
    let pixelSize: (width: Int, height: Int)?
    
    init(url: URL) {
        self.url = url
        byteCount = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        mimeType = source.flatMap(CGImageSourceGetType).flatMap { UTType($0 as String)?.preferredMIMEType }
        let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any]
        if let width = properties?[kCGImagePropertyPixelWidth] as? Int, let height = properties?[kCGImagePropertyPixelHeight] as? Int,
           width > 0, height > 0 {
            // Orientations 5 to 8 turn the image by a quarter.
            let isTurned = (properties?[kCGImagePropertyOrientation] as? Int).map { (5...8).contains($0) } ?? false
            pixelSize = isTurned ? (height, width) : (width, height)
        } else {
            pixelSize = nil
        }
    }
    
    /// The image redrawn as a JPEG without its metadata, upright: EXIF can say where a photo was taken, and pack images aren't encrypted.
    /// ponytail: as on web, only JPEGs are redrawn, since redrawing would stop an animated GIF, WebP or PNG.
    func jpegWithoutMetadata() -> Data? {
        guard let pixelSize, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(pixelSize.width, pixelSize.height)]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        // The web client's canvas encodes at 0.92 too.
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
