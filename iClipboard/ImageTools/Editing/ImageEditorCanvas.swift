import AppKit
import SwiftUI

/// SwiftUI owns the editing state. AppKit bridges only precise pixel pointer input,
/// a scrollable zoomed canvas, and native first-responder keyboard handling.
struct ImageEditorCanvas: NSViewRepresentable {
    @ObservedObject var session: ImageEditorSession
    @Environment(\.appPalette) private var palette

    func makeNSView(context: Context) -> ImageEditorScrollView {
        let scrollView = ImageEditorScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        let canvas = ImageEditorCanvasView(session: session)
        scrollView.documentView = canvas
        scrollView.canvas = canvas
        updateNSView(scrollView, context: context)
        return scrollView
    }

    func updateNSView(_ scrollView: ImageEditorScrollView, context: Context) {
        guard let canvas = scrollView.canvas else { return }
        canvas.backgroundColor = NSColor(palette.control)
        canvas.selectionColor = NSColor(palette.accent)
        canvas.checkerLight = NSColor(palette.panel)
        canvas.checkerDark = NSColor(palette.controlHover)
        scrollView.updateCanvasLayout()
        canvas.needsDisplay = true
        canvas.window?.invalidateCursorRects(for: canvas)
    }
}

final class ImageEditorScrollView: NSScrollView {
    weak var canvas: ImageEditorCanvasView?

    override func layout() {
        super.layout()
        updateCanvasLayout()
    }

    func updateCanvasLayout() {
        guard let canvas else { return }
        let transform = ImageCanvasTransform(pixelSize: canvas.session.document.original.pixelSize,
                                             viewportSize: contentView.bounds.size, zoom: canvas.session.zoom)
        canvas.transform = transform
        if canvas.frame.size != transform.contentSize {
            canvas.setFrameSize(transform.contentSize)
        }
        canvas.needsDisplay = true
    }
}

final class ImageEditorCanvasView: NSView {
    let session: ImageEditorSession
    var transform = ImageCanvasTransform(pixelSize: CGSize(width: 1, height: 1), viewportSize: .zero)
    var backgroundColor = NSColor.windowBackgroundColor
    var selectionColor = NSColor.controlAccentColor
    var checkerLight = NSColor.windowBackgroundColor
    var checkerDark = NSColor.controlBackgroundColor

    init(session: ImageEditorSession) {
        self.session = session
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("图片编辑画布")
        setAccessibilityHelp("使用工具栏选择工具，在图片上拖动绘制。选择模式中 Delete 删除，方向键移动，Escape 取消操作。")
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        dirtyRect.fill()
        let imageRect = transform.imageRect
        guard dirtyRect.intersects(imageRect) else { return }
        NSGraphicsContext.saveGraphicsState()
        imageRect.clip()
        checkerLight.setFill()
        imageRect.fill()
        // Screen-sized checkerboard makes transparent source pixels visible at any zoom.
        let visible = dirtyRect.intersection(imageRect)
        let cell: CGFloat = 10
        let firstX = Int(floor((visible.minX - imageRect.minX) / cell))
        let firstY = Int(floor((visible.minY - imageRect.minY) / cell))
        let lastX = Int(ceil((visible.maxX - imageRect.minX) / cell))
        let lastY = Int(ceil((visible.maxY - imageRect.minY) / cell))
        checkerDark.setFill()
        for y in firstY..<lastY {
            for x in firstX..<lastX where (x + y).isMultiple(of: 2) {
                CGRect(x: imageRect.minX + CGFloat(x) * cell, y: imageRect.minY + CGFloat(y) * cell,
                       width: cell, height: cell).fill()
            }
        }
        let image = NSImage(cgImage: session.displayImage, size: session.document.original.pixelSize)
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                   hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
        if let bounds = session.selectionBounds {
            strokeSelection(transform.viewRect(fromPixel: bounds))
        }
    }

    private func strokeSelection(_ rect: CGRect) {
        let path = NSBezierPath(rect: rect.insetBy(dx: -2, dy: -2))
        path.lineWidth = 1
        path.setLineDash([4, 3], count: 2, phase: 0)
        selectionColor.setStroke()
        path.stroke()
    }

    override func resetCursorRects() {
        addCursorRect(transform.imageRect, cursor: session.tool == .select ? .arrow : .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        guard session.isInputEnabled else { return }
        window?.makeFirstResponder(self)
        guard let point = transform.pixelPoint(fromView: convert(event.locationInWindow, from: nil)) else {
            session.document.selectedID = nil
            needsDisplay = true
            return
        }
        session.pointerDown(at: point, tolerance: 6 / transform.scale, clickCount: event.clickCount)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let point = transform.pixelPoint(fromView: convert(event.locationInWindow, from: nil), clamped: true) else { return }
        session.pointerDragged(to: point)
        autoscroll(with: event)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let point = transform.pixelPoint(fromView: convert(event.locationInWindow, from: nil), clamped: true) else { return }
        session.pointerUp(at: point)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard session.isInputEnabled else { return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
            if event.modifierFlags.contains(.shift) { session.redo() } else { session.undo() }
        } else if event.keyCode == 51 || event.keyCode == 117 {
            session.deleteSelection()
        } else if event.keyCode == 53 {
            session.cancelGesture()
            session.document.selectedID = nil
        } else if (123...126).contains(event.keyCode), session.document.selectedAnnotation != nil {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let desired = CGSize(width: event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0,
                                 height: event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0)
            session.moveSelection(by: desired)
        } else {
            super.keyDown(with: event)
        }
        needsDisplay = true
    }
}
