import AppKit

enum ImagePreviewLoader {
    static func thumbnailData(from url: URL, maxDimension: CGFloat = 320) -> Data? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        return thumbnailData(from: image, maxDimension: maxDimension)
    }

    static func thumbnailData(from data: Data, maxDimension: CGFloat = 320) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        return thumbnailData(from: image, maxDimension: maxDimension)
    }

    private static func thumbnailData(from image: NSImage, maxDimension: CGFloat) -> Data? {
        let targetSize = scaledSize(for: image.size, maxDimension: maxDimension)
        let thumbnail = NSImage(size: targetSize)
        thumbnail.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: targetSize), from: .zero, operation: .copy, fraction: 1.0)
        thumbnail.unlockFocus()
        
        guard let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }

    private static func scaledSize(for size: CGSize, maxDimension: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: maxDimension, height: maxDimension) }
        let scale = min(maxDimension / max(size.width, size.height), 1.0)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}
