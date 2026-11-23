import ImageIO
import UIKit
import UniformTypeIdentifiers
import os

/// A picture the reader chose for the chat, made small enough to keep: at most
/// 3000 pixels on its longest side, written as a JPEG.
///
/// Four ways in, in order of cost: the preview a camera photo already carries,
/// a full decode ImageIO scales on the way out, the whole image, and UIKit's
/// decoder. A ProRAW shot has a preview that opens where its full decode does
/// not, and a HEIC is only a name to the last one.
enum ChatBackgroundPicture {
    /// The ceiling on either side: nothing draws it larger than a screen.
    static let maxPixel: CGFloat = 3000

    private static let log = Logger(subsystem: "com.fluoxetine.luros", category: "ChatBackground")

    static var ceiling: CGSize {
        CGSize(width: maxPixel, height: maxPixel)
    }

    /// The picture's own bytes, decoded and re-encoded. Nil when no decoder
    /// takes the file at all.
    static func storedJPEG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else {
            log.error("ImageIO could not open the picture's data (\(data.count, privacy: .public) bytes)")
            return nil
        }
        let type = CGImageSourceGetType(source) as String? ?? "unknown"
        // The picture itself first: a camera file's embedded preview can be a
        // few hundred pixels wide, and taking it — as the first version of
        // this did — left a blurry background on a screen of thousands.
        if let image = decoded(source) {
            log.info("picture decoded from \(type, privacy: .public), \(image.width, privacy: .public)×\(image.height, privacy: .public)")
            return jpegData(image)
        }
        if let image = UIImage(data: data) {
            let scaled = image.preparingThumbnail(of: ceiling) ?? image
            log.info("picture decoded by UIImage from \(type, privacy: .public), \(Int(scaled.size.width), privacy: .public)×\(Int(scaled.size.height), privacy: .public)")
            return scaled.jpegData(compressionQuality: 0.88)
        }
        if let image = thumbnail(source) {
            log.error("only the picture's own preview could be read: \(image.width, privacy: .public)×\(image.height, privacy: .public) from \(type, privacy: .public)")
            return jpegData(image)
        }
        log.error("no decoder took the picture of type \(type, privacy: .public)")
        return nil
    }

    /// An image the picker handed over decoded, scaled to the same ceiling.
    static func storedJPEG(_ image: UIImage) -> Data? {
        let scaled = image.preparingThumbnail(of: ceiling) ?? image
        return scaled.jpegData(compressionQuality: 0.88)
    }

    /// What the file already holds: a camera's embedded preview, scaled to the
    /// ceiling if it is larger. A last resort — it is often much smaller than
    /// the picture beside it.
    private static func thumbnail(_ source: CGImageSource) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary)
    }

    /// The whole picture, decoded and scaled in one step: the way in that
    /// keeps the detail a full screen needs.
    private static func decoded(_ source: CGImageSource) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary)
    }

    private static func jpegData(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil,
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary,
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
