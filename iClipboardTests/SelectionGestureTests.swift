import AppKit
import XCTest
@testable import iClipboard

final class SelectionGestureTests: XCTestCase {
    func testSingleClickDoesNotStartSelectionCaptureOrCopy() {
        var tracker = SelectionGestureTracker()
        XCTAssertFalse(tracker.consume(type: .leftMouseDown, point: .zero, clickCount: 1, shiftPressed: false, processIdentifier: 1))
        XCTAssertFalse(tracker.consume(type: .leftMouseUp, point: .zero, clickCount: 1, shiftPressed: false, processIdentifier: 1))
    }

    func testDragDoubleClickTripleClickAndShiftClickCapture() {
        for clicks in [1, 2, 3] {
            var tracker = SelectionGestureTracker()
            _ = tracker.consume(type: .leftMouseDown, point: .zero, clickCount: clicks, shiftPressed: false, processIdentifier: 1)
            let end = clicks == 1 ? CGPoint(x: 40, y: 0) : .zero
            XCTAssertTrue(tracker.consume(type: .leftMouseUp, point: end, clickCount: clicks, shiftPressed: false, processIdentifier: 1))
        }
        var tracker = SelectionGestureTracker()
        _ = tracker.consume(type: .leftMouseDown, point: .zero, clickCount: 1, shiftPressed: true, processIdentifier: 1)
        XCTAssertTrue(tracker.consume(type: .leftMouseUp, point: .zero, clickCount: 1, shiftPressed: true, processIdentifier: 1))
    }

    func testAppSwitchOrMissingMouseDownDoesNotCapture() {
        var tracker = SelectionGestureTracker()
        XCTAssertFalse(tracker.consume(type: .leftMouseUp, point: .zero, clickCount: 2, shiftPressed: false, processIdentifier: 1))
        _ = tracker.consume(type: .leftMouseDown, point: .zero, clickCount: 1, shiftPressed: false, processIdentifier: 1)
        XCTAssertFalse(tracker.consume(type: .leftMouseUp, point: CGPoint(x: 50, y: 0), clickCount: 1, shiftPressed: false, processIdentifier: 2))
    }

    func testActivationDuringFirstDragPreservesTheGesture() {
        var tracker = SelectionGestureTracker()
        _ = tracker.consume(type: .leftMouseDown, point: .zero, clickCount: 1, shiftPressed: false, processIdentifier: 1)
        tracker.applicationDidActivate(1)
        XCTAssertTrue(tracker.consume(type: .leftMouseUp, point: CGPoint(x: 50, y: 0), clickCount: 1, shiftPressed: false, processIdentifier: 1))
    }

    func testScrollKeyboardAndAppChangesCancelTheGesture() {
        for interrupt in [NSEvent.EventType.scrollWheel, .keyDown, .rightMouseDown] {
            var tracker = SelectionGestureTracker()
            _ = tracker.consume(type: .leftMouseDown, point: .zero, clickCount: 1, shiftPressed: false, processIdentifier: 1)
            _ = tracker.consume(type: interrupt, point: .zero, clickCount: 0, shiftPressed: false, processIdentifier: 1)
            XCTAssertFalse(tracker.consume(type: .leftMouseUp, point: CGPoint(x: 50, y: 0), clickCount: 1, shiftPressed: false, processIdentifier: 1))
        }
        var tracker = SelectionGestureTracker()
        _ = tracker.consume(type: .leftMouseDown, point: .zero, clickCount: 1, shiftPressed: false, processIdentifier: 1)
        tracker.applicationDidActivate(2)
        tracker.applicationDidActivate(1)
        XCTAssertFalse(tracker.consume(type: .leftMouseUp, point: CGPoint(x: 50, y: 0), clickCount: 1, shiftPressed: false, processIdentifier: 1))
    }
}
