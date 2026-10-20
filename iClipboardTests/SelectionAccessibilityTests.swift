import AppKit
import ApplicationServices
import XCTest
@testable import iClipboard

final class SelectionAccessibilityTests: XCTestCase {
    private final class Reader: SelectionAccessibilityReading {
        typealias Element = String
        var attributes: [String: [String: Any]] = [:]
        var parameterized: [String: [String: Any]] = [:]
        var hit: String?
        var reads = 0

        func value(_ attribute: String, of element: String) -> Any? {
            reads += 1
            return attributes[element]?[attribute]
        }
        func value(_ attribute: String, parameter: Any, of element: String) -> Any? {
            reads += 1
            return parameterized[element]?[attribute]
        }
        func hitTest(_ point: CGPoint, in application: String) -> String? { hit }
    }

    private func resolve(_ reader: Reader) -> SelectionResolution {
        SelectionAccessibilityResolver(reader: reader).resolve(application: "app", point: .zero)
    }

    func testChromeSelectionAcrossDOMNodesAndIframeAncestors() {
        let reader = Reader()
        reader.hit = "text"
        reader.attributes = [
            "app": [kAXFocusedUIElementAttribute: "addressBar"],
            "addressBar": [kAXSelectedTextAttribute: "stale URL"],
            "text": [kAXParentAttribute: "link"],
            "link": [kAXParentAttribute: "paragraph"],
            "paragraph": [kAXParentAttribute: "iframe"],
            "iframe": [kAXParentAttribute: "webArea"],
            "webArea": ["AXSelectedTextMarkerRange": "opaque marker"]
        ]
        reader.parameterized = ["webArea": ["AXStringForTextMarkerRange": " selected across nodes "]]
        XCTAssertEqual(resolve(reader), .selected(.init(text: "selected across nodes", bounds: nil)))
    }

    func testAttributedMarkerSelectionWithoutBoundsStillProducesText() {
        let reader = Reader()
        reader.hit = "webArea"
        reader.attributes = ["webArea": ["AXSelectedTextMarkerRange": "opaque marker"]]
        reader.parameterized = ["webArea": ["AXAttributedStringForTextMarkerRange": NSAttributedString(string: "网页正文")]]
        XCTAssertEqual(resolve(reader), .selected(.init(text: "网页正文", bounds: nil)))
    }

    func testNativeDirectSelectionRemainsSupported() {
        let reader = Reader()
        reader.attributes = ["app": [kAXFocusedUIElementAttribute: "editor"], "editor": [kAXSelectedTextAttribute: "hello"]]
        XCTAssertEqual(resolve(reader), .selected(.init(text: "hello", bounds: nil)))
    }

    func testDistantStaleSelectionDoesNotOverrideCurrentSelection() {
        let reader = Reader()
        reader.hit = "oldControl"
        var range = CFRange(location: 0, length: 3)
        var bounds = CGRect(x: 900, y: 900, width: 100, height: 20)
        reader.attributes = [
            "app": [kAXFocusedUIElementAttribute: "editor"],
            "oldControl": [kAXSelectedTextAttribute: "old", kAXSelectedTextRangeAttribute: AXValueCreate(.cfRange, &range)!],
            "editor": [kAXSelectedTextAttribute: "current"]
        ]
        reader.parameterized = ["oldControl": [kAXBoundsForRangeParameterizedAttribute: AXValueCreate(.cgRect, &bounds)!]]
        XCTAssertEqual(resolve(reader), .selected(.init(text: "current", bounds: nil)))
    }

    func testRangeFallbackUsesUTF16AndNeverReturnsTheWholeField() {
        let reader = Reader()
        reader.hit = "editor"
        var range = CFRange(location: 2, length: 2)
        reader.attributes = ["editor": [
            kAXSelectedTextRangeAttribute: AXValueCreate(.cfRange, &range)!,
            kAXValueAttribute: "😀中文 suffix"
        ]]
        XCTAssertEqual(resolve(reader), .selected(.init(text: "中文", bounds: nil)))
        XCTAssertNil(SelectionText.substring("😀text", range: CFRange(location: 1, length: 1)))
        XCTAssertNil(SelectionText.substring("text", range: CFRange(location: Int.max, length: 2)))
        XCTAssertNil(SelectionText.substring("text", range: CFRange(location: 0, length: 0)))
    }

    func testSecureFocusedFieldBlocksStaleWebSelectionAndCopyFallback() {
        let reader = Reader()
        reader.hit = "webArea"
        reader.attributes = [
            "app": [kAXFocusedUIElementAttribute: "password"],
            "password": [kAXSubroleAttribute: kAXSecureTextFieldSubrole],
            "webArea": [kAXSelectedTextAttribute: "stale selection"]
        ]
        XCTAssertEqual(resolve(reader), .blocked)
    }

