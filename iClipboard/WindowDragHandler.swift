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
        
        // Either mouseDownCanMoveWindow = true (if the view is the content view's background)
        // or we manually call performDrag
        
        override func mouseDown(with event: NSEvent) {
            // Initiate window dragging
            window?.performDrag(with: event)
        }
    }
}
