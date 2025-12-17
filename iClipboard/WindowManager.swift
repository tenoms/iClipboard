import SwiftUI
import AppKit
import Combine

class WindowManager: ObservableObject {
    static let shared = WindowManager()
    
    @Published var isPinned: Bool = false
    
    var panel: ClipboardPanel?
    var statusItem: NSStatusItem?
    
    private init() {}
    
    func toggleWindow() {
        guard let panel = panel else { return }
        
        if panel.isVisible {
            if !isPinned {
                closeWindow()
            } else {
                // If pinned, we might just want to activate it if it wasn't key
                panel.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        } else {
            openWindow()
        }
    }
    
    func openWindow() {
        guard let panel = panel, let statusButton = statusItem?.button else { return }
        
        // Position relative to status item
        if let screen = statusButton.window?.screen {
            let buttonFrame = statusButton.window?.frame ?? .zero
            let panelSize = panel.frame.size
            
            // Calculate x position (centered under icon, but constrained to screen)
            var x = buttonFrame.midX - (panelSize.width / 2)
            
            // Constrain left
            if x < screen.visibleFrame.minX + 10 {
                x = screen.visibleFrame.minX + 10
            }
            // Constrain right
            if x + panelSize.width > screen.visibleFrame.maxX - 10 {
                x = screen.visibleFrame.maxX - panelSize.width - 10
            }
            
            // Calculate y position (below menu bar)
            let y = screen.visibleFrame.maxY - panelSize.height
            
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func closeWindow() {
        guard !isPinned else { return }
        panel?.orderOut(nil)
    }
    
    // Called when the application resigns active or window loses focus
    func handleFocusLoss() {
        if !isPinned {
            closeWindow()
        }
    }
}
