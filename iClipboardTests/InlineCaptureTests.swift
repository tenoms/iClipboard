import AppKit
import XCTest
@testable import iClipboard

@MainActor
final class InlineCaptureTests: XCTestCase {
    private var timeoutSleep: @MainActor (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }

    func testToolbarBelowNarrowCropCanBeWiderAndIsClampedToScreen() {
        let screen = CGRect(x: -1_440, y: -200, width: 1_440, height: 900)
        let crop = CGRect(x: -25, y: 300, width: 20, height: 100)
        let toolbar = ScreenCaptureWorkspacePlacement.toolbar(imageRect: crop, bounds: screen, preferredWidth: 548)
        XCTAssertGreaterThan(toolbar.width, crop.width)
        XCTAssertLessThan(toolbar.maxY, crop.minY)
        XCTAssertTrue(screen.insetBy(dx: 8, dy: 8).contains(toolbar))
    }

    func testToolbarMovesAboveBottomEdgeAndClampsForFullScreenCrop() {
        let screen = CGRect(x: 0, y: 0, width: 960, height: 640)
        let crop = CGRect(x: 2, y: 2, width: 80, height: 60)
        let toolbar = ScreenCaptureWorkspacePlacement.toolbar(imageRect: crop, bounds: screen, preferredWidth: 548)
        XCTAssertGreaterThan(toolbar.minY, crop.maxY)
        XCTAssertTrue(screen.contains(toolbar))
        let full = ScreenCaptureWorkspacePlacement.toolbar(imageRect: screen, bounds: screen, preferredWidth: 548)
        XCTAssertTrue(screen.contains(full), "A full-screen crop still keeps output controls reachable")
    }

