import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ImagePreviewLoader {
    private static let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary

    static func thumbnailData(from url: URL, maxDimension: CGFloat = 320) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        return thumbnailData(from: source, maxDimension: maxDimension)
    }

    static func thumbnailData(from data: Data, maxDimension: CGFloat = 320) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        return thumbnailData(from: source, maxDimension: maxDimension)
    }

    static func previewImage(from data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              let image = thumbnail(from: source, maxDimension: 320) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private static func thumbnailData(from source: CGImageSource, maxDimension: CGFloat) -> Data? {
        guard let image = thumbnail(from: source, maxDimension: maxDimension) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func thumbnail(from source: CGImageSource, maxDimension: CGFloat) -> CGImage? {
        guard maxDimension.isFinite, maxDimension > 0 else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}
