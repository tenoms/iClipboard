import AppKit
import ImageIO
import UniformTypeIdentifiers

struct ToolImage {
    let cgImage: CGImage
    let title: String
    let isOriginal: Bool

    static let maximumPixelCount = 64_000_000

    init(cgImage: CGImage, title: String = "图片", isOriginal: Bool = true) {
        self.cgImage = cgImage
        self.title = title
        self.isOriginal = isOriginal
    }

    var pixelSize: CGSize {
        CGSize(width: cgImage.width, height: cgImage.height)
    }

    var nsImage: NSImage {
        NSImage(cgImage: cgImage, size: pixelSize)
    }

    static func decode(_ data: Data, title: String = "图片", isOriginal: Bool = true) throws -> ToolImage {
        let source = try validatedSource(data)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw ImageToolsError.invalidImage }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageToolsError.invalidImage
        }
        return ToolImage(cgImage: image, title: title, isOriginal: isOriginal)
    }

    /// Validate dimensions without allocating a full-resolution bitmap. Callers
    /// that only need a history preview decode at most 320 pixels on the long edge.
    static func validatedSource(_ data: Data) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw ImageToolsError.invalidImage }
        guard width <= maximumPixelCount / height else { throw ImageToolsError.imageTooLarge }
        return source
    }

    func pngData() throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ImageToolsError.encodingFailed
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImageToolsError.encodingFailed }
        return data as Data
    }

    static func pasteboardItem(pngData: Data, sourceFileURL: URL? = nil) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setData(pngData, forType: .png)
        if let url = sourceFileURL, url.isFileURL,
           FileManager.default.isReadableFile(atPath: url.path) {
            item.setString(url.absoluteString, forType: .fileURL)
        }
        return item
    }

    // Draw through a known sRGB format rather than assuming the source's channel layout.
    func color(at point: CGPoint) -> SampledImageColor? {
        let x = Int(floor(point.x)), y = Int(floor(point.y))
        guard x >= 0, y >= 0, x < cgImage.width, y < cgImage.height,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1,
                                          bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                            CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.interpolationQuality = .none
            context.translateBy(x: -CGFloat(x), y: CGFloat(y + 1 - cgImage.height))
            context.draw(cgImage, in: CGRect(origin: .zero, size: pixelSize))
            return true
        }
        guard rendered else { return nil }
        let alpha = Double(bytes[3]) / 255
        func channel(_ value: UInt8) -> Int {
            alpha > 0 ? min(255, Int((Double(value) / alpha).rounded())) : 0
        }
        return SampledImageColor(red: channel(bytes[0]), green: channel(bytes[1]),
                                 blue: channel(bytes[2]), alpha: alpha)
    }
}

struct SampledImageColor: Equatable {
    let red: Int
    let green: Int
    let blue: Int
    let alpha: Double

    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
    var rgb: String { "RGB(\(red), \(green), \(blue))" }
}

enum ImageToolsError: LocalizedError {
    case invalidImage
    case imageTooLarge
    case encodingFailed
    case noImage
    case clipboardWriteFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "无法读取这张图片，请使用 PNG、JPEG 或 TIFF 图片重试。"
        case .imageTooLarge: return "图片超过 6400 万像素，无法安全打开，请先缩小图片。"
        case .encodingFailed: return "无法编码图片，请重试。"
        case .noImage: return "剪贴板中没有可读取的图片。"
        case .clipboardWriteFailed: return "结果已保存到历史，但写入剪贴板失败，请重试复制。"
        }
    }
}
