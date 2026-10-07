import AppKit
import SwiftUI

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class TranslationSurfacePanel: NSPanel {
    init(size: CGSize, movable: Bool) {
        super.init(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        isReleasedWhenClosed = false
        isMovableByWindowBackground = movable
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class TranslationPanelController: NSObject {
    static let shared = TranslationPanelController()

    let viewModel = TranslationPanelViewModel()
    var onDismiss: (() -> Void)?
    var isPinned: Bool { viewModel.isPinned }

    private enum PanelSize {
        static let trigger = CGSize(width: 38, height: 38)
        static let failure = CGSize(width: 440, height: 218)
    }

    private let panel = TranslationSurfacePanel(
        size: CGSize(width: TranslationPanelSizing.width, height: 220),
        movable: true
    )
    private let triggerPanel = TranslationSurfacePanel(
        size: PanelSize.trigger,
        movable: false
    )

    private lazy var panelHostingView: FirstMouseHostingView<TranslationPanelView> = {
        let view = FirstMouseHostingView(
            rootView: TranslationPanelView(model: viewModel)
        )
        view.sizingOptions = []
        return view
    }()
    private lazy var triggerHostingView: FirstMouseHostingView<TranslationTriggerView> = {
        let view = FirstMouseHostingView(
            rootView: TranslationTriggerView { [weak self] in
                self?.viewModel.requestTranslation()
            }
        )
        view.sizingOptions = []
        return view
    }()

    private var anchorRect = CGRect.zero
    private var globalMouseMonitor: Any?
    private var localEventMonitor: Any?
    private var panelPresentationID = UUID()
    private var triggerPresentationID = UUID()
    private var fixedVerticalEdge: CGRectEdge = .maxYEdge

    private override init() {
        super.init()
        panelHostingView.wantsLayer = true
        panelHostingView.layer?.cornerRadius = 16
        panelHostingView.layer?.cornerCurve = .continuous
        panelHostingView.layer?.masksToBounds = true
        panel.contentView = panelHostingView

        triggerHostingView.wantsLayer = true
        triggerHostingView.layer?.cornerRadius = 19
        triggerHostingView.layer?.cornerCurve = .continuous
        triggerHostingView.layer?.masksToBounds = true
        triggerPanel.contentView = triggerHostingView

        viewModel.onPinChange = { [weak self] _ in
            self?.pinStateDidChange()
        }
        viewModel.onDismiss = { [weak self] in
            self?.hideTrigger(animated: true)
            self?.hideResult(
                animated: true,
                notify: true,
                resetModel: true,
                resetPin: true
            )
        }
    }

    func showSelection(_ context: SelectedTextContext) {
        anchorRect = context.anchorRect

        if panel.isVisible, !viewModel.isPinned {
            hideResult(
                animated: false,
                notify: false,
                resetModel: false,
                resetPin: false
            )
        }

        showTrigger()
    }

    func beginTranslation(
        context: SelectedTextContext,
        provider: TranslationProvider
    ) {
        anchorRect = context.anchorRect
        hideTrigger(animated: false)
        viewModel.beginTranslation(context, provider: provider)
        configurePanelBehavior()
        presentResult(size: preferredResultSize)
    }

    func updateDetectedDirection(targetLanguage: String) {
        viewModel.setDetectedDirection(targetLanguage: targetLanguage)
    }

    func updateStreamingText(_ text: String) {
        viewModel.updatePartialText(text)
        guard let presentation = viewModel.presentation else { return }
        let requestedSize = TranslationPanelSizing.size(
            sourceText: presentation.context.text,
            translatedText: text,
            mode: .streaming
        )
        if abs(panel.frame.height - requestedSize.height) >= 12 {
            presentResult(size: requestedSize)
        }
    }

    func finish(result: TranslationResult) async {
        await viewModel.finish(with: result)
        guard !Task.isCancelled else { return }
        presentResult(size: preferredResultSize)
    }

    func showError(_ message: String) {
        viewModel.fail(message: message)
        presentResult(size: preferredResultSize)
    }

    func containsScreenPoint(_ point: CGPoint) -> Bool {
        let resultContains = panel.isVisible
            && panel.frame.insetBy(dx: -8, dy: -8).contains(point)
        let triggerContains = triggerPanel.isVisible
            && triggerPanel.frame.insetBy(dx: -8, dy: -8).contains(point)
        return resultContains || triggerContains
    }

    func hide() {
        hideTrigger(animated: false)
        hideResult(
            animated: false,
            notify: true,
            resetModel: true,
            resetPin: true
        )
    }

    private var preferredResultSize: CGSize {
        switch viewModel.phase {
        case .hidden:
            return CGSize(width: TranslationPanelSizing.width, height: 220)
        case let .translating(presentation):
            return TranslationPanelSizing.size(
                sourceText: presentation.context.text,
                translatedText: presentation.translatedText,
                mode: .streaming
            )
        case let .translated(presentation, _):
            return TranslationPanelSizing.size(
                sourceText: presentation.context.text,
                translatedText: presentation.translatedText,
                mode: .result
            )
        case .failed:
            return PanelSize.failure
        }
    }

    private func showTrigger() {
        triggerPresentationID = UUID()
        let targetScreen = screen(
            for: CGPoint(x: anchorRect.midX, y: anchorRect.midY)
        )
        let targetFrame = TranslationPanelPlacement.compactFrame(
            anchor: anchorRect,
            size: PanelSize.trigger,
            visibleFrame: targetScreen.visibleFrame
        )

        installDismissMonitorsIfNeeded()
        if triggerPanel.isVisible {
            animateFrame(of: triggerPanel, to: targetFrame, duration: 0.12)
        } else {
            triggerPanel.alphaValue = 0
            triggerPanel.setFrame(targetFrame, display: true)
            triggerPanel.orderFrontRegardless()
            animateAlpha(of: triggerPanel, to: 1, duration: 0.12)
        }
    }

    private func presentResult(size: CGSize) {
        panelPresentationID = UUID()
        let wasVisible = panel.isVisible
        let targetFrame: CGRect

        if wasVisible {
            let targetScreen = screen(
                for: CGPoint(x: panel.frame.midX, y: panel.frame.midY)
            )
            targetFrame = TranslationPanelPlacement.resizedFrame(
                currentFrame: panel.frame,
                size: size,
                fixedVerticalEdge: fixedVerticalEdge,
                visibleFrame: targetScreen.visibleFrame
            )
        } else {
            let targetScreen = screen(
                for: CGPoint(x: anchorRect.midX, y: anchorRect.midY)
            )
            targetFrame = TranslationPanelPlacement.expandedFrame(
                anchor: anchorRect,
                size: size,
                visibleFrame: targetScreen.visibleFrame
            )
            fixedVerticalEdge = targetFrame.maxY <= anchorRect.minY + 1
                ? .maxYEdge
                : .minYEdge
        }

        installDismissMonitorsIfNeeded()
        if wasVisible {
            animateFrame(of: panel, to: targetFrame, duration: 0.16)
        } else {
            panel.alphaValue = 0
            panel.setFrame(targetFrame, display: true)
            panel.orderFrontRegardless()
            animateAlpha(of: panel, to: 1, duration: 0.14)
        }
    }

    private func pinStateDidChange() {
        configurePanelBehavior()
        guard panel.isVisible else { return }
        panel.orderFrontRegardless()
    }

    private func configurePanelBehavior() {
        panel.level = .floating
        panel.collectionBehavior = viewModel.isPinned
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    private func animateFrame(
        of targetPanel: NSPanel,
        to frame: CGRect,
        duration: TimeInterval
    ) {
        let resolvedDuration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? 0
            : duration
        guard resolvedDuration > 0 else {
            targetPanel.setFrame(frame, display: true)
            targetPanel.invalidateShadow()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = resolvedDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            targetPanel.animator().setFrame(frame, display: true)
        } completionHandler: {
            targetPanel.invalidateShadow()
        }
    }

    private func animateAlpha(
        of targetPanel: NSPanel,
        to value: CGFloat,
        duration: TimeInterval
    ) {
        let resolvedDuration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? 0
            : duration
        guard resolvedDuration > 0 else {
            targetPanel.alphaValue = value
            targetPanel.invalidateShadow()
            return
        }

        targetPanel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = resolvedDuration
            targetPanel.animator().alphaValue = value
        } completionHandler: {
            targetPanel.invalidateShadow()
        }
    }

    private func screen(for point: CGPoint) -> NSScreen {
        NSScreen.screens.first(where: { $0.frame.contains(point) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func installDismissMonitorsIfNeeded() {
        guard globalMouseMonitor == nil, localEventMonitor == nil else { return }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.hideIfPointerIsOutside()
            }
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.dismissTransientSurfaces()
                return nil
            }
            self.hideIfPointerIsOutside()
            return event
        }
    }

    private func dismissTransientSurfaces() {
        hideTrigger(animated: true)
        guard !viewModel.isPinned else { return }
        hideResult(
            animated: true,
            notify: true,
            resetModel: true,
            resetPin: false
        )
    }

    private func hideIfPointerIsOutside() {
        let point = NSEvent.mouseLocation
        let insideResult = panel.isVisible
            && panel.frame.insetBy(dx: -6, dy: -6).contains(point)
        let insideTrigger = triggerPanel.isVisible
            && triggerPanel.frame.insetBy(dx: -6, dy: -6).contains(point)
        guard !insideResult, !insideTrigger else { return }

        hideTrigger(animated: true)
        if !viewModel.isPinned {
            hideResult(
                animated: true,
                notify: true,
                resetModel: true,
                resetPin: false
            )
        }
    }

    private func hideTrigger(animated: Bool) {
        guard triggerPanel.isVisible else {
            updateDismissMonitors()
            return
        }

        let dismissalID = UUID()
        triggerPresentationID = dismissalID
        let duration: TimeInterval = animated
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? 0.1
            : 0
        guard duration > 0 else {
            triggerPanel.orderOut(nil)
            triggerPanel.alphaValue = 1
            updateDismissMonitors()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            triggerPanel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.triggerPresentationID == dismissalID else { return }
            self.triggerPanel.orderOut(nil)
            self.triggerPanel.alphaValue = 1
            self.updateDismissMonitors()
        }
    }

    private func hideResult(
        animated: Bool,
        notify: Bool,
        resetModel: Bool,
        resetPin: Bool
    ) {
        let dismissalID = UUID()
        panelPresentationID = dismissalID
        if resetModel {
            viewModel.hide(resetPin: resetPin)
        }
        if notify { onDismiss?() }

        guard panel.isVisible else {
            updateDismissMonitors()
            return
        }

        let duration: TimeInterval = animated
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? 0.12
            : 0
        guard duration > 0 else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            updateDismissMonitors()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.panelPresentationID == dismissalID else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            self.updateDismissMonitors()
        }
    }

    private func updateDismissMonitors() {
        guard !panel.isVisible, !triggerPanel.isVisible else { return }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
    }
}
