import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import iClipboard

final class ToolImageTests: XCTestCase {
    func testDecodeSamplesAllFourCornersUsingTopLeftPixelCoordinates() throws {
        let image = try cornerImage()
        let decoded = try ToolImage.decode(encode(image, as: .png), title: "Corners")

        XCTAssertEqual(decoded.pixelSize, CGSize(width: 3, height: 2))
        XCTAssertEqual(decoded.title, "Corners")
        XCTAssertTrue(decoded.isOriginal)
        assertColor(decoded.color(at: CGPoint(x: 0, y: 0)), red: 255, green: 0, blue: 0)
        assertColor(decoded.color(at: CGPoint(x: 2, y: 0)), red: 0, green: 255, blue: 0)
        assertColor(decoded.color(at: CGPoint(x: 0, y: 1)), red: 0, green: 0, blue: 255)
        assertColor(decoded.color(at: CGPoint(x: 2, y: 1)), red: 255, green: 255, blue: 0)
        assertColor(decoded.color(at: CGPoint(x: 0.99, y: 0.99)), red: 255, green: 0, blue: 0)
        assertColor(decoded.color(at: CGPoint(x: 2.99, y: 1.99)), red: 255, green: 255, blue: 0)
    }

    func testSamplingRejectsCoordinatesOutsidePixelBounds() throws {
        let image = ToolImage(cgImage: try cornerImage())
        for point in [
            CGPoint(x: -0.01, y: 0), CGPoint(x: 0, y: -0.01),
            CGPoint(x: 3, y: 0), CGPoint(x: 0, y: 2),
            CGPoint(x: 30, y: 20)
        ] {
            XCTAssertNil(image.color(at: point), "Out-of-bounds sample at \(point)")
        }
    }

    func testPNGEncodingRoundTripPreservesSizeAndTransparentAlpha() throws {
        let bitmap = try bitmap(width: 4, height: 3)
        let translucent = NSColor(deviceRed: 0.2, green: 0.4, blue: 0.8, alpha: 0.5)
        for y in 0..<3 {
            for x in 0..<4 { bitmap.setColor(translucent, atX: x, y: y) }
        }
        bitmap.setColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0), atX: 3, y: 2)
        let image = ToolImage(cgImage: try sRGBImage(from: bitmap))
        let data = try image.pngData()
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier)

        let decoded = try ToolImage.decode(data, title: "Preview", isOriginal: false)
        XCTAssertEqual(decoded.pixelSize, CGSize(width: 4, height: 3))
        XCTAssertEqual(decoded.title, "Preview")
        XCTAssertFalse(decoded.isOriginal)
        assertColor(decoded.color(at: CGPoint(x: 0, y: 0)), red: 51, green: 102, blue: 204,
                    alpha: 0.5, tolerance: 2)
        XCTAssertEqual(try XCTUnwrap(decoded.color(at: CGPoint(x: 3, y: 2))).alpha, 0)

        let second = try ToolImage.decode(decoded.pngData())
        assertColor(second.color(at: CGPoint(x: 0, y: 0)), red: 51, green: 102, blue: 204,
                    alpha: 0.5, tolerance: 2)
        XCTAssertEqual(try XCTUnwrap(second.color(at: CGPoint(x: 3, y: 2))).alpha, 0)
    }

    func testSamplingConvertsDisplayP3ColorsToSRGB() throws {
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let srgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let color = try XCTUnwrap(CGColor(colorSpace: p3, components: [0.6, 0.4, 0.2, 1]))
        let converted = try XCTUnwrap(color.converted(to: srgb, intent: .relativeColorimetric, options: nil))
        let components = try XCTUnwrap(converted.components)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: p3, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                CGBitmapInfo.byteOrder32Big.rawValue
        ))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = ToolImage(cgImage: try XCTUnwrap(context.makeImage()))
        let sample = try XCTUnwrap(image.color(at: .zero))

        assertColor(sample, red: Int((components[0] * 255).rounded()),
                    green: Int((components[1] * 255).rounded()),
                    blue: Int((components[2] * 255).rounded()), tolerance: 3)
        XCTAssertGreaterThan(abs(sample.blue - 51), 5,
                             "The sampler must convert the source profile, not return raw P3 components")
    }

    func testSamplingDoesNotAssumeSourceChannelOrderOrAlphaLayout() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let layouts: [UInt32] = [
            CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue,
            CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue,
            CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ]
        for layout in layouts {
            let context = try XCTUnwrap(CGContext(
                data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: layout
            ))
            context.setFillColor(try XCTUnwrap(CGColor(colorSpace: space, components: [0.2, 0.4, 0.8, 1])))
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            let image = ToolImage(cgImage: try XCTUnwrap(context.makeImage()))
            assertColor(image.color(at: .zero), red: 51, green: 102, blue: 204)
        }
    }

    func testDecodeAppliesOrientationBeforeSamplingPixels() throws {
        let data = try encode(cornerImage(), as: .tiff,
                              properties: [kCGImagePropertyOrientation: 6])
        let image = try ToolImage.decode(data)

        XCTAssertEqual(image.pixelSize, CGSize(width: 2, height: 3))
        assertColor(image.color(at: CGPoint(x: 0, y: 0)), red: 0, green: 0, blue: 255)
        assertColor(image.color(at: CGPoint(x: 1, y: 0)), red: 255, green: 0, blue: 0)
        assertColor(image.color(at: CGPoint(x: 0, y: 2)), red: 255, green: 255, blue: 0)
        assertColor(image.color(at: CGPoint(x: 1, y: 2)), red: 0, green: 255, blue: 0)
    }

    func testDecodeRejectsEmptyAndNonImageData() {
        for data in [Data(), Data("not an image".utf8)] {
            XCTAssertThrowsError(try ToolImage.decode(data)) { error in
                guard let imageError = error as? ImageToolsError,
                      case .invalidImage = imageError else {
                    return XCTFail("Expected invalidImage, got \(error)")
                }
            }
        }
    }

    private func cornerImage() throws -> CGImage {
        let bitmap = try bitmap(width: 3, height: 2)
        for y in 0..<2 {
            for x in 0..<3 {
                bitmap.setColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1), atX: x, y: y)
            }
        }
        bitmap.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: 0, y: 0)
        bitmap.setColor(NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1), atX: 2, y: 0)
        bitmap.setColor(NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1), atX: 0, y: 1)
        bitmap.setColor(NSColor(deviceRed: 1, green: 1, blue: 0, alpha: 1), atX: 2, y: 1)
        return try sRGBImage(from: bitmap)
    }

    private func bitmap(width: Int, height: Int) throws -> NSBitmapImageRep {
        try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bitmapFormat: .alphaNonpremultiplied,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
    }

    private func sRGBImage(from bitmap: NSBitmapImageRep) throws -> CGImage {
        let image = try XCTUnwrap(bitmap.cgImage)
        return try XCTUnwrap(image.copy(colorSpace: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))))
    }

    private func encode(_ image: CGImage, as type: UTType,
                        properties: [CFString: Any] = [:]) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func assertColor(_ color: SampledImageColor?, red: Int, green: Int, blue: Int,
                             alpha: Double = 1, tolerance: Double = 1,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let color else { return XCTFail("Missing sampled color", file: file, line: line) }
        XCTAssertEqual(Double(color.red), Double(red), accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(Double(color.green), Double(green), accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(Double(color.blue), Double(blue), accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(color.alpha, alpha, accuracy: 1.0 / 255, file: file, line: line)
    }
}
