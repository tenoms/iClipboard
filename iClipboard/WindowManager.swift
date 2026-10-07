import AppKit
import Combine
import QuartzCore
import SwiftUI

class WindowManager: ObservableObject {
    static let shared = WindowManager()

    private enum PanelMotion {
        static let openDuration: TimeInterval = 0.22
        static let closeDuration: TimeInterval = 0.14
        static let verticalTravel: CGFloat = 8
        static let compactScale: CGFloat = 0.985
        static let scaleAnimationKey = "iClipboard.panel.presentation-scale"

        static var openTiming: CAMediaTimingFunction {
            CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        }

        static var closeTiming: CAMediaTimingFunction {
            CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
        }
    }
    
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
            panel.setFrame(
                targetFrame.offsetBy(dx: 0, dy: PanelMotion.verticalTravel),
                display: false
            )
        }
        animateContentScale(
            of: panel,
            from: wasClosing ? nil : PanelMotion.compactScale,
            to: 1,
            duration: PanelMotion.openDuration,
            timingFunction: PanelMotion.openTiming,
            holdsFinalState: false
        )
        panel.makeKeyAndOrderFront(nil)
        statusButton.highlight(true)
        NSApp.activate(ignoringOtherApps: true)

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            resetContentScale(of: panel)
            panel.setFrame(targetFrame, display: true)
            panel.alphaValue = 1
            panel.invalidateShadow()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = PanelMotion.openDuration
            context.timingFunction = PanelMotion.openTiming
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
        let currentFrame = panel.frame

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            resetContentScale(of: panel)
            finishClosing(panel, animationID: animationID)
            return
        }

        animateContentScale(
            of: panel,
            from: nil,
            to: PanelMotion.compactScale,
            duration: PanelMotion.closeDuration,
            timingFunction: PanelMotion.closeTiming,
            holdsFinalState: true
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = PanelMotion.closeDuration
            context.timingFunction = PanelMotion.closeTiming
            panel.animator().setFrame(
                currentFrame.offsetBy(dx: 0, dy: PanelMotion.verticalTravel),
                display: true
            )
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.finishClosing(panel, animationID: animationID)
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
        animationID: UUID
    ) {
        guard panelAnimationID == animationID, isClosing else { return }
        statusItem?.button?.highlight(false)
        panel.orderOut(nil)
        isClosing = false
    }

    private func animateContentScale(
        of panel: ClipboardPanel,
        from requestedStartScale: CGFloat?,
        to targetScale: CGFloat,
        duration: TimeInterval,
        timingFunction: CAMediaTimingFunction,
        holdsFinalState: Bool
    ) {
        guard let contentView = panel.contentView else { return }
        contentView.wantsLayer = true
        guard let layer = contentView.layer else { return }

        let startScale = requestedStartScale ?? displayedScale(of: layer)
        layer.removeAnimation(forKey: PanelMotion.scaleAnimationKey)
        layer.transform = CATransform3DIdentity

        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = startScale
        animation.toValue = targetScale
        animation.duration = duration
        animation.timingFunction = timingFunction
        if holdsFinalState {
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
        }
        layer.add(animation, forKey: PanelMotion.scaleAnimationKey)
    }

    private func displayedScale(of layer: CALayer) -> CGFloat {
        let transform = layer.presentation()?.transform ?? layer.transform
        return hypot(transform.m11, transform.m12)
    }

    private func resetContentScale(of panel: ClipboardPanel) {
        guard let layer = panel.contentView?.layer else { return }
        layer.removeAnimation(forKey: PanelMotion.scaleAnimationKey)
        layer.transform = CATransform3DIdentity
    }

    // Called when the application resigns active or window loses focus
    func handleFocusLoss() {
        // If there is an attached sheet (like a preview), don't close.
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
