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

enum TranslationPanelSizing {
    enum Mode {
        case streaming
        case result
    }

    static let width: CGFloat = 440
    static let maximumHeight: CGFloat = 540

    static func size(
        sourceText: String,
        translatedText: String,
        mode: Mode
    ) -> CGSize {
        let sourceTextHeight = measuredTextHeight(
            sourceText,
            font: .systemFont(ofSize: 12.5),
            lineSpacing: 0
        )
        let sourceBlockHeight = min(max(sourceTextHeight, 15), 30) + 20

        let translationTextHeight = measuredTextHeight(
            translatedText,
            font: roundedTranslationFont,
            lineSpacing: 4
        )
        let supplementalHeight: CGFloat = mode == .streaming ? 21 : 4
        let minimumViewportHeight: CGFloat = mode == .streaming ? 64 : 46
        let viewportHeight = min(
            360,
            max(minimumViewportHeight, translationTextHeight + supplementalHeight)
        )

        let headerAndDividers: CGFloat = 47
        let phaseChrome: CGFloat = mode == .streaming ? 53 : 86
        let minimumPanelHeight: CGFloat = mode == .streaming ? 220 : 230
        let desiredHeight = headerAndDividers
            + sourceBlockHeight
            + phaseChrome
            + viewportHeight

        return CGSize(
            width: width,
            height: min(maximumHeight, max(minimumPanelHeight, ceil(desiredHeight)))
        )
    }

    private static let textWidth: CGFloat = 412

    private static var roundedTranslationFont: NSFont {
        let baseFont = NSFont.systemFont(ofSize: 15.5, weight: .medium)
        let descriptor = baseFont.fontDescriptor.withDesign(.rounded)
            ?? baseFont.fontDescriptor
        return NSFont(descriptor: descriptor, size: 15.5) ?? baseFont
    }

    private static func measuredTextHeight(
        _ text: String,
        font: NSFont,
        lineSpacing: CGFloat
    ) -> CGFloat {
        guard !text.isEmpty else { return 0 }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        let attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .paragraphStyle: paragraphStyle
            ]
        )
        return ceil(
            attributedText.boundingRect(
                with: CGSize(
                    width: textWidth,
                    height: CGFloat.greatestFiniteMagnitude
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height
        )
    }
}
