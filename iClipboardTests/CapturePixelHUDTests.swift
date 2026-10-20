import AppKit
import XCTest
@testable import iClipboard

@MainActor
final class CapturePixelHUDTests: XCTestCase {
    func testCenterAndLabelsUseTheSameTopDownSRGBSampleAsCopy() throws {
        let image = try cornerImage()
        let hud = CapturePixelHUD(frame: .zero)
        let pixel = CGPoint(x: 4.9, y: 4.2)
        hud.show(image: image, pixel: pixel, pointer: CGPoint(x: 300, y: 400), in: screenBounds)
        let sample = try XCTUnwrap(hud.sampledColor)
        XCTAssertEqual(sample, image.color(at: pixel))
        XCTAssertEqual(sample.hex, "#00FFFF")
        XCTAssertEqual(sample.rgb, "RGB(0, 255, 255)")
        let rendered = try render(hud)
        XCTAssertEqual(try color(in: rendered, at: CGPoint(x: 95, y: 118)), sample)
    }

    func testNineByNineLensKeepsAllFourCornersAndCenterInTopDownOrder() throws {
        let hud = CapturePixelHUD(frame: .zero)
        hud.show(image: try cornerImage(), pixel: CGPoint(x: 4, y: 4),
                 pointer: CGPoint(x: 300, y: 400), in: screenBounds)
        let rendered = try render(hud)
        for (point, hex) in [
            (CGPoint(x: 47, y: 166), "#FF0000"),
            (CGPoint(x: 143, y: 166), "#00FF00"),
            (CGPoint(x: 47, y: 70), "#0000FF"),
            (CGPoint(x: 143, y: 70), "#FFFF00"),
            (CGPoint(x: 95, y: 118), "#00FFFF")
        ] {
            XCTAssertEqual(try color(in: rendered, at: point).hex, hex, "Lens orientation at \(point)")
        }
        // Adjacent points within a magnified cell stay flat, with no interpolation.
        XCTAssertEqual(try color(in: rendered, at: CGPoint(x: 43, y: 163)).hex, "#FF0000")
        XCTAssertEqual(try color(in: rendered, at: CGPoint(x: 51, y: 169)).hex, "#FF0000")
    }

    func testEverySourceCornerRemainsCenteredAndMissingNeighborsAreCheckerboard() throws {
        let image = try cornerImage()
        let hud = CapturePixelHUD(frame: .zero)
        for pixel in [CGPoint.zero, CGPoint(x: 8, y: 0), CGPoint(x: 0, y: 8), CGPoint(x: 8, y: 8)] {
            hud.show(image: image, pixel: pixel, pointer: .zero, in: screenBounds)
            let rendered = try render(hud)
            XCTAssertEqual(try color(in: rendered, at: CGPoint(x: 95, y: 118)), image.color(at: pixel))
        }
        hud.show(image: image, pixel: .zero, pointer: .zero, in: screenBounds)
        let rendered = try render(hud)
        let missing = try color(in: rendered, at: CGPoint(x: 44, y: 166))
        XCTAssertGreaterThan(missing.red, 100)
        XCTAssertEqual(missing.red, missing.green)
        XCTAssertEqual(missing.green, missing.blue)
    }

    func testCardClampsAtEveryEdgeAndSupportsNonzeroBoundsOrigins() throws {
        let image = try cornerImage()
        let hud = CapturePixelHUD(frame: .zero)
        let bounds = CGRect(x: -700, y: -240, width: 960, height: 640)
        for pointer in [bounds.origin, CGPoint(x: bounds.maxX, y: bounds.maxY),
                        CGPoint(x: bounds.minX, y: bounds.maxY), CGPoint(x: bounds.maxX, y: bounds.minY)] {
            hud.show(image: image, pixel: .zero, pointer: pointer, in: bounds)
            XCTAssertEqual(hud.frame.size, CGSize(width: 190, height: 184))
            XCTAssertTrue(bounds.insetBy(dx: 8, dy: 8).contains(hud.frame))
        }
        let tiny = CGRect(x: 15, y: -30, width: 80, height: 45)
        hud.show(image: image, pixel: .zero, pointer: CGPoint(x: 500, y: 500), in: tiny)
        XCTAssertTrue(tiny.contains(hud.frame), "Even a smaller host cannot put the HUD outside its bounds")
    }

