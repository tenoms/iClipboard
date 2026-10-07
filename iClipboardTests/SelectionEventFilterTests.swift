import CoreGraphics
import XCTest

final class SelectionEventFilterTests: XCTestCase {
    func testMouseSelectionIsCaptured() {
        XCTAssertTrue(SelectionEventFilter.shouldCapture(type: .leftMouseUp))
    }

    func testKeyboardEventsAreIgnored() {
        XCTAssertFalse(SelectionEventFilter.shouldCapture(type: .keyUp))
        XCTAssertFalse(SelectionEventFilter.shouldCapture(type: .keyDown))
    }

    func testOtherMouseEventsAreIgnored() {
        XCTAssertFalse(SelectionEventFilter.shouldCapture(type: .rightMouseUp))
        XCTAssertFalse(SelectionEventFilter.shouldCapture(type: .leftMouseDown))
    }
}
