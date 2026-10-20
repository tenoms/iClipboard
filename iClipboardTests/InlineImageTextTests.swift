import XCTest
import AppKit
import CoreText
import VisionKit
@testable import iClipboard

@MainActor
final class InlineImageTextTests: XCTestCase {
    func testFlattenedImageActuallyRendersAcrossExactBoundsAndDoesNotEatBlankCanvas() async throws {
        _ = NSApplication.shared
        let analyzer = ManualInlineAnalyzer(isSupported: false)
        let fallback = ManualInlineFallback()
        let view = InlineImageTextInteraction(frame: CGRect(x: 0, y: 0, width: 240, height: 80),
                                             analyzer: analyzer, fallbackRecognizer: fallback,
                                             debounceNanoseconds: 0)
        defer { view.cancel() }
        view.interactionEnabled = true
        view.update(image: try makeImage(), revision: UUID())
        await waitForCalls(fallback, count: 1)
        let imageView = try XCTUnwrap(view.subviews.compactMap { $0 as? NSImageView }.first)
        let overlay = try XCTUnwrap(view.subviews.compactMap { $0 as? ImageAnalysisOverlayView }.first)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(imageView.frame, view.bounds)
        XCTAssertEqual(overlay.frame, view.bounds)
        XCTAssertTrue(overlay.trackingImageView === imageView)
        XCTAssertTrue(overlay.delegate === view)
        XCTAssertEqual(view.contentsRect(for: overlay), CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertTrue(view.contentView(for: overlay) === imageView)

        let bitmap = try XCTUnwrap(imageView.bitmapImageRepForCachingDisplay(in: imageView.bounds))
        imageView.cacheDisplay(in: imageView.bounds, to: bitmap)
        let left = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 4, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        let right = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide * 3 / 4, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(left.redComponent, 0.8, "The current flattened image must really be drawn, not only stored")
        XCTAssertLessThan(left.blueComponent, 0.2)
        XCTAssertGreaterThan(right.blueComponent, 0.8)
        XCTAssertLessThan(right.redComponent, 0.2)
        XCTAssertNil(view.hitTest(CGPoint(x: 10, y: 10)))
        fallback.complete(0, text: "fallback text")
        try await waitUntil { view.phase == .ready }
        XCTAssertFalse(view.supportsTextSelection)
        XCTAssertTrue(view.statusText.contains("原位文字选择不可用"))
        XCTAssertNil(view.hitTest(CGPoint(x: 10, y: 10)))
        XCTAssertFalse(view.overlayView(overlay, shouldBeginAt: .zero, forAnalysisType: .textSelection))
    }

    func testImagePreparationIsDebouncedWithAnalysisAndCancelledSourcesAreNeverRendered() async throws {
        let analyzer = ManualInlineAnalyzer(isSupported: true)
        let fallback = ManualInlineFallback()
        let view = InlineImageTextInteraction(analyzer: analyzer, fallbackRecognizer: fallback,
                                             debounceNanoseconds: 30_000_000)
        defer { view.cancel() }
        let image = try makeImage()
        var prepared: [Int] = []
        for index in 0..<10 {
            view.update(revision: UUID()) {
                prepared.append(index)
                return image
            }
        }
        XCTAssertTrue(prepared.isEmpty, "Source rendering must not happen before the shared debounce")
        await waitForCalls(analyzer, count: 1)
        XCTAssertEqual(prepared, [9])
        analyzer.complete(0, text: "Only latest source")
        try await waitUntil { view.phase == .ready }
        view.update(revision: UUID()) { XCTFail("Invalidated source must not render"); return image }
        view.invalidate()
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(analyzer.images.count, 1)
        XCTAssertEqual(prepared, [9])
    }

    func testNativeTranscriptUsesNewFlattenedImageAndDoesNotRunFallback() async throws {
        let analyzer = ManualInlineAnalyzer(isSupported: true)
        let fallback = ManualInlineFallback()
        let view = makeView(analyzer, fallback)
        defer { view.cancel() }
        let image = try makeImage()
        view.update(image: image, revision: UUID())
        await waitForCalls(analyzer, count: 1)
        XCTAssertTrue(analyzer.images.first === image.cgImage)
        analyzer.complete(0, text: "native transcript")
        try await waitUntil { view.phase == .ready }
        XCTAssertEqual(view.fullText, "native transcript")
        XCTAssertEqual(fallback.calls.count, 0)
        // Simulated transcripts carry no ImageAnalysis: do not claim native
        // selection, create fake boxes, or expose an artificial selection API.
        XCTAssertFalse(view.hasActiveTextSelection)
    }

    func testForceRefreshClearsPreviousTextImmediatelyAndSameRevisionStillRejectsLateResult() async throws {
        let analyzer = ManualInlineAnalyzer(isSupported: false)
        let fallback = ManualInlineFallback()
        let view = makeView(analyzer, fallback)
        defer { view.cancel() }
        let image = try makeImage()
        let revision = UUID()
        view.update(image: image, revision: revision)
        await waitForCalls(fallback, count: 1)
        fallback.complete(0, text: "previous")
        try await waitUntil { view.phase == .ready }
        XCTAssertEqual(view.fullText, "previous")

        view.update(image: image, revision: revision, forceRefresh: true)
        XCTAssertEqual(view.phase, .analyzing)
        XCTAssertTrue(view.fullText.isEmpty)
        await waitForCalls(fallback, count: 2)
        view.update(image: image, revision: revision, forceRefresh: true)
        await waitForCalls(fallback, count: 3)
        fallback.complete(2, text: "current")
        try await waitUntil { view.fullText == "current" }
        fallback.complete(1, text: "stale same revision")
        try await waitUntil { fallback.completionCount == 3 }
        XCTAssertEqual(view.fullText, "current", "Generation protects even a caller-reused revision")
        XCTAssertEqual(view.phase, .ready)
    }

    func testDifferentRevisionRejectsLateNativeErrorWithoutStartingFallback() async throws {
        let analyzer = ManualInlineAnalyzer(isSupported: true)
        let fallback = ManualInlineFallback()
        let view = makeView(analyzer, fallback)
        defer { view.cancel() }
        let image = try makeImage()
        view.update(image: image, revision: UUID())
        await waitForCalls(analyzer, count: 1)
        view.update(image: image, revision: UUID())
        await waitForCalls(analyzer, count: 2)
        analyzer.complete(1, text: "new revision")
        try await waitUntil { view.phase == .ready }
        analyzer.fail(0)
        try await waitUntil { analyzer.completionCount == 2 }
        XCTAssertEqual(view.fullText, "new revision")
        XCTAssertEqual(fallback.calls.count, 0)
    }

    func testUnsupportedAndNativeErrorFallBackToFullTextWithExplicitUnavailableStatus() async throws {
        for supported in [false, true] {
            let analyzer = ManualInlineAnalyzer(isSupported: supported)
            let fallback = ManualInlineFallback()
            let view = makeView(analyzer, fallback)
            defer { view.cancel() }
            let image = try makeImage()
            var stateChanges = 0
            view.onStateChange = { stateChanges += 1 }
            view.update(image: image, revision: UUID())
            if supported {
                await waitForCalls(analyzer, count: 1)
                analyzer.fail(0)
            }
            await waitForCalls(fallback, count: 1)
            XCTAssertFalse(view.supportsTextSelection)
            XCTAssertTrue(view.statusText.contains("原位文字选择不可用"))
            XCTAssertTrue(fallback.images.first === image.cgImage)
            fallback.complete(0, text: "全文\nfull text")
            try await waitUntil { view.phase == .ready }
            XCTAssertEqual(view.fullText, "全文\nfull text")
            XCTAssertTrue(view.statusText.contains("全文"))
            XCTAssertGreaterThanOrEqual(stateChanges, 2)
            XCTAssertEqual(analyzer.calls.count, supported ? 1 : 0)
        }
    }

    func testInvalidateImmediatelyClearsAnalysisImageAndBlocksLateCompletion() async throws {
        let analyzer = ManualInlineAnalyzer(isSupported: false)
        let fallback = ManualInlineFallback()
        let view = makeView(analyzer, fallback)
        defer { view.cancel() }
        view.update(image: try makeImage(), revision: UUID())
        await waitForCalls(fallback, count: 1)
        fallback.complete(0, text: "sensitive old pixels")
        try await waitUntil { view.phase == .ready }
        view.update(image: try makeImage(), revision: UUID())
        await waitForCalls(fallback, count: 2)
        let overlay = try XCTUnwrap(view.subviews.compactMap { $0 as? ImageAnalysisOverlayView }.first)
        view.invalidate()
        XCTAssertEqual(view.phase, .idle)
        XCTAssertTrue(view.fullText.isEmpty)
        XCTAssertFalse(view.hasActiveTextSelection)
        XCTAssertNil(overlay.analysis)
        XCTAssertNil(overlay.trackingImageView?.image)
        fallback.complete(1, text: "late sensitive pixels")
        try await waitUntil { fallback.completionCount == 2 }
        XCTAssertEqual(view.phase, .idle)
        XCTAssertTrue(view.fullText.isEmpty)
    }

    func testCancelIsTerminalClearsClosuresAndDoesNotRetainViewWhileAnalysisFinishes() async throws {
        let analyzer = ManualInlineAnalyzer(isSupported: true)
        let fallback = ManualInlineFallback()
        var view: InlineImageTextInteraction? = autoreleasepool { makeView(analyzer, fallback) }
        weak var weakView = view
        let image = try makeImage()
        view?.onStateChange = {}
        view?.onWillCopySelection = { XCTFail("Analysis/cancellation must never imply a user copy") }
        view?.update(image: image, revision: UUID())
        await waitForCalls(analyzer, count: 1)
        try autoreleasepool {
            let overlay = try XCTUnwrap(view?.subviews.compactMap { $0 as? ImageAnalysisOverlayView }.first)
            view?.cancel()
            view?.cancel()
            XCTAssertNil(view?.onStateChange)
            XCTAssertNil(view?.onWillCopySelection)
            XCTAssertNil(overlay.delegate)
            XCTAssertNil(overlay.trackingImageView)
            XCTAssertNil(overlay.analysis)
            view?.update(image: image, revision: UUID())
            XCTAssertEqual(view?.phase, .idle)
            view = nil
        }
        XCTAssertNil(weakView)
        analyzer.complete(0, text: "must not revive")
        try await waitUntil { analyzer.completionCount == 1 }
        XCTAssertEqual(analyzer.calls.count, 1)
        XCTAssertEqual(fallback.calls.count, 0)
    }

    func testFallbackEmptyFailureAndRetryPublishToolbarState() async throws {
        let analyzer = ManualInlineAnalyzer(isSupported: false)
        let fallback = ManualInlineFallback()
        let view = makeView(analyzer, fallback)
        defer { view.cancel() }
        let image = try makeImage()
        view.update(image: image, revision: UUID())
        await waitForCalls(fallback, count: 1)
        fallback.complete(0, text: " \n ")
        try await waitUntil { view.phase == .empty }
        view.update(image: image, revision: UUID())
        await waitForCalls(fallback, count: 2)
        fallback.fail(1)
        try await waitUntil { if case .failed = view.phase { return true }; return false }
        XCTAssertTrue(view.fullText.isEmpty)
        XCTAssertTrue(view.statusText.contains("原位文字选择不可用"))
        view.update(image: image, revision: UUID())
        await waitForCalls(fallback, count: 3)
        fallback.complete(2, text: "retry")
        try await waitUntil { view.phase == .ready }
        XCTAssertEqual(view.fullText, "retry")
    }

    func testDebounceOnlyAnalyzesTheLatestImage() async throws {
        let analyzer = ManualInlineAnalyzer(isSupported: false)
        let fallback = ManualInlineFallback()
        let view = InlineImageTextInteraction(analyzer: analyzer, fallbackRecognizer: fallback,
                                             debounceNanoseconds: 20_000_000)
        defer { view.cancel() }
        let image = try makeImage()
        for _ in 0..<10 { view.update(image: image, revision: UUID()) }
        await waitForCalls(fallback, count: 1)
        XCTAssertEqual(fallback.calls.count, 1)
        fallback.complete(0, text: "only latest")
        try await waitUntil { view.phase == .ready }
    }

    func testNoSelectionNeverConsumesCopyOrCallsCopyIntent() throws {
        _ = NSApplication.shared
        let view = makeView(ManualInlineAnalyzer(isSupported: false), ManualInlineFallback())
        defer { view.cancel() }
        view.interactionEnabled = true
        view.onWillCopySelection = { XCTFail("No selection must fall through to capture's image copy") }
        for flags: NSEvent.ModifierFlags in [.command, [.command, .shift], [.command, .option], []] {
            XCTAssertFalse(view.handleCopyKeyEquivalent(try key("c", flags: flags)))
        }
        XCTAssertFalse(view.handleCopyKeyEquivalent(try key("a", flags: .command)))
        let overlay = try XCTUnwrap(view.subviews.compactMap { $0 as? ImageAnalysisOverlayView }.first)
        XCTAssertFalse(view.overlayView(overlay, shouldHandleKeyDownEvent: try key("c", flags: .command)))
        XCTAssertNil(view.hitTest(.zero))
        view.isHidden = true
        XCTAssertNil(view.hitTest(.zero))
        view.interactionEnabled = false
        XCTAssertNil(view.hitTest(.zero))
    }

    func testRealNativeAnalysisRenderAndDelegateRoutingWhenSupported() async throws {
        guard ImageAnalyzer.isSupported else {
            throw XCTSkip("Live Text is not supported on this Mac; fallback and lifecycle tests remain unconditional")
        }
        _ = NSApplication.shared
        let view = InlineImageTextInteraction(frame: CGRect(x: 0, y: 0, width: 450, height: 130))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        defer { view.cancel(); window.contentView = nil; window.orderOut(nil); window.close() }
        view.interactionEnabled = true
        view.update(image: try makeImage(withText: true), revision: UUID())
        try await waitUntil(timeout: 15) { view.phase != .analyzing }
        XCTAssertEqual(view.phase, .ready)
        XCTAssertTrue(view.fullText.contains("OFFLINE TEXT"))
        XCTAssertTrue(view.supportsTextSelection, "A native error must be reported as unavailable rather than mocked selection")
        let overlay = try XCTUnwrap(view.subviews.compactMap { $0 as? ImageAnalysisOverlayView }.first)
        XCTAssertNotNil(overlay.analysis)
        XCTAssertTrue(overlay.trackingImageView?.image != nil)
        XCTAssertTrue(overlay.delegate === view)
        XCTAssertTrue(view.overlayView(overlay, shouldBeginAt: CGPoint(x: 50, y: 50), forAnalysisType: .textSelection))
        XCTAssertFalse(view.overlayView(overlay, shouldBeginAt: .zero, forAnalysisType: .dataDetectors))
        XCTAssertTrue(view.overlayView(overlay, shouldHandleKeyDownEvent: try key("a", flags: .command)),
                      "Native select-all stays with VisionKit, without synthesizing text input commands")
        XCTAssertFalse(view.handleCopyKeyEquivalent(try key("c", flags: .command)),
                       "A transcript alone is never treated as a user text selection")
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let imageView = try XCTUnwrap(overlay.trackingImageView)
        let bitmap = try XCTUnwrap(imageView.bitmapImageRepForCachingDisplay(in: imageView.bounds))
        imageView.cacheDisplay(in: imageView.bounds, to: bitmap)
        let textPoint = CGPoint(x: 65, y: 94)
        XCTAssertTrue(overlay.analysisHasText(at: overlay.convert(textPoint, from: view)))
        XCTAssertNotNil(view.hitTest(textPoint), "Known rendered glyphs must reach native selection")
        view.updateTrackingAreas()
        XCTAssertTrue(view.trackingAreas.contains { $0.options.contains([.mouseMoved, .cursorUpdate, .mouseEnteredAndExited]) })
        let textMove = try mouseMove(textPoint, in: view)
        NSCursor.crosshair.set()
        view.mouseMoved(with: textMove)
        XCTAssertEqual(NSCursor.current, NSCursor.iBeam, "Real native glyph hover must set the actual I-beam")
        NSCursor.crosshair.set()
        view.cursorUpdate(with: textMove)
        XCTAssertEqual(NSCursor.current, NSCursor.iBeam, "AppKit cursor-update delivery uses the same native coordinates")
        // A native selection delegate notification is not a layout/tool change
        // and must not reset the host canvas cursor on every selection movement.
        NSCursor.crosshair.set()
        view.overlayView(overlay, highlightSelectedItemsDidChange: true)
        XCTAssertEqual(NSCursor.current, NSCursor.crosshair)
        for point in [CGPoint(x: 5, y: 5), CGPoint(x: 445, y: 5),
                      CGPoint(x: 5, y: 125), CGPoint(x: 445, y: 125)] {
            let parentPoint = view.convert(point, to: view.superview)
            XCTAssertFalse(overlay.analysisHasText(at: overlay.convert(point, from: view)),
                           "Fixture corners have no text after real layout/render: \(point)")
            XCTAssertNil(view.hitTest(parentPoint), "Blank crop space belongs to the annotation canvas: \(point)")
            view.mouseMoved(with: try mouseMove(point, in: view))
            XCTAssertEqual(NSCursor.current, NSCursor.arrow, "Blank crop pixels never inherit a whole-crop I-beam")
        }
        let nativeAnalysis = overlay.analysis
        view.interactionEnabled = false
        NSCursor.crosshair.set()
        view.mouseMoved(with: textMove)
        XCTAssertEqual(NSCursor.current, NSCursor.crosshair, "Disabled Live Text leaves the annotation tool cursor alone")
        XCTAssertFalse(view.trackingAreas.contains { $0.options.contains(.cursorUpdate) })
        view.interactionEnabled = true
        XCTAssertTrue(overlay.analysis === nativeAnalysis, "Tool changes preserve the exact native revision analysis")
        view.mouseMoved(with: textMove)
        XCTAssertEqual(NSCursor.current, NSCursor.iBeam)
        view.interactionEnabled = false
        XCTAssertNil(view.hitTest(CGPoint(x: 50, y: 50)))
        XCTAssertFalse(view.overlayView(overlay, shouldBeginAt: .zero, forAnalysisType: .textSelection))
        view.invalidate()
        XCTAssertNil(overlay.analysis)
        XCTAssertTrue(view.fullText.isEmpty)
        XCTAssertFalse(view.hasActiveTextSelection)
    }

    func testRealNativeWordSelectionResolvesCopyTargetAndNotifiesBeforeDispatch() async throws {
        guard #available(macOS 14.0, *) else {
            throw XCTSkip("Only the test selection setter needs macOS 14; production uses macOS 13 native selection")
        }
        guard ImageAnalyzer.isSupported else { throw XCTSkip("Live Text is unsupported on this Mac") }
        _ = NSApplication.shared
        let view = InlineImageTextInteraction(frame: CGRect(x: 0, y: 0, width: 450, height: 130))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        defer { view.cancel(); window.contentView = nil; window.orderOut(nil); window.close() }
        view.interactionEnabled = true
        view.update(image: try makeImage(withText: true), revision: UUID())
        try await waitUntil(timeout: 15) { view.phase != .analyzing }
        XCTAssertEqual(view.phase, .ready)
        XCTAssertTrue(view.supportsTextSelection)
        let overlay = try XCTUnwrap(view.subviews.compactMap { $0 as? ImageAnalysisOverlayView }.first)
        view.layoutSubtreeIfNeeded()
        try await waitUntil { overlay.text.contains("OFFLINE") }
        // Establish the same native focus that a real click/drag establishes;
        // setting a model selection in an offscreen window is not a user route.
        let textPoint = CGPoint(x: 65, y: 94)
        XCTAssertTrue(overlay.analysisHasText(at: overlay.convert(textPoint, from: view)))
        let hit = try XCTUnwrap(view.hitTest(textPoint))
        let location = view.convert(textPoint, to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
                                                   modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil,
                                                   eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location,
                                                 modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: 2, clickCount: 1, pressure: 0))
        NSApp.postEvent(up, atStart: true)
        hit.mouseDown(with: down)
        let range = try XCTUnwrap(overlay.text.range(of: "OFFLINE"))
        overlay.selectedRanges = [range]
        try await waitUntil { overlay.hasActiveTextSelection }
        XCTAssertTrue(view.hasActiveTextSelection)
        XCTAssertEqual(overlay.selectedText, "OFFLINE")
        // No synthetic events, fake character geometry, or pasteboard round-trip.
        // The production handler must first resolve an actual native copy:
        // responder. Cancel at its pre-dispatch callback so the test proves that
        // resolution and callback ordering without overwriting the user's board.
        var copyIntents = 0
        view.onWillCopySelection = {
            copyIntents += 1
            XCTAssertTrue(view.hasActiveTextSelection)
            XCTAssertEqual(overlay.selectedText, "OFFLINE")
            view.invalidate()
        }
        XCTAssertTrue(view.handleCopyKeyEquivalent(try key("c", flags: .command)),
                      "A real native word selection must resolve a system copy: target")
        XCTAssertEqual(copyIntents, 1, "The copy-intent callback must run before native dispatch")
        XCTAssertFalse(view.hasActiveTextSelection)
        XCTAssertEqual(view.phase, .idle)
    }

    func testRealNativeWorkspaceKeepsSourceTextAcrossAnnotationsWithoutRepaintingTheCanvas() async throws {
        guard ImageAnalyzer.isSupported else { throw XCTSkip("Live Text is unsupported on this Mac") }
        _ = NSApplication.shared
        let image = try makeImage(withText: true)
        let frame = CGRect(x: 0, y: 0, width: 450, height: 130)
        let workspace = ScreenCaptureWorkspace(image: image, imageRect: frame, anchor: frame,
                                               bounds: CGRect(x: 0, y: 0, width: 640, height: 320))
        let window = NSWindow(contentRect: workspace.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = workspace
        window.makeKeyAndOrderFront(nil)
        defer { workspace.invalidate(); window.contentView = nil; window.orderOut(nil); window.close() }
        let interaction = workspace.textInteraction
        try await waitUntil(timeout: 15) { interaction.phase != .analyzing }
        XCTAssertEqual(interaction.phase, .ready)
        XCTAssertTrue(interaction.fullText.contains("OFFLINE TEXT"))
        let overlay = try XCTUnwrap(interaction.subviews.compactMap { $0 as? ImageAnalysisOverlayView }.first)
        let initialAnalysis = try XCTUnwrap(overlay.analysis)
        let textPoint = CGPoint(x: 65, y: 94)
        workspace.layoutSubtreeIfNeeded()
        XCTAssertNil(overlay.trackingImageView, "The annotation canvas is supplied through the public delegate")
        XCTAssertTrue(interaction.contentView(for: overlay) === workspace.canvas)
        XCTAssertTrue(overlay.analysisHasText(at: textPoint))
        XCTAssertNotNil(interaction.hitTest(textPoint))

        workspace.session.tool = .text
        workspace.session.pointerDown(at: CGPoint(x: 450, y: 15), tolerance: 2, clickCount: 1)
        workspace.session.textDraft = "ADDED LABEL"
        workspace.session.commitText()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(overlay.analysis === initialAnalysis, "A committed label must not trigger another native analysis")
        XCTAssertFalse(interaction.fullText.contains("ADDED LABEL"))
        let bitmap = try XCTUnwrap(workspace.bitmapImageRepForCachingDisplay(in: frame))
        workspace.cacheDisplay(in: frame, to: bitmap)
        var annotationPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                   color.redComponent > 0.7, color.greenComponent < 0.5, color.blueComponent < 0.5 { annotationPixels += 1 }
            }
        }
        XCTAssertGreaterThan(annotationPixels, 10, "The original OCR reference must never cover newly drawn pixels")

        // Put a control/mark over source glyphs: canvas editing wins at that point.
        workspace.session.document.add(ImageAnnotation(kind: .rectangle,
            points: [CGPoint(x: 100, y: 40), CGPoint(x: 180, y: 100)]))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(overlay.analysis === initialAnalysis)
        XCTAssertNil(interaction.hitTest(textPoint))
        XCTAssertFalse(interaction.overlayView(overlay, shouldBeginAt: textPoint, forAnalysisType: .textSelection))
        workspace.session.undo()
        workspace.session.undo()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(overlay.analysis === initialAnalysis)
        XCTAssertNotNil(interaction.hitTest(textPoint))
    }

    func testPinnedImageNativeTextSelectionSurvivesLetterboxingAndZoomAndRoutesCopy() async throws {
        guard #available(macOS 14.0, *), ImageAnalyzer.isSupported else {
            throw XCTSkip("Only the test selection setter requires macOS 14 and native Live Text")
        }
        _ = NSApplication.shared
        let image = try makeImage(withText: true)
        let controller = PinnedImageWindowController(image: image, anchor: nil)
        defer { controller.dispose() }
        controller.present()
        let panel = controller.panel
        let interaction = controller.textInteraction
        try await waitUntil(timeout: 15) { interaction.phase != .analyzing }
        XCTAssertEqual(interaction.phase, .ready)
        XCTAssertTrue(interaction.fullText.contains("OFFLINE TEXT"))
        let overlay = try XCTUnwrap(interaction.subviews.compactMap { $0 as? ImageAnalysisOverlayView }.first)
        let analysis = try XCTUnwrap(overlay.analysis)
        let canvas = try XCTUnwrap(interaction.imageContentView as? PinnedImageCanvas)
        panel.setFrame(CGRect(origin: panel.frame.origin, size: CGSize(width: 640, height: 320)), display: true)
        panel.contentView?.layoutSubtreeIfNeeded()
        canvas.layoutSubtreeIfNeeded()
        XCTAssertEqual(interaction.frame, canvas.bounds)
        XCTAssertLessThan(interaction.imageContentsRect.height, 1, "The fixture must have letterboxing")
        func textPoint() -> CGPoint {
            CGPoint(x: canvas.imageRect.minX + canvas.imageRect.width * 65 / 450,
                    y: canvas.imageRect.minY + canvas.imageRect.height * 94 / 130)
        }
        let point = textPoint()
        XCTAssertTrue(overlay.analysisHasText(at: overlay.convert(point, from: canvas)))
        XCTAssertNotNil(interaction.hitTest(point))
        XCTAssertNil(interaction.hitTest(CGPoint(x: canvas.bounds.midX, y: 2)), "Letterbox pixels drag the pin")
        var fullText = ""
        var imageCopies = 0
        let copied = expectation(description: "configured action reads shared native text")
        controller.onCopyFullText = { readText in
            Task { @MainActor in
                do { fullText = try await readText() }
                catch { XCTFail("Full-text copy failed: \(error)") }
                copied.fulfill()
            }
        }
        controller.onAction = { action, _, _ in if case .copy = action { imageCopies += 1 } }
        XCTAssertFalse(panel.performKeyEquivalent(with: try key("c", flags: [.command, .shift])))
        XCTAssertTrue(fullText.isEmpty, "There is no additional hardcoded Cmd-Shift-C binding")
        panel.makeKey()
        XCTAssertTrue(controller.copyFullText())
        await fulfillment(of: [copied], timeout: 2)
        XCTAssertTrue(fullText.contains("OFFLINE TEXT"))
        XCTAssertEqual(imageCopies, 0)
        XCTAssertTrue(panel.performKeyEquivalent(with: try key("c", flags: .command)))
        XCTAssertEqual(imageCopies, 1, "Without native selection Cmd-C still copies the pin image")

        // The window intercepts image wheel events even over the native text layer.
        let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                          wheel1: -2, wheel2: 0, wheel3: 0))
        wheel.location = .zero
        let base = try XCTUnwrap(NSEvent(cgEvent: wheel)).locationInWindow
        let target = canvas.convert(point, to: nil)
        wheel.location = CGPoint(x: target.x - base.x, y: base.y - target.y)
        let scroll = try XCTUnwrap(NSEvent(cgEvent: wheel))
        XCTAssertEqual(scroll.locationInWindow.x, target.x, accuracy: 0.01)
        XCTAssertEqual(scroll.locationInWindow.y, target.y, accuracy: 0.01)
        let width = panel.frame.width
        panel.sendEvent(scroll)
        XCTAssertLessThan(panel.frame.width, width)
        canvas.layoutSubtreeIfNeeded()
        XCTAssertTrue(overlay.analysis === analysis, "Zoom changes geometry, not OCR pixels")
        XCTAssertTrue(overlay.analysisHasText(at: overlay.convert(textPoint(), from: canvas)))

        panel.makeKey()
        let hit = try XCTUnwrap(interaction.hitTest(textPoint()))
        let location = canvas.convert(textPoint(), to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        NSApp.postEvent(up, atStart: true)
        hit.mouseDown(with: down)
        overlay.selectedRanges = [try XCTUnwrap(overlay.text.range(of: "OFFLINE"))]
        try await waitUntil { interaction.hasActiveTextSelection }
        XCTAssertNil(interaction.hitTest(CGPoint(x: canvas.bounds.midX, y: 2)),
                     "Even with a native selection, blank pin pixels remain available for dragging")
        var selectionCopies = 0
        controller.onWillCopySelection = {
            selectionCopies += 1
            XCTAssertEqual(overlay.selectedText, "OFFLINE")
            interaction.invalidate() // Stop before writing the user's system pasteboard.
        }
        XCTAssertTrue(panel.performKeyEquivalent(with: try key("c", flags: .command)))
        XCTAssertEqual(selectionCopies, 1)
        XCTAssertEqual(imageCopies, 1, "A native text copy must not also copy the image")
        controller.dispose()
        XCTAssertNil(overlay.analysis)
        XCTAssertNil(overlay.delegate)
        XCTAssertNil(interaction.imageContentView)
    }

    func testFocusedPinFullTextCopyWaitsForSharedOCRAndRejectsHiddenOrClosedPins() async throws {
        _ = NSApplication.shared
        let analyzer = ManualInlineAnalyzer(isSupported: true)
        let interaction = makeView(analyzer, ManualInlineFallback())
        let image = try makeImage()
        let controller = PinnedImageWindowController(image: image, anchor: nil, textInteraction: interaction)
        defer { controller.dispose() }
        controller.present()
        controller.panel.makeKey()
        await waitForCalls(analyzer, count: 1)
        var completions: [Result<String, Error>] = []
        controller.onCopyFullText = { readText in
            Task { @MainActor in
                do { completions.append(.success(try await readText())) }
                catch { completions.append(.failure(error)) }
            }
        }
        XCTAssertTrue(controller.copyFullText())
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(completions.isEmpty, "The configured action waits rather than copying an empty or partial result")
        XCTAssertEqual(analyzer.calls.count, 1)
        controller.hide()
        analyzer.complete(0, text: "Do not copy from a hidden pin")
        try await waitUntil { completions.count == 1 }
        guard case .failure(let hiddenError) = completions[0] else { return XCTFail("Lost focus must cancel full-text copy") }
        XCTAssertTrue(hiddenError is CancellationError)
        XCTAssertFalse(controller.copyFullText())
        controller.present()
        controller.panel.makeKey()
        XCTAssertTrue(controller.copyFullText())
        try await waitUntil { completions.count == 2 }
        XCTAssertEqual(try completions[1].get(), "Do not copy from a hidden pin")
        XCTAssertEqual(analyzer.calls.count, 1, "Refocusing reuses the same completed source analysis")
        interaction.update(image: image, revision: UUID())
        await waitForCalls(analyzer, count: 2)
        XCTAssertTrue(controller.copyFullText())
        for _ in 0..<10 { await Task.yield() }
        controller.dispose()
        try await waitUntil { completions.count == 3 }
        guard case .failure(let closedError) = completions[2] else { return XCTFail("Closed pins must not publish late text") }
        XCTAssertTrue(closedError is CancellationError)
        analyzer.complete(1, text: "Closed pin stale text")
    }

    func testSameRevisionSharesPendingRecognitionAndReadyCacheAcrossCallersAndTools() async throws {
        let analyzer = ManualInlineAnalyzer(isSupported: true)
        let fallback = ManualInlineFallback()
        let view = InlineImageTextInteraction(analyzer: analyzer, fallbackRecognizer: fallback,
                                             debounceNanoseconds: 20_000_000)
        defer { view.cancel() }
        let image = try makeImage()
        let revision = UUID()
        var started = 0
        view.update(image: image, revision: revision)
        let callers = (0..<8).map { _ in Task { @MainActor in
            started += 1
            return try await view.recognizedText()
        } }
        try await waitUntil { started == callers.count }
        for _ in 0..<5 {
            view.update(image: image, revision: revision)
            view.interactionEnabled.toggle()
        }
        await waitForCalls(analyzer, count: 1)
        analyzer.complete(0, text: "one shared revision")
        for caller in callers {
            let text = try await caller.value
            XCTAssertEqual(text, "one shared revision")
        }
        view.update(image: image, revision: revision)
        let cached = try await view.recognizedText()
        XCTAssertEqual(cached, "one shared revision")
        XCTAssertEqual(analyzer.calls.count, 1)
        XCTAssertEqual(fallback.calls.count, 0)
    }

    func testCancelingManyPendingAwaitersResumesPromptlyWithoutCancelingSharedAnalysis() async throws {
        let analyzer = ManualInlineAnalyzer(isSupported: false)
        let fallback = ManualInlineFallback()
        let view = makeView(analyzer, fallback)
        defer { view.cancel() }
        view.update(image: try makeImage(), revision: UUID())
        let canceled = expectation(description: "All canceled subscriptions finish before OCR")
        canceled.expectedFulfillmentCount = 12
        var started = 0
        var healthyFinished = 0
        let callers = (0..<24).map { index in Task { @MainActor in
            started += 1
            do {
                let text = try await view.recognizedText()
                if index < 12 { XCTFail("Canceled waiter returned text") }
                else { healthyFinished += 1; XCTAssertEqual(text, "still valid") }
            } catch {
                XCTAssertLessThan(index, 12)
                XCTAssertTrue(error is CancellationError)
                canceled.fulfill()
            }
        } }
        try await waitUntil { started == callers.count }
        await waitForCalls(fallback, count: 1)
        callers.prefix(12).forEach { $0.cancel() }
        await fulfillment(of: [canceled], timeout: 1)
        XCTAssertEqual(healthyFinished, 0, "Other consumers still await the same unfinished OCR")
        XCTAssertEqual(view.phase, .analyzing)
        fallback.complete(0, text: "still valid")
        for caller in callers { await caller.value }
        XCTAssertEqual(healthyFinished, 12)
        XCTAssertEqual(fallback.calls.count, 1)
        let cached = try await view.recognizedText()
        XCTAssertEqual(cached, "still valid")
    }

    func testInvalidationCancelsAwaitersAndSameRevisionRestoreRejectsLateAnalysis() async throws {
        let analyzer = ManualInlineAnalyzer(isSupported: false)
        let fallback = ManualInlineFallback()
        let view = makeView(analyzer, fallback)
        defer { view.cancel() }
        let image = try makeImage()
        let revision = UUID()
        view.update(image: image, revision: revision)
        let stopped = expectation(description: "Invalidated waiter finishes before late OCR")
        let old = Task { @MainActor in
            do { _ = try await view.recognizedText(); XCTFail("Invalidated result escaped") }
            catch { XCTAssertTrue(error is CancellationError); stopped.fulfill() }
        }
        await waitForCalls(fallback, count: 1)
        view.invalidate()
        await fulfillment(of: [stopped], timeout: 1)
        await old.value
        do { _ = try await view.recognizedText(); XCTFail("No current revision") }
        catch { XCTAssertTrue(error is CancellationError) }
        view.update(image: image, revision: revision)
        let current = Task { try await view.recognizedText() }
        await waitForCalls(fallback, count: 2)
        fallback.complete(0, text: "invalidated preview")
        try await waitUntil { fallback.completionCount == 1 }
        XCTAssertTrue(view.fullText.isEmpty)
        XCTAssertEqual(view.phase, .analyzing)
        fallback.complete(1, text: "restored preview")
        let text = try await current.value
        XCTAssertEqual(text, "restored preview")
        XCTAssertEqual(view.fullText, "restored preview")
    }

    func testEmptyAndLocalizedFailureAreCachedUntilExplicitForceRetry() async throws {
        let analyzer = ManualInlineAnalyzer(isSupported: false)
        let fallback = ManualInlineFallback()
        let view = makeView(analyzer, fallback)
        defer { view.cancel() }
        let image = try makeImage()
        let revision = UUID()
        view.update(image: image, revision: revision)
        await waitForCalls(fallback, count: 1)
        fallback.complete(0, text: " \n ")
        try await waitUntil { view.phase == .empty }
        for _ in 0..<3 {
            view.update(image: image, revision: revision)
            let text = try await view.recognizedText()
            XCTAssertEqual(text, " \n ")
        }
        XCTAssertEqual(fallback.calls.count, 1)
        view.update(image: image, revision: revision, forceRefresh: true)
        let failed = Task { try await view.recognizedText() }
        await waitForCalls(fallback, count: 2)
        fallback.fail(1)
        do { _ = try await failed.value; XCTFail("OCR error must throw") }
        catch {
            XCTAssertTrue(error is InlineImageTextInteraction.RecognitionError)
            XCTAssertEqual(error.localizedDescription, InlineTestError.failed.localizedDescription)
        }
        for _ in 0..<3 {
            view.update(image: image, revision: revision)
            do { _ = try await view.recognizedText(); XCTFail("Cached OCR error must throw") }
            catch { XCTAssertEqual(error.localizedDescription, InlineTestError.failed.localizedDescription) }
        }
        XCTAssertEqual(fallback.calls.count, 2)
        view.update(image: image, revision: revision, forceRefresh: true)
        let retry = Task { try await view.recognizedText() }
        await waitForCalls(fallback, count: 3)
        fallback.complete(2, text: "explicit retry")
        let text = try await retry.value
        XCTAssertEqual(text, "explicit retry")
    }

    func testForceRefreshCancelsOnlyOldGenerationAwaitersAndRejectsLateResult() async throws {
        let analyzer = ManualInlineAnalyzer(isSupported: false)
        let fallback = ManualInlineFallback()
        let view = makeView(analyzer, fallback)
        defer { view.cancel() }
        let image = try makeImage()
        let revision = UUID()
        view.update(image: image, revision: revision)
        let canceled = expectation(description: "Force-refresh detaches old subscription")
        let old = Task { @MainActor in
            do { _ = try await view.recognizedText(); XCTFail("Old generation escaped") }
            catch { XCTAssertTrue(error is CancellationError); canceled.fulfill() }
        }
        await waitForCalls(fallback, count: 1)
        view.update(image: image, revision: revision, forceRefresh: true)
        let fresh = Task { try await view.recognizedText() }
        await fulfillment(of: [canceled], timeout: 1)
        await old.value
        await waitForCalls(fallback, count: 2)
        fallback.complete(1, text: "new generation")
        let text = try await fresh.value
        XCTAssertEqual(text, "new generation")
        fallback.complete(0, text: "late same revision")
        try await waitUntil { fallback.completionCount == 2 }
        XCTAssertEqual(view.fullText, "new generation")
    }

    func testTerminalOwnerCancelAndPreCanceledCallerThrowWithoutWaitingForOCR() async throws {
        let analyzer = ManualInlineAnalyzer(isSupported: false)
        let fallback = ManualInlineFallback()
        let view = makeView(analyzer, fallback)
        let image = try makeImage()
        view.update(image: image, revision: UUID())
        let preCanceled = Task { try await view.recognizedText() }
        preCanceled.cancel()
        do { _ = try await preCanceled.value; XCTFail("Canceled caller must throw") }
        catch { XCTAssertTrue(error is CancellationError) }
        let canceled = expectation(description: "Owner cancel resumes pending waiter")
        let pending = Task { @MainActor in
            do { _ = try await view.recognizedText(); XCTFail("Terminal owner canceled") }
            catch { XCTAssertTrue(error is CancellationError); canceled.fulfill() }
        }
        await waitForCalls(fallback, count: 1)
        view.cancel()
        await fulfillment(of: [canceled], timeout: 1)
        await pending.value
        do { _ = try await view.recognizedText(); XCTFail("Terminal owner must throw") }
        catch { XCTAssertTrue(error is CancellationError) }
        fallback.complete(0, text: "too late")
        try await waitUntil { fallback.completionCount == 1 }
        XCTAssertEqual(view.phase, .idle)
        XCTAssertTrue(view.fullText.isEmpty)
    }

    func testSynchronousStateCallbackCanInvalidateAndRestoreWithoutLosingTask() async throws {
        let analyzer = ManualInlineAnalyzer(isSupported: false)
        let fallback = ManualInlineFallback()
        let view = makeView(analyzer, fallback)
        defer { view.cancel() }
        let image = try makeImage()
        let revision = UUID()
        var didReenter = false
        view.onStateChange = {
            guard view.phase == .analyzing, !didReenter else { return }
            didReenter = true
            view.invalidate()
            view.update(image: image, revision: revision)
        }
        view.update(image: image, revision: revision)
        let text = Task { try await view.recognizedText() }
        await waitForCalls(fallback, count: 1)
        fallback.complete(0, text: "reentrant latest")
        let result = try await text.value
        XCTAssertEqual(result, "reentrant latest")
        XCTAssertTrue(didReenter)
        XCTAssertEqual(fallback.calls.count, 1)
        view.onStateChange = nil
    }

    private func makeView(_ analyzer: ManualInlineAnalyzer, _ fallback: ManualInlineFallback) -> InlineImageTextInteraction {
        InlineImageTextInteraction(analyzer: analyzer, fallbackRecognizer: fallback, debounceNanoseconds: 0)
    }

    private func waitForCalls(_ analyzer: ManualInlineAnalyzer, count: Int) async {
        await fulfillment(of: [analyzer.expectCalls(count, in: self)], timeout: 3)
    }

    private func waitForCalls(_ fallback: ManualInlineFallback, count: Int) async {
        await fulfillment(of: [fallback.expectCalls(count, in: self)], timeout: 3)
    }

    private func waitUntil(timeout: TimeInterval = 3, _ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail("Timed out waiting for inline analysis state")
                throw InlineTestError.timedOut
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func mouseMove(_ point: NSPoint, in view: NSView) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: view.convert(point, to: nil),
                                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: view.window?.windowNumber ?? 0, context: nil,
                                        eventNumber: 0, clickCount: 0, pressure: 0))
    }

    private func key(_ character: String, flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                      timestamp: 0, windowNumber: 0, context: nil,
                                      characters: character, charactersIgnoringModifiers: character,
                                      isARepeat: false, keyCode: character == "c" ? 8 : 0))
    }

    private func makeImage(withText: Bool = false) throws -> ToolImage {
        let width = withText ? 900 : 120, height = withText ? 260 : 40
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                            bitsPerComponent: 8, bytesPerRow: width * 4,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        if withText {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 60, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ]
            for (text, y) in [("OFFLINE TEXT", 165.0), ("HELLO WORLD", 65.0)] {
                context.textPosition = CGPoint(x: 60, y: y)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
            }
        } else {
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        }
        return ToolImage(cgImage: try XCTUnwrap(context.makeImage()), title: "flattened inline text fixture", isOriginal: false)
    }
}