    func testTransparentPixelsExposeCheckerboardAndReportActualAlpha() throws {
        let image = try solidImage(red: 0, green: 0, blue: 0, alpha: 0)
        let hud = CapturePixelHUD(frame: .zero)
        hud.show(image: image, pixel: CGPoint(x: 4, y: 4), pointer: .zero, in: screenBounds)
        XCTAssertEqual(hud.sampledColor, image.color(at: CGPoint(x: 4, y: 4)))
        XCTAssertEqual(hud.sampledColor?.alpha, 0)
        let rendered = try render(hud)
        let dark = try color(in: rendered, at: CGPoint(x: 92, y: 115))
        let light = try color(in: rendered, at: CGPoint(x: 98, y: 115))
        XCTAssertNotEqual(dark, light)
        XCTAssertGreaterThan(dark.red, 100)
        XCTAssertGreaterThan(light.red, 100)
        XCTAssertEqual(dark.alpha, 1)
        XCTAssertEqual(light.alpha, 1)
    }

    func testTranslucentCenterReportsUnpremultipliedChannelsInsteadOfCheckerColor() throws {
        let image = try solidImage(red: 64, green: 128, blue: 240, alpha: 128)
        let hud = CapturePixelHUD(frame: .zero)
        hud.show(image: image, pixel: CGPoint(x: 4, y: 4), pointer: .zero, in: screenBounds)
        let sample = try XCTUnwrap(hud.sampledColor)
        XCTAssertEqual(sample, image.color(at: CGPoint(x: 4, y: 4)))
        XCTAssertEqual(sample.alpha, 128.0 / 255, accuracy: 1.0 / 255)
        let composited = try color(in: render(hud), at: CGPoint(x: 95, y: 118))
        XCTAssertNotEqual(composited, sample)
        XCTAssertEqual(composited.alpha, 1)
    }

    func testHUDNeverHitsCreatesWindowsOrChangesSourcePixels() throws {
        _ = NSApplication.shared
        let windows = Set(NSApp.windows.map(\.windowNumber))
        let image = try cornerImage()
        let originalBytes = try image.pngData()
        let hud = CapturePixelHUD(frame: .zero)
        hud.show(image: image, pixel: CGPoint(x: 4, y: 4), pointer: .zero, in: screenBounds)
        XCTAssertFalse(hud.isOpaque)
        XCTAssertFalse(hud.acceptsFirstResponder)
        XCTAssertNil(hud.hitTest(CGPoint(x: hud.frame.midX, y: hud.frame.midY)))
        XCTAssertNil(hud.shadow)
        XCTAssertNil(hud.layer?.shadowPath)
        XCTAssertNil(hud.window)
        _ = try render(hud)
        XCTAssertEqual(try image.pngData(), originalBytes)
        XCTAssertEqual(Set(NSApp.windows.map(\.windowNumber)), windows)
        hud.hide()
        XCTAssertTrue(hud.isHidden)
        XCTAssertNil(hud.sampledColor)
    }

