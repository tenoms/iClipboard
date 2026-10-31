import AppKit
import XCTest
@testable import iClipboard

final class SelectionGestureTests: XCTestCase {
    private func consume(_ tracker: inout SelectionGestureTracker, _ type: NSEvent.EventType,
                         _ point: CGPoint = .zero, clicks: Int = 1, shift: Bool = false) -> CGPoint? {
        tracker.consume(type: type, point: point, clickCount: clicks, shiftPressed: shift)
    }

    func testSingleClickDoesNotStartSelectionCaptureOrCopy() {
        var tracker = SelectionGestureTracker()
        XCTAssertNil(consume(&tracker, .leftMouseDown))
        XCTAssertNil(consume(&tracker, .leftMouseUp))
    }

    func testDragDoubleClickTripleClickAndShiftClickReturnThePressLocation() {
        let origin = CGPoint(x: 10, y: 20)
        for clicks in [1, 2, 3] {
            var tracker = SelectionGestureTracker()
            _ = consume(&tracker, .leftMouseDown, origin, clicks: clicks)
            let end = clicks == 1 ? CGPoint(x: 60, y: 20) : origin
            XCTAssertEqual(consume(&tracker, .leftMouseUp, end, clicks: clicks), origin)
        }
        var tracker = SelectionGestureTracker()
        _ = consume(&tracker, .leftMouseDown, origin, shift: true)
        XCTAssertEqual(consume(&tracker, .leftMouseUp, origin, shift: true), origin)
    }

    func testMissingMouseDownOrInterruptionCancelsTheGesture() {
        var tracker = SelectionGestureTracker()
        XCTAssertNil(consume(&tracker, .leftMouseUp, clicks: 2))
        for interrupt in [NSEvent.EventType.scrollWheel, .keyDown, .rightMouseDown] {
            var tracker = SelectionGestureTracker()
            _ = consume(&tracker, .leftMouseDown)
            _ = consume(&tracker, interrupt, clicks: 0)
            XCTAssertNil(consume(&tracker, .leftMouseUp, CGPoint(x: 50, y: 0)))
        }
    }

    func testOnlyApplicationWindowLayersCanSourceASelection() {
        let dock = Int(CGWindowLevelForKey(.dockWindow))
        let desktop = Int(CGWindowLevelForKey(.desktopIconWindow))
        let menuBar = Int(CGWindowLevelForKey(.mainMenuWindow))
        for (layer, expected) in [(0, true), (3, true), (desktop, false), (dock, false), (menuBar, false)] {
            let window = CaptureDetectionWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                                windowID: 1, ownerPID: 1, layer: layer)
            XCTAssertEqual(SelectionSourceWindow.isSelectable(window), expected, "layer \(layer)")
        }
    }
}