    func testSelectedDescendantOfHitGroupIsFound() {
        let reader = Reader()
        reader.hit = "group"
        reader.attributes = ["group": [kAXChildrenAttribute: ["editor"]], "editor": [kAXSelectedTextAttribute: "document"]]
        XCTAssertEqual(resolve(reader), .selected(.init(text: "document", bounds: nil)))
    }

    func testCyclesAndUnavailableAttributesTerminate() {
        let reader = Reader()
        reader.hit = "group"
        reader.attributes = ["group": [kAXParentAttribute: "group", kAXChildrenAttribute: ["group"]]]
        XCTAssertEqual(resolve(reader), .unavailable)
        XCTAssertLessThan(reader.reads, 30)
    }

    func testCancelledCaptureDoesNotReadAnyAttributes() {
        let reader = Reader()
        let resolver = SelectionAccessibilityResolver(reader: reader, shouldContinue: { false })
        XCTAssertEqual(resolver.resolve(application: "app", point: .zero), .unavailable)
        XCTAssertEqual(reader.reads, 0)
    }

    func testOversizedAXSelectionDoesNotFallThroughToCopy() {
        let reader = Reader()
        reader.hit = "webArea"
        reader.attributes = ["webArea": [kAXSelectedTextAttribute: String(repeating: "a", count: 20_001)]]
        XCTAssertEqual(resolve(reader), .blocked)
    }