    func testInvalidSamplesAndBoundsHidePreviousSampleWithoutTrapping() throws {
        let image = try cornerImage()
        let hud = CapturePixelHUD(frame: .zero)
        for pixel in [CGPoint(x: -1, y: 0), CGPoint(x: 9, y: 0), CGPoint(x: 0, y: 9),
                      CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: CGFloat.infinity, y: 0)] {
            hud.show(image: image, pixel: .zero, pointer: .zero, in: screenBounds)
            hud.show(image: image, pixel: pixel, pointer: .zero, in: screenBounds)
            XCTAssertTrue(hud.isHidden)
            XCTAssertNil(hud.sampledColor)
        }
        for bounds in [CGRect.zero, CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 400)] {
            hud.show(image: image, pixel: .zero, pointer: .zero, in: bounds)
            XCTAssertTrue(hud.isHidden)
        }
    }

    func testWorkspaceTracksGlobalPointerAndOptionWithoutSamplingEditingOrReanalysis() async throws {
        let (workspace, window, analyzer) = try makeWorkspace()
        defer { workspace.invalidate(); window.close() }
        _ = try await workspace.textInteraction.recognizedText()
        XCTAssertEqual(analyzer.calls, 1)
        let revision = workspace.session.revision
        let pixels = try workspace.session.currentFlattenedImage.pngData()
        let cursorInvalidations = workspace.canvasCursorInvalidationCount
        var actions = 0
        var samples = 0
        var pointers: [(CGPoint, NSEvent.ModifierFlags)] = []
        var exits = 0
        workspace.onAction = { _ in actions += 1 }
        workspace.onSamplePixel = { _ in samples += 1 }
        workspace.onPointerChanged = { pointers.append(($0, $1)) }
        workspace.onPointerExited = { exits += 1 }
        workspace.updateTrackingAreas()
        let tracking = try XCTUnwrap(workspace.trackingAreas.first { $0.owner === workspace })
        XCTAssertTrue(tracking.options.contains([.activeAlways, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate]))

        let point = CGPoint(x: 250, y: 280)
        workspace.mouseEntered(with: try mouse(.mouseEntered, point: point, in: window))
        workspace.mouseMoved(with: try mouse(.mouseMoved, point: point, in: window))
        let cursor = NSCursor.current
        workspace.cursorUpdate(with: try mouse(.cursorUpdate, point: point, in: window))
        XCTAssertEqual(NSCursor.current, cursor, "Workspace tracking must not replace Live Text's cursor")
        workspace.flagsChanged(with: try flags(.option, in: window))
        XCTAssertEqual(pointers.last?.0, window.convertPoint(toScreen: point))
        XCTAssertTrue(pointers.last?.1.contains(.option) == true)
        workspace.flagsChanged(with: try flags([], in: window))
        XCTAssertFalse(pointers.last?.1.contains(.option) == true)
        workspace.mouseExited(with: try mouse(.mouseExited, point: point, in: window))
        XCTAssertGreaterThan(exits, 0)
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(samples, 0)
        XCTAssertEqual(actions, 0)
        XCTAssertEqual(workspace.session.revision, revision)
        XCTAssertEqual(try workspace.session.currentFlattenedImage.pngData(), pixels)
        XCTAssertEqual(workspace.canvasCursorInvalidationCount, cursorInvalidations)
        XCTAssertEqual(analyzer.calls, 1, "Hover and Option changes reuse the single OCR analysis")
    }

    func testWorkspaceForwardsControlFlagsAndLeavesControlKeysUnhandled() throws {
        let (workspace, window, _) = try makeWorkspace()
        defer { workspace.invalidate(); window.close() }
        let responder = HUDRecordingResponder()
        workspace.nextResponder = responder
        workspace.mouseMoved(with: try mouse(.mouseMoved, point: CGPoint(x: 250, y: 280), in: window))
        workspace.flagsChanged(with: try flags(.control, in: window))
        XCTAssertEqual(responder.flags.count, 1)
        XCTAssertTrue(responder.flags[0].contains(.control))
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control,
                                               timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                               characters: "c", charactersIgnoringModifiers: "c",
                                               isARepeat: false, keyCode: 8))
        XCTAssertFalse(workspace.handleKey(key), "Control-C must remain a native key, not pixel copy")
    }

    func testWorkspaceControlsBusyAndInvalidationClearPreviewCallbacks() throws {
        let (workspace, window, _) = try makeWorkspace()
        defer { workspace.invalidate(); window.close() }
        let crop = CGPoint(x: 250, y: 280)
        let outside = CGPoint(x: 850, y: 500)
        XCTAssertTrue(workspace.canShowHUD(at: crop))
        XCTAssertTrue(workspace.canShowHUD(at: outside))
        let toolbar = CGPoint(x: workspace.toolbarFrame.midX, y: workspace.toolbarFrame.midY)
        XCTAssertFalse(workspace.canShowHUD(at: toolbar))
        XCTAssertFalse(workspace.canShowHUD(at: CGPoint(x: -1, y: 300)))
        var changes = 0
        var exits = 0
        workspace.onPointerChanged = { _, _ in changes += 1 }
        workspace.onPointerExited = { exits += 1 }
        workspace.mouseMoved(with: try mouse(.mouseMoved, point: toolbar, in: window))
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(exits, 1)
        workspace.setBusy(true)
        XCTAssertFalse(workspace.canShowHUD(at: crop))
        workspace.mouseMoved(with: try mouse(.mouseMoved, point: crop, in: window))
        XCTAssertEqual(changes, 0)
        workspace.setBusy(false)
        workspace.mouseMoved(with: try mouse(.mouseMoved, point: outside, in: window))
        XCTAssertEqual(changes, 1)
        workspace.updateTrackingAreas()
        workspace.invalidate()
        let finalExits = exits
        XCTAssertGreaterThan(finalExits, 1)
        XCTAssertNil(workspace.onPointerChanged)
        XCTAssertNil(workspace.onPointerExited)
        XCTAssertTrue(workspace.trackingAreas.isEmpty)
        workspace.updateTrackingAreas()
        workspace.mouseMoved(with: try mouse(.mouseMoved, point: crop, in: window))
        XCTAssertFalse(workspace.canShowHUD(at: crop))
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(exits, finalExits)
        XCTAssertTrue(workspace.trackingAreas.isEmpty)
    }

    private let screenBounds = CGRect(x: 0, y: 0, width: 960, height: 640)

    private func cornerImage() throws -> ToolImage {
        var bytes: [UInt8] = (0..<81).flatMap { _ -> [UInt8] in [0, 0, 0, 255] }
        let corners: [(Int, [UInt8])] = [(0, [255, 0, 0, 255]), (8, [0, 255, 0, 255]),
                                        (72, [0, 0, 255, 255]), (80, [255, 255, 0, 255]),
                                        (40, [0, 255, 255, 255])]
        for (index, rgba) in corners {
            bytes.replaceSubrange((index * 4)..<(index * 4 + 4), with: rgba)
        }
        return try toolImage(bytes)
    }

    private func solidImage(red: Int, green: Int, blue: Int, alpha: Int) throws -> ToolImage {
        try toolImage((0..<81).flatMap { _ in [UInt8(red), UInt8(green), UInt8(blue), UInt8(alpha)] })
    }

    private func toolImage(_ bytes: [UInt8]) throws -> ToolImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return ToolImage(cgImage: try XCTUnwrap(CGImage(width: 9, height: 9, bitsPerComponent: 8,
                                                       bitsPerPixel: 32, bytesPerRow: 36, space: space,
                                                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                                       provider: provider, decode: nil, shouldInterpolate: false,
                                                       intent: .defaultIntent)))
    }

    private func render(_ hud: CapturePixelHUD) throws -> ToolImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 190, height: 184, bitsPerComponent: 8,
                                              bytesPerRow: 190 * 4, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        hud.draw(hud.bounds)
        return ToolImage(cgImage: try XCTUnwrap(context.makeImage()))
    }

    private func color(in image: ToolImage, at point: CGPoint) throws -> SampledImageColor {
        try XCTUnwrap(image.color(at: CGPoint(x: point.x, y: image.pixelSize.height - point.y - 1)))
    }

    private func makeWorkspace() throws -> (ScreenCaptureWorkspace, NSWindow, HUDCountingAnalyzer) {
        let app = NSApplication.shared
        if !app.isRunning { app.finishLaunching() }
        let window = NSWindow(contentRect: CGRect(x: -500, y: 150, width: 960, height: 640),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let analyzer = HUDCountingAnalyzer()
        let interaction = InlineImageTextInteraction(analyzer: analyzer, fallbackRecognizer: HUDNeverFallback(),
                                                     debounceNanoseconds: 0)
        let rect = CGRect(x: 180, y: 200, width: 300, height: 200)
        let workspace = ScreenCaptureWorkspace(image: try cornerImage(), imageRect: rect, anchor: rect,
                                               bounds: screenBounds, textInteraction: interaction)
        window.contentView = workspace
        return (workspace, window, analyzer)
    }

    private func mouse(_ type: NSEvent.EventType, point: CGPoint, in window: NSWindow) throws -> NSEvent {
        if type == .mouseEntered || type == .mouseExited || type == .cursorUpdate {
            return try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [],
                                                        timestamp: 0, windowNumber: window.windowNumber,
                                                        context: nil, eventNumber: 1, trackingNumber: 1,
                                                        userData: nil))
        }
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil,
                                               eventNumber: 1, clickCount: 0, pressure: 0))
    }

    private func flags(_ flags: NSEvent.ModifierFlags, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: "",
                                      charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58))
    }
}

@MainActor
private final class HUDCountingAnalyzer: InlineImageTextAnalyzing {
    let isSupported = true
    var calls = 0
    func analyze(_ image: CGImage) async throws -> InlineImageTextAnalysis {
        calls += 1
        return InlineImageTextAnalysis(text: "One analysis", nativeAnalysis: nil)
    }
}

private struct HUDNeverFallback: TextRecognizer {
    func recognize(_ image: ToolImage) async throws -> ImageTextRecognitionResult {
        XCTFail("Hover must not start a second OCR recognizer")
        return ImageTextRecognitionResult(lines: [])
    }
}

@MainActor
private final class HUDRecordingResponder: NSResponder {
    var flags: [NSEvent.ModifierFlags] = []
    override func flagsChanged(with event: NSEvent) { flags.append(event.modifierFlags) }
}