    func testStableDetectionCandidateDoesNotInvalidateFrozenScreenOnEveryHover() async throws {
        let window = CaptureDetectionWindow(frame: CGRect(x: 140, y: 140, width: 600, height: 360),
                                             windowID: 11, ownerPID: 9001)
        let (capture, task, panel) = try await startCapture(detectionMode: .window, detectionWindows: [window])
        defer { capture.cancel() }
        let root = try XCTUnwrap(panel.contentView)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: CGPoint(x: 220, y: 320),
            modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            eventNumber: 1, clickCount: 0, pressure: 0))
        root.mouseMoved(with: event)
        root.displayIfNeeded()
        root.needsDisplay = false
        for _ in 0..<20 { root.mouseMoved(with: event) }
        XCTAssertFalse(root.needsDisplay, "Unchanged candidate and HUD position must not repaint the full frozen display")
        let before = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: before)
        panel.setDetectionCandidate(CaptureDetectionCandidate(rect: CGRect(x: 20, y: 20, width: 200, height: 100),
                                                              windowID: 12, ownerPID: 9002, kind: .window))
        let after = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: after)
        let x = 60 * after.pixelsWide / 960
        let y = (640 - 60) * after.pixelsHigh / 640
        let oldColor = try XCTUnwrap(before.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        let newColor = try XCTUnwrap(after.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(newColor.redComponent, oldColor.redComponent + 0.1,
                             "A changed candidate must really restore its selected pixels, not just toggle a dirty flag")
        capture.cancel()
        _ = try await task.value
    }

    func testExactCanvasTransformDoesNotFitPadOrAssumeUniformDisplayScale() {
        let transform = ImageCanvasTransform(pixelSize: CGSize(width: 300, height: 250),
                                             exactViewSize: CGSize(width: 200, height: 100))
        XCTAssertEqual(transform.imageRect, CGRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertEqual(transform.contentSize, CGSize(width: 200, height: 100))
        XCTAssertEqual(transform.viewPoint(fromPixel: CGPoint(x: 150, y: 125)), CGPoint(x: 100, y: 50))
        XCTAssertEqual(transform.pixelPoint(fromView: CGPoint(x: 100, y: 50)), CGPoint(x: 150, y: 125))
    }

    func testSyntheticMouseUpEntersInlineWorkspaceInSameWindowAndLocksCrop() async throws {
        let initialWindows = visibleWindowNumbers()
        let (capture, task, panel) = try await startCapture()
        defer { capture.cancel() }
        let windowNumber = panel.windowNumber
        try drag(panel, from: CGPoint(x: 180, y: 200), to: CGPoint(x: 480, y: 400))
        let workspace = try XCTUnwrap(panel.workspace)
        XCTAssertEqual(workspace.session.tool, .select)
        XCTAssertEqual(workspace.imageRect, CGRect(x: 180, y: 200, width: 300, height: 200))
        XCTAssertEqual(workspace.canvas.transform.imageRect.size, workspace.imageRect.size)
        XCTAssertNil(workspace.canvas.enclosingScrollView)
        XCTAssertEqual(workspace.window?.windowNumber, windowNumber)
        XCTAssertEqual(visibleWindowNumbers().subtracting(initialWindows), Set([windowNumber]))
        // Double-click now belongs to text/annotation selection, never crop finish.
        try mouse(panel, type: .leftMouseDown, at: CGPoint(x: 240, y: 280), clickCount: 2)
        try mouse(panel, type: .leftMouseUp, at: CGPoint(x: 240, y: 280), clickCount: 2)
        XCTAssertTrue(panel.workspace === workspace)
        XCTAssertEqual(capture.capturePanels.count, 1)
        try drag(panel, from: CGPoint(x: 600, y: 450), to: CGPoint(x: 700, y: 500))
        XCTAssertEqual(workspace.imageRect, CGRect(x: 180, y: 200, width: 300, height: 200))
        capture.cancel()
        let result = try await task.value
        XCTAssertNil(result)
        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(capture.capturePanels.isEmpty)
    }

    func testInteractiveCaptureHasNoDeadlineThatDiscardsUnsavedAnnotations() async throws {
        var deadlines: [UInt64] = []
        timeoutSleep = { nanoseconds in
            deadlines.append(nanoseconds)
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        let (capture, task, panel) = try await startCapture()
        defer { capture.cancel() }
        try drag(panel, from: CGPoint(x: 180, y: 200), to: CGPoint(x: 480, y: 400))
        let workspace = try XCTUnwrap(panel.workspace)
        workspace.session.document.add(ImageAnnotation(kind: .line, points: [.zero, CGPoint(x: 80, y: 80)]))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(panel.isVisible, "A preparation watchdog must never discard an interactive capture")
        XCTAssertTrue(panel.workspace === workspace)
        XCTAssertEqual(workspace.session.document.annotations.count, 1)
        XCTAssertEqual(deadlines, [20_000_000_000], "Only screen preparation has a timeout")
        capture.cancel()
        _ = try await task.value
    }

    func testCancelledSaveDoesNotRearmAnInteractiveCaptureDeadline() async throws {
        var deadlines: [UInt64] = []
        var savePanels = 0
        timeoutSleep = { nanoseconds in
            deadlines.append(nanoseconds)
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        let (capture, task, panel) = try await startCapture { action in
            if case let .saveImage(_, willPresentPanel) = action {
                willPresentPanel()
                savePanels += 1
            }
            return .cancelled
        }
        defer { capture.cancel() }
        try drag(panel, from: CGPoint(x: 180, y: 200), to: CGPoint(x: 480, y: 400))
        let workspace = try XCTUnwrap(panel.workspace)
        workspace.session.document.add(ImageAnnotation(kind: .line, points: [.zero, CGPoint(x: 80, y: 80)]))
        workspace.onAction?(.saveImage(workspace.session.document.original))
        await waitUntil { savePanels == 1 && !capture.isPerformingAction }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.workspace === workspace)
        XCTAssertTrue(workspace.session.document.canUndo)
        XCTAssertEqual(deadlines, [20_000_000_000])
        capture.cancel()
        _ = try await task.value
    }

    func testSaveCancelRestoresSamePanelDocumentAndUndoThenSuccessCompletes() async throws {
        var actions = 0
        var continuation: CheckedContinuation<ScreenCaptureActionOutcome, Error>?
        let (capture, task, panel) = try await startCapture { action in
            actions += 1
            if case let .saveImage(_, willPresentPanel) = action {
                willPresentPanel()
                return try await withCheckedThrowingContinuation { continuation = $0 }
            }
            return .completed
        }
        defer { capture.cancel(); continuation?.resume(returning: .cancelled) }
        try drag(panel, from: CGPoint(x: 180, y: 200), to: CGPoint(x: 480, y: 400))
        let workspace = try XCTUnwrap(panel.workspace)
        let document = workspace.session.document
        document.add(ImageAnnotation(kind: .line, points: [.zero, CGPoint(x: 80, y: 80)]))
        let revision = workspace.session.revision
        workspace.onAction?(.saveImage(try document.renderedImage()))
        await waitUntil { continuation != nil }
        XCTAssertTrue(capture.isPerformingAction)
        XCTAssertTrue(workspace.isBusy)
        XCTAssertFalse(panel.isVisible)
        workspace.session.undo()
        XCTAssertEqual(document.annotations.count, 1, "Busy freezes pixel editing")
        workspace.onAction?(.copyImage(document.original))
        XCTAssertEqual(actions, 1, "Repeated output is rejected while saving")
        continuation?.resume(returning: .cancelled)
        continuation = nil
        await waitUntil { !capture.isPerformingAction }
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.workspace === workspace)
        XCTAssertTrue(workspace.session.document === document)
        XCTAssertEqual(workspace.session.revision, revision)
        XCTAssertTrue(document.canUndo)
        workspace.session.undo()
        XCTAssertTrue(document.annotations.isEmpty)
        workspace.onAction?(.copyImage(document.original))
        let result = try await task.value
        guard case .completed? = result else { return XCTFail("Handled output must return completed") }
        XCTAssertEqual(actions, 2)
        XCTAssertFalse(panel.isVisible)
    }

    func testCancelledActionIgnoresLateSuccessAndDoesNotResurrectPanel() async throws {
        var continuation: CheckedContinuation<ScreenCaptureActionOutcome, Error>?
        let (capture, task, panel) = try await startCapture { _ in
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
        defer { capture.cancel(); continuation?.resume(returning: .cancelled) }
        try drag(panel, from: CGPoint(x: 180, y: 200), to: CGPoint(x: 480, y: 400))
        let workspace = try XCTUnwrap(panel.workspace)
        workspace.onAction?(.saveImage(workspace.session.document.original))
        await waitUntil { continuation != nil }
        capture.cancel()
        let result = try await task.value
        XCTAssertNil(result)
        continuation?.resume(returning: .completed)
        continuation = nil
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(panel.isVisible)
        XCTAssertNil(panel.workspace)
        XCTAssertTrue(capture.capturePanels.isEmpty)
    }

    func testOutputFailureKeepsEditsAndRetryAvailable() async throws {
        let (capture, task, panel) = try await startCapture { _ in throw ImageToolsError.encodingFailed }
        defer { capture.cancel() }
        try drag(panel, from: CGPoint(x: 180, y: 200), to: CGPoint(x: 480, y: 400))
        let workspace = try XCTUnwrap(panel.workspace)
        workspace.session.document.add(ImageAnnotation(kind: .brush, points: [CGPoint(x: 20, y: 20)]))
        workspace.onAction?(.copyImage(try workspace.session.document.renderedImage()))
        await waitUntil { !capture.isPerformingAction }
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.workspace === workspace)
        XCTAssertEqual(workspace.session.document.annotations.count, 1)
        XCTAssertFalse(workspace.isBusy)
        capture.cancel()
        _ = try await task.value
    }

    func testRightClickRoutingPreservesControlsAndCopiesPixelsWithoutClosing() async throws {
        var texts: [String] = []
        let (capture, task, panel) = try await startCapture { action in
            if case .copyText(let text) = action { texts.append(text) }
            return .completed
        }
        defer { capture.cancel() }
        try drag(panel, from: CGPoint(x: 180, y: 200), to: CGPoint(x: 480, y: 400))
        let workspace = try XCTUnwrap(panel.workspace)
        let toolbarPoint = CGPoint(x: workspace.toolbarFrame.midX, y: workspace.toolbarFrame.midY)
        let controlEvent = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: toolbarPoint,
                                                           modifierFlags: [], timestamp: 0,
                                                           windowNumber: panel.windowNumber, context: nil,
                                                           eventNumber: 2, clickCount: 1, pressure: 1))
        XCTAssertFalse(workspace.shouldSampleRightClick(controlEvent))
        workspace.rightMouseDown(with: controlEvent)
        XCTAssertTrue(panel.isVisible)
        let blankEvent = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown,
                                                         location: CGPoint(x: 900, y: 550),
                                                         modifierFlags: [], timestamp: 0,
                                                         windowNumber: panel.windowNumber, context: nil,
                                                         eventNumber: 3, clickCount: 1, pressure: 1))
        XCTAssertTrue(workspace.shouldSampleRightClick(blankEvent))
        workspace.setBusy(true)
        workspace.rightMouseDown(with: blankEvent)
        XCTAssertTrue(texts.isEmpty, "Busy ignores pixel sampling without opening a native context menu")
        workspace.setBusy(false)
        NSApp.sendEvent(blankEvent)
        await waitUntil { !texts.isEmpty && !capture.isPerformingAction }
        XCTAssertEqual(texts, ["#FFFFFF"])
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.workspace === workspace)
        XCTAssertTrue(workspace.statusText.contains("#FFFFFF"))
        capture.cancel()
        _ = try await task.value
    }

    func testCopyImageIgnoresCapsLockAndOtherNonShortcutFlags() async throws {
        let (capture, task, panel) = try await startCapture()
        defer { capture.cancel() }
        try drag(panel, from: CGPoint(x: 180, y: 200), to: CGPoint(x: 480, y: 400))
        let workspace = try XCTUnwrap(panel.workspace)
        var outputs = 0
        workspace.onAction = { _ in outputs += 1 }
        for flags: NSEvent.ModifierFlags in [[.command, .capsLock], [.command, .function, .numericPad]] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: flags, timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
            XCTAssertTrue(workspace.handleKey(event))
        }
        XCTAssertEqual(outputs, 2)
        capture.cancel()
        _ = try await task.value
    }

    func testUnconfiguredCommandShiftCDoesNotCopyTextOrImage() async throws {
        var outputs = 0
        let (capture, task, panel) = try await startCapture { _ in outputs += 1; return .completed }
        defer { capture.cancel() }
        try drag(panel, from: CGPoint(x: 180, y: 200), to: CGPoint(x: 480, y: 400))
        let workspace = try XCTUnwrap(panel.workspace)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command, .shift], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil, characters: "C", charactersIgnoringModifiers: "c",
            isARepeat: false, keyCode: 8))
        XCTAssertFalse(workspace.handleKey(event), "Full-text copy is exclusively the configured action, not an extra fixed key")
        XCTAssertEqual(outputs, 0)
        capture.cancel()
        _ = try await task.value
    }

    func testCopyAllTextCompletesWithoutClosingWorkspace() async throws {
        var copiedText: String?
        let (capture, task, panel) = try await startCapture { action in
            if case .copyText(let text) = action { copiedText = text }
            return .completed
        }
        defer { capture.cancel() }
        try drag(panel, from: CGPoint(x: 180, y: 200), to: CGPoint(x: 480, y: 400))
        let workspace = try XCTUnwrap(panel.workspace)
        workspace.onAction?(.copyText("Recognized text"))
        await waitUntil { copiedText != nil && !capture.isPerformingAction }
        XCTAssertEqual(copiedText, "Recognized text")
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.workspace === workspace)
        XCTAssertFalse(workspace.isBusy)
        capture.cancel()
        _ = try await task.value
    }

    func testDisplayChangeCancelsPendingActionAndLateResultCannotRestoreCapture() async throws {
        var continuation: CheckedContinuation<ScreenCaptureActionOutcome, Error>?
        let (capture, task, panel) = try await startCapture { _ in
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
        defer { capture.cancel(); continuation?.resume(returning: .cancelled) }
        try drag(panel, from: CGPoint(x: 180, y: 200), to: CGPoint(x: 480, y: 400))
        let workspace = try XCTUnwrap(panel.workspace)
        workspace.onAction?(.saveImage(workspace.session.document.original))
        await waitUntil { continuation != nil }
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let result = try await task.value
        XCTAssertNil(result)
        continuation?.resume(returning: .cancelled)
        continuation = nil
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(capture.capturePanels.isEmpty)
    }

    func testSyntheticDrawingInvalidatesOCRAndUndoCreatesFreshRevision() async throws {
        let (capture, task, panel) = try await startCapture()
        defer { capture.cancel() }
        try drag(panel, from: CGPoint(x: 180, y: 200), to: CGPoint(x: 480, y: 400))
        let workspace = try XCTUnwrap(panel.workspace)
        let originalRevision = workspace.session.revision
        workspace.session.tool = .mosaic
        for _ in 0..<5 { await Task.yield() }
        try mouse(panel, type: .leftMouseDown, at: CGPoint(x: 200, y: 380))
        try mouse(panel, type: .leftMouseDragged, at: CGPoint(x: 260, y: 320))
        XCTAssertEqual(workspace.textInteraction.phase, .idle)
        XCTAssertTrue(workspace.textInteraction.fullText.isEmpty, "Invalidate at the first real changed mosaic pixel, not a zero-area mouse down")
        try mouse(panel, type: .leftMouseUp, at: CGPoint(x: 260, y: 320))
        XCTAssertEqual(workspace.session.document.annotations.first?.kind, .mosaic)
        let mosaicRevision = workspace.session.revision
        XCTAssertNotEqual(mosaicRevision, originalRevision)
        workspace.session.undo()
        XCTAssertNotEqual(workspace.session.revision, mosaicRevision)
        XCTAssertEqual(workspace.textInteraction.phase, .analyzing, "Undo immediately registers the adapter's single debounced analysis")
        workspace.session.redo()
        XCTAssertNotEqual(workspace.session.revision, mosaicRevision)
        capture.cancel()
        _ = try await task.value
    }

    func testContextualCopyIsWindowLocalAndDoesNotStealUppercaseAnnotationInput() async throws {
        var outputs = 0
        var recognizedRequests = 0
        let (capture, task, panel) = try await startCapture { action in
            if case .copyRecognizedText = action { outputs += 1 }
            return .cancelled
        }
        defer { capture.cancel() }
        capture.onContextualKeyEvent = { event in
            guard event.keyCode == 8,
                  event.modifierFlags.intersection(KeyboardShortcut.supportedModifiers) == .shift,
                  let window = event.window, capture.canCopyRecognizedText(in: window) else { return false }
            recognizedRequests += 1
            capture.requestCurrentAction(.copyRecognizedText)
            return true
        }
        defer { capture.onContextualKeyEvent = nil }
        func shiftC(_ window: NSWindow) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: .shift, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "C",
                charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        }
        NSApp.sendEvent(try shiftC(panel))
        XCTAssertEqual(recognizedRequests, 0, "An unfinished selection must not consume a configured key")
        try drag(panel, from: CGPoint(x: 180, y: 200), to: CGPoint(x: 480, y: 400))
        let workspace = try XCTUnwrap(panel.workspace)
        XCTAssertTrue(capture.canCopyRecognizedText(in: panel))
        NSApp.sendEvent(try shiftC(panel))
        await waitUntil { !capture.isPerformingAction && outputs == 1 }
        XCTAssertEqual(recognizedRequests, 1)
        XCTAssertTrue(panel.isVisible)
        workspace.session.tool = .text
        for _ in 0..<5 { await Task.yield() }
        try mouse(panel, type: .leftMouseDown, at: CGPoint(x: 220, y: 350))
        try mouse(panel, type: .leftMouseUp, at: CGPoint(x: 220, y: 350))
        await waitUntil { panel.firstResponder is NSTextView }
        let editor = try XCTUnwrap(panel.firstResponder as? NSTextView)
        XCTAssertFalse(capture.canCopyRecognizedText(in: panel))
        NSApp.sendEvent(try shiftC(panel))
        XCTAssertEqual(editor.string, "C", "Shift+C must remain uppercase text while entering an annotation")
        XCTAssertEqual(recognizedRequests, 1)
        XCTAssertEqual(outputs, 1)
        capture.cancel()
        _ = try await task.value
    }

    func testTextInputEnterAndEscapePrecedeCopyAndCaptureCancellation() async throws {
        var outputs = 0
        let (capture, task, panel) = try await startCapture { _ in outputs += 1; return .completed }
        defer { capture.cancel() }
        try drag(panel, from: CGPoint(x: 180, y: 200), to: CGPoint(x: 480, y: 400))
        let workspace = try XCTUnwrap(panel.workspace)
        workspace.session.tool = .text
        for _ in 0..<5 { await Task.yield() }
        try mouse(panel, type: .leftMouseDown, at: CGPoint(x: 220, y: 350))
        try mouse(panel, type: .leftMouseUp, at: CGPoint(x: 220, y: 350))
        await waitUntil { panel.firstResponder is NSTextView }
        let editor = try XCTUnwrap(panel.firstResponder as? NSTextView)
        editor.insertText("Inline", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(workspace.handleKey(try key(panel, code: 36)))
        XCTAssertEqual(workspace.session.document.annotations.first?.text, "Inline")
        XCTAssertEqual(outputs, 0)
        workspace.session.tool = .text
        for _ in 0..<5 { await Task.yield() }
        try mouse(panel, type: .leftMouseDown, at: CGPoint(x: 240, y: 300))
        try mouse(panel, type: .leftMouseUp, at: CGPoint(x: 240, y: 300))
        await waitUntil { panel.firstResponder is NSTextView }
        XCTAssertTrue(workspace.handleKey(try key(panel, code: 53)))
        XCTAssertFalse(workspace.session.isEditingText)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(workspace.handleKey(try key(panel, code: 36)))
        let result = try await task.value
        guard case .completed? = result else { return XCTFail("Enter after input must copy image") }
        XCTAssertEqual(outputs, 1)
    }

    func testAnnotationSlidersShowCurrentNumericValuesWhileAdjustingAndOnReopen() async throws {
        let (capture, task, panel) = try await startCapture()
        defer { capture.cancel() }
        try drag(panel, from: CGPoint(x: 180, y: 160), to: CGPoint(x: 680, y: 460))
        let workspace = try XCTUnwrap(panel.workspace)
        func descendants<T: NSView>(_ view: NSView, type: T.Type) -> [T] {
            view.subviews.flatMap { child -> [T] in
                (child as? T).map { [$0] } ?? descendants(child, type: type)
            }
        }
        let button = try XCTUnwrap(descendants(workspace, type: NSButton.self).first {
            $0.toolTip == "线宽 / 字号 / 马赛克色块"
        })
        button.performClick(nil)
        await waitUntil { panel.childWindows?.isEmpty == false }
        let child = try XCTUnwrap(panel.childWindows?.first)
        let content = try XCTUnwrap(child.contentView)
        let sliders = descendants(content, type: NSSlider.self).sorted { $0.tag < $1.tag }
        XCTAssertEqual(sliders.count, 3)
        let defaults = ["4 px", "28 px", "14 px"]
        for (index, slider) in sliders.enumerated() {
            let label = try XCTUnwrap(descendants(content, type: NSTextField.self).first {
                $0.identifier?.rawValue == "annotation-value-\(index)"
            })
            XCTAssertEqual(label.stringValue, defaults[index])
            slider.doubleValue = Double([12, 56, 32][index])
            XCTAssertTrue(slider.sendAction(slider.action, to: slider.target))
            XCTAssertEqual(label.stringValue, "\([12, 56, 32][index]) px")
        }
        XCTAssertEqual(workspace.session.style.lineWidth, 12)
        XCTAssertEqual(workspace.session.style.fontSize, 56)
        XCTAssertEqual(workspace.session.mosaicBlockSize, 32)
        button.performClick(nil)
        for _ in 0..<10 { await Task.yield() }
        let reopened = try XCTUnwrap(panel.childWindows?.last?.contentView)
        XCTAssertEqual(descendants(reopened, type: NSTextField.self).first {
            $0.identifier?.rawValue == "annotation-value-1"
        }?.stringValue, "56 px")
        let bitmap = try XCTUnwrap(reopened.bitmapImageRepForCachingDisplay(in: reopened.bounds))
        reopened.cacheDisplay(in: reopened.bounds, to: bitmap)
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("icl-annotation-values-\(UUID().uuidString).png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: evidence)
        capture.cancel()
        _ = try await task.value
    }

    func testAddedTextStaysVisibleAndEditableWithoutBecomingNewOCRInput() async throws {
        let analyzer = CaptureCountingAnalyzer(text: "Only captured text")
        var copied = ""
        let (capture, task, panel) = try await startCapture(analyzer: analyzer) { action in
            if case .copyRecognizedText(let supplier) = action { copied = try await supplier() }
            return .completed
        }
        defer { capture.cancel() }
        try drag(panel, from: CGPoint(x: 180, y: 160), to: CGPoint(x: 680, y: 460))
        let workspace = try XCTUnwrap(panel.workspace)
        await waitUntil { workspace.textInteraction.phase == .ready }
        let source = workspace.session.document.original.cgImage
        workspace.session.tool = .text
        for _ in 0..<5 { await Task.yield() }
        try mouse(panel, type: .leftMouseDown, at: CGPoint(x: 220, y: 400))
        try mouse(panel, type: .leftMouseUp, at: CGPoint(x: 220, y: 400))
        await waitUntil { panel.firstResponder is NSTextView }
        let editor = try XCTUnwrap(panel.firstResponder as? NSTextView)
        editor.insertText("User annotation", replacementRange: NSRange(location: NSNotFound, length: 0))
        capture.requestCurrentAction(.copyRecognizedText)
        XCTAssertTrue(workspace.session.isEditingText, "The OCR shortcut must not commit or steal a text draft")
        XCTAssertFalse(capture.isPerformingAction)
        XCTAssertTrue(copied.isEmpty)
        XCTAssertTrue(workspace.handleKey(try key(panel, code: 36)))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(analyzer.calls, 1)
        XCTAssertTrue(analyzer.images.first === source)
        XCTAssertEqual(workspace.textInteraction.fullText, "Only captured text")
        XCTAssertFalse(try annotationInkBounds(workspace).isNull, "The OCR reference must not repaint over the annotation canvas")
        let referenceImage = try XCTUnwrap(workspace.textInteraction.subviews.compactMap { $0 as? NSImageView }.first)
        XCTAssertTrue(referenceImage.isHidden)
        XCTAssertTrue(workspace.textInteraction.imageContentView === workspace.canvas)
        let annotation = try XCTUnwrap(workspace.session.document.annotations.first)
        let pixel = CGPoint(x: annotation.bounds.midX, y: annotation.bounds.midY)
        let point = workspace.textInteraction.convert(workspace.canvas.transform.viewPoint(fromPixel: pixel), from: workspace.canvas)
        XCTAssertEqual(workspace.textInteraction.allowsTextInteractionAt?(point), false,
                       "Live Text must not intercept selection of an existing annotation")
        workspace.session.undo()
        workspace.session.redo()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(analyzer.calls, 1, "Text undo/redo does not change the OCR source")
        capture.requestCurrentAction(.copyRecognizedText)
        let result = try await task.value
        guard case .completed? = result else { return XCTFail("Copy should finish the active crop") }
        XCTAssertEqual(copied, "Only captured text")
        XCTAssertEqual(analyzer.calls, 1)
    }

    func testMosaicUpdatesRecognitionSourceWithoutIncludingTextAnnotations() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 960, height: 640, bitsPerComponent: 8,
                                              bytesPerRow: 960 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 960, height: 640))
        context.setFillColor(NSColor.black.cgColor)
        for x in stride(from: 0, to: 960, by: 8) { context.fill(CGRect(x: x, y: 0, width: 2, height: 640)) }
        let snapshot = ScreenCaptureSnapshot(displayID: 1, frame: CGRect(x: 0, y: 0, width: 960, height: 640),
                                             image: try XCTUnwrap(context.makeImage()))
        let analyzer = CaptureCountingAnalyzer(text: "Captured source")
        let (capture, task, panel) = try await startCapture(analyzer: analyzer, snapshots: [snapshot])
        defer { capture.cancel() }
        try drag(panel, from: CGPoint(x: 180, y: 160), to: CGPoint(x: 680, y: 460))
        let workspace = try XCTUnwrap(panel.workspace)
        await waitUntil { workspace.textInteraction.phase == .ready }
        workspace.session.document.add(ImageAnnotation(kind: .text, points: [CGPoint(x: 150, y: 20)],
            text: "ADDED LABEL", textSize: CGSize(width: 200, height: 50)))
        workspace.session.tool = .mosaic
        workspace.session.pointerDown(at: CGPoint(x: 20, y: 20), tolerance: 2, clickCount: 1)
        workspace.session.pointerDragged(to: CGPoint(x: 100, y: 100))
        XCTAssertEqual(workspace.textInteraction.phase, .idle)
        XCTAssertTrue(workspace.textInteraction.fullText.isEmpty, "No old text can be copied during a redaction gesture")
        workspace.session.pointerUp(at: CGPoint(x: 100, y: 100))
        await waitUntil { workspace.textInteraction.phase == .ready && analyzer.calls == 2 }
        let redactions = workspace.session.document.annotations.filter { $0.kind == .mosaic }
        let expected = ToolImage(cgImage: try ImageDocumentRenderer.render(
            original: workspace.session.document.original.cgImage, annotations: redactions))
        let recognizedImage = ToolImage(cgImage: try XCTUnwrap(analyzer.images.last))
        XCTAssertEqual(try recognizedImage.pngData(), try expected.pngData())
        XCTAssertNotEqual(try recognizedImage.pngData(), try workspace.session.document.renderedImage().pngData(),
                          "OCR must not receive the user-authored label, even after a privacy-source update")
        workspace.session.undo()
        await waitUntil { workspace.textInteraction.phase == .ready && analyzer.calls == 3 }
        XCTAssertTrue(analyzer.images.last === workspace.session.document.original.cgImage)
        workspace.session.undo()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(analyzer.calls, 3, "Undoing the remaining text label still reuses the unredacted crop analysis")
        capture.cancel()
        _ = try await task.value
    }

    func testTextGlyphsStayInPlaceWhenEnterCommitsAtDifferentPixelScales() async throws {
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("icl-text-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: false)
        for scale: CGFloat in [1, 1.5, 2] {
            let context = try XCTUnwrap(CGContext(data: nil, width: Int(960 * scale), height: Int(640 * scale),
                                                 bitsPerComponent: 8, bytesPerRow: Int(960 * scale) * 4,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 960 * scale, height: 640 * scale))
            let snapshot = ScreenCaptureSnapshot(displayID: 1, frame: CGRect(x: 0, y: 0, width: 960, height: 640),
                                                 image: try XCTUnwrap(context.makeImage()))
            let (capture, task, panel) = try await startCapture(snapshots: [snapshot])
            defer { capture.cancel() }
            try drag(panel, from: CGPoint(x: 180, y: 160), to: CGPoint(x: 680, y: 460))
            let workspace = try XCTUnwrap(panel.workspace)
            workspace.session.changeStyle { $0.fontSize = 36 }
            workspace.session.tool = .text
            for _ in 0..<5 { await Task.yield() }
            try mouse(panel, type: .leftMouseDown, at: CGPoint(x: 220, y: 400))
            try mouse(panel, type: .leftMouseUp, at: CGPoint(x: 220, y: 400))
            await waitUntil { panel.firstResponder is NSTextView }
            let editor = try XCTUnwrap(panel.firstResponder as? NSTextView)
            editor.insertText("Hello 世界\n第二行 gy", replacementRange: NSRange(location: NSNotFound, length: 0))
            editor.insertionPointColor = .gray // The caret is editing chrome, not annotation ink.
            let before = try annotationInkBounds(workspace, screenshot: evidence.appendingPathComponent("editing-\(scale)x.png"))
            XCTAssertTrue(workspace.handleKey(try key(panel, code: 36)))
            let after = try annotationInkBounds(workspace, screenshot: evidence.appendingPathComponent("committed-\(scale)x.png"))
            XCTAssertEqual(before.minX, after.minX, accuracy: 1, "Horizontal jump at pixel scale \(scale)")
            XCTAssertEqual(before.minY, after.minY, accuracy: 1, "Vertical jump at pixel scale \(scale)")
            XCTAssertEqual(before.width, after.width, accuracy: 1, "Font or wrapping changed at pixel scale \(scale)")
            XCTAssertEqual(before.height, after.height, accuracy: 1, "Line spacing changed at pixel scale \(scale)")
            capture.cancel()
            _ = try await task.value
        }
    }

    func testWrappedTextKeepsItsAnchorAndLineBreaksOnCommit() async throws {
        let (capture, task, panel) = try await startCapture()
        defer { capture.cancel() }
        try drag(panel, from: CGPoint(x: 180, y: 160), to: CGPoint(x: 680, y: 460))
        let workspace = try XCTUnwrap(panel.workspace)
        workspace.session.changeStyle { $0.fontSize = 40 }
        workspace.session.tool = .text
        for _ in 0..<5 { await Task.yield() }
        try mouse(panel, type: .leftMouseDown, at: CGPoint(x: 500, y: 420))
        try mouse(panel, type: .leftMouseUp, at: CGPoint(x: 500, y: 420))
        await waitUntil { panel.firstResponder is NSTextView }
        let editor = try XCTUnwrap(panel.firstResponder as? NSTextView)
        editor.insertText("Hello 世界 wrapped text", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.insertionPointColor = .gray
        let before = try annotationInkBounds(workspace)
        XCTAssertTrue(workspace.handleKey(try key(panel, code: 36)))
        let after = try annotationInkBounds(workspace)
        XCTAssertGreaterThan(after.height, 100, "The fixture must actually wrap")
        XCTAssertEqual(before.minX, after.minX, accuracy: 1)
        XCTAssertEqual(before.minY, after.minY, accuracy: 1)
        XCTAssertEqual(before.width, after.width, accuracy: 1)
        XCTAssertEqual(before.height, after.height, accuracy: 1)
        capture.cancel()
        _ = try await task.value
    }

    func testTextNearScreenEdgeDoesNotRepositionTheInputAwayFromItsAnchor() async throws {
        let (capture, task, panel) = try await startCapture()
        defer { capture.cancel() }
        try drag(panel, from: CGPoint(x: 580, y: 80), to: CGPoint(x: 940, y: 280))
        let workspace = try XCTUnwrap(panel.workspace)
        workspace.session.tool = .text
        for _ in 0..<5 { await Task.yield() }
        try mouse(panel, type: .leftMouseDown, at: CGPoint(x: 910, y: 100))
        try mouse(panel, type: .leftMouseUp, at: CGPoint(x: 910, y: 100))
        await waitUntil { panel.firstResponder is NSTextView }
        let editor = try XCTUnwrap(panel.firstResponder as? NSTextView)
        editor.insertText("UI", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.insertionPointColor = .gray
        let before = try annotationInkBounds(workspace)
        XCTAssertTrue(workspace.handleKey(try key(panel, code: 36)))
        let after = try annotationInkBounds(workspace)
        XCTAssertEqual(workspace.session.document.annotations.first?.points.first, CGPoint(x: 330, y: 180))
        XCTAssertEqual(before.minX, after.minX, accuracy: 1)
        XCTAssertEqual(before.minY, after.minY, accuracy: 1)
        XCTAssertEqual(before.width, after.width, accuracy: 1)
        XCTAssertEqual(before.height, after.height, accuracy: 1)
        capture.cancel()
        _ = try await task.value
    }

    private func annotationInkBounds(_ workspace: ScreenCaptureWorkspace, screenshot: URL? = nil) throws -> CGRect {
        workspace.layoutSubtreeIfNeeded()
        workspace.displayIfNeeded()
        let bitmap = try XCTUnwrap(workspace.bitmapImageRepForCachingDisplay(in: workspace.imageRect))
        workspace.cacheDisplay(in: workspace.imageRect, to: bitmap)
        if let screenshot { try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: screenshot) }
        var bounds = CGRect.null
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      color.redComponent > 0.7, color.greenComponent < 0.5, color.blueComponent < 0.5 else { continue }
                bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        XCTAssertFalse(bounds.isNull, "The editable annotation must use the same visible color as the exported text")
        return bounds
    }

    func testReselectClearsDocumentAndStartsFreshWorkspaceWithoutNewWindow() async throws {
        let (capture, task, panel) = try await startCapture()
        defer { capture.cancel() }
        try drag(panel, from: CGPoint(x: 180, y: 200), to: CGPoint(x: 480, y: 400))
        let old = try XCTUnwrap(panel.workspace)
        old.session.document.add(ImageAnnotation(kind: .line, points: [.zero, CGPoint(x: 20, y: 20)]))
        old.onReselect?()
        XCTAssertNil(panel.workspace)
        try drag(panel, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 200))
        let fresh = try XCTUnwrap(panel.workspace)
        XCTAssertFalse(old === fresh)
        XCTAssertTrue(fresh.session.document.annotations.isEmpty)
        XCTAssertFalse(fresh.session.document.canUndo)
        XCTAssertEqual(fresh.session.tool, .select)
        XCTAssertEqual(capture.capturePanels.count, 1)
        capture.cancel()
        _ = try await task.value
    }

    func testCurrentPinCommitsInputAndRendersLiveAnnotationsNotPreviousClipboard() async throws {
        var pinned: ToolImage?
        var anchor: CGRect?
        let (capture, task, panel) = try await startCapture { action in
            if case .pinImage(let image, let rect) = action { pinned = image; anchor = rect }
            return .completed
        }
        defer { capture.cancel() }
        capture.requestCurrentAction(.pin)
        XCTAssertNil(pinned, "An unfinished selection is ignored")
        try drag(panel, from: CGPoint(x: 180, y: 200), to: CGPoint(x: 480, y: 400))
        let workspace = try XCTUnwrap(panel.workspace)
        workspace.session.tool = .brush
        for _ in 0..<5 { await Task.yield() }
        try mouse(panel, type: .leftMouseDown, at: CGPoint(x: 210, y: 380))
        try mouse(panel, type: .leftMouseDragged, at: CGPoint(x: 260, y: 350))
        try mouse(panel, type: .leftMouseUp, at: CGPoint(x: 260, y: 350))
        workspace.session.tool = .text
        for _ in 0..<5 { await Task.yield() }
        try mouse(panel, type: .leftMouseDown, at: CGPoint(x: 230, y: 300))
        try mouse(panel, type: .leftMouseUp, at: CGPoint(x: 230, y: 300))
        await waitUntil { panel.firstResponder is NSTextView }
        let editor = try XCTUnwrap(panel.firstResponder as? NSTextView)
        editor.insertText("Current crop", replacementRange: NSRange(location: NSNotFound, length: 0))
        capture.requestCurrentAction(.pin)
        XCTAssertEqual(workspace.session.document.annotations.map(\.kind), [.brush, .text])
        let expected = try workspace.session.document.renderedImage().pngData()
        let result = try await task.value
        guard case .completed? = result else { return XCTFail("Pin is terminal") }
        XCTAssertEqual(try pinned?.pngData(), expected)
        XCTAssertEqual(anchor, CGRect(x: 180, y: 200, width: 300, height: 200))
    }

    func testRecognitionShortcutAfterSelectionAwaitsSharedAnalysisAndExitsOnSuccess() async throws {
        let analyzer = CaptureCountingAnalyzer(text: "One shared native transcript")
        var copied = ""
        var actions = 0
        let (capture, task, panel) = try await startCapture(analyzer: analyzer) { action in
            guard case .copyRecognizedText(let supplier) = action else { return .cancelled }
            actions += 1
            copied = try await supplier()
            return .completed
        }
        defer { capture.cancel() }
        capture.requestCurrentAction(.copyRecognizedText)
        XCTAssertEqual(actions, 0, "No selection means no OCR output or new capture")
        try drag(panel, from: CGPoint(x: 180, y: 200), to: CGPoint(x: 480, y: 400))
        XCTAssertNotNil(panel.workspace)
        XCTAssertEqual(actions, 0, "Finishing a regular crop never automatically copies text")
        XCTAssertFalse(capture.isPerformingAction)
        capture.requestCurrentAction(.copyRecognizedText)
        capture.requestCurrentAction(.pin)
        let result = try await task.value
        guard case .completed? = result else { return XCTFail("Explicit selection-only OCR should finish after copying") }
        XCTAssertEqual(copied, "One shared native transcript")
        XCTAssertEqual(actions, 1, "Busy global shortcuts cannot enqueue another output")
        XCTAssertEqual(analyzer.calls, 1, "Terminal OCR reuses the workspace's native analysis")
        XCTAssertFalse(panel.isVisible)
    }

    func testEmptyExplicitOCRPreservesCallerContentsAndOffersReselect() async throws {
        let analyzer = CaptureCountingAnalyzer(text: " \n ")
        var callerClipboard = "Keep existing clipboard"
        let (capture, task, panel) = try await startCapture(analyzer: analyzer) { action in
            if case .copyRecognizedText(let supplier) = action { callerClipboard = try await supplier() }
            return .completed
        }
        defer { capture.cancel() }
        try drag(panel, from: CGPoint(x: 180, y: 200), to: CGPoint(x: 480, y: 400))
        let workspace = try XCTUnwrap(panel.workspace)
        capture.requestCurrentAction(.copyRecognizedText)
        await waitUntil { !capture.isPerformingAction && workspace.statusText.contains("未识别到文字") }
        XCTAssertEqual(callerClipboard, "Keep existing clipboard")
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(workspace.isBusy)
        workspace.onReselect?()
        XCTAssertNil(panel.workspace)
        capture.cancel()
        _ = try await task.value
    }

    func testOrdinaryMouseClicksReuseAnalysisAndStateChangesKeepCanvasCursor() async throws {
        let analyzer = CaptureCountingAnalyzer(text: "Cached")
        let (capture, task, panel) = try await startCapture(analyzer: analyzer)
        defer { capture.cancel() }
        try drag(panel, from: CGPoint(x: 180, y: 200), to: CGPoint(x: 480, y: 400))
        let workspace = try XCTUnwrap(panel.workspace)
        await waitUntil { workspace.textInteraction.phase == .ready }
        let revision = workspace.session.revision
        let cursorCount = workspace.canvasCursorInvalidationCount
        for _ in 0..<5 {
            try mouse(panel, type: .leftMouseDown, at: CGPoint(x: 200, y: 350))
            try mouse(panel, type: .leftMouseUp, at: CGPoint(x: 200, y: 350))
            workspace.textInteraction.onStateChange?()
        }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(analyzer.calls, 1)
        XCTAssertEqual(workspace.session.revision, revision)
        XCTAssertEqual(workspace.canvasCursorInvalidationCount, cursorCount)
        workspace.session.tool = .brush
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(workspace.canvasCursorInvalidationCount, cursorCount + 1)
        // Drawing and cancelling a non-redaction preview reuse the crop's OCR.
        workspace.session.pointerDown(at: CGPoint(x: 10, y: 10), tolerance: 2, clickCount: 1)
        XCTAssertEqual(workspace.textInteraction.phase, .ready)
        workspace.session.cancelGesture()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(workspace.textInteraction.phase, .ready)
        XCTAssertEqual(analyzer.calls, 1)
        XCTAssertEqual(workspace.session.revision, revision)
        capture.cancel()
        _ = try await task.value
    }

    func testRightClickBeforeSelectionAndEditedCropPreserveDocumentAndUndo() async throws {
        var texts: [String] = []
        let (capture, task, panel) = try await startCapture { action in
            if case .copyText(let value) = action { texts.append(value) }
            return .completed
        }
        defer { capture.cancel() }
        try appRightClick(panel, at: CGPoint(x: 50, y: 500))
        await waitUntil { texts.count == 1 && !capture.isPerformingAction }
        XCTAssertEqual(texts, ["#FFFFFF"], "Preselection samples frozen pixels, not the dimmed overlay")
        XCTAssertNil(panel.workspace)
        try drag(panel, from: CGPoint(x: 180, y: 200), to: CGPoint(x: 480, y: 400))
        let workspace = try XCTUnwrap(panel.workspace)
        let document = workspace.session.document
        var blue = ImageAnnotationStyle()
        blue.setColor(.blue)
        blue.lineWidth = 30
        document.add(ImageAnnotation(kind: .brush, points: [CGPoint(x: 50, y: 50)], style: blue))
        let revision = workspace.session.revision
        let expected = workspace.session.currentFlattenedImage.color(at: CGPoint(x: 50, y: 50))?.hex
        try appRightClick(panel, at: CGPoint(x: 230, y: 350))
        await waitUntil { texts.count == 2 && !capture.isPerformingAction }
        XCTAssertEqual(texts.last, expected)
        XCTAssertNotEqual(texts.last, "#FFFFFF", "Edited crop must not sample the old snapshot")
        XCTAssertEqual(workspace.session.revision, revision)
        XCTAssertTrue(workspace.session.document === document)
        XCTAssertTrue(document.canUndo)
        XCTAssertTrue(panel.workspace === workspace)
        capture.cancel()
        _ = try await task.value
    }

    func testColorDotAndCaptureOwnedNativePanelDoNotHijackSharedColorPanel() async throws {
        let (capture, task, panel) = try await startCapture()
        defer { capture.cancel() }
        try drag(panel, from: CGPoint(x: 180, y: 200), to: CGPoint(x: 480, y: 400))
        let workspace = try XCTUnwrap(panel.workspace)
        workspace.session.changeStyle { $0.setColor(.systemPurple) }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(workspace.colorButton.contentTintColor, workspace.session.style.nsColor)
        let shared = NSColorPanel.shared
        let sharedLevel = shared.level
        let sharedVisible = shared.isVisible
        let sharedColor = shared.color
        workspace.showCustomColors()
        let custom = try XCTUnwrap(workspace.customColorPanel)
        XCTAssertFalse(custom === shared)
        XCTAssertTrue(custom.isVisible)
        XCTAssertGreaterThan(custom.level.rawValue, panel.level.rawValue)
        custom.color = .systemGreen
        XCTAssertTrue(NSApp.sendAction(NSSelectorFromString("customColorChanged:"), to: workspace, from: custom))
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(workspace.colorButton.contentTintColor, workspace.session.style.nsColor)
        XCTAssertEqual(shared.level, sharedLevel)
        XCTAssertEqual(shared.isVisible, sharedVisible)
        XCTAssertEqual(shared.color, sharedColor)
        workspace.onReselect?()
        XCTAssertFalse(custom.isVisible)
        XCTAssertNil(workspace.customColorPanel)
        XCTAssertEqual(shared.level, sharedLevel)
        XCTAssertEqual(shared.isVisible, sharedVisible)
        capture.cancel()
        _ = try await task.value
    }

    func testCompositeKeepsFrozenScreenAtEightyFourPercentAndCropAtOriginalBrightness() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 960, height: 640,
                                              bitsPerComponent: 8, bytesPerRow: 960 * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor(srgbRed: 0.8, green: 0.6, blue: 0.4, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 960, height: 640))
        context.setFillColor(NSColor(srgbRed: 0.4, green: 0.8, blue: 0.6, alpha: 1).cgColor)
        context.fill(CGRect(x: 100, y: 450, width: 100, height: 140))
        let snapshot = ScreenCaptureSnapshot(displayID: 1, frame: CGRect(x: 0, y: 0, width: 960, height: 640),
                                             image: try XCTUnwrap(context.makeImage()))
        let (capture, task, panel) = try await startCapture(snapshots: [snapshot])
        defer { capture.cancel() }
        try drag(panel, from: CGPoint(x: 240, y: 220), to: CGPoint(x: 600, y: 430))
        let workspace = try XCTUnwrap(panel.workspace)
        XCTAssertFalse(workspace.isOpaque)
        XCTAssertEqual(workspace.layer?.backgroundColor?.alpha, 0)
        let root = try XCTUnwrap(panel.contentView)
        root.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: bitmap)
        let composite = ToolImage(cgImage: try XCTUnwrap(bitmap.cgImage))
        func rendered(_ point: CGPoint) throws -> SampledImageColor {
            try XCTUnwrap(composite.color(at: CGPoint(x: point.x * CGFloat(bitmap.pixelsWide) / 960,
                                                       y: (640 - point.y) * CGFloat(bitmap.pixelsHigh) / 640)))
        }
        let outside = try rendered(CGPoint(x: 40, y: 550))
        let otherOutside = try rendered(CGPoint(x: 150, y: 550))
        XCTAssertNotEqual(outside, otherOutside, "Ready must retain the patterned frozen desktop, never a solid full-screen workspace")
        XCTAssertEqual(outside.red, Int((204.0 * 0.84).rounded()), accuracy: 2)
        XCTAssertEqual(outside.green, Int((153.0 * 0.84).rounded()), accuracy: 2)
        XCTAssertEqual(outside.blue, Int((102.0 * 0.84).rounded()), accuracy: 2)
        let inside = try rendered(CGPoint(x: 350, y: 330))
        XCTAssertEqual(inside.red, 204, accuracy: 2)
        XCTAssertEqual(inside.green, 153, accuracy: 2)
        XCTAssertEqual(inside.blue, 102, accuracy: 2)
        capture.cancel()
        _ = try await task.value
    }

    func testRightClickOnOtherOwnedDisplayStillCopiesThatFrozenScreen() async throws {
        func snapshot(id: UInt32, x: CGFloat, color: NSColor) throws -> ScreenCaptureSnapshot {
            let context = try XCTUnwrap(CGContext(data: nil, width: 480, height: 320, bitsPerComponent: 8,
                                                  bytesPerRow: 480 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 480, height: 320))
            return ScreenCaptureSnapshot(displayID: id, frame: CGRect(x: x, y: 0, width: 480, height: 320),
                                         image: try XCTUnwrap(context.makeImage()))
        }
        var texts: [String] = []
        let snapshots = [try snapshot(id: 1, x: 0, color: .white), try snapshot(id: 2, x: -480, color: .blue)]
        let (capture, task, panel) = try await startCapture(snapshots: snapshots) { action in
            if case .copyText(let text) = action { texts.append(text) }
            return .completed
        }
        defer { capture.cancel() }
        try drag(panel, from: CGPoint(x: 180, y: 100), to: CGPoint(x: 380, y: 260))
        let workspace = try XCTUnwrap(panel.workspace)
        let other = try XCTUnwrap(capture.capturePanels.first { $0.displayID == 2 })
        try appRightClick(other, at: CGPoint(x: 100, y: 100))
        await waitUntil { texts.count == 1 && !capture.isPerformingAction }
        XCTAssertEqual(texts, ["#0000FF"])
        XCTAssertTrue(panel.workspace === workspace)
        XCTAssertTrue(other.selectionLockedElsewhere)
        XCTAssertTrue(other.isVisible)
        capture.cancel()
        _ = try await task.value
    }

    func testWindowDetectionClickUsesFrontCandidateInExistingPanel() async throws {
        let front = CaptureDetectionWindow(frame: CGRect(x: 150, y: 120, width: 620, height: 400),
                                            windowID: 20, ownerPID: 9001)
        let back = CaptureDetectionWindow(frame: CGRect(x: 40, y: 40, width: 850, height: 550),
                                           windowID: 21, ownerPID: 9002)
        let (capture, task, panel) = try await startCapture(detectionMode: .window, detectionWindows: [front, back])
        defer { capture.cancel() }
        try mouse(panel, type: .mouseMoved, at: CGPoint(x: 250, y: 250))
        try mouse(panel, type: .leftMouseDown, at: CGPoint(x: 250, y: 250))
        XCTAssertFalse(panel.selectionLockedElsewhere)
        try mouse(panel, type: .leftMouseUp, at: CGPoint(x: 250, y: 250))
        let workspace = try XCTUnwrap(panel.workspace)
        XCTAssertEqual(workspace.imageRect, front.frame)
        XCTAssertTrue(workspace.window === panel)
        capture.cancel()
        _ = try await task.value
    }

    func testFullDisplayDockSurfaceDoesNotPreventWindowCaptureOnNegativeOriginExternalPanel() async throws {
        let mainFrame = CGRect(x: 0, y: 0, width: 960, height: 640)
        let externalFrame = CGRect(x: -640, y: 120, width: 640, height: 480)
        let applicationFrame = CGRect(x: -580, y: 180, width: 420, height: 300)
        func snapshot(id: UInt32, frame: CGRect) throws -> ScreenCaptureSnapshot {
            let context = try XCTUnwrap(CGContext(data: nil, width: Int(frame.width), height: Int(frame.height),
                                                  bitsPerComponent: 8, bytesPerRow: Int(frame.width) * 4,
                                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(origin: .zero, size: frame.size))
            return ScreenCaptureSnapshot(displayID: id, frame: frame, image: try XCTUnwrap(context.makeImage()))
        }
        let snapshots = [try snapshot(id: 1, frame: mainFrame), try snapshot(id: 2, frame: externalFrame)]
        let coordinates = CaptureDetectionCoordinates(primaryHeight: 640, displayFrames: [mainFrame, externalFrame])
        func description(id: Int, pid: Int, layer: Int, frame: CGRect) -> [String: Any] {
            [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid,
             kCGWindowLayer as String: layer, kCGWindowAlpha as String: 1,
             kCGWindowBounds as String: coordinates.quartzRect(fromGlobalAppKit: frame).dictionaryRepresentation]
        }
        let windows = CaptureDetectionWindow.parse([
            description(id: 1, pid: 12, layer: Int(CGWindowLevelForKey(.dockWindow)), frame: externalFrame),
            description(id: 2, pid: 42, layer: 0, frame: applicationFrame)
        ], excludingPID: 100, coordinates: coordinates, displayFrames: coordinates.displayFrames,
            ownerBundleIdentifier: { $0 == 12 ? "com.apple.dock" : nil })
        let (capture, task, mainPanel) = try await startCapture(snapshots: snapshots, detectionMode: .window,
                                                               detectionWindows: windows)
        defer { capture.cancel() }
        let externalPanel = try XCTUnwrap(capture.capturePanels.first { $0.displayID == 2 })
        externalPanel.makeKey()
        let localPoint = CGPoint(x: 150, y: 200)
        try mouse(externalPanel, type: .mouseMoved, at: localPoint)
        try mouse(externalPanel, type: .leftMouseDown, at: localPoint)
        try mouse(externalPanel, type: .leftMouseUp, at: localPoint)
        let workspace = try XCTUnwrap(externalPanel.workspace)
        XCTAssertEqual(workspace.imageRect, CGRect(x: 60, y: 60, width: 420, height: 300))
        XCTAssertEqual(workspace.session.document.original.pixelSize, CGSize(width: 420, height: 300))
        XCTAssertTrue(mainPanel.selectionLockedElsewhere)
        XCTAssertTrue(workspace.window === externalPanel)
        capture.cancel()
        _ = try await task.value
    }

    func testManualDragOverridesWindowCandidateAndNoneModeHasNoAutoClick() async throws {
        let window = CaptureDetectionWindow(frame: CGRect(x: 50, y: 50, width: 850, height: 550),
                                             windowID: 11, ownerPID: 9001)
        let (capture, task, panel) = try await startCapture(detectionMode: .window, detectionWindows: [window])
        try mouse(panel, type: .mouseMoved, at: CGPoint(x: 200, y: 200))
        try drag(panel, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 410, y: 330))
        XCTAssertEqual(panel.workspace?.imageRect, CGRect(x: 200, y: 200, width: 210, height: 130))
        capture.cancel()
        _ = try await task.value
        let (manual, manualTask, manualPanel) = try await startCapture(detectionMode: .none, detectionWindows: [window])
        defer { manual.cancel() }
        try mouse(manualPanel, type: .mouseMoved, at: CGPoint(x: 200, y: 200))
        try mouse(manualPanel, type: .leftMouseDown, at: CGPoint(x: 200, y: 200))
        try mouse(manualPanel, type: .leftMouseUp, at: CGPoint(x: 200, y: 200))
        XCTAssertNil(manualPanel.workspace)
        try drag(manualPanel, from: CGPoint(x: 210, y: 210), to: CGPoint(x: 350, y: 350))
        XCTAssertNotNil(manualPanel.workspace)
        manual.cancel()
        _ = try await manualTask.value
    }

    func testDraggingAwayAndReturningDoesNotBecomeWindowClickOrLockSelection() async throws {
        let window = CaptureDetectionWindow(frame: CGRect(x: 50, y: 50, width: 850, height: 550),
                                             windowID: 11, ownerPID: 9001)
        let (capture, task, panel) = try await startCapture(detectionMode: .window, detectionWindows: [window])
        defer { capture.cancel() }
        try mouse(panel, type: .mouseMoved, at: CGPoint(x: 200, y: 200))
        try mouse(panel, type: .leftMouseDown, at: CGPoint(x: 200, y: 200))
        try mouse(panel, type: .leftMouseDragged, at: CGPoint(x: 500, y: 400))
        try mouse(panel, type: .leftMouseUp, at: CGPoint(x: 200, y: 200))
        XCTAssertNil(panel.workspace, "A drag returning to its origin must not adopt the automatic window")
        try drag(panel, from: CGPoint(x: 220, y: 220), to: CGPoint(x: 380, y: 380))
        XCTAssertNotNil(panel.workspace, "An aborted manual drag must release its display lock")
        capture.cancel()
        _ = try await task.value
    }

    func testQuickSaveKeepsScreenshotVisibleUntilItsWriteCompletes() async throws {
        var continuation: CheckedContinuation<ScreenCaptureActionOutcome, Error>?
        let (capture, task, panel) = try await startCapture { _ in
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
        defer { capture.cancel(); continuation?.resume(returning: .cancelled) }
        try drag(panel, from: CGPoint(x: 180, y: 200), to: CGPoint(x: 480, y: 400))
        let workspace = try XCTUnwrap(panel.workspace)
        workspace.onAction?(.saveImage(workspace.session.document.original))
        await waitUntil { continuation != nil }
        XCTAssertTrue(panel.isVisible, "Only a real save-panel presentation may hide the capture")
        XCTAssertTrue(workspace.isBusy)
        continuation?.resume(returning: .completed)
        continuation = nil
        _ = try await task.value
        XCTAssertFalse(panel.isVisible)
    }

    func testPixelHUDIsIntegratedDuringSelectionAndOptionHoverButNotPNG() async throws {
        let (capture, task, panel) = try await startCapture()
        defer { capture.cancel() }
        try mouse(panel, type: .mouseMoved, at: CGPoint(x: 100, y: 100))
        let root = try XCTUnwrap(panel.contentView)
        let hud = try XCTUnwrap(root.subviews.compactMap { $0 as? CapturePixelHUD }.first)
        XCTAssertFalse(hud.isHidden)
        XCTAssertEqual(hud.sampledColor?.hex, "#FFFFFF")
        XCTAssertNil(hud.hitTest(.zero))
        try drag(panel, from: CGPoint(x: 180, y: 200), to: CGPoint(x: 480, y: 400))
        let workspace = try XCTUnwrap(panel.workspace)
        XCTAssertTrue(hud.isHidden)
        let point = panel.convertPoint(toScreen: CGPoint(x: 240, y: 300))
        panel.updatePixelPreview(at: point, modifiers: .option)
        XCTAssertFalse(hud.isHidden)
        XCTAssertTrue(hud.superview === workspace.superview)
        XCTAssertGreaterThan(root.subviews.firstIndex(of: hud)!, root.subviews.firstIndex(of: workspace)!)
        let rendered = try workspace.session.document.renderedImage()
        XCTAssertEqual(rendered.pixelSize, CGSize(width: 300, height: 200))
        XCTAssertEqual(rendered.color(at: CGPoint(x: 30, y: 30))?.hex, "#FFFFFF")
        panel.updatePixelPreview(at: point, modifiers: [])
        XCTAssertTrue(hud.isHidden)
        capture.cancel()
        _ = try await task.value
    }

    func testAutomaticCandidateAndColorHUDRenderInSamePanel() async throws {
        let window = CaptureDetectionWindow(frame: CGRect(x: 140, y: 140, width: 600, height: 360),
                                             windowID: 11, ownerPID: 9001)
        let (capture, task, panel) = try await startCapture(detectionMode: .window, detectionWindows: [window])
        defer { capture.cancel() }
        try mouse(panel, type: .mouseMoved, at: CGPoint(x: 220, y: 320))
        let view = try XCTUnwrap(panel.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("icl-round4-window-hud.png"))
        XCTAssertNil(panel.workspace)
        XCTAssertEqual(capture.capturePanels.count, 1)
        capture.cancel()
        _ = try await task.value
    }

    private func appRightClick(_ panel: NSWindow, at point: CGPoint) throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: panel.windowNumber, context: nil,
                                                    eventNumber: 9, clickCount: 1, pressure: 1))
        NSApp.sendEvent(event)
    }

    private func startCapture(intent: ScreenCaptureSession.Intent = .image,
                              analyzer: CaptureCountingAnalyzer? = nil,
                              snapshots: [ScreenCaptureSnapshot]? = nil,
                              detectionMode: CaptureDetectionMode = .none,
                              detectionWindows: [CaptureDetectionWindow] = [],
                              handler: ScreenCaptureActionHandler? = nil) async throws
        -> (ScreenCaptureSession, Task<ScreenCaptureSession.Result?, Error>, ScreenCaptureOverlayPanel) {
        let app = NSApplication.shared
        if !app.isRunning { app.finishLaunching() }
        let context = try XCTUnwrap(CGContext(data: nil, width: 960, height: 640,
                                              bitsPerComponent: 8, bytesPerRow: 960 * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 960, height: 640))
        let snapshot = ScreenCaptureSnapshot(displayID: 1, frame: CGRect(x: 0, y: 0, width: 960, height: 640),
                                             image: try XCTUnwrap(context.makeImage()))
        let capture = ScreenCaptureSession(providerFactory: { InlineCaptureProvider(snapshots: snapshots ?? [snapshot]) },
                                           accessCheck: { true }, accessRequest: { XCTFail("No TCC in tests"); return false },
                                           textInteractionFactory: analyzer.map { analyzer in
            { InlineImageTextInteraction(analyzer: analyzer, fallbackRecognizer: CaptureNeverFallback(),
                                         debounceNanoseconds: 0) }
        }, detectionModeProvider: { detectionMode },
           detectionWindowsProvider: { _ in detectionWindows }, timeoutSleep: timeoutSleep)
        let task = Task { try await capture.run(intent, onAction: handler) }
        await waitUntil { !capture.capturePanels.isEmpty }
        guard let panel = capture.capturePanels.first else {
            capture.cancel()
            _ = try? await task.value
            throw XCTUnwrapErrorForCapture()
        }
        // NSWindow's normal mouse dispatch requires the activation notification.
        try await Task.sleep(nanoseconds: 60_000_000)
        panel.makeKey()
        return (capture, task, panel)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Timed out waiting for capture UI state")
    }

    private func visibleWindowNumbers() -> Set<Int> {
        Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
    }

    private func drag(_ panel: NSWindow, from: CGPoint, to: CGPoint) throws {
        try mouse(panel, type: .leftMouseDown, at: from)
        try mouse(panel, type: .leftMouseDragged, at: to)
        try mouse(panel, type: .leftMouseUp, at: to)
    }

    private func mouse(_ panel: NSWindow, type: NSEvent.EventType, at: CGPoint, clickCount: Int = 1) throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: at, modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: panel.windowNumber, context: nil,
                                                    eventNumber: 1, clickCount: clickCount, pressure: 1))
        panel.sendEvent(event)
    }

    private func key(_ panel: NSWindow, code: UInt16) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: panel.windowNumber, context: nil,
                                      characters: code == 36 ? "\r" : "\u{1B}",
                                      charactersIgnoringModifiers: code == 36 ? "\r" : "\u{1B}",
                                      isARepeat: false, keyCode: code))
    }
}

@MainActor
private final class CaptureCountingAnalyzer: InlineImageTextAnalyzing {
    var isSupported = true
    var calls = 0
    var images: [CGImage] = []
    let text: String
    init(text: String) { self.text = text }
    func analyze(_ image: CGImage) async throws -> InlineImageTextAnalysis {
        calls += 1
        images.append(image)
        return InlineImageTextAnalysis(text: text, nativeAnalysis: nil)
    }
}

private struct CaptureNeverFallback: TextRecognizer {
    func recognize(_ image: ToolImage) async throws -> ImageTextRecognitionResult {
        XCTFail("The workspace and terminal action must share the native analysis")
        return ImageTextRecognitionResult(lines: [])
    }
}

private struct XCTUnwrapErrorForCapture: Error {}

@MainActor
private final class InlineCaptureProvider: ScreenCaptureProviding {
    let values: [ScreenCaptureSnapshot]
    init(snapshots: [ScreenCaptureSnapshot]) { self.values = snapshots }
    func snapshots() async throws -> [ScreenCaptureSnapshot] { values }
    func cancel() {}
}