    @MainActor
    func testCopyFallbackRestoresClipboardAndSuppressesHistory() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("original", forType: .string)
        let fallback = SelectionCopyFallback(pasteboard: pasteboard)
        let text = await fallback.capture(isValid: { true }) {
            XCTAssertTrue(fallback.shouldIgnoreClipboardChange(pasteboard.changeCount))
            pasteboard.clearContents()
            pasteboard.setString(" selected text ", forType: .string)
            return true
        }
        XCTAssertEqual(text, "selected text")
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
        XCTAssertFalse(fallback.shouldIgnoreClipboardChange(pasteboard.changeCount + 1))
        XCTAssertTrue(fallback.shouldIgnoreClipboardChange(pasteboard.changeCount))
    }

    @MainActor
    func testCopyThatDoesNotWriteCannotReturnOldClipboardText() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("old unrelated text", forType: .string)
        let fallback = SelectionCopyFallback(pasteboard: pasteboard)
        let text = await fallback.capture(isValid: { true }) { true }
        XCTAssertNil(text)
        XCTAssertEqual(pasteboard.string(forType: .string), "old unrelated text")
        XCTAssertFalse(fallback.shouldIgnoreClipboardChange(pasteboard.changeCount + 1))
    }

    @MainActor
    func testExpiredCaptureNeverInvokesCopy() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let fallback = SelectionCopyFallback(pasteboard: pasteboard)
        let text = await fallback.capture(isValid: { false }) {
            XCTFail("Must not copy after a new interaction or application switch")
            return true
        }
        XCTAssertNil(text)
    }

    @MainActor
    func testCopyFallbackDoesNotConsumeOrRestoreOverConcurrentClipboardWrites() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("original", forType: .string)
        let fallback = SelectionCopyFallback(pasteboard: pasteboard)
        let text = await fallback.capture(isValid: { true }) {
            pasteboard.clearContents()
            pasteboard.setString("selection", forType: .string)
            pasteboard.clearContents()
            pasteboard.setString("newer user copy", forType: .string)
            return true
        }
        XCTAssertNil(text)
        XCTAssertEqual(pasteboard.string(forType: .string), "newer user copy")
        XCTAssertFalse(fallback.shouldIgnoreClipboardChange(pasteboard.changeCount + 1))
    }

    @MainActor
    func testInvalidatedSelectionStillCleansUpItsTemporaryCopy() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("original", forType: .string)
        let fallback = SelectionCopyFallback(pasteboard: pasteboard)
        var isCurrent = true
        let text = await fallback.capture(isValid: { isCurrent }) {
            pasteboard.clearContents()
            pasteboard.setString("temporary selection", forType: .string)
            isCurrent = false
            return true
        }
        XCTAssertNil(text)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
        XCTAssertTrue(fallback.shouldIgnoreClipboardChange(pasteboard.changeCount))
    }

    @MainActor
    func testTaskCancellationStillRestoresTemporaryClipboard() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("original", forType: .string)
        let fallback = SelectionCopyFallback(pasteboard: pasteboard)
        let task = Task {
            await fallback.capture(isValid: { true }) {
                pasteboard.clearContents()
                pasteboard.setString("temporary selection", forType: .string)
                withUnsafeCurrentTask { $0?.cancel() }
                return true
            }
        }
        let text = await task.value
        XCTAssertNil(text)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    @MainActor
    func testUserCopyIntentPreventsRestoreEvenWithOnlyOneClipboardChange() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("original", forType: .string)
        let fallback = SelectionCopyFallback(pasteboard: pasteboard)
        let text = await fallback.capture(isValid: { true }) {
            fallback.noteUserClipboardAction()
            pasteboard.clearContents()
            pasteboard.setString("user copy", forType: .string)
            return true
        }
        XCTAssertNil(text)
        XCTAssertEqual(pasteboard.string(forType: .string), "user copy")
        XCTAssertFalse(fallback.shouldIgnoreClipboardChange(pasteboard.changeCount))
    }

    @MainActor
    func testCopyWaitsForTextWrittenAfterPasteboardOwnershipChanges() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("original", forType: .string)
        let fallback = SelectionCopyFallback(pasteboard: pasteboard)
        let text = await fallback.capture(isValid: { true }) {
            pasteboard.clearContents()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                pasteboard.setString("delayed text", forType: .string)
            }
            return true
        }
        XCTAssertEqual(text, "delayed text")
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    @MainActor
    func testOverlappingSelectionCannotStartASecondCopy() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("original", forType: .string)
        let fallback = SelectionCopyFallback(pasteboard: pasteboard)
        let text = await fallback.capture(isValid: { true }) {
            let nested = await fallback.capture(isValid: { true }) {
                XCTFail("A temporary copy is already in flight")
                return true
            }
            XCTAssertNil(nested)
            pasteboard.clearContents()
            pasteboard.setString("first selection", forType: .string)
            return true
        }
        XCTAssertEqual(text, "first selection")
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testCopyFallbackRequiresEnabledStandardCommandC() {
        let reader = Reader()
        reader.attributes = [
            "app": [kAXMenuBarAttribute: "menuBar"],
            "menuBar": [kAXChildrenAttribute: ["edit"]],
            "edit": [kAXChildrenAttribute: ["menu"]],
            "menu": [kAXChildrenAttribute: ["copy"]],
            "copy": [kAXMenuItemCmdCharAttribute: "C", kAXMenuItemCmdModifiersAttribute: 0, kAXEnabledAttribute: false]
        ]
        XCTAssertNil(SelectionCopyMenu.find(application: "app", reader: reader, shouldContinue: { true }))
        reader.attributes["copy"]?[kAXEnabledAttribute] = true
        XCTAssertEqual(SelectionCopyMenu.find(application: "app", reader: reader, shouldContinue: { true }), "copy")
        reader.attributes["copy"]?[kAXMenuItemCmdModifiersAttribute] = 1
        XCTAssertNil(SelectionCopyMenu.find(application: "app", reader: reader, shouldContinue: { true }))
    }

    func testClipboardRestorationPreservesMultipleItemsAndRepresentations() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let first = NSPasteboardItem()
        first.setString("original", forType: .string)
        let richText = Data("{\\rtf1\\ansi original}".utf8)
        first.setData(richText, forType: .rtf)
        let second = NSPasteboardItem()
        second.setString("file:///tmp/example", forType: .fileURL)
        pasteboard.writeObjects([first, second])
        let snapshot = try XCTUnwrap(SelectionPasteboardSnapshot(pasteboard: pasteboard))
        pasteboard.clearContents()
        pasteboard.setString("selected text", forType: .string)
        XCTAssertEqual(pasteboard.changeCount, snapshot.changeCount + 1)
        XCTAssertTrue(snapshot.restore(to: pasteboard, ifUnchangedSince: pasteboard.changeCount))
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 2)
        XCTAssertEqual(pasteboard.pasteboardItems?.first?.string(forType: .string), "original")
        XCTAssertEqual(pasteboard.pasteboardItems?.first?.data(forType: .rtf), richText)
        XCTAssertEqual(pasteboard.pasteboardItems?.last?.string(forType: .fileURL), "file:///tmp/example")
    }

    func testClipboardRestorationDoesNotOverwriteANewerUserCopy() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("original", forType: .string)
        let snapshot = try XCTUnwrap(SelectionPasteboardSnapshot(pasteboard: pasteboard))
        pasteboard.clearContents()
        pasteboard.setString("selection", forType: .string)
        let copiedChangeCount = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString("user's newer copy", forType: .string)
        XCTAssertFalse(snapshot.restore(to: pasteboard, ifUnchangedSince: copiedChangeCount))
        XCTAssertEqual(pasteboard.string(forType: .string), "user's newer copy")
    }

    func testNewGestureOrStopInvalidatesResultsAlreadyQueuedForDelivery() {
        let state = SelectionCaptureState()
        let first = state.replaceToken()
        let second = state.replaceToken()
        XCTAssertFalse(state.isActive(first))
        state.finish(first)
        XCTAssertTrue(state.isActive(second))
        state.invalidate()
        XCTAssertFalse(state.isActive(second))
    }
}
