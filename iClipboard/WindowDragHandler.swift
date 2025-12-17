import SwiftUI
import AppKit

struct WindowDragHandler: NSViewRepresentable {
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

struct ResetCursorHandler: NSViewRepresentable {
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

extension View {
    func dragCursorIgnored() -> some View {
        self.background(ResetCursorHandler())
    }
}
