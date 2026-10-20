import AppKit
import XCTest
@testable import iClipboard

@MainActor
final class ImageDocumentTests: XCTestCase {
    private func image(width: Int = 40, height: Int = 32,
                       pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8) = { _, _ in (0, 0, 0, 0) }) throws -> ToolImage {
        var bytes = [UInt8]()
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = pixel(x, y)
                bytes += [r, g, b, a]
            }
        }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let cgImage = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue |
                                                                    CGBitmapInfo.byteOrder32Big.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return ToolImage(cgImage: cgImage, title: "coordinate-fixture")
    }

    private func render(_ original: ToolImage, _ annotations: [ImageAnnotation]) throws -> ToolImage {
        ToolImage(cgImage: try ImageDocumentRenderer.render(original: original.cgImage, annotations: annotations))
    }

    private func color(_ image: ToolImage, _ x: Int, _ y: Int) throws -> SampledImageColor {
        try XCTUnwrap(image.color(at: CGPoint(x: x, y: y)))
    }

    private var red: ImageAnnotationStyle { ImageAnnotationStyle(red: 1, green: 0, blue: 0, alpha: 1, lineWidth: 2, fontSize: 16) }

    func testFitAndZoomUseTopLeftSourcePixels() {
        for zoom: CGFloat in [0.25, 1, 2, 4] {
            let transform = ImageCanvasTransform(pixelSize: CGSize(width: 100, height: 60),
                                                 viewportSize: CGSize(width: 400, height: 280), zoom: zoom)
            for pixel in [CGPoint.zero, CGPoint(x: 99, y: 0), CGPoint(x: 0, y: 59), CGPoint(x: 99, y: 59), CGPoint(x: 48.5, y: 27.25)] {
                let view = transform.viewPoint(fromPixel: pixel)
                let converted = transform.pixelPoint(fromView: view)
                XCTAssertEqual(converted?.x ?? -1, pixel.x, accuracy: 0.00001)
                XCTAssertEqual(converted?.y ?? -1, pixel.y, accuracy: 0.00001)
            }
            XCTAssertNil(transform.pixelPoint(fromView: CGPoint(x: -10, y: -10)))
            XCTAssertEqual(transform.pixelPoint(fromView: CGPoint(x: -10, y: -10), clamped: true), .zero)
        }
    }

    func testEmptyRenderAndUndoReuseOriginalBitmapWithoutAnotherFullSizeAllocation() throws {
        let source = try image()
        XCTAssertTrue(try ImageDocumentRenderer.render(original: source.cgImage, annotations: []) === source.cgImage)
        let session = ImageEditorSession(image: source)
        session.document.add(ImageAnnotation(kind: .line, points: [.zero, CGPoint(x: 20, y: 20)]))
        XCTAssertFalse(session.displayImage === source.cgImage)
        session.undo()
        XCTAssertTrue(session.displayImage === source.cgImage)
        XCTAssertTrue(session.currentFlattenedImage.cgImage === source.cgImage)
    }

    func testNewStrokePreviewReusesCommittedPixelsWithoutChangingExportBytes() throws {
        let source = try image(width: 64, height: 48) { x, y in
            (UInt8(x * 2), UInt8(y * 2), UInt8((x + y) % 128), 128)
        }
        let session = ImageEditorSession(image: source)
        session.document.add(ImageAnnotation(kind: .mosaic, points: [CGPoint(x: 2, y: 3), CGPoint(x: 40, y: 35)],
                                             mosaicBlockSize: 7))
        session.tool = .line
        session.pointerDown(at: CGPoint(x: 5, y: 8), tolerance: 1, clickCount: 1)
        session.pointerDragged(to: CGPoint(x: 50, y: 37))
        let preview = try XCTUnwrap(session.previewAnnotation)
        let expected = try ImageDocumentRenderer.render(original: source.cgImage,
                                                        annotations: session.document.annotations + [preview])
        XCTAssertEqual(session.displayImage.dataProvider?.data as Data?, expected.dataProvider?.data as Data?)
        session.pointerUp(at: CGPoint(x: 50, y: 37))
        XCTAssertEqual(session.currentFlattenedImage.cgImage.dataProvider?.data as Data?, expected.dataProvider?.data as Data?)
    }

    func testReusedPreviewPreservesWideGamutAndTranslucentSourcePixels() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 256,
            space: CGColorSpace(name: CGColorSpace.displayP3)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
                                     components: [0.65, 0.35, 0.2, 0.5])!)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let source = ToolImage(cgImage: try XCTUnwrap(context.makeImage()))
        let session = ImageEditorSession(image: source)
        session.document.add(ImageAnnotation(kind: .mosaic, points: [.zero, CGPoint(x: 40, y: 35)], mosaicBlockSize: 7))
        session.tool = .line
        session.pointerDown(at: CGPoint(x: 5, y: 8), tolerance: 1, clickCount: 1)
        session.pointerDragged(to: CGPoint(x: 50, y: 37))
        let expected = try ImageDocumentRenderer.render(original: source.cgImage,
            annotations: session.document.annotations + [XCTUnwrap(session.previewAnnotation)])
        XCTAssertEqual(session.displayImage.dataProvider?.data as Data?, expected.dataProvider?.data as Data?)
    }

    func testOverlappingUnmodifiedSavesKeepIndependentReceiptsWhenBitmapIsReused() throws {
        let editor = ImageEditorController(image: try image())
        defer { editor.close() }
        var images: [ToolImage] = []
        editor.onSave = { images.append($0) }
        editor.requestSave()
        editor.requestSave()
        XCTAssertEqual(images.count, 2)
        XCTAssertTrue(images[0].cgImage === images[1].cgImage)
        XCTAssertEqual(editor.pendingSaveCount, 2)
        editor.finishSave(image: images[0], succeeded: false)
        XCTAssertEqual(editor.pendingSaveCount, 1)
        editor.finishSave(image: images[1], succeeded: true)
        XCTAssertEqual(editor.pendingSaveCount, 0)
    }

    func testCornerColorsSurviveRenderWithoutVerticalFlip() throws {
        let original = try image(width: 6, height: 4) { x, y in
            if y == 0 { return x < 3 ? (255, 0, 0, 255) : (0, 255, 0, 255) }
            return x < 3 ? (0, 0, 255, 255) : (128, 128, 0, 128)
        }
        let output = try render(original, [])
        XCTAssertEqual(try color(output, 0, 0).hex, "#FF0000")
        XCTAssertEqual(try color(output, 5, 0).hex, "#00FF00")
        XCTAssertEqual(try color(output, 0, 3).hex, "#0000FF")
        XCTAssertEqual(try color(output, 5, 3).hex, "#FFFF00")
        XCTAssertEqual(try color(output, 5, 3).alpha, 128.0 / 255, accuracy: 0.001)
    }

    func testRectangleAndEllipseRenderAtRequestedTopLeftPixels() throws {
        let original = try image()
        let rectangle = ImageAnnotation(kind: .rectangle, points: [CGPoint(x: 3, y: 3), CGPoint(x: 13, y: 11)], style: red)
        let ellipse = ImageAnnotation(kind: .ellipse, points: [CGPoint(x: 20, y: 2), CGPoint(x: 34, y: 14)], style: red)
        let output = try render(original, [rectangle, ellipse])
        XCTAssertGreaterThan(try color(output, 7, 3).alpha, 0.9)
        XCTAssertGreaterThan(try color(output, 27, 2).alpha, 0.5)
        XCTAssertEqual(try color(output, 7, 7).alpha, 0)
        XCTAssertEqual(try color(output, 27, 8).alpha, 0)
        XCTAssertEqual(try color(output, 7, 28).alpha, 0)
    }

    func testLineArrowAndBrushAreActualStrokes() throws {
        let original = try image()
        let output = try render(original, [
            ImageAnnotation(kind: .line, points: [CGPoint(x: 2, y: 4), CGPoint(x: 16, y: 4)], style: red),
            ImageAnnotation(kind: .arrow, points: [CGPoint(x: 3, y: 13), CGPoint(x: 24, y: 13)], style: red),
            ImageAnnotation(kind: .brush, points: [CGPoint(x: 2, y: 22), CGPoint(x: 11, y: 22), CGPoint(x: 11, y: 28)], style: red)
        ])
        XCTAssertGreaterThan(try color(output, 8, 4).alpha, 0.9)
        XCTAssertGreaterThan(try color(output, 18, 10).alpha, 0.2, "Arrowhead must exist off the shaft")
        XCTAssertGreaterThan(try color(output, 6, 22).alpha, 0.9)
        XCTAssertGreaterThan(try color(output, 11, 26).alpha, 0.9)
        XCTAssertEqual(try color(output, 32, 25).alpha, 0)
    }

    func testBrushDotAndAlphaArePreserved() throws {
        let original = try image()
        var style = red
        style.lineWidth = 8
        style.alpha = 0.5
        let annotation = ImageAnnotation(kind: .brush, points: [CGPoint(x: 10, y: 8)], style: style)
        let output = try render(original, [annotation])
        XCTAssertEqual(try color(output, 10, 8).red, 255)
        XCTAssertEqual(try color(output, 10, 8).alpha, 0.5, accuracy: 0.01)
        XCTAssertEqual(try color(output, 10, 22).alpha, 0)
        XCTAssertEqual(try color(original, 10, 8).alpha, 0, "Original CGImage must remain immutable")
    }

    func testOpacityCompositesOverOpaqueSource() throws {
        let original = try image { _, _ in (255, 255, 255, 255) }
        var style = red
        style.lineWidth = 8
        style.alpha = 0.5
        let output = try render(original, [ImageAnnotation(kind: .line, points: [CGPoint(x: 3, y: 8), CGPoint(x: 20, y: 8)], style: style)])
        let sample = try color(output, 10, 8)
        XCTAssertEqual(sample.red, 255)
        XCTAssertEqual(sample.green, 127, accuracy: 2)
        XCTAssertEqual(sample.blue, 127, accuracy: 2)
        XCTAssertEqual(sample.alpha, 1)
    }

    func testTextRendersWithinTopLeftTextBounds() throws {
        let original = try image(width: 100, height: 80)
        let size = ImageDocumentRenderer.textSize("Hello\n世界", style: red, maximumWidth: 80)
        XCTAssertGreaterThan(size.height, red.fontSize * 1.5)
        let annotation = ImageAnnotation(kind: .text, points: [CGPoint(x: 4, y: 3)], style: red, text: "Hello\n世界", textSize: size)
        let output = try render(original, [annotation])
        var changed = 0
        for y in 3..<min(70, Int(ceil(size.height + 3))) {
            for x in 4..<min(90, Int(ceil(size.width + 4))) {
                if try color(output, x, y).alpha > 0 { changed += 1 }
            }
        }
        XCTAssertGreaterThan(changed, 20)
        XCTAssertEqual(try color(output, 2, 2).alpha, 0)
        XCTAssertEqual(try color(output, 30, 75).alpha, 0)
    }

    func testMosaicActuallyReplacesPixelsOnlyInsideRegion() throws {
        let original = try image(width: 12, height: 10) { x, y in
            (UInt8(x * 20), UInt8(y * 24), UInt8((x + y) * 10), 255)
        }
        let mosaic = ImageAnnotation(kind: .mosaic, points: [CGPoint(x: 2, y: 1), CGPoint(x: 8, y: 7)], mosaicBlockSize: 3)
        let output = try render(original, [mosaic])
        let first = try color(output, 2, 1)
        XCTAssertEqual(first, try color(output, 4, 3))
        XCTAssertNotEqual(first, try color(original, 2, 1))
        XCTAssertNotEqual(first, try color(output, 5, 1))
        for y in 0..<10 {
            for x in 0..<12 where !(2..<8).contains(x) || !(1..<7).contains(y) {
                XCTAssertEqual(try color(output, x, y), try color(original, x, y), "Mosaic leaked at \(x),\(y)")
            }
        }
        XCTAssertEqual(try color(original, 2, 1).red, 40)
    }

    func testMosaicFlattensPriorAnnotationsAndPreservesAlpha() throws {
        let original = try image(width: 8, height: 8)
        var style = red
        style.lineWidth = 2
        style.alpha = 0.5
        let dot = ImageAnnotation(kind: .brush, points: [CGPoint(x: 3, y: 3)], style: style)
        let region = ImageAnnotation(kind: .mosaic, points: [.zero, CGPoint(x: 8, y: 8)], mosaicBlockSize: 8)
        let output = try render(original, [dot, region])
        let corner = try color(output, 0, 0)
        XCTAssertGreaterThan(corner.alpha, 0)
        XCTAssertLessThan(corner.alpha, 0.1)
        XCTAssertEqual(corner.red, 255)
        XCTAssertEqual(corner, try color(output, 7, 7))
    }

    func testUndoRedoMoveDeleteAndNewBranch() throws {
        let document = ImageDocument(image: try image())
        let annotation = ImageAnnotation(kind: .rectangle, points: [CGPoint(x: 2, y: 2), CGPoint(x: 10, y: 10)], style: red)
        document.add(annotation)
        document.replace(annotation.translated(by: CGSize(width: 3, height: 4)))
        XCTAssertEqual(document.annotations.first?.bounds.origin, CGPoint(x: 5, y: 6))
        document.undo()
        XCTAssertEqual(document.annotations.first, annotation)
        document.redo()
        XCTAssertEqual(document.annotations.first?.bounds.origin, CGPoint(x: 5, y: 6))
        document.deleteSelected()
        XCTAssertTrue(document.annotations.isEmpty)
        document.undo()
        XCTAssertEqual(document.annotations.count, 1)
        document.add(ImageAnnotation(kind: .brush, points: [CGPoint(x: 20, y: 20)], style: red))
        XCTAssertFalse(document.canRedo)
        XCTAssertEqual(document.annotations.count, 2)
    }

    func testSelectionUsesTopmostAnnotationAndLineDistance() throws {
        let document = ImageDocument(image: try image())
        let line = ImageAnnotation(kind: .line, points: [CGPoint(x: 2, y: 2), CGPoint(x: 15, y: 15)], style: red)
        document.add(line)
        XCTAssertNil(document.annotation(at: CGPoint(x: 2, y: 15), tolerance: 1))
        XCTAssertEqual(document.annotation(at: CGPoint(x: 7, y: 7), tolerance: 1)?.id, line.id)
        let rectangle = ImageAnnotation(kind: .rectangle, points: [CGPoint(x: 3, y: 3), CGPoint(x: 12, y: 12)], style: red)
        document.add(rectangle)
        XCTAssertEqual(document.annotation(at: CGPoint(x: 7, y: 7), tolerance: 1)?.id, rectangle.id)
    }

    func testArrowheadIsSelectableAndIncludedInBounds() {
        let arrow = ImageAnnotation(kind: .arrow, points: [CGPoint(x: 2, y: 16), CGPoint(x: 32, y: 16)], style: red)
        XCTAssertTrue(arrow.contains(CGPoint(x: 24, y: 12), tolerance: 1))
        XCTAssertLessThan(arrow.bounds.minY, 16)
        XCTAssertGreaterThan(arrow.bounds.maxY, 16)
    }

    func testSelectingClippedTextDoesNotMoveIt() throws {
        let annotation = ImageAnnotation(kind: .text, points: [CGPoint(x: 4, y: 25)], style: red,
                                         text: "两行\\n文字", textSize: CGSize(width: 30, height: 40))
        let size = CGSize(width: 40, height: 32)
        XCTAssertEqual(annotation.translated(by: .zero, constrainedTo: size), annotation)
        let session = ImageEditorSession(image: try image())
        session.document.add(annotation)
        session.tool = .select
        session.pointerDown(at: CGPoint(x: 5, y: 26), tolerance: 1, clickCount: 1)
        session.pointerUp(at: CGPoint(x: 5, y: 26))
        XCTAssertEqual(session.document.annotations, [annotation])
        session.undo()
        XCTAssertTrue(session.document.annotations.isEmpty, "A click must not add a movement undo step")
    }

    func testSavedSnapshotDoesNotClearLaterEdits() throws {
        let document = ImageDocument(image: try image())
        document.add(ImageAnnotation(kind: .brush, points: [CGPoint(x: 3, y: 3)], style: red))
        let exportedState = document.annotations
        document.add(ImageAnnotation(kind: .brush, points: [CGPoint(x: 7, y: 7)], style: red))
        document.markSaved(annotations: exportedState)
        XCTAssertTrue(document.isModified)
        document.undo()
        XCTAssertFalse(document.isModified)
        document.undo()
        XCTAssertTrue(document.isModified)
    }

    func testFlattenedExportRetainsTitleAndPNGContainsMosaic() throws {
        let original = try image(width: 8, height: 8) { x, y in (UInt8(x * 30), UInt8(y * 30), 0, 255) }
        let document = ImageDocument(image: original)
        document.add(ImageAnnotation(kind: .mosaic, points: [.zero, CGPoint(x: 8, y: 8)], mosaicBlockSize: 8))
        let flattened = try document.renderedImage()
        XCTAssertEqual(flattened.title, original.title)
        let decoded = try ToolImage.decode(flattened.pngData())
        XCTAssertEqual(try color(decoded, 0, 0), try color(decoded, 7, 7))
        XCTAssertNotEqual(try color(decoded, 0, 0), try color(original, 0, 0))
        document.undo()
        XCTAssertEqual(try color(document.renderedImage(), 0, 0), try color(original, 0, 0))
        document.redo()
        XCTAssertEqual(try color(document.renderedImage(), 0, 0), try color(flattened, 0, 0))
    }

    func testRecognitionCropUsesTopLeftPixelsAndIndependentStorage() throws {
        let original = try image(width: 12, height: 10) { x, y in
            (UInt8(x * 20), UInt8(y * 24), UInt8((x + y) * 10), 255)
        }
        let document = ImageDocument(image: original)
        let crop = try document.renderedImage(croppedTo: CGRect(x: 2, y: 1, width: 5, height: 3))
        XCTAssertEqual(crop.pixelSize, CGSize(width: 5, height: 3))
        XCTAssertEqual(crop.title, original.title)
        for y in 0..<3 {
            for x in 0..<5 {
                XCTAssertEqual(try color(crop, x, y), try color(original, x + 2, y + 1))
            }
        }
        let storage = try XCTUnwrap(crop.cgImage.dataProvider?.data)
        XCTAssertEqual(CFDataGetLength(storage), crop.cgImage.bytesPerRow * 3)
        XCTAssertEqual(crop.cgImage.bytesPerRow, 5 * 4)
        XCTAssertThrowsError(try document.renderedImage(croppedTo: CGRect(x: 20, y: 20, width: 2, height: 2)))
    }

    func testRecognitionCropCannotSeeThroughMosaic() throws {
        let original = try image(width: 12, height: 10) { x, y in
            (UInt8(x * 20), UInt8(y * 24), UInt8((x + y) * 10), 255)
        }
        let document = ImageDocument(image: original)
        document.add(ImageAnnotation(kind: .mosaic, points: [CGPoint(x: 2, y: 1), CGPoint(x: 8, y: 7)], mosaicBlockSize: 3))
        let crop = try document.renderedImage(croppedTo: CGRect(x: 2, y: 1, width: 3, height: 3))
        XCTAssertEqual(try color(crop, 0, 0), try color(crop, 2, 2))
        XCTAssertNotEqual(try color(crop, 0, 0), try color(original, 2, 1))
        let decoded = try ToolImage.decode(crop.pngData())
        XCTAssertEqual(try color(decoded, 0, 0), try color(decoded, 2, 2))
    }

    func testFinishingSaveReleasesPendingStatesOnSuccessAndFailure() throws {
        _ = NSApplication.shared
        let editor = ImageEditorController(image: try image())
        defer { editor.close() }
        var exportedImage: ToolImage?
        editor.onSave = { exportedImage = $0 }
        editor.requestSave()
        XCTAssertEqual(editor.pendingSaveCount, 1)
        editor.finishSave(image: try XCTUnwrap(exportedImage), succeeded: false)
        XCTAssertEqual(editor.pendingSaveCount, 0)
        editor.markSaved()
        XCTAssertEqual(editor.pendingSaveCount, 0)
        editor.requestSave()
        XCTAssertEqual(editor.pendingSaveCount, 1)
        editor.markSaved(image: try XCTUnwrap(exportedImage))
        XCTAssertEqual(editor.pendingSaveCount, 0)
    }

    func testEditorGestureCommitsOneUndoStepAndSamplesFlattenedImage() throws {
        let session = ImageEditorSession(image: try image())
        session.tool = .brush
        session.pointerDown(at: CGPoint(x: 5, y: 5), tolerance: 1, clickCount: 1)
        for x in 6...18 { session.pointerDragged(to: CGPoint(x: x, y: 5)) }
        session.pointerUp(at: CGPoint(x: 18, y: 5))
        XCTAssertEqual(session.document.annotations.count, 1)
        session.tool = .eyedropper
        session.pointerDown(at: CGPoint(x: 10, y: 5), tolerance: 1, clickCount: 1)
        XCTAssertEqual(session.sampledColor?.hex, "#FF2E29")
        session.undo()
        XCTAssertTrue(session.document.annotations.isEmpty)
        XCTAssertFalse(session.document.canUndo)
        session.redo()
        XCTAssertEqual(session.document.annotations.count, 1)
    }

    private final class PixelNotifications {
        var willChange = 0
        var didChange = 0
    }

    private func observePixels(_ session: ImageEditorSession) -> PixelNotifications {
        let notifications = PixelNotifications()
        session.onPixelsWillChange = { notifications.willChange += 1 }
        session.onPixelsDidChange = { notifications.didChange += 1 }
        return notifications
    }

    func testBlankClicksZeroDistanceSelectionAndConstrainedMovesDoNotInvalidatePixels() throws {
        let session = ImageEditorSession(image: try image())
        let annotation = ImageAnnotation(kind: .rectangle, points: [.zero, CGPoint(x: 10, y: 10)], style: red)
        session.document.add(annotation)
        session.document.markSaved()
        session.tool = .select
        let revision = session.revision
        let notifications = observePixels(session)

        session.pointerDown(at: CGPoint(x: 30, y: 25), tolerance: 1, clickCount: 1)
        session.pointerUp(at: CGPoint(x: 30, y: 25))
        session.pointerDown(at: CGPoint(x: 5, y: 5), tolerance: 1, clickCount: 1)
        session.pointerUp(at: CGPoint(x: 5, y: 5))
        session.pointerDown(at: CGPoint(x: 5, y: 5), tolerance: 1, clickCount: 1)
        session.pointerDragged(to: CGPoint(x: -5, y: -5))
        session.pointerUp(at: CGPoint(x: -5, y: -5))
        session.moveSelection(by: .zero)
        session.moveSelection(by: CGSize(width: -10, height: -10))
        session.tool = .mosaic
        session.tool = .select
        session.cancelGesture()

        XCTAssertEqual(notifications.willChange, 0)
        XCTAssertEqual(notifications.didChange, 0)
        XCTAssertEqual(session.revision, revision)
        XCTAssertEqual(session.document.annotations, [annotation])
        XCTAssertFalse(session.document.isModified)
        session.undo()
        XCTAssertTrue(session.document.annotations.isEmpty, "No-op input must not enter undo history")
    }

    func testSameStyleAndNonPixelDefaultsDoNotInvalidatePixels() throws {
        let session = ImageEditorSession(image: try image())
        let annotation = ImageAnnotation(kind: .rectangle, points: [CGPoint(x: 2, y: 2), CGPoint(x: 10, y: 10)])
        session.document.add(annotation)
        let revision = session.revision
        let notifications = observePixels(session)
        session.changeStyle { _ in }
        session.changeStyle { $0.lineWidth = annotation.style.lineWidth }
        session.changeStyle { $0.setColor(annotation.style.nsColor) }
        session.changeStyle { $0.fontSize += 1 }
        XCTAssertEqual(session.document.annotations, [annotation], "Font size does not alter a rectangle's pixels")
        session.document.selectedID = nil
        session.changeStyle { $0.lineWidth += 2 }
        session.changeStyle { $0.setColor(.blue) }
        XCTAssertEqual(notifications.willChange, 0)
        XCTAssertEqual(notifications.didChange, 0)
        XCTAssertEqual(session.revision, revision)
        session.undo()
        XCTAssertTrue(session.document.annotations.isEmpty)
    }

    func testRealMoveInvalidatesBeforePreviewAndNotifiesOncePerCommitUndoAndRedo() throws {
        let session = ImageEditorSession(image: try image())
        let annotation = ImageAnnotation(kind: .rectangle, points: [CGPoint(x: 2, y: 2), CGPoint(x: 10, y: 10)], style: red)
        session.document.add(annotation)
        session.tool = .select
        let revision = session.revision
        let initialImage = session.displayImage
        let notifications = observePixels(session)
        session.onPixelsWillChange = {
            notifications.willChange += 1
            if notifications.willChange == 1 {
                XCTAssertTrue(session.displayImage === initialImage, "Invalidate old OCR before changing the preview")
                XCTAssertNil(session.previewAnnotation)
            }
        }
        session.pointerDown(at: CGPoint(x: 5, y: 5), tolerance: 1, clickCount: 1)
        XCTAssertEqual(notifications.willChange, 0)
        session.pointerDragged(to: CGPoint(x: 8, y: 7))
        session.pointerDragged(to: CGPoint(x: 12, y: 9))
        XCTAssertEqual(notifications.willChange, 1)
        XCTAssertEqual(notifications.didChange, 0)
        XCTAssertEqual(session.revision, revision)
        XCTAssertEqual(session.document.annotations, [annotation])
        session.pointerUp(at: CGPoint(x: 12, y: 9))
        XCTAssertEqual(notifications.willChange, 1)
        XCTAssertEqual(notifications.didChange, 1)
        XCTAssertNotEqual(session.revision, revision)
        XCTAssertEqual(session.document.annotations.first?.bounds.origin, CGPoint(x: 9, y: 6))
        session.undo()
        XCTAssertEqual(session.document.annotations, [annotation])
        XCTAssertEqual(notifications.willChange, 2)
        XCTAssertEqual(notifications.didChange, 2)
        session.redo()
        XCTAssertEqual(notifications.willChange, 3)
        XCTAssertEqual(notifications.didChange, 3)
    }

    func testCancelledAndReturningMovePreviewsRestoreWithoutRevisionOrUndoEntry() throws {
        let session = ImageEditorSession(image: try image())
        let annotation = ImageAnnotation(kind: .rectangle, points: [CGPoint(x: 2, y: 2), CGPoint(x: 10, y: 10)], style: red)
        session.document.add(annotation)
        session.tool = .select
        let revision = session.revision
        let initialImage = session.displayImage
        let notifications = observePixels(session)
        session.pointerDown(at: CGPoint(x: 5, y: 5), tolerance: 1, clickCount: 1)
        session.pointerDragged(to: CGPoint(x: 8, y: 8))
        session.cancelGesture()
        session.cancelGesture()
        XCTAssertEqual(notifications.willChange, 1)
        XCTAssertEqual(notifications.didChange, 1)
        XCTAssertTrue(session.displayImage === initialImage)
        XCTAssertEqual(session.revision, revision)
        session.pointerDown(at: CGPoint(x: 5, y: 5), tolerance: 1, clickCount: 1)
        session.pointerDragged(to: CGPoint(x: 8, y: 8))
        session.pointerUp(at: CGPoint(x: 5, y: 5))
        XCTAssertEqual(notifications.willChange, 2)
        XCTAssertEqual(notifications.didChange, 2)
        XCTAssertEqual(session.document.annotations, [annotation])
        XCTAssertEqual(session.revision, revision)
        session.undo()
        XCTAssertTrue(session.document.annotations.isEmpty)
    }

    func testDrawingOnlyNotifiesForEffectivePixelsAndBrushClickRemainsUndoable() throws {
        let session = ImageEditorSession(image: try image())
        let revision = session.revision
        let notifications = observePixels(session)
        for tool: ImageEditorTool in [.arrow, .line, .rectangle, .ellipse, .mosaic] {
            session.tool = tool
            session.pointerDown(at: CGPoint(x: 5, y: 5), tolerance: 1, clickCount: 1)
            session.pointerUp(at: CGPoint(x: 5, y: 5))
        }
        session.tool = .rectangle
        session.pointerDown(at: CGPoint(x: 5, y: 5), tolerance: 1, clickCount: 1)
        session.pointerUp(at: CGPoint(x: 20, y: 5))
        XCTAssertEqual(notifications.willChange, 0)
        XCTAssertEqual(notifications.didChange, 0)
        XCTAssertEqual(session.revision, revision)
        session.tool = .brush
        session.pointerDown(at: CGPoint(x: 5, y: 5), tolerance: 1, clickCount: 1)
        XCTAssertEqual(notifications.willChange, 1)
        XCTAssertEqual(notifications.didChange, 0)
        XCTAssertGreaterThan(try color(ToolImage(cgImage: session.displayImage), 5, 5).alpha, 0)
        session.pointerUp(at: CGPoint(x: 5, y: 5))
        XCTAssertEqual(notifications.didChange, 1)
        XCTAssertEqual(session.document.annotations.count, 1)
        session.undo()
        XCTAssertFalse(session.document.canUndo)
        XCTAssertEqual(notifications.willChange, 2)
        XCTAssertEqual(notifications.didChange, 2)
    }

    func testNewMosaicDefaultDoesNotChangePixelsAndIsUsedByNextAnnotation() throws {
        let session = ImageEditorSession(image: try image { x, y in (UInt8(x * 6), UInt8(y * 7), 0, 255) })
        let revision = session.revision
        let notifications = observePixels(session)
        session.beginMosaicAdjustment()
        session.updateMosaicBlockSize(0)
        XCTAssertEqual(session.mosaicBlockSize, 4)
        session.updateMosaicBlockSize(100)
        XCTAssertEqual(session.mosaicBlockSize, 64)
        session.updateMosaicBlockSize(20)
        session.endMosaicAdjustment()
        XCTAssertEqual(notifications.willChange, 0)
        XCTAssertEqual(notifications.didChange, 0)
        XCTAssertEqual(session.revision, revision)
        XCTAssertFalse(session.document.canUndo)
        session.tool = .mosaic
        session.pointerDown(at: CGPoint(x: 2, y: 2), tolerance: 1, clickCount: 1)
        XCTAssertEqual(notifications.willChange, 0)
        session.pointerDragged(to: CGPoint(x: 30, y: 25))
        XCTAssertEqual(notifications.willChange, 1)
        session.pointerUp(at: CGPoint(x: 30, y: 25))
        XCTAssertEqual(session.document.annotations.first?.mosaicBlockSize, 20)
        XCTAssertEqual(notifications.didChange, 1)
        XCTAssertEqual(try color(session.currentFlattenedImage, 2, 2), try color(session.currentFlattenedImage, 20, 20))
        session.undo()
        XCTAssertTrue(session.document.annotations.isEmpty)
        XCTAssertFalse(session.document.canUndo)
    }

    func testSelectedMosaicSynchronizesStrengthAndImmediateChangeIsUndoable() throws {
        let session = ImageEditorSession(image: try image())
        let first = ImageAnnotation(kind: .mosaic, points: [.zero, CGPoint(x: 12, y: 12)], mosaicBlockSize: 8)
        let second = ImageAnnotation(kind: .mosaic, points: [CGPoint(x: 20, y: 20), CGPoint(x: 35, y: 30)], mosaicBlockSize: 24)
        session.document.add(first)
        session.document.add(second)
        XCTAssertEqual(session.mosaicBlockSize, 24)
        session.tool = .select
        session.pointerDown(at: CGPoint(x: 5, y: 5), tolerance: 1, clickCount: 1)
        session.pointerUp(at: CGPoint(x: 5, y: 5))
        XCTAssertEqual(session.mosaicBlockSize, 8)
        let notifications = observePixels(session)
        session.updateMosaicBlockSize(18)
        XCTAssertEqual(session.document.annotations[0].mosaicBlockSize, 18)
        XCTAssertEqual(session.document.annotations[1], second)
        XCTAssertEqual(session.mosaicBlockSize, 18)
        XCTAssertEqual(notifications.willChange, 1)
        XCTAssertEqual(notifications.didChange, 1)
        session.undo()
        XCTAssertEqual(session.document.annotations, [first, second])
        XCTAssertEqual(session.mosaicBlockSize, 8)
        session.redo()
        XCTAssertEqual(session.mosaicBlockSize, 18)
        session.document.selectedID = second.id
        XCTAssertEqual(session.mosaicBlockSize, 24)
    }

    func testMosaicSliderPreviewsManyValuesAndCommitsOneUndoGroup() throws {
        let session = ImageEditorSession(image: try image { x, y in (UInt8(x * 6), UInt8(y * 7), 0, 255) })
        let annotation = ImageAnnotation(kind: .mosaic, points: [.zero, CGPoint(x: 32, y: 30)], mosaicBlockSize: 8)
        session.document.add(annotation)
        let revision = session.revision
        let notifications = observePixels(session)
        session.beginMosaicAdjustment()
        session.updateMosaicBlockSize(8)
        XCTAssertEqual(notifications.willChange, 0)
        for value in [10, 12, 16, 24] { session.updateMosaicBlockSize(value) }
        XCTAssertEqual(session.document.annotations, [annotation])
        XCTAssertEqual(session.previewAnnotation?.mosaicBlockSize, 24)
        XCTAssertEqual(session.revision, revision)
        XCTAssertEqual(notifications.willChange, 1)
        XCTAssertEqual(notifications.didChange, 0)
        XCTAssertNotEqual(try color(ToolImage(cgImage: session.displayImage), 0, 0), try color(session.currentFlattenedImage, 0, 0))
        session.endMosaicAdjustment()
        session.endMosaicAdjustment()
        XCTAssertEqual(session.document.annotations.first?.mosaicBlockSize, 24)
        XCTAssertNotEqual(session.revision, revision)
        XCTAssertEqual(notifications.willChange, 1)
        XCTAssertEqual(notifications.didChange, 1)
        session.undo()
        XCTAssertEqual(session.document.annotations, [annotation])
        session.undo()
        XCTAssertTrue(session.document.annotations.isEmpty, "All slider ticks must share one undo step")
        XCTAssertFalse(session.document.canUndo)
    }

    func testMosaicUnchangedClampedCancelledAndReturningAdjustmentsDoNotEnterUndo() throws {
        let session = ImageEditorSession(image: try image())
        let annotation = ImageAnnotation(kind: .mosaic, points: [.zero, CGPoint(x: 30, y: 30)], mosaicBlockSize: 64)
        session.document.add(annotation)
        let revision = session.revision
        let notifications = observePixels(session)
        session.beginMosaicAdjustment()
        session.updateMosaicBlockSize(64)
        session.updateMosaicBlockSize(100)
        session.endMosaicAdjustment()
        XCTAssertEqual(notifications.willChange, 0)
        XCTAssertEqual(notifications.didChange, 0)
        session.beginMosaicAdjustment()
        session.updateMosaicBlockSize(32)
        session.updateMosaicBlockSize(64)
        session.endMosaicAdjustment()
        XCTAssertEqual(notifications.willChange, 1)
        XCTAssertEqual(notifications.didChange, 1)
        session.beginMosaicAdjustment()
        session.updateMosaicBlockSize(16)
        session.cancelGesture()
        session.endMosaicAdjustment()
        XCTAssertEqual(session.mosaicBlockSize, 64)
        XCTAssertEqual(session.document.annotations, [annotation])
        XCTAssertEqual(session.revision, revision)
        XCTAssertEqual(notifications.willChange, 2)
        XCTAssertEqual(notifications.didChange, 2)
        session.undo()
        XCTAssertTrue(session.document.annotations.isEmpty)
        XCTAssertFalse(session.document.canUndo)
    }

    func testTextCancelAndUnchangedCommitReusePixelsButRealTextEditNotifiesOnce() throws {
        let session = ImageEditorSession(image: try image(width: 120, height: 80))
        let annotation = ImageAnnotation(kind: .text, points: [CGPoint(x: 4, y: 3)], text: "Existing",
                                         textSize: CGSize(width: 90, height: 40))
        session.document.add(annotation)
        session.tool = .select
        let revision = session.revision
        let notifications = observePixels(session)
        let committedPixels = try session.currentFlattenedImage.pngData()
        session.pointerDown(at: CGPoint(x: 5, y: 5), tolerance: 1, clickCount: 2)
        session.pointerUp(at: CGPoint(x: 5, y: 5))
        XCTAssertEqual(try ToolImage(cgImage: session.displayImage).pngData(), try session.document.original.pngData(),
                       "Reediting paints only the native draft, not the committed text underneath")
        XCTAssertEqual(try session.currentFlattenedImage.pngData(), committedPixels)
        session.textDraft = "Cancelled"
        session.changeStyle { $0.setColor(.blue) }
        session.cancelText()
        XCTAssertEqual(try ToolImage(cgImage: session.displayImage).pngData(), committedPixels,
                       "Cancel must restore the exact committed preview without a pixel revision")
        session.pointerDown(at: CGPoint(x: 5, y: 5), tolerance: 1, clickCount: 2)
        session.commitText()
        session.tool = .text
        session.pointerDown(at: CGPoint(x: 100, y: 60), tolerance: 1, clickCount: 1)
        session.cancelText()
        XCTAssertEqual(notifications.willChange, 0)
        XCTAssertEqual(notifications.didChange, 0)
        XCTAssertEqual(session.revision, revision)
        XCTAssertEqual(session.document.annotations, [annotation])
        session.tool = .select
        session.pointerDown(at: CGPoint(x: 5, y: 5), tolerance: 1, clickCount: 2)
        session.textDraft = "Changed"
        session.commitText()
        XCTAssertEqual(notifications.willChange, 1)
        XCTAssertEqual(notifications.didChange, 1)
        XCTAssertNotEqual(session.revision, revision)
        session.undo()
        XCTAssertEqual(session.document.annotations, [annotation])
        session.undo()
        XCTAssertTrue(session.document.annotations.isEmpty)
    }

    func testTextInputActuallyCommitsAndCanBeReedited() throws {
        let session = ImageEditorSession(image: try image(width: 120, height: 80))
        session.tool = .text
        session.pointerDown(at: CGPoint(x: 4, y: 3), tolerance: 1, clickCount: 1)
        XCTAssertTrue(session.isEditingText)
        session.textDraft = "提交文字"
        session.commitText()
        XCTAssertEqual(session.document.annotations.first?.text, "提交文字")
        XCTAssertFalse(session.isEditingText)
        let id = session.document.annotations.first?.id
        session.pointerDown(at: CGPoint(x: 5, y: 5), tolerance: 1, clickCount: 2)
        XCTAssertTrue(session.isEditingText)
        session.textDraft = "已修改"
        session.commitText()
        XCTAssertEqual(session.document.annotations.count, 1)
        XCTAssertEqual(session.document.annotations.first?.id, id)
        XCTAssertEqual(session.document.annotations.first?.text, "已修改")
    }
}
