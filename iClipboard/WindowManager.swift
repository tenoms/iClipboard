import SwiftUI
import AppKit
import Combine

class WindowManager: ObservableObject {
    static let shared = WindowManager()
    
    @Published var isPinned: Bool = false
    
    var panel: ClipboardPanel?
    var statusItem: NSStatusItem?
    
    private init() {
        HotKeyManager.shared.setHandler { [weak self] in
            DispatchQueue.main.async {
                self?.toggleWindow()
            }
        }
    }
    
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
        // If there is an attached sheet (like a preview), don't close.
        // Xcode: CGSWindowShmemCreateWithPort failed on port 0
        if panel?.attachedSheet != nil { return }
        
        if !isPinned {
            closeWindow()
        }
    }
    
    func flashIcon() {
        guard let button = statusItem?.button else { return }
        
        let originalAlpha = button.alphaValue
        let flashDuration = 0.15
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = flashDuration
            button.animator().alphaValue = 0.3
        } completionHandler: {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = flashDuration
                button.animator().alphaValue = originalAlpha
            } completionHandler: {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = flashDuration
                    button.animator().alphaValue = 0.3
                } completionHandler: {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = flashDuration
                        button.animator().alphaValue = originalAlpha
                    }
                }
            }
        }
    }
}
