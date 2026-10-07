import SwiftUI
import AppKit
import Combine

class WindowManager: ObservableObject {
    static let shared = WindowManager()
    
    @Published var isPinned: Bool = false
    
    var panel: ClipboardPanel?
    var statusItem: NSStatusItem?

    private var panelAnimationID = UUID()
    private var isClosing = false
    
    private init() {
        HotKeyManager.shared.setHandler { [weak self] in
            DispatchQueue.main.async {
                self?.toggleWindow()
            }
        }
    }
    
    func toggleWindow() {
        guard let panel = panel else { return }
        
        if isClosing {
            openWindow()
        } else if panel.isVisible {
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

        let targetFrame = anchoredFrame(for: panel, statusButton: statusButton)
        let animationID = UUID()
        panelAnimationID = animationID
        let wasClosing = isClosing
        isClosing = false

        if !wasClosing {
            panel.alphaValue = 0
            panel.setFrame(targetFrame.offsetBy(dx: 0, dy: 10), display: false)
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.setFrame(targetFrame, display: true)
            panel.alphaValue = 1
            panel.invalidateShadow()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(targetFrame, display: true)
            panel.animator().alphaValue = 1
        } completionHandler: { [weak self, weak panel] in
            guard let self,
                  let panel,
                  self.panelAnimationID == animationID,
                  !self.isClosing else {
                return
            }
            panel.setFrame(targetFrame, display: true)
            panel.alphaValue = 1
            panel.invalidateShadow()
        }
    }
    
    func closeWindow() {
        guard !isPinned,
              !isClosing,
              let panel,
              panel.isVisible else {
            return
        }

        let animationID = UUID()
        panelAnimationID = animationID
        isClosing = true
        let originalFrame = panel.frame

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            finishClosing(
                panel,
                originalFrame: originalFrame,
                animationID: animationID
            )
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(
                originalFrame.offsetBy(dx: 0, dy: 8),
                display: true
            )
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.finishClosing(
                panel,
                originalFrame: originalFrame,
                animationID: animationID
            )
        }
    }

    private func anchoredFrame(
        for panel: ClipboardPanel,
        statusButton: NSStatusBarButton
    ) -> CGRect {
        guard let screen = statusButton.window?.screen else {
            return panel.frame
        }

        let buttonFrame = statusButton.window?.frame ?? .zero
        let panelSize = panel.frame.size
        let visibleFrame = screen.visibleFrame
        var x = buttonFrame.midX - panelSize.width / 2
        x = max(visibleFrame.minX + 10, x)
        x = min(visibleFrame.maxX - panelSize.width - 10, x)

        return CGRect(
            x: x,
            y: visibleFrame.maxY - panelSize.height,
            width: panelSize.width,
            height: panelSize.height
        )
    }

    private func finishClosing(
        _ panel: ClipboardPanel,
        originalFrame: CGRect,
        animationID: UUID
    ) {
        guard panelAnimationID == animationID, isClosing else { return }
        panel.orderOut(nil)
        panel.setFrame(originalFrame, display: false)
        panel.alphaValue = 1
        panel.invalidateShadow()
        isClosing = false
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
