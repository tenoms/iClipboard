import SwiftUI
import AppKit

extension View {
    func windowDraggable() -> some View {
        self.background(WindowDragHandler())
    }

    func dragCursorIgnored() -> some View {
        self.background(ResetCursorHandler())
    }
}

private struct WindowDragHandler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = DragView()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

private struct ResetCursorHandler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return ResetCursorView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private class ResetCursorView: NSView {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .arrow)
        }
    }
}
