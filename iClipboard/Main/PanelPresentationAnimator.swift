import AppKit
import QuartzCore

/// AppKit animates only window opacity; content and window geometry stay untouched.
final class PanelPresentationAnimator {
    private var generation = UUID()
    private(set) var isAnimating = false

    func transition(
        _ panel: NSWindow,
        opening: Bool,
        reduceMotion: Bool,
        completion: @escaping () -> Void = {}
    ) {
        precondition(Thread.isMainThread)
        let id = UUID()
        generation = id
        let target: CGFloat = opening ? 1 : 0

        if opening {
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.makeKeyAndOrderFront(nil)
        }

        // Reversals start at AppKit's current opacity and take only the remaining time.
        let duration = reduceMotion ? 0 : (opening ? 0.12 : 0.08) * Double(abs(target - panel.alphaValue))
        isAnimating = duration > 0
        let finish = { [weak self, weak panel] in
            // AppKit also completes replaced animations; only the latest may change visibility.
            guard let self, let panel, self.generation == id else { return }
            self.isAnimating = false
            if !opening {
                // Keep the window transparent through ordering out and content teardown.
                // Restoring opacity here can expose a final frame during compositing.
                panel.alphaValue = 0
                panel.orderOut(nil)
            }
            completion()
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = target
        } completionHandler: {
            if duration > 0 { finish() }
        }
        // A zero-duration proxy assignment also stops any fade that was in progress.
        if duration == 0 { finish() }
    }
}
