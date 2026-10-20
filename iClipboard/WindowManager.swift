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
    private var presentationSuspensions = Set<UUID>()
    private var suspendedPresentation: SuspendedPresentation?
    private var flashGeneration = UUID()
    private var flashOriginalAlpha: CGFloat?
    var isPresentationAnimating: Bool { presentationAnimator.isAnimating }

    private final class SuspendedPresentation {
        weak var panel: ClipboardPanel?
        let wasVisible: Bool
        let wasHighlighted: Bool
        let wasPanelVisible: Bool
        let wasClosing: Bool
        var wasClosed = false
        var isTerminating = false
        var observers: [NSObjectProtocol] = []

        init(panel: ClipboardPanel?, highlighted: Bool, panelVisible: Bool, closing: Bool) {
            self.panel = panel
            wasVisible = panel?.isVisible == true
            wasHighlighted = highlighted
            wasPanelVisible = panelVisible
            wasClosing = closing
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }
    }
    
    init(registerHotKey: Bool = true,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.reduceMotion = reduceMotion
        guard registerHotKey else { return }
        HotKeyManager.shared.setHandler { [weak self] in
            self?.toggleWindow()
        }
    }
    
    func toggleWindow() {
        guard presentationSuspensions.isEmpty, let panel = panel else { return }
        
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
        guard presentationSuspensions.isEmpty,
              let panel, let statusButton = statusItem?.button else { return }
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
        guard !isPinned else { return }
        if !presentationSuspensions.isEmpty {
            suspendedPresentation?.wasClosed = true
            isClosing = false
            isPanelVisible = false
            return
        }
        guard !isClosing, let panel, panel.isVisible else { return }
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

    @MainActor
    func suspendPresentation() -> @MainActor () -> Void {
        let token = UUID()
        if presentationSuspensions.isEmpty {
            let snapshot = SuspendedPresentation(
                panel: panel,
                highlighted: statusItem?.button?.isHighlighted ?? false,
                panelVisible: isPanelVisible,
                closing: isClosing
            )
            suspendedPresentation = snapshot
            if let panel {
                snapshot.observers.append(NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification, object: panel, queue: .main
                ) { [weak snapshot] _ in snapshot?.wasClosed = true })
            }
            snapshot.observers.append(NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { [weak snapshot] _ in snapshot?.isTerminating = true })

            // No cancel API: a zero-duration close replaces the animation generation,
            // cancels its completion, and orders out without unloading history or unpinning.
            presentationSuspensions.insert(token)
            if let panel {
                presentationAnimator.transition(panel, opening: false, reduceMotion: true)
            }
            flashGeneration = UUID()
            if let originalAlpha = flashOriginalAlpha {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    statusItem?.button?.animator().alphaValue = originalAlpha
                }
                flashOriginalAlpha = nil
            }
            statusItem?.button?.highlight(false)
        } else {
            presentationSuspensions.insert(token)
        }
        return { [weak self] in
            guard let self, self.presentationSuspensions.remove(token) != nil,
                  self.presentationSuspensions.isEmpty,
                  let snapshot = self.suspendedPresentation else { return }
            self.suspendedPresentation = nil
            guard let panel = snapshot.panel, self.panel === panel else { return }
            self.isClosing = false
            guard !snapshot.wasClosed, !snapshot.isTerminating else {
                self.isPanelVisible = false
                self.statusItem?.button?.highlight(false)
                return
            }
            if snapshot.wasClosing, !self.isPinned {
                self.isPanelVisible = false
                self.statusItem?.button?.highlight(false)
                return
            }
            self.isPanelVisible = snapshot.wasPanelVisible
            self.statusItem?.button?.highlight(snapshot.wasHighlighted)
            if snapshot.wasVisible {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    panel.animator().alphaValue = 1
                }
                panel.orderFrontRegardless()
            }
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
        guard presentationSuspensions.isEmpty else { return }
        // If there is an attached sheet (like a preview), don't close.
        if panel?.attachedSheet != nil { return }
        
        if !isPinned {
            closeWindow()
        }
    }
    
    func flashIcon() {
        guard presentationSuspensions.isEmpty, let button = statusItem?.button else { return }

        let originalAlpha = flashOriginalAlpha ?? button.alphaValue
        flashOriginalAlpha = originalAlpha
        let id = UUID()
        flashGeneration = id
        let flashDuration = 0.15

        NSAnimationContext.runAnimationGroup { context in
            context.duration = flashDuration
            button.animator().alphaValue = 0.3
        } completionHandler: { [weak self] in
            guard let self, self.flashGeneration == id,
                  self.presentationSuspensions.isEmpty else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = flashDuration
                button.animator().alphaValue = originalAlpha
            } completionHandler: { [weak self] in
                guard let self, self.flashGeneration == id,
                      self.presentationSuspensions.isEmpty else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = flashDuration
                    button.animator().alphaValue = 0.3
                } completionHandler: { [weak self] in
                    guard let self, self.flashGeneration == id,
                          self.presentationSuspensions.isEmpty else { return }
                    self.flashOriginalAlpha = nil
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = flashDuration
                        button.animator().alphaValue = originalAlpha
                    }
                }
            }
        }
    }
}
