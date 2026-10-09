import AppKit
import Combine

class WindowManager: ObservableObject {
    static let shared = WindowManager()

    @Published var isPinned: Bool = false {
        didSet {
            if isPinned && isClosing { openWindow() }
        }
    }
    @Published private(set) var isPanelVisible = false
    
    var panel: ClipboardPanel?
    var statusItem: NSStatusItem?

    private var isClosing = false
    private let presentationAnimator = PanelPresentationAnimator()
    private let reduceMotion: () -> Bool
    var isPresentationAnimating: Bool { presentationAnimator.isAnimating }
    
    init(registerHotKey: Bool = true,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.reduceMotion = reduceMotion
        guard registerHotKey else { return }
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
        guard let panel, let statusButton = statusItem?.button else { return }
        let source = sourceRect(for: statusButton, fallback: panel.frame)
        let targetFrame = anchoredFrame(for: panel, statusButton: statusButton, sourceRect: source)
        isClosing = false
        isPanelVisible = true
        statusButton.highlight(true)
        panel.setFrame(targetFrame, display: false)

        presentationAnimator.transition(
            panel, opening: true, reduceMotion: reduceMotion()
        )
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeWindow() {
        guard !isPinned, !isClosing, let panel, panel.isVisible else { return }
        isClosing = true
        statusItem?.button?.highlight(false)
        presentationAnimator.transition(
            panel, opening: false, reduceMotion: reduceMotion()
        ) { [weak self] in
            guard let self, self.isClosing else { return }
            self.isClosing = false
            // Unload history and previews only after the last visible animation frame.
            self.isPanelVisible = false
        }
    }

    private func sourceRect(for button: NSStatusBarButton, fallback: NSRect) -> NSRect {
        guard let window = button.window else { return fallback }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func anchoredFrame(
        for panel: ClipboardPanel, statusButton: NSStatusBarButton, sourceRect: NSRect
    ) -> CGRect {
        guard let screen = statusButton.window?.screen else { return panel.frame }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let margin: CGFloat = 10
        let x = min(max(visible.minX + margin, sourceRect.midX - size.width / 2),
                    max(visible.minX + margin, visible.maxX - size.width - margin))
        let top = visible.maxY
        let scale = screen.backingScaleFactor
        return CGRect(x: (x * scale).rounded() / scale,
                      y: ((top - size.height) * scale).rounded() / scale,
                      width: size.width, height: size.height)
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
