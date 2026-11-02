import AppKit

enum TranslationPanelPlacement {
    static let screenInset: CGFloat = 12
    static let anchorSpacing: CGFloat = 7

    static func compactFrame(
        anchor: CGRect,
        size: CGSize,
        visibleFrame: CGRect
    ) -> CGRect {
        let visible = visibleFrame.insetBy(dx: screenInset, dy: screenInset)
        var origin = CGPoint(
            x: anchor.maxX + anchorSpacing,
            y: anchor.minY - size.height - anchorSpacing
        )

        if origin.x + size.width > visible.maxX {
            origin.x = anchor.minX - size.width - anchorSpacing
        }
        if origin.y < visible.minY {
            origin.y = anchor.maxY + anchorSpacing
        }

        return constrained(
            CGRect(origin: origin, size: size),
            to: visibleFrame
        )
    }

    static func expandedFrame(
        anchor: CGRect,
        size: CGSize,
        visibleFrame: CGRect
    ) -> CGRect {
        let visible = visibleFrame.insetBy(dx: screenInset, dy: screenInset)
        var origin = CGPoint(
            x: anchor.minX,
            y: anchor.minY - size.height - anchorSpacing
        )

        if origin.y < visible.minY {
            origin.y = anchor.maxY + anchorSpacing
        }
        if origin.x + size.width > visible.maxX {
            origin.x = anchor.maxX - size.width
        }

        return constrained(
            CGRect(origin: origin, size: size),
            to: visibleFrame
        )
    }

    static func pinnedFrame(
        currentFrame: CGRect,
        size: CGSize,
        visibleFrame: CGRect
    ) -> CGRect {
        resizedFrame(
            currentFrame: currentFrame,
            size: size,
            fixedVerticalEdge: .maxYEdge,
            visibleFrame: visibleFrame
        )
    }

    static func resizedFrame(
        currentFrame: CGRect,
        size: CGSize,
        fixedVerticalEdge: CGRectEdge,
        visibleFrame: CGRect
    ) -> CGRect {
        let y = fixedVerticalEdge == .minYEdge
            ? currentFrame.minY
            : currentFrame.maxY - size.height
        return constrained(
            CGRect(
                x: currentFrame.minX,
                y: y,
                width: size.width,
                height: size.height
            ),
            to: visibleFrame
        )
    }

    static func constrained(_ frame: CGRect, to visibleFrame: CGRect) -> CGRect {
        let visible = visibleFrame.insetBy(dx: screenInset, dy: screenInset)
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        let x = min(max(frame.minX, visible.minX), visible.maxX - width)
        let y = min(max(frame.minY, visible.minY), visible.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
