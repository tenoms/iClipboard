import AppKit
import CryptoKit
import Darwin
import Foundation
import ImageIO

/// Synthetic, process-isolated production-function probes. Never reads screen pixels,
/// user history, preferences or the system pasteboard.
@main
struct ImageToolsPerformance {
    static func main() throws {
        let mode = CommandLine.arguments[1]
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[2])
        if mode == "fixture" {
            let image = makeImage(size: 4096)
            let destination = CGImageDestinationCreateWithURL(fixtureURL as CFURL, "public.jpeg" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image.cgImage,
                                      [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { fatalError("Fixture encoding failed") }
            return
        }
        if mode == "capture" { try capture(fixtureURL); return }
        try render(mode: mode)
    }

    static func makeImage(size: Int) -> ToolImage {
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<size {
            for x in 0..<size {
                let offset = y * context.bytesPerRow + x * 4
                bytes[offset] = UInt8(truncatingIfNeeded: x * 31 + y * 17)
                bytes[offset + 1] = UInt8(truncatingIfNeeded: x * 7 + y * 23)
                bytes[offset + 2] = UInt8(truncatingIfNeeded: x * 13 + y * 11)
                bytes[offset + 3] = 255
            }
        }
        return ToolImage(cgImage: context.makeImage()!)
    }

    static func capture(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        try measure(scenario: "passive_capture", size: 4096, iterations: 5) {
            try autoreleasepool { () throws -> Int in
#if LEGACY_CAPTURE
                _ = try ToolImage.decode(data)
                let payload = CapturedPayload.image(data: data, title: "Fixture")
#else
                guard let payload = CapturedPayload.capturedImage(data: data, title: "Fixture") else {
                    fatalError("Capture rejected")
                }
#endif
                guard payload.originalImageData == data else { fatalError("Original encoding changed") }
                return payload.imageData!.count
            }
        }
    }

    static func render(mode: String) throws {
        let size = 2048
        let image = makeImage(size: size)
        let annotations = mode == "empty" ? [] : [ImageAnnotation(kind: .mosaic, points: [.zero, CGPoint(x: size, y: size)],
                                                                  mosaicBlockSize: 14)]
        if mode == "mosaic-digest" {
            let output = try ImageDocumentRenderer.render(original: image.cgImage, annotations: annotations)
            let digest = SHA256.hash(data: output.dataProvider!.data! as Data)
            print("mosaic_sha256=" + digest.map { String(format: "%02x", $0) }.joined())
            return
        }
        try measure(scenario: mode, size: size, iterations: mode == "empty" ? 30 : 5) {
            try autoreleasepool {
                try ImageDocumentRenderer.render(original: image.cgImage, annotations: annotations).width
            }
        }
    }

    static func measure(scenario: String, size: Int, iterations: Int, operation: () throws -> Int) throws {
        var before = rusage()
        getrusage(RUSAGE_SELF, &before)
        let start = ProcessInfo.processInfo.systemUptime
        var checksum = 0
        for _ in 0..<iterations { checksum += try operation() }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        var after = rusage()
        getrusage(RUSAGE_SELF, &after)
        func cpu(_ value: rusage) -> Double {
            Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) +
                Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
        }
        let report: [String: Any] = ["scenario": scenario, "size": size, "iterations": iterations,
                                   "wall_ms": elapsed * 1000, "cpu_ms": (cpu(after) - cpu(before)) * 1000,
                                   "max_rss_bytes": after.ru_maxrss, "checksum": checksum]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }
}
