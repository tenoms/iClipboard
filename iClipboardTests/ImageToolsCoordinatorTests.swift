import AppKit
import Carbon
import CoreData
import XCTest
@testable import iClipboard

@MainActor
final class ImageToolsCoordinatorTests: XCTestCase {
    private func fixture() throws -> (NSPersistentContainer, ClipboardStore, UserDefaults, String) {
        let container = NSPersistentContainer(name: "iClipboard")
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]
        var failure: Error?
        container.loadPersistentStores { _, error in failure = error }
        if let failure { throw failure }
        let suite = "iClipboard.CoordinatorTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let store = ClipboardStore(context: container.viewContext, defaults: defaults,
                                   monitorPasteboard: false, onCapture: {})
        return (container, store, defaults, suite)
    }

    private func image() throws -> ToolImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 480,
                                            bitsPerComponent: 8, bytesPerRow: 640 * 4,
                                            space: space,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.8, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        return ToolImage(cgImage: try XCTUnwrap(context.makeImage()), title: "Original")
    }

    private func waitFor(_ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(4)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition())
    }

    private func openPin(for entry: ClipboardEntry, using coordinator: ImageToolsCoordinator) async throws -> PinnedImageWindowController {
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        coordinator.perform(.pin, on: entry)
        await waitFor {
            NSApp.windows.contains {
                !existing.contains(ObjectIdentifier($0)) && $0.isVisible && $0 is PinnedImagePanel
            }
        }
        let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? PinnedImagePanel }.first {
            !existing.contains(ObjectIdentifier($0)) && $0.isVisible
        })
        return try XCTUnwrap(panel.delegate as? PinnedImageWindowController)
    }

    private func unassignedHotKeys(defaults: UserDefaults) -> HotKeyManager {
        HotKeyManager(defaults: defaults, registerHotKey: { _, _, _, _ in
            XCTFail("Unassigned shortcuts must not register with Carbon")
            return OSStatus(paramErr)
        }, installEventHandler: false, conflictChecker: nil)
    }

    func testHistoryImageCopyUsesFullPNGWithoutAddingHistoryAndCompletesAfterWrite() async throws {
        let (container, store, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = try image()
        _ = try await store.submit(.image(data: source.pngData(), title: source.title))
        await waitFor { store.entries.count == 1 }
        let entry = try XCTUnwrap(store.entries.first)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let manager = ImageToolsCoordinator(store: store, windowManager: WindowManager(registerHotKey: false),
                                            pasteboard: pasteboard, preferences: ImageToolsPreferences(defaults: defaults))
        defer { manager.stop() }
        var completed = false
        manager.perform(.copy, on: entry) {
            XCTAssertNotNil(pasteboard.data(forType: .png))
            completed = true
        }
        await waitFor { completed }
        let result = try ToolImage.decode(XCTUnwrap(pasteboard.data(forType: .png)))
        XCTAssertEqual(result.pixelSize, source.pixelSize)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(try container.viewContext.count(for: Item.fetchRequest()), 1)
        XCTAssertEqual(result.color(at: .zero)?.alpha ?? 0, 0.5, accuracy: 0.01)
    }

    func testHistoryImageFileCopyKeepsFileRepresentationButEditorOutputDoesNot() async throws {
        let (_, store, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.png")
        let source = try image()
        try source.pngData().write(to: url)
        _ = try await store.submit(.image(data: source.pngData(), title: source.title, fileURL: url))
        await waitFor { store.entries.count == 1 }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let coordinator = ImageToolsCoordinator(store: store, windowManager: WindowManager(registerHotKey: false),
                                                 pasteboard: pasteboard, preferences: ImageToolsPreferences(defaults: defaults))
        defer { coordinator.stop() }
        var copied = false
        coordinator.perform(.copy, on: try XCTUnwrap(store.entries.first)) { copied = true }
        await waitFor { copied }
        XCTAssertEqual(pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], [url])
        XCTAssertNotNil(pasteboard.data(forType: .png))
        _ = try await coordinator.performCaptureAction(.copyImage(source))
        XCTAssertNil(pasteboard.string(forType: .fileURL), "Tool outputs must never refer to an unedited source file")
        XCTAssertNotNil(pasteboard.data(forType: .png))
    }

    func testPinnedFavoriteOutputReturnsToHistoryAfterHistoryClear() async throws {
        let (container, store, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = try image()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let coordinator = ImageToolsCoordinator(store: store, windowManager: WindowManager(registerHotKey: false),
                                                 pasteboard: pasteboard, preferences: ImageToolsPreferences(defaults: defaults))
        defer { coordinator.stop() }
        _ = try await coordinator.performCaptureAction(.copyImage(source))
        await waitFor { store.entries.count == 1 }
        let entry = try XCTUnwrap(store.entries.first)
        let controller = try await openPin(for: entry, using: coordinator)
        let list = FavoriteList(context: container.viewContext)
        list.name = "Keep"
        list.createdAt = Date()
        let item = try XCTUnwrap(container.viewContext.existingObject(with: entry.id) as? Item)
        item.favoriteList = list
        try container.viewContext.save()
        store.deleteAll()
        await waitFor { store.entries.allSatisfy(\.isDeletedFromHistory) }
        XCTAssertTrue(store.contains(entry.id), "The favorite still exists outside history")
        XCTAssertFalse(store.containsInHistory(entry.id))
        let count = pasteboard.changeCount
        controller.panel.onCommand?("c")
        await waitFor { pasteboard.changeCount != count }
        await waitFor { store.entries.contains { !$0.isDeletedFromHistory } }
        XCTAssertEqual(store.entries.filter { !$0.isDeletedFromHistory }.count, 1)
        XCTAssertEqual(store.entries.filter(\.isDeletedFromHistory).map(\.id), [entry.id])
        XCTAssertTrue(controller.panel.isVisible)
    }

    private final class PreparationCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func prepare(_ image: ToolImage) throws -> CapturedPayload {
            lock.lock(); count += 1; lock.unlock()
            XCTAssertFalse(Thread.isMainThread)
            return .image(data: try image.pngData(), title: image.title)
        }
    }

    func testHistoryPinDoesNotEncodeAndEachExplicitCopyOrSavePreparesOnlyOnce() async throws {
        let (_, store, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = try await store.submit(.image(data: image().pngData(), title: "Stored"))
        await waitFor { store.entries.count == 1 }
        let entry = try XCTUnwrap(store.entries.first)
        let counter = PreparationCounter()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var saves = 0
        let coordinator = ImageToolsCoordinator(store: store, windowManager: WindowManager(registerHotKey: false),
            pasteboard: pasteboard, selectSaveURL: { _ in saves += 1; return nil },
            preferences: ImageToolsPreferences(defaults: defaults), prepareImage: { try counter.prepare($0) })
        defer { coordinator.stop() }
        let pin = try await openPin(for: entry, using: coordinator)
        XCTAssertEqual(counter.value, 0, "Pinning a stored image must not prepare a new PNG payload")
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        coordinator.perform(.edit, on: entry)
        await waitFor { NSApp.windows.contains { !existing.contains(ObjectIdentifier($0)) && $0.isVisible } }
        XCTAssertEqual(counter.value, 0, "Opening an editor must not prepare a new PNG payload")
        var copied = false
        coordinator.perform(.copy, on: entry) { copied = true }
        await waitFor { copied }
        XCTAssertEqual(counter.value, 1)
        coordinator.perform(.save, on: entry)
        await waitFor { saves == 1 }
        XCTAssertEqual(counter.value, 2)
        XCTAssertEqual(store.entries.count, 1)
        let count = pasteboard.changeCount
        pin.panel.onCommand?("c")
        await waitFor { pasteboard.changeCount != count }
        XCTAssertEqual(counter.value, 3)
        XCTAssertEqual(store.entries.count, 1, "An unchanged pin must still reuse the history image by weak identity")
    }

    func testRepeatedHistoryCopyReusesExistingRecord() async throws {
        let (_, store, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = try image()
        _ = try await store.submit(.image(data: source.pngData(), title: "Stored image"))
        await waitFor { store.entries.count == 1 }
        let entry = try XCTUnwrap(store.entries.first)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let manager = ImageToolsCoordinator(store: store, windowManager: WindowManager(registerHotKey: false),
                                            pasteboard: pasteboard, preferences: ImageToolsPreferences(defaults: defaults))
        defer { manager.stop() }
        var copies = 0
        for expected in 1...2 {
            manager.perform(.copy, on: entry) { copies += 1 }
            await waitFor { copies == expected }
        }
        XCTAssertEqual(store.entries.count, 1)
    }

    func testStoppedCoordinatorDoesNotReadOrWriteClipboard() async throws {
        let (_, store, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = try image()
        _ = try await store.submit(.image(data: source.pngData(), title: "Stored"))
        await waitFor { store.entries.count == 1 }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Keep", forType: .string)
        let count = pasteboard.changeCount
        let manager = ImageToolsCoordinator(store: store, windowManager: WindowManager(registerHotKey: false),
                                            pasteboard: pasteboard, preferences: ImageToolsPreferences(defaults: defaults))
        manager.stop()
        var completed = false
        manager.perform(.copy, on: try XCTUnwrap(store.entries.first)) { completed = true }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(completed)
        XCTAssertEqual(pasteboard.changeCount, count)
        XCTAssertEqual(pasteboard.string(forType: .string), "Keep")
    }

    func testLaterExternalCopyIsNotOverwrittenByPendingImageCopy() async throws {
        let (_, store, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = try image()
        _ = try await store.submit(.image(data: source.pngData(), title: "Stored"))
        await waitFor { store.entries.count == 1 }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let manager = ImageToolsCoordinator(store: store, windowManager: WindowManager(registerHotKey: false),
                                            pasteboard: pasteboard, preferences: ImageToolsPreferences(defaults: defaults))
        defer { manager.stop() }
        var completed = false
        manager.perform(.copy, on: try XCTUnwrap(store.entries.first)) { completed = true }
        pasteboard.clearContents()
        pasteboard.setString("Later user copy", forType: .string)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(completed)
        XCTAssertEqual(pasteboard.string(forType: .string), "Later user copy")
        XCTAssertNil(pasteboard.data(forType: .png))
    }

    func testLatestImageCopyWinsWhenRequestsOverlap() async throws {
        let (_, store, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = try image()
        _ = try await store.submit(.image(data: source.pngData(), title: "Stored"))
        await waitFor { store.entries.count == 1 }
        let entry = try XCTUnwrap(store.entries.first)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let manager = ImageToolsCoordinator(store: store, windowManager: WindowManager(registerHotKey: false),
                                            pasteboard: pasteboard, preferences: ImageToolsPreferences(defaults: defaults))
        defer { manager.stop() }
        var firstCompleted = false
        var secondCompleted = false
        manager.perform(.copy, on: entry) { firstCompleted = true }
        manager.perform(.copy, on: entry) { secondCompleted = true }
        await waitFor { secondCompleted }
        XCTAssertFalse(firstCompleted)
        XCTAssertNotNil(pasteboard.data(forType: .png))
        XCTAssertEqual(store.entries.count, 1)
    }

    func testEditorRendersSyntheticImageWithoutScreenCapturePermission() async throws {
        let controller = ImageEditorController(image: try image())
        controller.onCopy = { _ in }
        controller.onSave = { _ in }
        controller.onPin = { _ in }
        controller.present()
        defer { controller.close() }
        try? await Task.sleep(nanoseconds: 150_000_000)
        let view = try XCTUnwrap(controller.window?.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 900)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 500)
        if let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("icl-image-editor-smoke.png"))
        }
    }

    private final class CaptureStub: ScreenCapturing {
        var onWillCopySelection: (() -> Void)?
        var onContextualKeyEvent: ((NSEvent) -> Bool)?
        var handler: ScreenCaptureActionHandler?
        var continuation: CheckedContinuation<ScreenCaptureSession.Result?, Error>?
        var didCancel = false
        var intents: [ScreenCaptureSession.Intent] = []
        var requestedActions: [ScreenCaptureCurrentAction] = []

        func requestCurrentAction(_ action: ScreenCaptureCurrentAction) { requestedActions.append(action) }
        func canCopyRecognizedText(in window: NSWindow) -> Bool { false }

        func run(_ intent: ScreenCaptureSession.Intent, onAction: ScreenCaptureActionHandler?) async throws -> ScreenCaptureSession.Result? {
            intents.append(intent)
            handler = onAction
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }

        func finish() {
            let continuation = self.continuation
            self.continuation = nil
            continuation?.resume(returning: .completed)
        }

        func cancel() {
            didCancel = true
            let continuation = self.continuation
            self.continuation = nil
            continuation?.resume(returning: nil)
        }
    }

    func testInlineImageAndTextActionsAreAwaitedWithoutOpeningAdditionalWindows() async throws {
        let (_, store, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let capture = CaptureStub()
        let coordinator = ImageToolsCoordinator(store: store, windowManager: WindowManager(registerHotKey: false),
                                                 pasteboard: pasteboard, captureSession: capture, preferences: ImageToolsPreferences(defaults: defaults))
        defer { coordinator.stop() }
        let windowsBefore = Set(NSApp.windows.map(ObjectIdentifier.init))
        coordinator.perform(.capture)
        await waitFor { capture.handler != nil }
        let handler = try XCTUnwrap(capture.handler)
        let textResult = try await handler(.copyText("Selected text 中文"))
        XCTAssertEqual(textResult, .completed)
        XCTAssertEqual(pasteboard.string(forType: .string), "Selected text 中文")
        XCTAssertNotNil(capture.continuation, "Copying text keeps capture ready")
        let copyResult = try await handler(.copyImage(image()))
        XCTAssertEqual(copyResult, .completed)
        XCTAssertNotNil(pasteboard.data(forType: .png))
        capture.finish()
        try? await Task.sleep(nanoseconds: 30_000_000)
        let unexpected = NSApp.windows.filter { !windowsBefore.contains(ObjectIdentifier($0)) && $0.isVisible }
        XCTAssertTrue(unexpected.isEmpty, "Copying screenshot image or text must not create additional windows")
    }

    func testRecognitionOutsideCaptureDoesNotStartCaptureOrRecognizeClipboardImage() async throws {
        let (_, store, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let data = try image().pngData()
        pasteboard.setData(data, forType: .png)
        let count = pasteboard.changeCount
        let capture = CaptureStub()
        let coordinator = ImageToolsCoordinator(store: store, windowManager: WindowManager(registerHotKey: false),
                                                 pasteboard: pasteboard, captureSession: capture,
                                                 preferences: ImageToolsPreferences(defaults: defaults))
        defer { coordinator.stop() }
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        coordinator.perform(.recognizeScreen)
        coordinator.perform(.recognizeScreen)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(capture.intents.isEmpty, "Recognition must never initiate a screenshot")
        XCTAssertTrue(capture.requestedActions.isEmpty)
        XCTAssertNil(capture.handler)
        XCTAssertEqual(pasteboard.changeCount, count)
        XCTAssertEqual(pasteboard.data(forType: .png), data)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(NSApp.windows.contains {
            !before.contains(ObjectIdentifier($0)) && $0.isVisible
        })
    }

    func testRecognitionHotKeyOnlyRequestsCurrentCaptureAndDoesNotRestartCompletedCapture() async throws {
        let (_, store, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Keep", forType: .string)
        let count = pasteboard.changeCount
        let keys = HotKeyManager(defaults: defaults, registerHotKey: { _, _, _, _ in
            XCTFail("Unassigned shortcuts must not register with Carbon")
            return -1
        }, installEventHandler: false, conflictChecker: nil)
        let capture = CaptureStub()
        let coordinator = ImageToolsCoordinator(store: store, windowManager: WindowManager(registerHotKey: false),
                                                 pasteboard: pasteboard, captureSession: capture,
                                                 preferences: ImageToolsPreferences(defaults: defaults))
        defer { coordinator.stop() }
        coordinator.start(hotKeyManager: keys)
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        keys.invokeHandler(for: .recognizeScreen)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(capture.intents.isEmpty)
        XCTAssertTrue(capture.requestedActions.isEmpty)

        keys.invokeHandler(for: .capture)
        // The capture task exists, but has not entered run/prepared any selection.
        keys.invokeHandler(for: .recognizeScreen)
        XCTAssertTrue(capture.intents.isEmpty)
        XCTAssertEqual(capture.requestedActions.count, 1)
        await waitFor { capture.handler != nil }
        // With no crop in this stub, forwarding still must not start another run.
        keys.invokeHandler(for: .recognizeScreen)
        XCTAssertEqual(capture.intents.count, 1)
        guard case .image = try XCTUnwrap(capture.intents.first) else {
            return XCTFail("Only the explicit screenshot shortcut may start image capture")
        }
        XCTAssertEqual(capture.requestedActions.count, 2)
        XCTAssertTrue(capture.requestedActions.allSatisfy {
            if case .copyRecognizedText = $0 { return true }
            return false
        })
        capture.finish()
        try await Task.sleep(nanoseconds: 30_000_000)
        keys.invokeHandler(for: .recognizeScreen)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(capture.intents.count, 1, "Recognition after exit must not restart capture")
        XCTAssertEqual(capture.requestedActions.count, 2)
        XCTAssertEqual(pasteboard.changeCount, count)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(NSApp.windows.contains {
            !before.contains(ObjectIdentifier($0)) && $0.isVisible
        })
    }

    func testHistoryImagePinOpensOnlyPinnedImageWithoutCaptureOrClipboardChanges() async throws {
        let (_, store, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = try image()
        _ = try await store.submit(.image(data: source.pngData(), title: source.title))
        await waitFor { store.entries.count == 1 }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Keep", forType: .string)
        let count = pasteboard.changeCount
        let capture = CaptureStub()
        let coordinator = ImageToolsCoordinator(store: store, windowManager: WindowManager(registerHotKey: false),
                                                 pasteboard: pasteboard, captureSession: capture,
                                                 preferences: ImageToolsPreferences(defaults: defaults))
        defer { coordinator.stop() }
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        coordinator.perform(.pin, on: try XCTUnwrap(store.entries.first))
        await waitFor {
            NSApp.windows.contains {
                !before.contains(ObjectIdentifier($0)) && $0.isVisible && $0 is PinnedImagePanel
            }
        }
        let opened = NSApp.windows.filter { !before.contains(ObjectIdentifier($0)) && $0.isVisible }
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(opened.first is PinnedImagePanel)
        XCTAssertTrue(capture.intents.isEmpty)
        XCTAssertTrue(capture.requestedActions.isEmpty)
        XCTAssertEqual(pasteboard.changeCount, count, "Opening an image for inline text selection must not copy text")
        XCTAssertEqual(pasteboard.string(forType: .string), "Keep")
        XCTAssertEqual(store.entries.count, 1)
    }

    func testConfiguredLocalID4CopiesOnlyFocusedPinFullTextThroughCoordinatorHistoryWithoutNewWindows() async throws {
        let (_, store, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = try image()
        _ = try await store.submit(.image(data: source.pngData(), title: source.title))
        await waitFor { store.entries.count == 1 }
        let entry = try XCTUnwrap(store.entries.first)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Keep", forType: .string)
        let capture = CaptureStub()
        let coordinator = ImageToolsCoordinator(store: store, windowManager: WindowManager(registerHotKey: false),
                                                 pasteboard: pasteboard, captureSession: capture,
                                                 preferences: ImageToolsPreferences(defaults: defaults))
        defer { coordinator.stop() }
        let recognitionModifiers: NSEvent.ModifierFlags = [.control, .option]
        let recognition = KeyboardShortcut(keyCode: kVK_ANSI_O, modifiers: Int(recognitionModifiers.rawValue))
        defaults.set(try JSONEncoder().encode(["4": recognition]), forKey: "globalShortcuts")
        let saved = defaults.data(forKey: "globalShortcuts")
        var registrations: [UInt32] = []
        let keys = HotKeyManager(defaults: defaults, registerHotKey: { code, modifiers, id, ref in
            XCTAssertEqual(code, UInt32(kVK_ANSI_O))
            XCTAssertEqual(modifiers, UInt32(controlKey | optionKey))
            XCTAssertEqual(id.signature, 0x69436C70)
            registrations.append(id.id)
            ref = EventHotKeyRef(bitPattern: 1)!
            return noErr
        }, unregisterHotKey: { _ in noErr }, installEventHandler: false, conflictChecker: nil)
        coordinator.start(hotKeyManager: keys)
        let focused = try await openPin(for: entry, using: coordinator)
        let recent = try await openPin(for: entry, using: coordinator)
        let forward = try XCTUnwrap(focused.onCopyFullText)
        var reads = 0
        focused.onCopyFullText = { _ in
            // Only replace OCR timing; retain the real manager/coordinator callbacks.
            forward {
                reads += 1
                return "  Focused 中文\n"
            }
        }
        recent.onCopyFullText = { _ in XCTFail("Hover/recent pin must never replace the key pin") }
        let pointer = NSEvent.mouseLocation
        recent.panel.setFrameOrigin(CGPoint(x: pointer.x - recent.panel.frame.width / 2,
                                            y: pointer.y - recent.panel.frame.height / 2))
        focused.panel.makeKey()
        XCTAssertTrue(focused.panel.isKeyWindow)
        XCTAssertTrue(NSApp.keyWindow === focused.panel)
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: recognitionModifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: focused.panel.windowNumber, context: nil, characters: "o",
            charactersIgnoringModifiers: "o", isARepeat: false, keyCode: UInt16(kVK_ANSI_O)))
        NSApp.sendEvent(event)
        await waitFor { pasteboard.string(forType: .string) == "Focused 中文" && store.entries.count == 2 }
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(registrations.isEmpty, "ID4 must not be registered with Carbon")
        XCTAssertEqual(keys.shortcut(for: .recognizeScreen), recognition)
        XCTAssertEqual(defaults.data(forKey: "globalShortcuts"), saved)
        XCTAssertNil(pasteboard.data(forType: .png))
        XCTAssertEqual(store.entries.filter { $0.kind == .text }.map(\.content), ["Focused 中文"])
        XCTAssertTrue(capture.intents.isEmpty)
        XCTAssertTrue(capture.requestedActions.isEmpty)
        XCTAssertTrue(NSApp.keyWindow === focused.panel, "The copy command must not move keyboard focus")
        XCTAssertFalse(NSApp.windows.contains { !before.contains(ObjectIdentifier($0)) && $0.isVisible })
    }

    func testShiftOnlyContextShortcutsLeaveTypingAloneAndCloseOnlyTheKeyPin() async throws {
        let (_, store, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = try await store.submit(.image(data: image().pngData(), title: "Stored"))
        await waitFor { store.entries.count == 1 }
        defaults.set(try JSONEncoder().encode([
            "4": KeyboardShortcut(keyCode: kVK_ANSI_C, modifiers: Int(NSEvent.ModifierFlags.shift.rawValue)),
            "6": KeyboardShortcut(keyCode: kVK_ANSI_X, modifiers: Int(NSEvent.ModifierFlags.shift.rawValue))
        ]), forKey: "globalShortcuts")
        let keys = HotKeyManager(defaults: defaults, registerHotKey: { _, _, _, _ in
            XCTFail("Shift-only contextual shortcuts must never reserve global keys")
            return OSStatus(paramErr)
        }, installEventHandler: false, conflictChecker: nil)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let coordinator = ImageToolsCoordinator(store: store, windowManager: WindowManager(registerHotKey: false),
                                                 pasteboard: pasteboard, preferences: ImageToolsPreferences(defaults: defaults))
        defer { coordinator.stop() }
        coordinator.start(hotKeyManager: keys)
        coordinator.start(hotKeyManager: keys)
        let entry = try XCTUnwrap(store.entries.first)
        let focused = try await openPin(for: entry, using: coordinator)
        let hovered = try await openPin(for: entry, using: coordinator)
        let pointer = NSEvent.mouseLocation
        hovered.panel.setFrameOrigin(CGPoint(x: pointer.x - hovered.panel.frame.width / 2,
                                             y: pointer.y - hovered.panel.frame.height / 2))
        let text = NSTextView(frame: CGRect(x: 0, y: 0, width: 240, height: 100))
        let other = NSWindow(contentRect: text.frame, styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.contentView = text
        defer { other.orderOut(nil); other.close() }
        NSApp.activate(ignoringOtherApps: true)
        other.makeKeyAndOrderFront(nil)
        XCTAssertTrue(other.makeFirstResponder(text))
        NSApp.sendEvent(try contextualKey(other, code: kVK_ANSI_C, characters: "C"))
        NSApp.sendEvent(try contextualKey(other, code: kVK_ANSI_X, characters: "X"))
        XCTAssertEqual(text.string, "CX", "Configured Shift+C and Shift+X must reach an ordinary text responder")
        XCTAssertTrue(focused.panel.isVisible)
        XCTAssertTrue(hovered.panel.isVisible)
        let forward = try XCTUnwrap(focused.onCopyFullText)
        var copies = 0
        focused.onCopyFullText = { _ in
            copies += 1
            forward { "Focused full text" }
        }
        hovered.onCopyFullText = { _ in XCTFail("The pointer must not choose the shortcut target") }
        focused.panel.makeKey()
        NSApp.sendEvent(try contextualKey(focused.panel, code: kVK_ANSI_C, characters: "C"))
        await waitFor { pasteboard.string(forType: .string) == "Focused full text" }
        XCTAssertEqual(copies, 1, "Repeated start must not install duplicate local handlers")
        keys.suspendRegistration()
        NSApp.sendEvent(try contextualKey(focused.panel, code: kVK_ANSI_X, characters: "X"))
        XCTAssertTrue(focused.panel.isVisible, "Recording pauses contextual actions too")
        keys.resumeRegistration()
        NSApp.sendEvent(try contextualKey(focused.panel, code: kVK_ANSI_X, characters: "X"))
        XCTAssertFalse(focused.panel.isVisible)
        XCTAssertTrue(hovered.panel.isVisible, "Close must target the key pin, not a hovered or recent one")
        other.makeKeyAndOrderFront(nil)
        XCTAssertTrue(other.makeFirstResponder(text))
        NSApp.sendEvent(try contextualKey(other, code: kVK_ANSI_X, characters: "X"))
        XCTAssertEqual(text.string, "CXX")
        XCTAssertTrue(hovered.panel.isVisible, "Without pin focus the close shortcut must not guess a target")
        coordinator.stop()
        NSApp.sendEvent(try contextualKey(other, code: kVK_ANSI_C, characters: "C"))
        XCTAssertEqual(text.string, "CXXC")
    }

    private final class SnapshotProvider: ScreenCaptureProviding {
        let snapshot: ScreenCaptureSnapshot
        init(_ snapshot: ScreenCaptureSnapshot) { self.snapshot = snapshot }
        func snapshots() async throws -> [ScreenCaptureSnapshot] { [snapshot] }
        func cancel() { }
    }

    func testConfiguredShiftCReachesRealCaptureWorkspaceWithoutGlobalRegistration() async throws {
        let (_, store, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode([
            "4": KeyboardShortcut(keyCode: kVK_ANSI_C, modifiers: Int(NSEvent.ModifierFlags.shift.rawValue))
        ]), forKey: "globalShortcuts")
        let keys = HotKeyManager(defaults: defaults, registerHotKey: { _, _, _, _ in
            XCTFail("Capture full-text shortcuts must be window-local too")
            return OSStatus(paramErr)
        }, installEventHandler: false, conflictChecker: nil)
        let source = try image()
        let snapshot = ScreenCaptureSnapshot(displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 640, height: 480), image: source.cgImage)
        let capture = ScreenCaptureSession(providerFactory: { SnapshotProvider(snapshot) },
            accessCheck: { true }, accessRequest: { XCTFail("No TCC requests in tests"); return false })
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let coordinator = ImageToolsCoordinator(store: store, windowManager: WindowManager(registerHotKey: false),
            pasteboard: pasteboard, captureSession: capture, preferences: ImageToolsPreferences(defaults: defaults))
        defer { coordinator.stop() }
        coordinator.start(hotKeyManager: keys)
        coordinator.perform(.capture)
        await waitFor { !capture.capturePanels.isEmpty }
        let panel = try XCTUnwrap(capture.capturePanels.first)
        try await Task.sleep(nanoseconds: 60_000_000)
        panel.makeKey()
        for (type, point): (NSEvent.EventType, CGPoint) in [
            (.leftMouseDown, CGPoint(x: 100, y: 100)),
            (.leftMouseDragged, CGPoint(x: 400, y: 300)),
            (.leftMouseUp, CGPoint(x: 400, y: 300))
        ] {
            panel.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)))
        }
        let workspace = try XCTUnwrap(panel.workspace)
        var requests = 0
        workspace.onAction = { action in
            if case .copyRecognizedText = action { requests += 1 }
            else { XCTFail("The configured key must only request full text") }
        }
        NSApp.sendEvent(try contextualKey(panel, code: kVK_ANSI_C, characters: "C"))
        XCTAssertEqual(requests, 1)
        keys.setShortcut(KeyboardShortcut(keyCode: kVK_ANSI_C, modifiers: Int(NSEvent.ModifierFlags.command.rawValue)),
                         for: .recognizeScreen)
        NSApp.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil, characters: "c",
            charactersIgnoringModifiers: "c", isARepeat: false, keyCode: UInt16(kVK_ANSI_C))))
        XCTAssertEqual(requests, 2, "Configured full text must precede the capture's built-in Command+C image action")
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(store.entries.isEmpty)
    }

    private func contextualKey(_ window: NSWindow, code: Int, characters: String) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .shift, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters.lowercased(), isARepeat: false, keyCode: UInt16(code)))
    }

    func testID4WithoutPinFocusDoesNotUseVisibleHoveredRecentOrHiddenPins() async throws {
        let (_, store, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = try image()
        let data = try source.pngData()
        _ = try await store.submit(.image(data: data, title: source.title))
        await waitFor { store.entries.count == 1 }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setData(data, forType: .png)
        let count = pasteboard.changeCount
        let capture = CaptureStub()
        let coordinator = ImageToolsCoordinator(store: store, windowManager: WindowManager(registerHotKey: false),
                                                 pasteboard: pasteboard, captureSession: capture,
                                                 preferences: ImageToolsPreferences(defaults: defaults))
        defer { coordinator.stop() }
        let keys = unassignedHotKeys(defaults: defaults)
        coordinator.start(hotKeyManager: keys)
        let controller = try await openPin(for: XCTUnwrap(store.entries.first), using: coordinator)
        controller.onCopyFullText = { _ in XCTFail("A pin without visible keyboard focus must not copy text") }
        let pointer = NSEvent.mouseLocation
        controller.panel.setFrameOrigin(CGPoint(x: pointer.x - controller.panel.frame.width / 2,
                                                y: pointer.y - controller.panel.frame.height / 2))
        let other = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 80, height: 60),
                             styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.makeKeyAndOrderFront(nil)
        defer { other.orderOut(nil); other.close() }
        XCTAssertTrue(NSApp.keyWindow === other)
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        keys.invokeHandler(for: .recognizeScreen)
        XCTAssertTrue(NSApp.keyWindow === other)
        other.orderOut(nil)
        controller.panel.makeKey()
        XCTAssertTrue(controller.panel.isKeyWindow)
        coordinator.perform(.togglePins)
        XCTAssertFalse(controller.panel.isVisible)
        keys.invokeHandler(for: .recognizeScreen)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(capture.intents.isEmpty)
        XCTAssertTrue(capture.requestedActions.isEmpty)
        XCTAssertEqual(pasteboard.changeCount, count)
        XCTAssertEqual(pasteboard.data(forType: .png), data)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertFalse(NSApp.windows.contains { !before.contains(ObjectIdentifier($0)) && $0.isVisible })
    }

    func testID4AlwaysTargetsCaptureBeforeFocusedPinIncludingBeforeCaptureRunStarts() async throws {
        let (_, store, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = try image()
        _ = try await store.submit(.image(data: source.pngData(), title: source.title))
        await waitFor { store.entries.count == 1 }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Keep", forType: .string)
        let count = pasteboard.changeCount
        let capture = CaptureStub()
        let coordinator = ImageToolsCoordinator(store: store, windowManager: WindowManager(registerHotKey: false),
                                                 pasteboard: pasteboard, captureSession: capture,
                                                 preferences: ImageToolsPreferences(defaults: defaults))
        defer { coordinator.stop() }
        let keys = unassignedHotKeys(defaults: defaults)
        coordinator.start(hotKeyManager: keys)
        let controller = try await openPin(for: XCTUnwrap(store.entries.first), using: coordinator)
        controller.onCopyFullText = { _ in XCTFail("An active capture must own ID 4 even if a pin is key") }
        controller.panel.makeKey()
        XCTAssertTrue(NSApp.keyWindow === controller.panel)
        keys.invokeHandler(for: .capture)
        keys.invokeHandler(for: .recognizeScreen)
        XCTAssertTrue(capture.intents.isEmpty, "The capture task has not started running yet")
        XCTAssertEqual(capture.requestedActions.count, 1)
        await waitFor { capture.handler != nil }
        XCTAssertFalse(controller.panel.isVisible, "Capture suspends existing pins")
        keys.invokeHandler(for: .recognizeScreen)
        XCTAssertEqual(capture.intents.count, 1)
        XCTAssertEqual(capture.requestedActions.count, 2)
        XCTAssertTrue(capture.requestedActions.allSatisfy {
            if case .copyRecognizedText = $0 { return true }
            return false
        })
        XCTAssertEqual(pasteboard.changeCount, count)
        XCTAssertEqual(store.entries.count, 1)
        capture.finish()
    }

    func testFocusedPinFullTextIntentInvalidatesPendingImageCopyBeforeOCRCompletes() async throws {
        let (_, store, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = try image()
        _ = try await store.submit(.image(data: source.pngData(), title: source.title))
        await waitFor { store.entries.count == 1 }
        let entry = try XCTUnwrap(store.entries.first)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Keep", forType: .string)
        let count = pasteboard.changeCount
        let coordinator = ImageToolsCoordinator(store: store, windowManager: WindowManager(registerHotKey: false),
                                                 pasteboard: pasteboard, preferences: ImageToolsPreferences(defaults: defaults))
        defer { coordinator.stop() }
        let keys = unassignedHotKeys(defaults: defaults)
        coordinator.start(hotKeyManager: keys)
        let controller = try await openPin(for: entry, using: coordinator)
        let forward = try XCTUnwrap(controller.onCopyFullText)
        var continuation: CheckedContinuation<String, Never>?
        controller.onCopyFullText = { _ in
            forward { await withCheckedContinuation { continuation = $0 } }
        }
        controller.panel.makeKey()
        XCTAssertTrue(NSApp.keyWindow === controller.panel)
        var imageCopied = false
        coordinator.perform(.copy, on: entry) { imageCopied = true }
        keys.invokeHandler(for: .recognizeScreen)
        await waitFor { continuation != nil }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(imageCopied)
        XCTAssertEqual(pasteboard.changeCount, count, "Text copy intent must invalidate older image writes before OCR returns")
        continuation?.resume(returning: "Focused full text")
        continuation = nil
        await waitFor { pasteboard.string(forType: .string) == "Focused full text" && store.entries.count == 2 }
        XCTAssertFalse(imageCopied)
        XCTAssertNil(pasteboard.data(forType: .png))
        XCTAssertEqual(store.entries.filter { $0.kind == .text }.map(\.content), ["Focused full text"])
    }

    func testExternalCopyBeforeOrDuringFocusedPinOCRIsNotOverwrittenByLateText() async throws {
        let (_, store, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = try image()
        _ = try await store.submit(.image(data: source.pngData(), title: source.title))
        await waitFor { store.entries.count == 1 }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let coordinator = ImageToolsCoordinator(store: store, windowManager: WindowManager(registerHotKey: false),
                                                 pasteboard: pasteboard, preferences: ImageToolsPreferences(defaults: defaults))
        defer { coordinator.stop() }
        let keys = unassignedHotKeys(defaults: defaults)
        coordinator.start(hotKeyManager: keys)
        let controller = try await openPin(for: XCTUnwrap(store.entries.first), using: coordinator)
        let forward = try XCTUnwrap(controller.onCopyFullText)
        var continuation: CheckedContinuation<String, Never>?
        controller.onCopyFullText = { _ in
            forward { await withCheckedContinuation { continuation = $0 } }
        }
        controller.panel.makeKey()
        XCTAssertTrue(NSApp.keyWindow === controller.panel)
        for copyBeforeTaskStarts in [true, false] {
            let newer = copyBeforeTaskStarts ? "User copy before OCR starts" : "User copy during OCR"
            let stale = copyBeforeTaskStarts ? "Stale queued OCR" : "Stale running OCR"
            keys.invokeHandler(for: .recognizeScreen)
            if !copyBeforeTaskStarts { await waitFor { continuation != nil } }
            pasteboard.clearContents()
            pasteboard.setString(newer, forType: .string)
            let changeCount = pasteboard.changeCount
            await waitFor { continuation != nil }
            continuation?.resume(returning: stale)
            continuation = nil
            await waitFor { store.entries.contains { $0.kind == .text && $0.content == stale } }
            try await Task.sleep(nanoseconds: 30_000_000)
            XCTAssertEqual(pasteboard.changeCount, changeCount)
            XCTAssertEqual(pasteboard.string(forType: .string), newer,
                           "The ticket must cover time before the OCR task starts and while it awaits analysis")
        }
        XCTAssertNil(pasteboard.data(forType: .png))
    }

    func testStoppedCoordinatorDoesNotCopyLateFocusedPinOCR() async throws {
        let (_, store, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = try image()
        _ = try await store.submit(.image(data: source.pngData(), title: source.title))
        await waitFor { store.entries.count == 1 }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Keep", forType: .string)
        let count = pasteboard.changeCount
        let coordinator = ImageToolsCoordinator(store: store, windowManager: WindowManager(registerHotKey: false),
                                                 pasteboard: pasteboard, preferences: ImageToolsPreferences(defaults: defaults))
        defer { coordinator.stop() }
        let controller = try await openPin(for: XCTUnwrap(store.entries.first), using: coordinator)
        let forward = try XCTUnwrap(controller.onCopyFullText)
        var continuation: CheckedContinuation<String, Never>?
        var readFinished = false
        controller.onCopyFullText = { _ in
            forward {
                let text = await withCheckedContinuation { continuation = $0 }
                readFinished = true
                return text
            }
        }
        controller.panel.makeKey()
        XCTAssertTrue(NSApp.keyWindow === controller.panel)
        coordinator.perform(.recognizeScreen)
        await waitFor { continuation != nil }
        coordinator.stop()
        continuation?.resume(returning: "Late OCR after stop")
        continuation = nil
        await waitFor { readFinished }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(controller.panel.isVisible)
        XCTAssertEqual(pasteboard.changeCount, count)
        XCTAssertEqual(pasteboard.string(forType: .string), "Keep")
        XCTAssertEqual(store.entries.count, 1)
    }

    func testPinnedImageNativeSelectionCopyInvalidatesPendingImageCopyBeforePasteboardChanges() async throws {
        let (_, store, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = try image()
        _ = try await store.submit(.image(data: source.pngData(), title: source.title))
        await waitFor { store.entries.count == 1 }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Keep", forType: .string)
        let count = pasteboard.changeCount
        let coordinator = ImageToolsCoordinator(store: store, windowManager: WindowManager(registerHotKey: false),
                                                 pasteboard: pasteboard,
                                                 preferences: ImageToolsPreferences(defaults: defaults))
        defer { coordinator.stop() }
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        let entry = try XCTUnwrap(store.entries.first)
        coordinator.perform(.pin, on: entry)
        await waitFor {
            NSApp.windows.contains {
                !before.contains(ObjectIdentifier($0)) && $0.isVisible && $0 is PinnedImagePanel
            }
        }
        let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? PinnedImagePanel }.first {
            !before.contains(ObjectIdentifier($0)) && $0.isVisible
        })
        let controller = try XCTUnwrap(panel.delegate as? PinnedImageWindowController)
        var completed = false
        coordinator.perform(.copy, on: entry) { completed = true }
        controller.onWillCopySelection?()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(completed)
        XCTAssertEqual(pasteboard.changeCount, count, "The copy-intent notification alone must invalidate older writes")
        XCTAssertEqual(pasteboard.string(forType: .string), "Keep")
        XCTAssertNil(pasteboard.data(forType: .png))
        XCTAssertEqual(store.entries.count, 1)
    }

    func testCaptureWaitsForHistorySaveFromIntentThroughPanelCancellation() async throws {
        let (_, store, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = try await store.submit(.image(data: image().pngData(), title: "Stored"))
        await waitFor { store.entries.count == 1 }
        let capture = CaptureStub()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Keep", forType: .string)
        var save: CheckedContinuation<URL?, Never>?
        let coordinator = ImageToolsCoordinator(store: store, windowManager: WindowManager(registerHotKey: false),
                                                 pasteboard: pasteboard, captureSession: capture,
                                                 selectSaveURL: { _ in
            await withCheckedContinuation { save = $0 }
        }, preferences: ImageToolsPreferences(defaults: defaults))
        defer { coordinator.stop(); save?.resume(returning: nil) }
        coordinator.perform(.save, on: try XCTUnwrap(store.entries.first))
        coordinator.perform(.capture)
        coordinator.perform(.capture)
        await waitFor { save != nil }
        XCTAssertTrue(capture.intents.isEmpty, "A save claims presentation before asynchronous image loading or encoding")
        save?.resume(returning: nil)
        save = nil
        await waitFor { capture.handler != nil }
        XCTAssertEqual(capture.intents.count, 1, "Repeated pending captures must coalesce")
        XCTAssertEqual(pasteboard.string(forType: .string), "Keep")
        XCTAssertEqual(store.entries.count, 1)
        capture.finish()
    }

    func testHistorySaveDuringCapturePresentsOnlyAfterCaptureFinishes() async throws {
        let (_, store, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = try await store.submit(.image(data: image().pngData(), title: "Stored"))
        await waitFor { store.entries.count == 1 }
        let capture = CaptureStub()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var savePanels = 0
        let coordinator = ImageToolsCoordinator(store: store, windowManager: WindowManager(registerHotKey: false),
                                                 pasteboard: pasteboard, captureSession: capture,
                                                 selectSaveURL: { _ in savePanels += 1; return nil },
                                                 preferences: ImageToolsPreferences(defaults: defaults))
        defer { coordinator.stop() }
        coordinator.perform(.capture)
        coordinator.perform(.save, on: try XCTUnwrap(store.entries.first))
        await waitFor { capture.handler != nil }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(savePanels, 0, "An ordinary save must not put its panel behind the capture overlays")
        capture.finish()
        await waitFor { savePanels == 1 }
        XCTAssertEqual(store.entries.count, 1)
    }

    func testCancelledSaveDoesNotWriteHistoryOrClipboardAndSameSessionCanRetry() async throws {
        let (_, store, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Keep", forType: .string)
        let count = pasteboard.changeCount
        let coordinator = ImageToolsCoordinator(store: store, windowManager: WindowManager(registerHotKey: false),
                                                 pasteboard: pasteboard, selectSaveURL: { _ in nil },
                                                 preferences: ImageToolsPreferences(defaults: defaults))
        defer { coordinator.stop() }
        let source = try image()
        let cancelled = try await coordinator.performCaptureAction(.saveImage(source))
        XCTAssertEqual(cancelled, .cancelled)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(pasteboard.changeCount, count)
        let copied = try await coordinator.performCaptureAction(.copyImage(source))
        XCTAssertEqual(copied, .completed)
        await waitFor { store.entries.count == 1 }
    }

    func testSuccessfulSaveWritesFullPNGBeforeCompletingAndDoesNotCopy() async throws {
        let (_, store, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Saved.png")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Keep", forType: .string)
        let coordinator = ImageToolsCoordinator(store: store, windowManager: WindowManager(registerHotKey: false),
                                                 pasteboard: pasteboard, selectSaveURL: { _ in url },
                                                 preferences: ImageToolsPreferences(defaults: defaults))
        defer { coordinator.stop() }
        let source = try image()
        let result = try await coordinator.performCaptureAction(.saveImage(source))
        XCTAssertEqual(result, .completed)
        let saved = try ToolImage.decode(Data(contentsOf: url))
        XCTAssertEqual(saved.pixelSize, source.pixelSize)
        XCTAssertEqual(pasteboard.string(forType: .string), "Keep")
        await waitFor { store.entries.count == 1 }
    }

    func testSaveFailureCanBeRetriedWithoutLosingImageOrAddingHistory() async throws {
        let (_, store, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("NoDirectory/image.png")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var attempts = 0
        let coordinator = ImageToolsCoordinator(store: store, windowManager: WindowManager(registerHotKey: false),
                                                 pasteboard: pasteboard, selectSaveURL: { _ in
            attempts += 1
            return attempts == 1 ? missing : nil
        }, preferences: ImageToolsPreferences(defaults: defaults))
        defer { coordinator.stop() }
        let source = try image()
        do {
            _ = try await coordinator.performCaptureAction(.saveImage(source))
            XCTFail("Writing into a missing directory should fail")
        } catch { }
        XCTAssertTrue(store.entries.isEmpty)
        let cancelled = try await coordinator.performCaptureAction(.saveImage(source))
        XCTAssertEqual(cancelled, .cancelled)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(source.pixelSize, CGSize(width: 640, height: 480))
    }

    func testCancellingAwaitedSaveDoesNotCommitOrCopy() async throws {
        let (_, store, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Keep", forType: .string)
        var presented = false
        let coordinator = ImageToolsCoordinator(store: store, windowManager: WindowManager(registerHotKey: false),
                                                 pasteboard: pasteboard, selectSaveURL: { _ in
            presented = true
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return nil
        }, preferences: ImageToolsPreferences(defaults: defaults))
        defer { coordinator.stop() }
        let source = try image()
        let task = Task { try await coordinator.performCaptureAction(.saveImage(source)) }
        await waitFor { presented }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelling the save must propagate to its caller")
        } catch is CancellationError { }
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(pasteboard.string(forType: .string), "Keep")
    }

    func testRealSavePanelTaskCancellationClosesOwnedPanel() async throws {
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        let task = Task { try await ImageSaveDestination.choose(name: "Cancellation test.png") }
        await waitFor {
            NSApp.windows.contains { $0 is NSSavePanel && !existing.contains(ObjectIdentifier($0)) }
        }
        let panel = NSApp.windows.compactMap { $0 as? NSSavePanel }.first {
            !existing.contains(ObjectIdentifier($0))
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelling the owner should cancel the actual save-panel request")
        } catch is CancellationError { }
        XCTAssertFalse(panel?.isVisible ?? false)
    }

    func testNativeTextCopyInvalidatesPendingImageCopyTicket() async throws {
        let (_, store, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = try image()
        _ = try await store.submit(.image(data: source.pngData(), title: "Stored"))
        await waitFor { store.entries.count == 1 }
        let capture = CaptureStub()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let coordinator = ImageToolsCoordinator(store: store, windowManager: WindowManager(registerHotKey: false),
                                                 pasteboard: pasteboard, captureSession: capture, preferences: ImageToolsPreferences(defaults: defaults))
        defer { coordinator.stop() }
        var completed = false
        coordinator.perform(.copy, on: try XCTUnwrap(store.entries.first)) { completed = true }
        capture.onWillCopySelection?()
        pasteboard.setString("Native selected text", forType: .string)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(completed)
        XCTAssertEqual(pasteboard.string(forType: .string), "Native selected text")
    }

    func testPinAndRecognitionCommandsUseCaptureContextInsteadOfClipboardOrNewCapture() async throws {
        let (_, store, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Old clipboard must not be read as an image", forType: .string)
        let count = pasteboard.changeCount
        let capture = CaptureStub()
        let coordinator = ImageToolsCoordinator(store: store, windowManager: WindowManager(registerHotKey: false),
                                                 pasteboard: pasteboard, captureSession: capture, preferences: ImageToolsPreferences(defaults: defaults))
        defer { coordinator.stop() }
        coordinator.perform(.capture)
        // Even before preparation returns, a pin hotkey must not fall back to the clipboard.
        coordinator.perform(.pinClipboard)
        coordinator.perform(.recognizeScreen)
        await waitFor { capture.handler != nil }
        XCTAssertEqual(capture.intents.count, 1)
        XCTAssertEqual(capture.requestedActions.count, 2)
        guard case .pin = capture.requestedActions[0],
              case .copyRecognizedText = capture.requestedActions[1] else {
            return XCTFail("Context commands must target the current selection")
        }
        XCTAssertEqual(pasteboard.changeCount, count)
        XCTAssertTrue(store.entries.isEmpty)
        capture.finish()
    }

    func testTerminalRecognitionWaitsOnceThenCopiesOnlyText() async throws {
        let (_, store, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let coordinator = ImageToolsCoordinator(store: store, windowManager: WindowManager(registerHotKey: false),
                                                 pasteboard: pasteboard, preferences: ImageToolsPreferences(defaults: defaults))
        defer { coordinator.stop() }
        var reads = 0
        let outcome = try await coordinator.performCaptureAction(.copyRecognizedText {
            reads += 1
            await Task.yield()
            return "Recognized 中文"
        })
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(pasteboard.string(forType: .string), "Recognized 中文")
        XCTAssertNil(pasteboard.data(forType: .png))
        await waitFor { store.entries.count == 1 }
        XCTAssertEqual(store.entries.first?.kind, .text)
    }

    func testUserCopyDuringPendingOCRPreventsOldRecognitionOverwrite() async throws {
        let (_, store, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let coordinator = ImageToolsCoordinator(store: store, windowManager: WindowManager(registerHotKey: false),
                                                 pasteboard: pasteboard, preferences: ImageToolsPreferences(defaults: defaults))
        defer { coordinator.stop() }
        var continuation: CheckedContinuation<String, Never>?
        let task = Task { try await coordinator.performCaptureAction(.copyRecognizedText {
            await withCheckedContinuation { continuation = $0 }
        }) }
        await waitFor { continuation != nil }
        pasteboard.clearContents()
        pasteboard.setString("New user copy", forType: .string)
        continuation?.resume(returning: "Old OCR")
        let outcome = try await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(pasteboard.string(forType: .string), "New user copy")
    }

    func testCancelledTerminalOCRDoesNotCopyLateText() async throws {
        let (_, store, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Keep", forType: .string)
        let coordinator = ImageToolsCoordinator(store: store, windowManager: WindowManager(registerHotKey: false),
                                                 pasteboard: pasteboard, preferences: ImageToolsPreferences(defaults: defaults))
        defer { coordinator.stop() }
        var continuation: CheckedContinuation<String, Never>?
        let task = Task { try await coordinator.performCaptureAction(.copyRecognizedText {
            await withCheckedContinuation { continuation = $0 }
        }) }
        await waitFor { continuation != nil }
        task.cancel()
        continuation?.resume(returning: "Late OCR")
        do { _ = try await task.value; XCTFail("Cancelled OCR must not complete") }
        catch is CancellationError { }
        XCTAssertEqual(pasteboard.string(forType: .string), "Keep")
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testEmptyRecognitionKeepsClipboardAndHistoryUnchanged() async throws {
        let (_, store, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Keep", forType: .string)
        let count = pasteboard.changeCount
        let coordinator = ImageToolsCoordinator(store: store, windowManager: WindowManager(registerHotKey: false),
                                                 pasteboard: pasteboard, preferences: ImageToolsPreferences(defaults: defaults))
        defer { coordinator.stop() }
        do {
            _ = try await coordinator.performCaptureAction(.copyRecognizedText { "  \n" })
            XCTFail("Empty OCR must remain available for reselection, not report success")
        } catch { XCTAssertTrue(error.localizedDescription.contains("文字")) }
        XCTAssertEqual(pasteboard.changeCount, count)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testDefaultSaveSuggestionUsesApplicationFilenameNotImageTitle() async throws {
        let (_, store, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var suggestion = ""
        let coordinator = ImageToolsCoordinator(store: store, windowManager: WindowManager(registerHotKey: false),
                                                 pasteboard: pasteboard, selectSaveURL: { name in
            suggestion = name
            return nil
        }, preferences: ImageToolsPreferences(defaults: defaults))
        defer { coordinator.stop() }
        _ = try await coordinator.performCaptureAction(.saveImage(image()))
        XCTAssertNotNil(suggestion.range(of: #"^iclipboard_\d{6}_\d{6}(?:_\d+)?\.png$"#, options: .regularExpression))
        XCTAssertFalse(suggestion.contains("Original"))
    }

    func testConfiguredDirectorySavesWithoutPanelCallbackAndKeepsClipboard() async throws {
        let (_, store, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = ImageToolsPreferences(defaults: defaults)
        try preferences.setDefaultSaveDirectory(directory)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Keep", forType: .string)
        let coordinator = ImageToolsCoordinator(store: store, windowManager: WindowManager(registerHotKey: false),
                                                 pasteboard: pasteboard, selectSaveURL: { _ in
            XCTFail("A configured export must not request a save panel")
            return nil
        }, preferences: preferences)
        defer { coordinator.stop() }
        var presentations = 0
        let outcome = try await coordinator.performCaptureAction(.saveImage(image(), willPresentPanel: { presentations += 1 }))
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(presentations, 0)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(try XCTUnwrap(files.first).lastPathComponent.hasPrefix("iclipboard_"))
        XCTAssertEqual(pasteboard.string(forType: .string), "Keep")
        await waitFor { store.entries.count == 1 }
    }

    func testApplicationActionsSurviveMenuRepopulationWithoutAccessibilityPermission() throws {
        let (_, store, defaults, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = ImageToolsCoordinator(store: store, windowManager: WindowManager(registerHotKey: false),
                                                 preferences: ImageToolsPreferences(defaults: defaults))
        defer { coordinator.stop() }
        let manager = MenuBarIconManager()
        manager.applicationMenuItems = { [weak coordinator] in coordinator?.makeMenuItems() ?? [] }
        let expectedCommands: [ImageToolsCoordinator.Command] = [.capture, .pinClipboard, .closePin, .togglePins, .closePins]
        XCTAssertEqual(coordinator.makeMenuItems().compactMap { $0.representedObject as? String },
                       expectedCommands.map(\.rawValue))
        let menu = manager.makeMenu()
        XCTAssertTrue(menu.items.contains { $0.title == "区域截图…" })
        XCTAssertFalse(menu.items.contains {
            $0.title == "截图识别文字…" || $0.representedObject as? String == ImageToolsCoordinator.Command.recognizeScreen.rawValue
        })
        manager.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items.filter { $0.title == "区域截图…" }.count, 1)
        XCTAssertFalse(menu.items.contains { $0.title == "屏幕取色…" || $0.title == "截图识别文字…" })
        XCTAssertFalse(menu.items.contains {
            $0.representedObject as? String == ImageToolsCoordinator.Command.recognizeScreen.rawValue
        })
        XCTAssertTrue(menu.items.contains { $0.title == "关闭贴图" })
    }
}
