import AppKit

/// A mouse-transparent sibling of the capture workspace in its existing panel.
/// Source pixels are top-down; pointer and bounds use the superview's local,
/// bottom-up AppKit coordinates. This view never edits or retains a rendered copy.
@MainActor
final class CapturePixelHUD: NSView {
    private(set) var sampledColor: SampledImageColor?

    private static let cardSize = CGSize(width: 190, height: 184)
    private static let lens = CGRect(x: 41, y: 64, width: 108, height: 108)
    private var source: ToolImage?
    private var pixel: CGPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(image: ToolImage, pixel: CGPoint, pointer: CGPoint, in bounds: CGRect) {
        // ToolImage.color converts through sRGB, including unpremultiplication.
        // Use exactly that sampler, rather than interpreting the source's bytes.
        guard pixel.x.isFinite, pixel.y.isFinite,
              pointer.x.isFinite, pointer.y.isFinite,
              bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0,
              pixel.x >= 0, pixel.y >= 0,
              pixel.x < image.pixelSize.width, pixel.y < image.pixelSize.height,
              let color = image.color(at: pixel) else {
            hide()
            return
        }
        source = image
        self.pixel = CGPoint(x: floor(pixel.x), y: floor(pixel.y))
        sampledColor = color

        let scale = min(1, bounds.width / Self.cardSize.width, bounds.height / Self.cardSize.height)
        let size = CGSize(width: Self.cardSize.width * scale, height: Self.cardSize.height * scale)
        let marginX = min(8, max(0, (bounds.width - size.width) / 2))
        let marginY = min(8, max(0, (bounds.height - size.height) / 2))
        frame = CGRect(x: max(bounds.minX + marginX,
                              min(pointer.x + 22, bounds.maxX - size.width - marginX)),
                       y: max(bounds.minY + marginY,
                              min(pointer.y - 190, bounds.maxY - size.height - marginY)),
                       width: size.width, height: size.height)
        isHidden = false
        needsDisplay = true
    }

    func hide() {
        isHidden = true
        source = nil
        pixel = nil
        sampledColor = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !isHidden, let source, let pixel, let color = sampledColor,
              let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.scaleBy(x: bounds.width / Self.cardSize.width, y: bounds.height / Self.cardSize.height)
        let card = CGRect(origin: .zero, size: Self.cardSize)
        NSColor.windowBackgroundColor.withAlphaComponent(0.97).setFill()
        let outline = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        outline.fill()
        NSColor.separatorColor.setStroke()
        outline.lineWidth = 0.5
        outline.stroke()

        drawMagnifier(image: source.cgImage, pixel: pixel, context: context)
        drawText(color.hex, at: CGPoint(x: 12, y: 38),
                 font: .monospacedSystemFont(ofSize: 14, weight: .semibold))
        drawText(color.rgb, at: CGPoint(x: 12, y: 16),
                 font: .monospacedSystemFont(ofSize: 11, weight: .regular))
        drawText("α \(Int((color.alpha * 100).rounded()))%", at: CGPoint(x: 108, y: 42),
                 font: .monospacedSystemFont(ofSize: 10, weight: .regular))

        let swatch = CGRect(x: 160, y: 35, width: 18, height: 18)
        context.saveGState()
        NSBezierPath(roundedRect: swatch, xRadius: 4, yRadius: 4).addClip()
        drawCheckerboard(in: swatch)
        NSColor(srgbRed: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255,
                blue: CGFloat(color.blue) / 255, alpha: color.alpha).setFill()
        swatch.fill()
        context.restoreGState()
    }

    /// The old overlay's 9×9 -> 108-point lens, now shared by every capture intent.
    /// Cropping and destination offsets keep the sampled pixel in the center even
    /// at a source edge; missing/transparent pixels expose a checkerboard, not black.
    private func drawMagnifier(image: CGImage, pixel: CGPoint, context: CGContext) {
        let lens = Self.lens
        drawCheckerboard(in: lens)
        let pixels = CGRect(x: pixel.x - 4, y: pixel.y - 4, width: 9, height: 9)
        let cropRect = pixels.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        if !cropRect.isEmpty, let crop = image.cropping(to: cropRect) {
            let destination = CGRect(x: lens.minX + (cropRect.minX - pixels.minX) * 12,
                                     y: lens.minY + (pixels.maxY - cropRect.maxY) * 12,
                                     width: cropRect.width * 12, height: cropRect.height * 12)
            context.interpolationQuality = .none
            context.draw(crop, in: destination)
        }
        NSColor.controlAccentColor.setStroke()
        let center = NSBezierPath(rect: CGRect(x: lens.midX - 6, y: lens.midY - 6, width: 12, height: 12))
        center.lineWidth = 2
        center.stroke()
    }

    private func drawCheckerboard(in rect: CGRect) {
        NSColor(srgbRed: 0.90, green: 0.90, blue: 0.90, alpha: 1).setFill()
        rect.fill()
        NSColor(srgbRed: 0.68, green: 0.68, blue: 0.68, alpha: 1).setFill()
        let cell: CGFloat = 6
        for y in 0..<Int(ceil(rect.height / cell)) {
            for x in 0..<Int(ceil(rect.width / cell)) where (x + y).isMultiple(of: 2) {
                CGRect(x: rect.minX + CGFloat(x) * cell, y: rect.minY + CGFloat(y) * cell,
                       width: min(cell, rect.width - CGFloat(x) * cell),
                       height: min(cell, rect.height - CGFloat(y) * cell)).fill()
            }
        }
    }

    private func drawText(_ text: String, at point: CGPoint, font: NSFont) {
        (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: NSColor.labelColor])
    }
}
