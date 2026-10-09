import AppKit
import CoreData
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import iClipboard

@MainActor
final class ClipboardMemoryTests: XCTestCase {
    private final class Fixture {
        let container = NSPersistentContainer(name: "iClipboard")
        let directory: URL
        let suite = "iClipboard.MemoryTests." + UUID().uuidString
        let defaults: UserDefaults

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defaults = UserDefaults(suiteName: suite)!
            let description = NSPersistentStoreDescription(url: directory.appendingPathComponent("test.sqlite"))
            description.shouldAddStoreAsynchronously = false
            container.persistentStoreDescriptions = [description]
            var failure: Error?
            container.loadPersistentStores { _, error in failure = error }
            if let failure { throw failure }
        }

        func store() -> ClipboardStore {
            ClipboardStore(context: container.viewContext, defaults: defaults,
                           monitorPasteboard: false, onCapture: {})
        }

        func item(_ content: String, kind: ClipboardContentKind = .text, age: TimeInterval = 0) -> Item {
            let item = Item(context: container.viewContext)
            item.content = content
            item.kind = kind.rawValue
            item.timestamp = Date(timeIntervalSince1970: 1_000_000 - age)
            return item
        }

        func cleanUp() {
            container.viewContext.reset()
            for store in container.persistentStoreCoordinator.persistentStores {
                try? container.persistentStoreCoordinator.remove(store)
            }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func drain() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    func testStoreAndSubscriptionsReleaseWithTheirOwner() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var store: ClipboardStore? = fixture.store()
        weak var weakStore = store
        await drain()
        store = nil
        await drain()
        XCTAssertNil(weakStore, "The filter subscription must not retain its Store")
    }

    func testMetadataFetchPreservesBinaryFlagsAndFavoritesWithoutRealizingAllItems() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let list = FavoriteList(context: fixture.container.viewContext)
        list.name = "Saved"
        list.createdAt = Date()
        let image = fixture.item("Image", kind: .image, age: 2)
        image.imageData = Data(repeating: 1, count: 2 * 1024 * 1024)
        image.favoriteList = list
        image.isDeletedFromHistory = true
        let rich = fixture.item("Rich", kind: .richText, age: 1)
        rich.rtfData = Data("{\\rtf1 Test}".utf8)
        _ = fixture.item("Newest")
        let undated = Item(context: fixture.container.viewContext)
        undated.favoriteList = list
        undated.kind = ClipboardContentKind.text.rawValue
        try fixture.container.viewContext.save()
        let imageID = image.objectID
        let listID = list.objectID
        fixture.container.viewContext.reset()

        let store = fixture.store()
        await drain()
        XCTAssertEqual(store.entries.count, 3)
        XCTAssertEqual(store.filteredEntries.count, 2)
        let entry = try XCTUnwrap(store.entries.first { $0.id == imageID })
        XCTAssertTrue(entry.hasImage)
        XCTAssertFalse(entry.hasRichText)
        XCTAssertEqual(entry.favoriteListID, listID)
        XCTAssertEqual(entry.favoriteListName, "Saved")
        XCTAssertEqual(store.favoriteLists.first?.count, 2)
        XCTAssertTrue(fixture.container.viewContext.registeredObjects
            .filter { $0 is Item }.allSatisfy(\.isFault))