private enum InlineTestError: Error { case failed, timedOut }

/// Test continuations intentionally ignore cancellation to exercise generation guards.
@MainActor
private final class ManualInlineAnalyzer: InlineImageTextAnalyzing {
    let isSupported: Bool
    var calls: [CheckedContinuation<InlineImageTextAnalysis, Error>?] = []
    var images: [CGImage] = []
    var completionCount = 0
    private var waiters: [(Int, XCTestExpectation)] = []
    init(isSupported: Bool) { self.isSupported = isSupported }

    func analyze(_ image: CGImage) async throws -> InlineImageTextAnalysis {
        defer { completionCount += 1 }
        return try await withCheckedThrowingContinuation { continuation in
            images.append(image)
            calls.append(continuation)
            let ready = waiters.filter { $0.0 <= calls.count }
            waiters.removeAll { $0.0 <= calls.count }
            ready.forEach { $0.1.fulfill() }
        }
    }

    func expectCalls(_ count: Int, in test: XCTestCase) -> XCTestExpectation {
        let expectation = test.expectation(description: "Native analyzer call \(count)")
        if calls.count >= count { expectation.fulfill() } else { waiters.append((count, expectation)) }
        return expectation
    }

    func complete(_ index: Int, text: String) {
        guard calls.indices.contains(index) else { return XCTFail("Missing analyzer call \(index)") }
        let continuation = calls[index]
        calls[index] = nil
        continuation?.resume(returning: InlineImageTextAnalysis(text: text, nativeAnalysis: nil))
    }

