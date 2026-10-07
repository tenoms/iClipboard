import AppKit
import XCTest

final class SelectionEventFilterTests: XCTestCase {
    func testMouseSelectionIsCaptured() {
        XCTAssertTrue(
            SelectionEventFilter.shouldCapture(
                type: .leftMouseUp,
                isInsideOwnedSurface: false
            )
        )
    }

    func testMouseUpInsideTranslationSurfaceIsIgnored() {
        XCTAssertFalse(
            SelectionEventFilter.shouldCapture(
                type: .leftMouseUp,
                isInsideOwnedSurface: true
            )
        )
    }

    func testKeyboardEventsAreIgnored() {
        XCTAssertFalse(
            SelectionEventFilter.shouldCapture(
                type: .keyUp,
                isInsideOwnedSurface: false
            )
        )
        XCTAssertFalse(
            SelectionEventFilter.shouldCapture(
                type: .keyDown,
                isInsideOwnedSurface: false
            )
        )
    }

    func testOtherMouseEventsAreIgnored() {
        XCTAssertFalse(
            SelectionEventFilter.shouldCapture(
                type: .rightMouseUp,
                isInsideOwnedSurface: false
            )
        )
        XCTAssertFalse(
            SelectionEventFilter.shouldCapture(
                type: .leftMouseDown,
                isInsideOwnedSurface: false
            )
        )
    }
}
