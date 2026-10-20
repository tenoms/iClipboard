import AppKit
import CoreData
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import iClipboard

@MainActor
final class ClipboardImageTests: XCTestCase {
    private final class Fixture {
        let directory: URL
        let suite = "iClipboard.ImageTests." + UUID().uuidString
        let defaults: UserDefaults
        let pasteboard = NSPasteboard.withUniqueName()
        private(set) var container: NSPersistentContainer
        var sqliteURL: URL { directory.appendingPathComponent("test.sqlite") }

        init(model: NSManagedObjectModel? = nil) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defaults = UserDefaults(suiteName: suite)!
            container = model.map { NSPersistentContainer(name: "iClipboard", managedObjectModel: $0) }
                ?? NSPersistentContainer(name: "iClipboard")
            try loadPersistentStore()
        }

        func store() -> ClipboardStore {
            ClipboardStore(context: container.viewContext, defaults: defaults,
                           monitorPasteboard: false, onCapture: {})
        }

        func imageItem(title: String, preview: Data, source: URL? = nil) -> Item {
            let item = Item(context: container.viewContext)
            item.content = title
            item.kind = ClipboardContentKind.image.rawValue
            item.timestamp = Date()
            item.imageData = preview
            item.filePath = source?.path
            return item
        }

        func reopen() throws {
            try closePersistentStore()
            container = NSPersistentContainer(name: "iClipboard")
            try loadPersistentStore()
        }

        func cleanUp() {
            try? closePersistentStore()
            pasteboard.releaseGlobally()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        private func loadPersistentStore() throws {
            let description = NSPersistentStoreDescription(url: sqliteURL)
            description.shouldAddStoreAsynchronously = false
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
            container.persistentStoreDescriptions = [description]
            var failure: Error?
            container.loadPersistentStores { _, error in failure = error }
            if let failure { throw failure }
        }

        private func closePersistentStore() throws {
            container.viewContext.reset()
            for store in container.persistentStoreCoordinator.persistentStores {
                try container.persistentStoreCoordinator.remove(store)
            }
        }
    }

    func testPNGOriginalAlphaDimensionsAndDigestPersistAfterSQLiteReopen() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let original = try imageData(width: 1000, height: 600, alpha: 0.5)
        let payload = CapturedPayload.image(data: original, title: "Transparent original")
        let expectedDigest = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(payload.originalImageData, original)
        XCTAssertEqual(payload.imageDigest, expectedDigest)
        let preview = try XCTUnwrap(payload.imageData)
        let previewImage = try ToolImage.decode(preview)
        XCTAssertEqual(previewImage.pixelSize, CGSize(width: 320, height: 192))

        var store: ClipboardStore? = fixture.store()
        await drain()
        let id = try await store!.submit(payload)
        await drain()
        let entry = try XCTUnwrap(store?.entries.first)
        XCTAssertEqual(entry.id, id)
        XCTAssertTrue(store!.contains(id))
        XCTAssertTrue(entry.hasImage)
        XCTAssertFalse(entry.hasRichText)
        XCTAssertFalse(Mirror(reflecting: entry).children.contains {
            $0.value is Data || $0.value is NSData || $0.value is NSImage || $0.value is NSManagedObject
        }, "History entries must contain metadata rather than image blobs or managed objects")
        XCTAssertTrue(fixture.container.viewContext.registeredObjects
            .filter { $0 is Item }.allSatisfy(\.isFault),
                      "Refreshing lightweight metadata must leave image Items faulted")

        let item = try XCTUnwrap(fixture.container.viewContext.existingObject(with: id) as? Item)
        XCTAssertEqual(item.originalImageData, original)
        XCTAssertEqual(item.imageData, preview)
        XCTAssertEqual(item.imageDigest, expectedDigest)
        fixture.container.viewContext.refresh(item, mergeChanges: false)
        let loaded = try await store!.loadImage(for: entry)
        assertOriginal(loaded, width: 1000, height: 600, alpha: 0.5)
        let uri = id.uriRepresentation()