    func fail(_ index: Int) {
        guard calls.indices.contains(index) else { return XCTFail("Missing analyzer call \(index)") }
        let continuation = calls[index]
        calls[index] = nil
        continuation?.resume(throwing: InlineTestError.failed)
    }
}

@MainActor
private final class ManualInlineFallback: TextRecognizer {
    var calls: [CheckedContinuation<ImageTextRecognitionResult, Error>?] = []
    var images: [CGImage] = []
    var completionCount = 0
    private var waiters: [(Int, XCTestExpectation)] = []

    func recognize(_ image: ToolImage) async throws -> ImageTextRecognitionResult {
        defer { completionCount += 1 }
        return try await withCheckedThrowingContinuation { continuation in
            images.append(image.cgImage)
            calls.append(continuation)
            let ready = waiters.filter { $0.0 <= calls.count }
            waiters.removeAll { $0.0 <= calls.count }
            ready.forEach { $0.1.fulfill() }
        }
    }

    func expectCalls(_ count: Int, in test: XCTestCase) -> XCTestExpectation {
        let expectation = test.expectation(description: "Fallback recognizer call \(count)")
        if calls.count >= count { expectation.fulfill() } else { waiters.append((count, expectation)) }
        return expectation
    }

    func complete(_ index: Int, text: String) {
        guard calls.indices.contains(index) else { return XCTFail("Missing fallback call \(index)") }
        let continuation = calls[index]
        calls[index] = nil
        continuation?.resume(returning: ImageTextRecognitionResult(lines: [ImageTextLine(text: text)]))
    }

    func fail(_ index: Int) {
        guard calls.indices.contains(index) else { return XCTFail("Missing fallback call \(index)") }
        let continuation = calls[index]
        calls[index] = nil
        continuation?.resume(throwing: InlineTestError.failed)
    }
}
