import AppKit
import OSLog
import SwiftUI

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
final class TranslationPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 188),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        becomesKeyOnlyIfNeeded = true
        minSize = CGSize(width: 420, height: 138)
        maxSize = CGSize(width: 720, height: 560)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class TranslationTriggerPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 38, height: 38),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class TranslationPanelController: NSObject, NSWindowDelegate {
    static let shared = TranslationPanelController()

    let viewModel = TranslationBubbleViewModel()
    var onDismiss: (() -> Void)?
    var isPinned: Bool { viewModel.isPinned }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.tenom.iClipboard",
        category: "TranslationPanel"
    )

    private let panel = TranslationPanel()
    private let triggerPanel = TranslationTriggerPanel()
    private lazy var panelHostingView: FirstMouseHostingView<TranslationBubbleView> = {
        let hostingView = FirstMouseHostingView(
            rootView: TranslationBubbleView(model: viewModel)
        )
        // NSHostingView defaults to .standardBounds (min/intrinsic/max sizing).
        // The NSPanel controller owns window geometry, so allowing SwiftUI to
        // publish competing AppKit sizing constraints creates a race whenever
        // the phase changes while the panel is pinned.
        hostingView.sizingOptions = []
        return hostingView
    }()
    private lazy var measurementController: NSHostingController<TranslationBubbleView> = {
        let controller = NSHostingController(
            rootView: TranslationBubbleView(model: viewModel)
        )
        controller.sizingOptions = []
        return controller
    }()

    private var anchorRect = CGRect.zero
    private var expansionOriginFrame = CGRect.zero
    private var globalMouseMonitor: Any?
    private var localEventMonitor: Any?
    private var dismissWorkItem: DispatchWorkItem?
    private var hasUserResizedWindow = false
    private var panelPresentationID = UUID()
    private var triggerPresentationID = UUID()
    private var fixedHorizontalEdge: CGRectEdge = .minXEdge
    private var fixedVerticalEdge: CGRectEdge = .maxYEdge

    private let triggerSize = CGSize(width: 38, height: 38)
    private let expandedMinSize = CGSize(width: 420, height: 138)
    private let expandedMaxSize = CGSize(width: 720, height: 560)
    private override init() {
        super.init()
        panel.delegate = self
        panel.contentView = panelHostingView

        let triggerHostingView = FirstMouseHostingView(
            rootView: TranslationTriggerView { [weak self] in
                self?.viewModel.onTranslate?()
            }
        )
        triggerHostingView.sizingOptions = []
        triggerPanel.contentView = triggerHostingView

        viewModel.onPinToggle = { [weak self] in self?.togglePinned() }
        installDismissMonitors()
    }
    deinit {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
    }

    func showSelection(anchorRect: CGRect) {
        dismissWorkItem?.cancel()
        self.anchorRect = anchorRect

        if panel.isVisible && !viewModel.isPinned {
            hideResult(animated: false, notify: false)
        }

        let targetFrame = compactFrame(for: triggerSize, anchoredTo: anchorRect)
        expansionOriginFrame = targetFrame
        updateFixedEdges(for: targetFrame)
        triggerPresentationID = UUID()

        if triggerPanel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                triggerPanel.animator().setFrame(targetFrame, display: true)
            }
        } else {
            triggerPanel.alphaValue = 0
            triggerPanel.setFrame(targetFrame, display: true)
            triggerPanel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                triggerPanel.animator().alphaValue = 1
            }
        }
    }

    func beginTranslation(
        sourceText: String,
        sourceApplicationName: String,
        provider: TranslationProvider
    ) {
        dismissWorkItem?.cancel()

        // A new selection starts a new content-fitting cycle even when the
        // panel is pinned. A resize the user made for the previous translation
        // should not lock an unrelated result into that old height.
        hasUserResizedWindow = false

        if triggerPanel.isVisible {
            expansionOriginFrame = triggerPanel.frame
            updateFixedEdges(for: expansionOriginFrame)
        }
        hideTrigger(animated: false)

        viewModel.prepareSelection(
            text: sourceText,
            applicationName: sourceApplicationName,
            provider: provider
        )
        viewModel.beginTranslation()

        // Measure the actual SwiftUI waiting state instead of relying on a
        // historical fixed height. This also gives pinned and transient panels
        // exactly the same content-driven sizing policy.
        presentFittedToContent()
        panel.orderFrontRegardless()
    }
    func updateDetectedDirection(targetLanguage: String) {
        viewModel.setDetectedDirection(targetLanguage: targetLanguage)
    }
    func updateStreamingText(_ text: String) {
        viewModel.enqueuePartialText(text)

        // During streaming the reveal animation may lag slightly behind the
        // network's latest partial string, so keep a bounded growth estimate.
        // The completed state below is always measured exactly from SwiftUI.
        let estimatedLines = min(13, max(2, Int(ceil(Double(text.count) / 42.0))))
        let requestedHeight = min(
            500,
            max(230, CGFloat(174 + estimatedLines * 22))
        )
        present(size: CGSize(width: 440, height: requestedHeight))
    }

    func finish(result: TranslationResult) async {
        await viewModel.finish(with: result)
        guard !Task.isCancelled else { return }

        // At completion the model contains the full translated text. Ask
        // SwiftUI for its actual fitted size at the panel width, including the
        // capped translation ScrollView and copy-action row.
        presentFittedToContent()
        scheduleDismiss(after: 30)
    }

    func showError(_ message: String) {
        viewModel.fail(message: message)
        presentFittedToContent()
        scheduleDismiss(after: 14)
    }
    func containsScreenPoint(_ point: CGPoint) -> Bool {
        let expandedContains = panel.isVisible
            && panel.frame.insetBy(dx: -8, dy: -8).contains(point)
        let triggerContains = triggerPanel.isVisible
            && triggerPanel.frame.insetBy(dx: -8, dy: -8).contains(point)
        return expandedContains || triggerContains
    }

    func hide() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        hideTrigger(animated: false)
        hideResult(animated: false, notify: true)
        if viewModel.isPinned {
            viewModel.isPinned = false
            configurePanelLevel()
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        // AppKit sends windowDidResize for programmatic, animation and hosting
        // view fitting changes as well. Only live resize is a reliable signal
        // that the user intentionally chose a custom panel size.
        hasUserResizedWindow = true
    }

    private func togglePinned() {
        viewModel.isPinned.toggle()
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        configurePanelLevel()

        if !viewModel.isPinned, case .translated = viewModel.phase {
            scheduleDismiss(after: 30)
        }
        panel.orderFrontRegardless()
    }

    private func configurePanelLevel() {
        if viewModel.isPinned {
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        } else {
            panel.level = .popUpMenu
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        }
    }

    private func fittedContentSize(width requestedWidth: CGFloat? = nil) -> CGSize {
        let width = min(
            expandedMaxSize.width,
            max(
                expandedMinSize.width,
                requestedWidth ?? (panel.isVisible ? panel.frame.width : 440)
            )
        )

        // Reassigning the root view takes a synchronous snapshot of the current
        // ObservableObject phase before asking AppKit for sizeThatFits.
        measurementController.rootView = TranslationBubbleView(model: viewModel)
        let measured = measurementController.sizeThatFits(
            in: CGSize(width: width, height: expandedMaxSize.height)
        )

        let fitted = CGSize(
            width: width,
            height: min(
                expandedMaxSize.height,
                max(expandedMinSize.height, ceil(measured.height))
            )
        )

        Self.logger.debug(
            "Measured translation panel width=\(width, privacy: .public) height=\(fitted.height, privacy: .public) pinned=\(self.viewModel.isPinned, privacy: .public) userResized=\(self.hasUserResizedWindow, privacy: .public)"
        )
        return fitted
    }

    private func presentFittedToContent() {
        present(size: fittedContentSize())
    }

    private func present(size requestedSize: CGSize) {
        panelPresentationID = UUID()

        // Pinning keeps the panel's location and lifetime stable; it must not
        // freeze the content size. Only an explicit user resize opts out of
        // automatic fitting.
        let isPinnedAndVisible = viewModel.isPinned && panel.isVisible
        let shouldPreserveUserSize = hasUserResizedWindow && panel.isVisible

        let size: CGSize
        if shouldPreserveUserSize {
            size = panel.frame.size
        } else {
            size = CGSize(
                width: min(expandedMaxSize.width, max(expandedMinSize.width, requestedSize.width)),
                height: min(expandedMaxSize.height, max(expandedMinSize.height, requestedSize.height))
            )
        }

        Self.logger.debug(
            "Apply translation panel requestedHeight=\(requestedSize.height, privacy: .public) resolvedHeight=\(size.height, privacy: .public) currentHeight=\(self.panel.frame.height, privacy: .public) pinned=\(self.viewModel.isPinned, privacy: .public) preserveUserSize=\(shouldPreserveUserSize, privacy: .public)"
        )

        let targetFrame: CGRect
        if isPinnedAndVisible {
            if shouldPreserveUserSize {
                targetFrame = constrained(
                    panel.frame,
                    to: screen(for: CGPoint(x: panel.frame.midX, y: panel.frame.midY))
                )
            } else {
                targetFrame = pinnedFrame(for: size, from: panel.frame)
            }
        } else if shouldPreserveUserSize {
            targetFrame = constrained(
                panel.frame,
                to: screen(for: CGPoint(x: panel.frame.midX, y: panel.frame.midY))
            )
        } else if panel.isVisible {
            targetFrame = expandedFrame(for: size, from: panel.frame)
        } else {
            targetFrame = expandedFrame(for: size, from: expansionOriginFrame)
        }

        if panel.isVisible {
            if isPinnedAndVisible {
                // Streaming can update several times within one animation
                // duration. Apply pinned geometry immediately so frame
                // animations cannot overlap and leave the window at an
                // intermediate height.
                panel.setFrame(targetFrame, display: true)
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    panel.animator().setFrame(targetFrame, display: true)
                }
            }
        } else {
            panel.alphaValue = 0
            panel.setFrame(targetFrame, display: true)
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().alphaValue = 1
            }
        }
    }

    private func compactFrame(for size: CGSize, anchoredTo anchor: CGRect) -> CGRect {
        let point = CGPoint(x: anchor.midX, y: anchor.midY)
        let targetScreen = screen(for: point)
        let visible = targetScreen.visibleFrame
        let inset: CGFloat = 12
        let spacing: CGFloat = 7

        var x = anchor.maxX + spacing
        if x + size.width > visible.maxX - inset {
            x = anchor.minX - size.width - spacing
        }
        x = min(max(x, visible.minX + inset), visible.maxX - size.width - inset)

        var y = anchor.minY - size.height - spacing
        if y < visible.minY + inset {
            y = anchor.maxY + spacing
        }
        y = min(max(y, visible.minY + inset), visible.maxY - size.height - inset)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private func expandedFrame(for size: CGSize, from originFrame: CGRect) -> CGRect {
        let x = fixedHorizontalEdge == .maxXEdge
            ? originFrame.maxX - size.width
            : originFrame.minX
        let y = fixedVerticalEdge == .maxYEdge
            ? originFrame.maxY - size.height
            : originFrame.minY
        let proposed = CGRect(x: x, y: y, width: size.width, height: size.height)
        return constrained(
            proposed,
            to: screen(for: CGPoint(x: originFrame.midX, y: originFrame.midY))
        )
    }

    private func pinnedFrame(for size: CGSize, from currentFrame: CGRect) -> CGRect {
        // A pinned utility panel should stay visually anchored where the user
        // placed it. Grow/shrink downward from its current top edge, then clamp
        // the whole window back into the active screen's visible frame.
        let proposed = CGRect(
            x: currentFrame.minX,
            y: currentFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        return constrained(
            proposed,
            to: screen(for: CGPoint(x: currentFrame.midX, y: currentFrame.midY))
        )
    }

    private func updateFixedEdges(for frame: CGRect) {
        let visible = screen(for: CGPoint(x: frame.midX, y: frame.midY)).visibleFrame
        let roomToRight = visible.maxX - frame.minX
        let roomToLeft = frame.maxX - visible.minX
        fixedHorizontalEdge = roomToRight >= roomToLeft ? .minXEdge : .maxXEdge
        fixedVerticalEdge = frame.maxY <= anchorRect.minY + 1 ? .maxYEdge : .minYEdge
    }

    private func screen(for point: CGPoint) -> NSScreen {
        NSScreen.screens.first(where: { $0.frame.contains(point) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func constrained(_ frame: CGRect, to screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        let x = min(max(frame.minX, visible.minX), visible.maxX - width)
        let y = min(max(frame.minY, visible.minY), visible.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func installDismissMonitors() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.hideIfPointerIsOutside() }
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            if event.type == .keyDown, event.keyCode == 53 {
                self?.dismissTransientSurfaces()
                return nil
            }
            self?.hideIfPointerIsOutside()
            return event
        }
    }

    private func dismissTransientSurfaces() {
        hideTrigger(animated: true)
        if !viewModel.isPinned {
            hideResult(animated: true, notify: true)
        }
    }

    private func hideIfPointerIsOutside() {
        let point = NSEvent.mouseLocation
        let insidePanel = panel.isVisible
            && panel.frame.insetBy(dx: -6, dy: -6).contains(point)
        let insideTrigger = triggerPanel.isVisible
            && triggerPanel.frame.insetBy(dx: -6, dy: -6).contains(point)
        guard !insidePanel, !insideTrigger else { return }

        hideTrigger(animated: true)
        if !viewModel.isPinned {
            hideResult(animated: true, notify: true)
        }
    }

    private func hideTrigger(animated: Bool) {
        guard triggerPanel.isVisible else { return }
        let presentationID = UUID()
        triggerPresentationID = presentationID
        guard animated else {
            triggerPanel.orderOut(nil)
            triggerPanel.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            triggerPanel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.triggerPresentationID == presentationID else { return }
            self.triggerPanel.orderOut(nil)
            self.triggerPanel.alphaValue = 1
        }
    }

    private func hideResult(animated: Bool, notify: Bool) {
        guard panel.isVisible else { return }
        let presentationID = UUID()
        panelPresentationID = presentationID
        if notify { onDismiss?() }
        guard animated else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.panelPresentationID == presentationID else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
        }
    }

    private func scheduleDismiss(after delay: TimeInterval) {
        guard !viewModel.isPinned else { return }
        dismissWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.hideResult(animated: true, notify: true)
        }
        dismissWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