        store = nil
        await drain()
        try fixture.reopen()
        let reopened = fixture.store()
        await drain()
        let restored = try XCTUnwrap(reopened.entries.first)
        XCTAssertEqual(restored.id.uriRepresentation(), uri)
        XCTAssertTrue(reopened.contains(restored.id))
        XCTAssertEqual(restored.content, "Transparent original")
        let restoredItem = try XCTUnwrap(fixture.container.viewContext.existingObject(with: restored.id) as? Item)
        XCTAssertEqual(restoredItem.originalImageData, original)
        XCTAssertEqual(restoredItem.imageDigest, expectedDigest)
        let restoredPreview = try ToolImage.decode(XCTUnwrap(restoredItem.imageData))
        XCTAssertLessThanOrEqual(max(restoredPreview.pixelSize.width, restoredPreview.pixelSize.height), 320)
        let restoredImage = try await reopened.loadImage(for: restored)
        assertOriginal(restoredImage, width: 1000, height: 600, alpha: 0.5)
    }

    func testIdenticalImageBytesDeduplicateAcrossTitlesAndDeletionRestoresFingerprint() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        await drain()
        let firstData = try imageData(width: 800, height: 400)
        let first = CapturedPayload.image(data: firstData, title: "First title")
        let renamed = CapturedPayload.image(data: firstData, title: "Different title")
        XCTAssertEqual(first.fingerprint, renamed.fingerprint)
        let firstID = try await store.submit(first)
        let duplicateID = try await store.submit(renamed)
        await drain()
        XCTAssertEqual(firstID, duplicateID)
        XCTAssertEqual(store.entries.count, 1)

        let secondData = try imageData(width: 600, height: 300, alpha: 0.5)
        let secondID = try await store.submit(.image(data: secondData, title: "First title"))
        await drain()
        XCTAssertNotEqual(firstID, secondID, "Distinct image bytes must not deduplicate by title")
        XCTAssertEqual(store.entries.count, 2)
        store.delete(try XCTUnwrap(store.entries.first { $0.id == secondID }))
        await drain()
        XCTAssertFalse(store.contains(secondID))
        let afterDelete = try await store.submit(renamed)
        await drain()
        XCTAssertEqual(afterDelete, firstID)
        XCTAssertEqual(store.entries.map(\.id), [firstID])

        store.delete(try XCTUnwrap(store.entries.first))
        await drain()
        XCTAssertFalse(store.contains(firstID))
        let replacement = try await store.submit(first)
        await drain()
        XCTAssertNotEqual(replacement, firstID)
        XCTAssertTrue(store.contains(replacement))
        XCTAssertEqual(store.entries.map(\.id), [replacement])
    }

    func testPersistedImageDigestDeduplicatesAfterReopenDespiteDifferentTitle() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let data = try imageData(width: 640, height: 480)
        var store: ClipboardStore? = fixture.store()
        await drain()
        let id = try await store!.submit(.image(data: data, title: "Before closing"))
        await drain()
        let uri = id.uriRepresentation()
        store = nil
        await drain()
        try fixture.reopen()

        let reopened = fixture.store()
        await drain()
        let duplicate = try await reopened.submit(.image(data: data, title: "After reopening"))
        await drain()
        XCTAssertEqual(duplicate.uriRepresentation(), uri)
        XCTAssertEqual(reopened.entries.count, 1)
    }

    func testCopyBackWritesFullResolutionPNGWithAlphaNotJPEGLabelledAsTIFF() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        await drain()
        let original = try imageData(width: 900, height: 600, alpha: 0.5)
        _ = try await store.submit(.image(data: original, title: "Full PNG"))
        await drain()
        store.copyToPasteboard(try XCTUnwrap(store.entries.first), to: fixture.pasteboard)
        let png = try assertPNG(on: fixture.pasteboard)
        assertOriginal(try ToolImage.decode(png), width: 900, height: 600, alpha: 0.5)
        XCTAssertEqual(try XCTUnwrap(ToolImage.decode(png).color(at: .zero)).alpha, 0)

        let snapshot = try XCTUnwrap(ClipboardCaptureSnapshot(pasteboard: fixture.pasteboard))
        let recaptured = ClipboardStore.capturePasteboard(snapshot, enabledTypes: [.image])
        XCTAssertEqual(recaptured.count, 1)
        XCTAssertEqual(recaptured.first?.originalImageData, png)
    }

    private final class PromisedRepresentations: NSObject, NSPasteboardItemDataProvider {
        var requested: [NSPasteboard.PasteboardType] = []
        let png: Data
        init(png: Data) { self.png = png }
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                        provideDataForType type: NSPasteboard.PasteboardType) {
            requested.append(type)
            if type == .png || type == .tiff { item.setData(png, forType: type) }
            else if type == .rtf { item.setData(Data("{\\rtf1 Promised}".utf8), forType: type) }
            else if type == .string { item.setString("Promised text", forType: type) }
        }
    }

    func testSnapshotRequestsOnlyEnabledRepresentationAndSkipsUnusedPromisedImageData() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        for enabled: Set<ClipboardContentKind> in [[.text], [.richText, .text], [.image], []] {
            let provider = PromisedRepresentations(png: try imageData(width: 40, height: 20))
            let item = NSPasteboardItem()
            item.setDataProvider(provider, forTypes: [.png, .tiff, .rtf, .string])
            fixture.pasteboard.clearContents()
            fixture.pasteboard.writeObjects([item])
            let snapshot = try XCTUnwrap(ClipboardCaptureSnapshot(pasteboard: fixture.pasteboard, enabledTypes: enabled))
            let expected: [NSPasteboard.PasteboardType] = enabled.contains(.image) ? [.png]
                : enabled.contains(.richText) ? [.rtf] : enabled.contains(.text) ? [.string] : []
            XCTAssertEqual(provider.requested, expected)
            XCTAssertEqual(ClipboardStore.capturePasteboard(snapshot, enabledTypes: enabled).count, enabled.isEmpty ? 0 : 1)
        }
    }

    func testPassiveImageCaptureKeepsOriginalEncodingWithBoundedValidatedPreview() throws {
        let original = try imageData(width: 1600, height: 900, alpha: 0.5)
        let payload = try XCTUnwrap(CapturedPayload.capturedImage(data: original, title: "Original"))
        XCTAssertEqual(payload.originalImageData, original)
        XCTAssertEqual(payload.imageDigest, CapturedPayload.image(data: original, title: "Original").imageDigest)
        XCTAssertEqual(try ToolImage.decode(XCTUnwrap(payload.imageData)).pixelSize, CGSize(width: 320, height: 180))
        XCTAssertNil(CapturedPayload.capturedImage(data: Data("not an image".utf8), title: "Invalid"))
    }

    func testWebSourceURLDoesNotSuppressFrozenPNGOrBecomeAFileRead() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let data = try imageData(width: 640, height: 400)
        let item = NSPasteboardItem()
        item.setString("https://example.invalid/image.png", forType: NSPasteboard.PasteboardType("public.url"))
        item.setData(data, forType: .png)
        fixture.pasteboard.writeObjects([item])
        let snapshot = try XCTUnwrap(ClipboardCaptureSnapshot(pasteboard: fixture.pasteboard))
        XCTAssertTrue(snapshot.fileURLs.isEmpty, "Web source URLs must never be read as files or downloaded")
        XCTAssertEqual(snapshot.data(forType: .png), data)
        let captured = ClipboardStore.capturePasteboard(snapshot, enabledTypes: [.image])
        XCTAssertEqual(captured.first?.originalImageData, data)
    }

    func testWebURLWithoutImageStaysTextAndNeverBecomesAFile() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let url = "https://example.invalid/page"
        fixture.pasteboard.setString(url, forType: NSPasteboard.PasteboardType("public.url"))
        fixture.pasteboard.setString(url, forType: .string)
        let snapshot = try XCTUnwrap(ClipboardCaptureSnapshot(pasteboard: fixture.pasteboard))
        XCTAssertTrue(snapshot.fileURLs.isEmpty)
        XCTAssertEqual(ClipboardStore.capturePasteboard(snapshot, enabledTypes: [.text, .file]).first?.kind, .text)
        XCTAssertEqual(snapshot.string(forType: .string), url)
    }

    func testImageFileCopyRetainsFileURLAlongsideFullPNG() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let original = try imageData(width: 900, height: 600)
        let url = fixture.directory.appendingPathComponent("source.png")
        try original.write(to: url)
        let store = fixture.store()
        _ = try await store.submit(.image(data: original, title: "Source file", fileURL: url))
        await drain()
        store.copyToPasteboard(try XCTUnwrap(store.entries.first), to: fixture.pasteboard)
        XCTAssertEqual(fixture.pasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL], [url])
        XCTAssertEqual(try ToolImage.decode(assertPNG(on: fixture.pasteboard)).pixelSize,
                       CGSize(width: 900, height: 600))
    }

    func testExplicitSubmitAfterHistoryClearDoesNotDeduplicateIntoHiddenFavorite() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        let payload = CapturedPayload.image(data: try imageData(width: 640, height: 400), title: "Favorite")
        let firstID = try await store.submit(payload)
        await drain()
        let list = FavoriteList(context: fixture.container.viewContext)
        list.name = "Keep"
        list.createdAt = Date()
        let item = try XCTUnwrap(fixture.container.viewContext.existingObject(with: firstID) as? Item)
        item.favoriteList = list
        try fixture.container.viewContext.save()
        store.deleteAll()
        // Submit before refresh has caught up: deduplication must inspect live history.
        let secondID = try await store.submit(payload)
        await drain()
        XCTAssertNotEqual(secondID, firstID)
        XCTAssertTrue(try XCTUnwrap(fixture.container.viewContext.existingObject(with: firstID) as? Item).favoriteList === list)
        XCTAssertEqual(store.entries.filter { !$0.isDeletedFromHistory }.map(\.id), [secondID])
        XCTAssertEqual(store.entries.filter(\.isDeletedFromHistory).map(\.id), [firstID])
    }

    func testLegacyJPEGPreviewCopiesAsAnActualPNG() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let jpeg = try imageData(width: 160, height: 80, type: .jpeg)
        _ = fixture.imageItem(title: "Legacy JPEG thumbnail", preview: jpeg)
        try fixture.container.viewContext.save()
        let store = fixture.store()
        await drain()

        store.copyToPasteboard(try XCTUnwrap(store.entries.first), to: fixture.pasteboard)
        let png = try assertPNG(on: fixture.pasteboard)
        XCTAssertEqual(try ToolImage.decode(png).pixelSize, CGSize(width: 160, height: 80))
    }

    func testBackgroundCaptureUsesFrozenSnapshotAfterPasteboardChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let first = try imageData(width: 640, height: 400, alpha: 0.5)
        let later = try imageData(width: 200, height: 100)
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.setData(first, forType: .png))
        XCTAssertTrue(fixture.pasteboard.setString("Original clipboard", forType: .string))
        let snapshot = try XCTUnwrap(ClipboardCaptureSnapshot(pasteboard: fixture.pasteboard))
        let originalChangeCount = snapshot.changeCount

        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.setData(later, forType: .png))
        XCTAssertTrue(fixture.pasteboard.setString("Programmatic replacement", forType: .string))
        XCTAssertNotEqual(fixture.pasteboard.changeCount, originalChangeCount)
        XCTAssertEqual(snapshot.data(forType: .png), first)
        XCTAssertNil(snapshot.string(forType: .string), "Image-first snapshots must not request an unused text representation")
        let captured = await Task.detached {
            ClipboardStore.capturePasteboard(snapshot, enabledTypes: [.image])
        }.value
        XCTAssertEqual(captured.count, 1)
        let payload = try XCTUnwrap(captured.first)
        XCTAssertEqual(payload.originalImageData, first)
        XCTAssertNotEqual(payload.originalImageData, later)

        let store = fixture.store()
        await drain()
        _ = try await store.submit(payload)
        await drain()
        let image = try await store.loadImage(for: XCTUnwrap(store.entries.first))
        assertOriginal(image, width: 640, height: 400, alpha: 0.5)
    }

    func testDisabledImageCaptureRespectsEnabledTextAndEmptyFallbacks() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.setData(try imageData(width: 40, height: 20), forType: .png))
        XCTAssertTrue(fixture.pasteboard.setString("Text is still enabled", forType: .string))
        let snapshot = try XCTUnwrap(ClipboardCaptureSnapshot(pasteboard: fixture.pasteboard, enabledTypes: [.text]))
        let text = ClipboardStore.capturePasteboard(snapshot, enabledTypes: [.text])
        XCTAssertEqual(text.count, 1)
        XCTAssertEqual(text.first?.kind, .text)
        XCTAssertEqual(text.first?.content, "Text is still enabled")
        XCTAssertNil(text.first?.originalImageData)
        XCTAssertTrue(ClipboardStore.capturePasteboard(snapshot, enabledTypes: []).isEmpty)

        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.setData(try imageData(width: 40, height: 20), forType: .png))
        let imageOnly = try XCTUnwrap(ClipboardCaptureSnapshot(pasteboard: fixture.pasteboard))
        XCTAssertTrue(ClipboardStore.capturePasteboard(imageOnly, enabledTypes: [.text, .file]).isEmpty)
        XCTAssertEqual(ClipboardStore.capturePasteboard(imageOnly, enabledTypes: [.image]).first?.kind, .image)
    }

    func testDisabledImageCaptureStillPreservesEnabledRichTextRepresentation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let rtf = Data("{\\rtf1\\ansi Styled text}".utf8)
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.setData(try imageData(width: 40, height: 20), forType: .png))
        XCTAssertTrue(fixture.pasteboard.setData(rtf, forType: .rtf))
        XCTAssertTrue(fixture.pasteboard.setString("Styled text", forType: .string))
        let snapshot = try XCTUnwrap(ClipboardCaptureSnapshot(pasteboard: fixture.pasteboard, enabledTypes: [.richText, .text]))
        let captured = ClipboardStore.capturePasteboard(snapshot, enabledTypes: [.richText, .text])

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.kind, .richText,
                       "An available PNG must not suppress enabled RTF when image capture is disabled")
        XCTAssertEqual(captured.first?.rtfData, rtf)
        XCTAssertEqual(captured.first?.content, "Styled text")
        XCTAssertNil(captured.first?.originalImageData)
    }

    func testDisabledImageFileDoesNotFallThroughToFileOrTextCapture() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let url = fixture.directory.appendingPathComponent("source.png")
        let data = try imageData(width: 400, height: 200)
        try data.write(to: url)
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.writeObjects([url as NSURL]))
        XCTAssertTrue(fixture.pasteboard.setString("Do not capture this image as text", forType: .string))
        let snapshot = try XCTUnwrap(ClipboardCaptureSnapshot(pasteboard: fixture.pasteboard))
        XCTAssertEqual(snapshot.fileURLs, [url])
        XCTAssertTrue(ClipboardStore.capturePasteboard(snapshot, enabledTypes: [.file, .text]).isEmpty)
        let image = try XCTUnwrap(ClipboardStore.capturePasteboard(snapshot, enabledTypes: [.image]).first)
        XCTAssertEqual(image.kind, .image)
        XCTAssertEqual(image.originalImageData, data)
        XCTAssertEqual(image.fileURL, url)
    }

    func testLegacyImageLoadsSourceFileThenFallsBackToNonOriginalThumbnail() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let original = try imageData(width: 1000, height: 500, alpha: 0.5)
        let thumbnail = try XCTUnwrap(ImagePreviewLoader.thumbnailData(from: original))
        let url = fixture.directory.appendingPathComponent("legacy-source.png")
        try original.write(to: url)
        let legacy = fixture.imageItem(title: "Legacy file", preview: thumbnail, source: url)
        let thumbnailOnly = fixture.imageItem(title: "Legacy preview only", preview: thumbnail)
        try fixture.container.viewContext.save()
        let legacyID = legacy.objectID
        let previewID = thumbnailOnly.objectID
        let store = fixture.store()
        await drain()
        let entry = try XCTUnwrap(store.entries.first { $0.id == legacyID })
        let fromSource = try await store.loadImage(for: entry)
        assertOriginal(fromSource, width: 1000, height: 500, alpha: 0.5)

        try FileManager.default.removeItem(at: url)
        let fallback = try await store.loadImage(for: entry)
        XCTAssertFalse(fallback.isOriginal)
        XCTAssertEqual(fallback.pixelSize, CGSize(width: 320, height: 160))
        let previewOnly = try await store.loadImage(for: XCTUnwrap(store.entries.first { $0.id == previewID }))
        XCTAssertFalse(previewOnly.isOriginal)
        XCTAssertEqual(previewOnly.pixelSize, fallback.pixelSize)
    }

    func testLegacyCorruptedSourceFallsBackToPreviewForLoadingAndPNGCopy() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let preview = try imageData(width: 160, height: 80, type: .jpeg)
        let url = fixture.directory.appendingPathComponent("corrupted-source.png")
        try Data("This file is no longer an image".utf8).write(to: url)
        _ = fixture.imageItem(title: "Legacy damaged source", preview: preview, source: url)
        try fixture.container.viewContext.save()
        let store = fixture.store()
        await drain()
        let entry = try XCTUnwrap(store.entries.first)

        let image = try await store.loadImage(for: entry)
        XCTAssertFalse(image.isOriginal)
        XCTAssertEqual(image.pixelSize, CGSize(width: 160, height: 80))
        store.copyToPasteboard(entry, to: fixture.pasteboard)
        let png = try assertPNG(on: fixture.pasteboard)
        XCTAssertEqual(try ToolImage.decode(png).pixelSize, image.pixelSize)
    }

    func testDeletingSourceFileDoesNotAffectNewPersistedOriginalOrCopyBack() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let original = try imageData(width: 960, height: 540, alpha: 0.5)
        let url = fixture.directory.appendingPathComponent("temporary-source.png")
        try original.write(to: url)
        let store = fixture.store()
        await drain()
        let id = try await store.submit(.image(data: original, title: "Saved original", fileURL: url))
        await drain()
        try FileManager.default.removeItem(at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let entry = try XCTUnwrap(store.entries.first { $0.id == id })
        let image = try await store.loadImage(for: entry)
        assertOriginal(image, width: 960, height: 540, alpha: 0.5)
        store.copyToPasteboard(entry, to: fixture.pasteboard)
        assertOriginal(try ToolImage.decode(assertPNG(on: fixture.pasteboard)),
                       width: 960, height: 540, alpha: 0.5)
    }

    func testV1SQLiteMigratesFavoritesSoftDeletionAndImageThenAcceptsOriginals() async throws {
        let v1 = try bundledV1Model()
        XCTAssertNil(v1.entitiesByName["Item"]?.attributesByName["originalImageData"])
        XCTAssertNil(v1.entitiesByName["Item"]?.attributesByName["imageDigest"])
        // Do not instantiate the V2 generated Item class against a V1 entity.
        let dynamicV1 = try XCTUnwrap(v1.copy() as? NSManagedObjectModel)
        for entity in dynamicV1.entities { entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self) }
        XCTAssertEqual(dynamicV1.entityVersionHashesByName, v1.entityVersionHashesByName)
        let fixture = try Fixture(model: dynamicV1)
        defer { fixture.cleanUp() }
        let context = fixture.container.viewContext
        let createdAt = Date(timeIntervalSince1970: 1_000_000)
        let timestamp = createdAt.addingTimeInterval(10)
        let list = NSEntityDescription.insertNewObject(forEntityName: "FavoriteList", into: context)
        list.setValue("Preserved favorites", forKey: "name")
        list.setValue(createdAt, forKey: "createdAt")
        let legacyData = try imageData(width: 240, height: 120, type: .jpeg)
        let legacy = NSEntityDescription.insertNewObject(forEntityName: "Item", into: context)
        legacy.setValue("V1 saved image", forKey: "content")
        legacy.setValue(ClipboardContentKind.image.rawValue, forKey: "kind")
        legacy.setValue(timestamp, forKey: "timestamp")
        legacy.setValue(legacyData, forKey: "imageData")
        legacy.setValue(true, forKey: "isDeletedFromHistory")
        legacy.setValue(list, forKey: "favoriteList")
        let history = NSEntityDescription.insertNewObject(forEntityName: "Item", into: context)
        history.setValue("V1 history text", forKey: "content")
        history.setValue(ClipboardContentKind.text.rawValue, forKey: "kind")
        history.setValue(timestamp.addingTimeInterval(1), forKey: "timestamp")
        history.setValue(false, forKey: "isDeletedFromHistory")
        try context.save()
        let oldMetadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType, at: fixture.sqliteURL, options: nil)
        XCTAssertTrue(v1.isConfiguration(withName: nil, compatibleWithStoreMetadata: oldMetadata))

        try fixture.reopen()
        let currentModel = fixture.container.managedObjectModel
        XCTAssertNotNil(currentModel.entitiesByName["Item"]?.attributesByName["originalImageData"])
        XCTAssertNotNil(currentModel.entitiesByName["Item"]?.attributesByName["imageDigest"])
        XCTAssertFalse(currentModel.isConfiguration(withName: nil, compatibleWithStoreMetadata: oldMetadata))
        let newMetadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType, at: fixture.sqliteURL, options: nil)
        XCTAssertTrue(currentModel.isConfiguration(withName: nil, compatibleWithStoreMetadata: newMetadata))
        let store = fixture.store()
        await drain()
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.filteredEntries.map(\.content), ["V1 history text"])
        let savedList = try XCTUnwrap(store.favoriteLists.first)
        XCTAssertEqual(savedList.name, "Preserved favorites")
        XCTAssertEqual(savedList.createdAt, createdAt)
        XCTAssertEqual(savedList.count, 1)
        let savedImage = try XCTUnwrap(store.entries.first { $0.content == "V1 saved image" })
        XCTAssertTrue(savedImage.isDeletedFromHistory)
        XCTAssertTrue(savedImage.hasImage)
        XCTAssertEqual(savedImage.timestamp, timestamp)
        XCTAssertEqual(savedImage.favoriteListID, savedList.id)
        XCTAssertEqual(savedImage.favoriteListName, "Preserved favorites")
        let migratedItem = try XCTUnwrap(fixture.container.viewContext.existingObject(with: savedImage.id) as? Item)
        XCTAssertEqual(migratedItem.imageData, legacyData)
        XCTAssertNil(migratedItem.originalImageData)
        XCTAssertNil(migratedItem.imageDigest)
        let legacyImage = try await store.loadImage(for: savedImage)
        XCTAssertFalse(legacyImage.isOriginal)
        XCTAssertEqual(legacyImage.pixelSize, CGSize(width: 240, height: 120))
        store.selectedListID = savedList.id
        XCTAssertEqual(store.filteredEntries.map(\.id), [savedImage.id])

        let original = try imageData(width: 800, height: 600, alpha: 0.5)
        let newID = try await store.submit(.image(data: original, title: "V2 original after migration"))
        await drain()
        let newEntry = try XCTUnwrap(store.entries.first { $0.id == newID })
        let newItem = try XCTUnwrap(fixture.container.viewContext.existingObject(with: newID) as? Item)
        XCTAssertEqual(newItem.originalImageData, original)
        XCTAssertNotNil(newItem.imageDigest)
        let newImage = try await store.loadImage(for: newEntry)
        assertOriginal(newImage, width: 800, height: 600, alpha: 0.5)
        XCTAssertEqual(store.favoriteLists.first?.count, 1)
        XCTAssertEqual(store.filteredEntries.map(\.id), [savedImage.id])
    }

    private func bundledV1Model() throws -> NSManagedObjectModel {
        let bundles = [Bundle(for: Item.self), Bundle.main, Bundle(for: ClipboardImageTests.self)]
        let modelDirectory = try XCTUnwrap(bundles.compactMap {
            $0.url(forResource: "iClipboard", withExtension: "momd")
        }.first, "The test host must bundle both Core Data model versions")
        let url = modelDirectory.appendingPathComponent("iClipboard.mom")
        return try XCTUnwrap(NSManagedObjectModel(contentsOf: url), "Missing bundled V1 model at \(url.path)")
    }

    private func imageData(width: Int, height: Int, alpha: CGFloat = 1, type: UTType = .png) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        let color = try XCTUnwrap(CGColor(colorSpace: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                         components: [0.2, 0.4, 0.8, alpha]))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if type == .png {
            context.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
            context.clear(CGRect(x: 0, y: height - 1, width: 1, height: 1))
        }
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @discardableResult
    private func assertPNG(on pasteboard: NSPasteboard,
                           file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        let data = try XCTUnwrap(pasteboard.data(forType: .png), "Copy-back must publish PNG", file: file, line: line)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil), file: file, line: line)
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier, file: file, line: line)
        if let tiff = pasteboard.data(forType: .tiff) {
            let source = try XCTUnwrap(CGImageSourceCreateWithData(tiff as CFData, nil), file: file, line: line)
            XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.tiff.identifier,
                           "JPEG thumbnail bytes must never be advertised as TIFF", file: file, line: line)
        }
        return data
    }

    private func assertOriginal(_ image: ToolImage, width: Int, height: Int, alpha: Double,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(image.isOriginal, file: file, line: line)
        XCTAssertEqual(image.pixelSize, CGSize(width: width, height: height), file: file, line: line)
        guard let sample = image.color(at: CGPoint(x: width / 2, y: height / 2)) else {
            return XCTFail("Missing center pixel", file: file, line: line)
        }
        XCTAssertEqual(sample.alpha, alpha, accuracy: 1.0 / 255, file: file, line: line)
        XCTAssertEqual(Double(sample.red), 51, accuracy: 2, file: file, line: line)
        XCTAssertEqual(Double(sample.green), 102, accuracy: 2, file: file, line: line)
        XCTAssertEqual(Double(sample.blue), 204, accuracy: 2, file: file, line: line)
    }

    private func drain() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}