        store.selectedListID = listID
        XCTAssertEqual(store.filteredEntries.map(\.id), [imageID])
        store.releasePreviews()
        XCTAssertEqual(store.filteredEntries.map(\.id), [imageID])
    }

    func testRecordingDeduplicatesAndDeletingNewestRestoresFingerprint() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        await drain()
        let a = CapturedPayload(kind: .text, content: "A", rtfData: nil, fileURL: nil, imageData: nil)
        let b = CapturedPayload(kind: .text, content: "B", rtfData: nil, fileURL: nil, imageData: nil)
        store.record([a, a])
        await drain()
        XCTAssertEqual(store.entries.count, 1)
        store.record([b])
        await drain()
        XCTAssertEqual(store.entries.count, 2)
        store.delete(try XCTUnwrap(store.entries.first { $0.content == "B" }))
        await drain()
        store.record([a])
        await drain()
        XCTAssertEqual(store.entries.map(\.content), ["A"])
    }

    func testTrimmingAndClearingHistoryKeepFavorites() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(10, forKey: "historyLimit")
        let list = FavoriteList(context: fixture.container.viewContext)
        list.name = "Saved"
        list.createdAt = Date()
        fixture.item("Favorite", age: 100).favoriteList = list
        for index in 0..<12 { _ = fixture.item("History \(index)", age: Double(index)) }
        try fixture.container.viewContext.save()
        let store = fixture.store()
        await drain()
        store.record([CapturedPayload(kind: .text, content: "New", rtfData: nil, fileURL: nil, imageData: nil)])
        await drain()
        XCTAssertEqual(store.filteredEntries.count, 10)
        XCTAssertEqual(store.entries.count, 11)
        XCTAssertTrue(try XCTUnwrap(store.entries.first { $0.content == "Favorite" }).isDeletedFromHistory)
        store.deleteAll()
        await drain()
        XCTAssertTrue(store.filteredEntries.isEmpty)
        XCTAssertEqual(store.entries.map(\.content), ["Favorite"])
        XCTAssertEqual(store.favoriteLists.first?.count, 1)
    }

    func testCopyBackUsesOriginalRichTextAndFileURL() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let rich = fixture.item("Styled", kind: .richText)
        let rtf = Data("{\\rtf1 Styled}".utf8)
        rich.rtfData = rtf
        let file = fixture.item("File", kind: .file, age: 1)
        let url = fixture.directory.appendingPathComponent("example.txt")
        try Data("Example".utf8).write(to: url)
        file.filePath = url.path
        try fixture.container.viewContext.save()
        let store = fixture.store()
        await drain()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        store.copyToPasteboard(try XCTUnwrap(store.entries.first { $0.kind == .richText }), to: pasteboard)
        XCTAssertEqual(pasteboard.data(forType: .rtf), rtf)
        XCTAssertEqual(pasteboard.string(forType: .string), "Styled")
        store.copyToPasteboard(try XCTUnwrap(store.entries.first { $0.kind == .file }), to: pasteboard)
        XCTAssertEqual((pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first, url)
        XCTAssertEqual(pasteboard.string(forType: .string), "example.txt")
    }

    func testPreviewCacheDecodesOnceAndReloadsAfterRelease() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let item = fixture.item("Image", kind: .image)
        item.imageData = try imageData(width: 1200, height: 600)
        try fixture.container.viewContext.save()
        let store = fixture.store()
        await drain()
        let entry = try XCTUnwrap(store.entries.first)
        let first = try XCTUnwrap(store.preview(for: entry).image)
        XCTAssertTrue(first === store.preview(for: entry).image)
        XCTAssertLessThanOrEqual(max(first.size.width, first.size.height), 320)
        store.releasePreviews()
        let second = try XCTUnwrap(store.preview(for: entry).image)
        XCTAssertFalse(first === second)
        XCTAssertEqual(second.size, first.size)
    }

    func testThumbnailDownsamplingHonorsOrientationAndSmallImages() throws {
        let landscape = try imageData(width: 2000, height: 1000, orientation: 6)
        let thumbnail = try XCTUnwrap(ImagePreviewLoader.thumbnailData(from: landscape))
        let image = try XCTUnwrap(ImagePreviewLoader.previewImage(from: thumbnail))
        XCTAssertEqual(image.size.width, 160)
        XCTAssertEqual(image.size.height, 320)
        let small = try imageData(width: 64, height: 32)
        let smallThumbnail = try XCTUnwrap(ImagePreviewLoader.thumbnailData(from: small))
        XCTAssertEqual(ImagePreviewLoader.previewImage(from: smallThumbnail)?.size, NSSize(width: 64, height: 32))
        XCTAssertNil(ImagePreviewLoader.thumbnailData(from: Data()))
        XCTAssertNil(ImagePreviewLoader.thumbnailData(from: small, maxDimension: 0))
    }

    private func imageData(width: Int, height: Int, orientation: Int = 1) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
                                  [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testPanelHidingReleasesHistoryAndRestoresScrollWithoutStoppingTheStore() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        for index in 0..<100 { _ = fixture.item("History \(index)", age: Double(index)) }
        try fixture.container.viewContext.save()
        let store = fixture.store()
        await drain()
        store.searchText = "History"

        let manager = WindowManager(registerHotKey: false)
        let status = NSStatusBar.system.statusItem(withLength: 24)
        let panel = ClipboardPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
            backing: .buffered, defer: false
        )
        let hosting = NSHostingView(rootView: ContentView(store: store).environmentObject(manager))
        panel.contentView = hosting
        manager.panel = panel
        manager.statusItem = status
        defer {
            panel.orderOut(nil)
            panel.contentView = nil
            NSStatusBar.system.removeStatusItem(status)
        }
        func tableScrollView() -> NSScrollView? {
            func find(_ view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView, scroll.documentView is NSTableView { return scroll }
                return view.subviews.lazy.compactMap { find($0) }.first
            }
            return find(hosting)
        }
        manager.openWindow()
        await waitFor { tableScrollView() != nil }
        try await Task.sleep(nanoseconds: 150_000_000)
        weak var oldList: NSScrollView?
        autoreleasepool {
            let scroll = tableScrollView()!
            oldList = scroll
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 900))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        await drain()
        manager.closeWindow()
        await waitFor { !manager.isPanelVisible && tableScrollView() == nil }
        await waitFor { oldList == nil }
        XCTAssertNil(oldList, "Hidden history must release its native table and row views")

        store.record([CapturedPayload(kind: .text, content: "Captured while hidden",
                                      rtfData: nil, fileURL: nil, imageData: nil)])
        await drain()
        XCTAssertEqual(store.entries.count, 101)
        XCTAssertEqual(store.searchText, "History")
        XCTAssertEqual(store.filteredEntries.count, 100)
        manager.openWindow()
        await waitFor { tableScrollView() != nil }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(tableScrollView()?.contentView.bounds.origin.y ?? -1, 900, accuracy: 2)
        manager.isPinned = true
        manager.closeWindow()
        XCTAssertTrue(manager.isPanelVisible)
        XCTAssertTrue(panel.isVisible)
        manager.isPinned = false
        for _ in 0..<3 {
            manager.closeWindow()
            await waitFor { !manager.isPanelVisible && tableScrollView() == nil }
            manager.openWindow()
            await waitFor { tableScrollView() != nil }
        }
        XCTAssertEqual(store.entries.count, 101)
    }

    func testUnusedTranslationDoesNotCreateItsPanels() {
        var creations = 0
        let coordinator = TranslationCoordinator(panelProvider: {
            creations += 1
            return TranslationPanelController.shared
        })
        coordinator.stop()
        XCTAssertEqual(creations, 0)
    }

    private func waitFor(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), "Timed out waiting for the panel lifecycle")
    }
}

@MainActor
final class ListScrollPositionTests: XCTestCase {
    private final class Rows: NSObject, NSTableViewDataSource {
        func numberOfRows(in tableView: NSTableView) -> Int { 100 }
    }

    func testOffsetRestoresAndViewsAndObserversCanRelease() {
        let position = ListScrollPosition()
        let rows = Rows()
        weak var weakScroll: NSScrollView?
        weak var weakCoordinator: ListScrollPositionReader.Coordinator?
        autoreleasepool {
            let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 3000))
            table.addTableColumn(NSTableColumn(identifier: .init("test")))
            table.rowHeight = 30
            table.dataSource = rows
            table.reloadData()
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
            scroll.documentView = table
            let coordinator = ListScrollPositionReader.Coordinator(position: position)
            weakScroll = scroll
            weakCoordinator = coordinator
            position.origin = NSPoint(x: 0, y: 600)
            coordinator.attach(to: scroll)
            XCTAssertEqual(scroll.contentView.bounds.origin.y, 600)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 900))
            coordinator.disconnect()
            XCTAssertEqual(position.origin?.y, 900)
        }
        XCTAssertNil(weakCoordinator)
        XCTAssertNil(weakScroll, "The restoration state must not retain the native list")
    }
}
