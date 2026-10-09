import CoreGraphics
import XCTest
@testable import iClipboard

final class TranslationPanelPlacementTests: XCTestCase {
    private let visibleFrame = CGRect(x: 0, y: 0, width: 1_440, height: 900)

    func testCompactFrameStaysInsideVisibleScreenAtBottomRight() {
        let frame = TranslationPanelPlacement.compactFrame(
            anchor: CGRect(x: 1_420, y: 5, width: 10, height: 14),
            size: CGSize(width: 38, height: 38),
            visibleFrame: visibleFrame
        )

        XCTAssertGreaterThanOrEqual(frame.minX, 12)
        XCTAssertGreaterThanOrEqual(frame.minY, 12)
        XCTAssertLessThanOrEqual(frame.maxX, 1_428)
        XCTAssertLessThanOrEqual(frame.maxY, 888)
    }

    func testExpandedFramePrefersBelowSelectionWhenSpaceExists() {
        let anchor = CGRect(x: 300, y: 600, width: 100, height: 20)
        let frame = TranslationPanelPlacement.expandedFrame(
            anchor: anchor,
            size: CGSize(width: 440, height: 280),
            visibleFrame: visibleFrame
        )

        XCTAssertLessThan(frame.maxY, anchor.minY)
    }

    func testExpandedFrameMovesAboveSelectionNearBottomEdge() {
        let anchor = CGRect(x: 300, y: 20, width: 100, height: 20)
        let frame = TranslationPanelPlacement.expandedFrame(
            anchor: anchor,
            size: CGSize(width: 440, height: 280),
            visibleFrame: visibleFrame
        )

        XCTAssertGreaterThan(frame.minY, anchor.maxY)
    }

    func testPinnedResizePreservesTopEdge() {
        let current = CGRect(x: 220, y: 400, width: 440, height: 200)
        let frame = TranslationPanelPlacement.pinnedFrame(
            currentFrame: current,
            size: CGSize(width: 440, height: 320),
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(frame.maxY, current.maxY, accuracy: 0.001)
        XCTAssertEqual(frame.minX, current.minX, accuracy: 0.001)
    }

    func testVisiblePanelResizeCanPreserveBottomEdge() {
        let current = CGRect(x: 220, y: 120, width: 440, height: 220)
        let frame = TranslationPanelPlacement.resizedFrame(
            currentFrame: current,
            size: CGSize(width: 440, height: 420),
            fixedVerticalEdge: .minYEdge,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(frame.minY, current.minY, accuracy: 0.001)
        XCTAssertEqual(frame.minX, current.minX, accuracy: 0.001)
    }

    func testShortTranslationProducesCompactPanel() {
        let size = TranslationPanelSizing.size(
            sourceText: "Hello",
            translatedText: "你好",
            mode: .result
        )

        XCTAssertLessThanOrEqual(size.height, 250)
    }

    func testLongTranslationExpandsViewportBeforeScrolling() {
        let shortSize = TranslationPanelSizing.size(
            sourceText: "Hello",
            translatedText: "简短译文",
            mode: .result
        )
        let longSize = TranslationPanelSizing.size(
            sourceText: "Hello",
            translatedText: String(repeating: "这是一段用于验证长译文视口扩展的文字。", count: 80),
            mode: .result
        )

        XCTAssertGreaterThan(longSize.height, shortSize.height + 200)
        XCTAssertLessThanOrEqual(longSize.height, TranslationPanelSizing.maximumHeight)
    }
}
