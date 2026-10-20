import AppKit

/// AppKit global coordinates are bottom-up; image pixel coordinates are top-down.
/// Always use the delivered image size, not an assumed backing scale, for mapping.
struct ScreenCaptureGeometry {
    let displayFrame: CGRect
    let imageSize: CGSize

    private var isValid: Bool {
        displayFrame.width > 0 && displayFrame.height > 0 &&
            imageSize.width > 0 && imageSize.height > 0 &&
            [displayFrame.minX, displayFrame.minY, displayFrame.width, displayFrame.height,
             imageSize.width, imageSize.height].allSatisfy { $0.isFinite }
    }

    func clampedPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, displayFrame.minX), displayFrame.maxX),
                y: min(max(point.y, displayFrame.minY), displayFrame.maxY))
    }

    func selection(from start: CGPoint, to end: CGPoint) -> CGRect {
        let start = clampedPoint(start), end = clampedPoint(end)
        return CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                      width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    func moving(_ selection: CGRect, by delta: CGSize) -> CGRect {
        let selection = selection.standardized.intersection(displayFrame)
        guard !selection.isNull else { return .zero }
        return CGRect(x: min(max(selection.minX + delta.width, displayFrame.minX),
                             displayFrame.maxX - selection.width),
                      y: min(max(selection.minY + delta.height, displayFrame.minY),
                             displayFrame.maxY - selection.height),
                      width: selection.width, height: selection.height)
    }

    func pixelRect(for selection: CGRect) -> CGRect? {
        guard isValid, [selection.origin.x, selection.origin.y, selection.width, selection.height]
            .allSatisfy({ $0.isFinite }) else { return nil }
        let clipped = selection.standardized.intersection(displayFrame)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        let scaleX = imageSize.width / displayFrame.width
        let scaleY = imageSize.height / displayFrame.height
        let left = max(0, floor((clipped.minX - displayFrame.minX) * scaleX))
        let right = min(imageSize.width, ceil((clipped.maxX - displayFrame.minX) * scaleX))
        let top = max(0, floor((displayFrame.maxY - clipped.maxY) * scaleY))
        let bottom = min(imageSize.height, ceil((displayFrame.maxY - clipped.minY) * scaleY))
        guard right > left, bottom > top else { return nil }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    func pixelPoint(at point: CGPoint) -> CGPoint? {
        guard isValid, point.x.isFinite, point.y.isFinite else { return nil }
        let point = clampedPoint(point)
        return CGPoint(x: min(imageSize.width - 1,
                              floor((point.x - displayFrame.minX) * imageSize.width / displayFrame.width)),
                       y: min(imageSize.height - 1,
                              floor((displayFrame.maxY - point.y) * imageSize.height / displayFrame.height)))
    }

    /// The anchor describes the actual outward-rounded pixels returned to the caller.
    func appKitRect(forPixels pixels: CGRect) -> CGRect {
        CGRect(x: displayFrame.minX + pixels.minX * displayFrame.width / imageSize.width,
               y: displayFrame.maxY - pixels.maxY * displayFrame.height / imageSize.height,
               width: pixels.width * displayFrame.width / imageSize.width,
               height: pixels.height * displayFrame.height / imageSize.height)
    }
}

enum ScreenCaptureImageRenderer {
    /// Do not return CGImage.cropping: it can retain the entire screen's pixel provider.
    static func independentCrop(of image: CGImage, pixels: CGRect) throws -> CGImage {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let pixels = pixels.standardized.integral.intersection(bounds)
        guard !pixels.isNull, pixels.width > 0, pixels.height > 0 else {
            throw ScreenCaptureError.invalidFrame
        }
        let width = Int(pixels.width), height = Int(pixels.height)
        guard width <= ToolImage.maximumPixelCount / height else { throw ScreenCaptureError.tooManyPixels }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                        CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw ScreenCaptureError.invalidFrame
        }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: -pixels.minX,
                                      y: pixels.maxY - CGFloat(image.height),
                                      width: CGFloat(image.width), height: CGFloat(image.height)))
        guard let result = context.makeImage() else { throw ScreenCaptureError.invalidFrame }
        return result
    }
}
