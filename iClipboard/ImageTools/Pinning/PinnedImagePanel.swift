import AppKit
import SwiftUI

/// Screen-space geometry never assumes that the current display starts at (0, 0).
enum PinnedImagePlacement {
    static let toolbarHeight: CGFloat = 38
    static let toolbarMinimumSize = CGSize(width: 240, height: 76)

    static func canShowToolbar(in size: CGSize) -> Bool {
        size.width >= toolbarMinimumSize.width && size.height >= toolbarMinimumSize.height
    }

    static func minimumImageWidth(aspect: CGFloat) -> CGFloat {
        // Keep even narrow pins recoverable without imposing a toolbar-sized floor.
        max(24 * max(1, aspect), 48 * min(1, aspect))
    }

    static func captureAnchor(_ anchor: CGRect?) -> CGRect? {
        guard let anchor, !anchor.isNull, !anchor.isInfinite,
              anchor.size.width > 0, anchor.size.height > 0,
              anchor.minX.isFinite, anchor.minY.isFinite,
              anchor.maxX.isFinite, anchor.maxY.isFinite else { return nil }
        return anchor
    }

    static func frame(imageSize: CGSize, anchor: CGRect?, visibleFrame: CGRect,
                      backingScale: CGFloat = 1, screenFrame: CGRect? = nil) -> CGRect {
        if let anchor = captureAnchor(anchor) {
            // Capture anchors already describe screen-space points, not pixels.
            // Keep their size, including over the menu bar/Dock; translate first
            // and shrink proportionally only when the target cannot fit at all.
            let available = screenFrame ?? visibleFrame
            let scale = min(1, available.width / anchor.width, available.height / anchor.height)
            let size = CGSize(width: anchor.width * scale, height: anchor.height * scale)
            return CGRect(x: min(max(anchor.minX, available.minX), available.maxX - size.width),
                          y: min(max(anchor.minY, available.minY), available.maxY - size.height),
                          width: size.width, height: size.height)
        }
        let available = visibleFrame.insetBy(dx: 8, dy: 8)
        let pixelScale = max(1, backingScale)
        let preferred = CGSize(width: imageSize.width / pixelScale,
                               height: imageSize.height / pixelScale)
        let maxWidth = max(1, available.width)
        let maxHeight = max(1, available.height)
        let scale = min(1, min(560, maxWidth) / preferred.width,
                        min(420, maxHeight) / preferred.height)
        // Keep the initial letterboxing for unusually tall/wide or tiny images.
        // The toolbar overlays this canvas; it never contributes to its geometry.
        let size = CGSize(width: min(maxWidth, max(min(280, maxWidth), preferred.width * scale)),
                          height: min(maxHeight, max(min(96, maxHeight), preferred.height * scale)))
        let center = CGPoint(x: visibleFrame.midX, y: visibleFrame.midY)
        return CGRect(x: min(max(center.x - size.width / 2, available.minX),
                             available.maxX - size.width).rounded(),
                      y: min(max(center.y - size.height / 2, available.minY),
                             available.maxY - size.height).rounded(),
                      width: size.width.rounded(.down), height: size.height.rounded(.down))
    }

    static func fittedImageSize(_ proposed: CGSize, aspect: CGFloat,
                                visibleFrame: CGRect, minimumWidth: CGFloat? = nil) -> CGSize {
        let maxWidth = max(1, visibleFrame.width)
        let maxHeight = max(1, visibleFrame.height)
        let minimumWidth = min(minimumWidth ?? minimumImageWidth(aspect: aspect),
                               maxWidth, maxHeight * aspect)
        let width = min(max(minimumWidth, proposed.width), maxWidth, maxHeight * aspect)
        return CGSize(width: width, height: width / aspect)
    }
}

/// No accumulated scale: every event starts at the actual, already-clamped size.
enum PinnedImageScrollZoom {
    static func factor(deltaX: CGFloat, deltaY: CGFloat, precise: Bool) -> CGFloat? {
        guard deltaX.isFinite, deltaY.isFinite, deltaY != 0,
              abs(deltaY) > abs(deltaX) else { return nil }
        // A wheel unit is one ~10% step. Trackpad points are much finer grained.
        let exponent = deltaY * (precise ? 0.005 : log(1.1))
        // Bound only the exponent to keep even pathological finite input finite;
        // fittedImageSize is the single geometric clamp for either input device.
        return exp(min(50, max(-50, exponent)))
    }
}

@MainActor
final class PinnedImagePanel: NSPanel {
    var onCloseRequested: (() -> Void)?
    var onCommand: ((String) -> Void)?
    var onFirstResponderChanged: (() -> Void)?
    var onCopyTextSelection: ((NSEvent) -> Bool)?
    var onImageScroll: ((NSEvent) -> Bool)?
    var usesFullScreenBounds = false

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // Capture placement has already clamped against the complete screen.
        // AppKit's default would move a borderless pin below the menu bar again.
        usesFullScreenBounds ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let changed = super.makeFirstResponder(responder)
        onFirstResponderChanged?()
        return changed
    }

    override func close() {
        if let onCloseRequested { onCloseRequested() }
        else { super.close() }
    }

    override func cancelOperation(_ sender: Any?) {
        // Escape may cancel native selection or controls, but closing a pin
        // belongs to the user's configured shortcut, not the responder chain.
    }

    override func sendEvent(_ event: NSEvent) {
        // Native text selection must not consume image zoom wheel events.
        if event.type == .scrollWheel, onImageScroll?(event) == true { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(KeyboardShortcut.supportedModifiers)
        if event.charactersIgnoringModifiers?.lowercased() == "c" {
            if modifiers == .command, onCopyTextSelection?(event) == true { return true }
        }
        if modifiers == .command,
           let key = event.charactersIgnoringModifiers?.lowercased(),
           ["c", "s", "e", "t", "[", "]", "+", "=", "-"].contains(key) {
            onCommand?(key)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class PinnedImageWindowController: NSObject, NSWindowDelegate {
    enum Action { case copy, save, edit }

    let panel: PinnedImagePanel
    let controls: PinnedImageControls
    var onClose: (() -> Void)?
    var onPresent: (() -> Void)?
    var onCopyFullText: ((@escaping @MainActor () async throws -> String) -> Void)?
    var onWillCopySelection: (() -> Void)?
    var onAction: ((Action, ToolImage, CGRect) -> Void)?
    let textInteraction: InlineImageTextInteraction
    private(set) var isToolbarVisible = true
    var hasPendingToolbarHide: Bool { toolbarHideTask != nil }

    private var image: ToolImage?
    private let canvas = PinnedImageCanvas()
    private let container = PinnedImageContainer()
    private var toolbar: PinnedImageToolbarHost?
    private let canvasAspect: CGFloat
    private let usesCaptureGeometry: Bool
    private let minimumResizeWidth: CGFloat
    private var isDisposed = false
    private var toolbarHideTask: Task<Void, Never>?
    private var isDismissingCompactControls = false
    private var observers: [NSObjectProtocol] = []

    init(image: ToolImage, anchor: CGRect?, textInteraction: InlineImageTextInteraction? = nil) {
        self.image = image
        self.textInteraction = textInteraction ?? InlineImageTextInteraction(frame: .zero)
        controls = PinnedImageControls(title: image.title, isOriginal: image.isOriginal)
        let captureAnchor = PinnedImagePlacement.captureAnchor(anchor)
        let point = captureAnchor.map { CGPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        let frame = PinnedImagePlacement.frame(imageSize: image.pixelSize, anchor: captureAnchor,
                                               visibleFrame: visible,
                                               backingScale: screen?.backingScaleFactor ?? 1,
                                               screenFrame: screen?.frame)
        // Pixel and point aspect normally match. If a snapshot used different
        // sampling on each axis, restore its point target rather than letterbox.
        let aspect = captureAnchor.map { $0.width / $0.height } ?? frame.width / frame.height
        canvasAspect = aspect
        usesCaptureGeometry = captureAnchor != nil
        let minimumWidth = PinnedImagePlacement.minimumImageWidth(aspect: aspect)
        minimumResizeWidth = captureAnchor == nil ? minimumWidth : min(minimumWidth, frame.width)
        panel = PinnedImagePanel(contentRect: frame,
                                 styleMask: [.borderless, .resizable, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        super.init()
        panel.title = image.title.isEmpty ? "贴图" : "贴图 — \(image.title)"
        panel.isReleasedWhenClosed = false
        // AppKit owns the resize gesture and fixed corner; never reselect a
        // driving axis from the size returned by the previous resize callback.
        panel.contentAspectRatio = CGSize(width: canvasAspect, height: 1)
        panel.usesFullScreenBounds = usesCaptureGeometry
        // Initialization can constrain the frame before the capture flag is set.
        if usesCaptureGeometry { panel.setFrame(frame, display: false) }
        panel.isRestorable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.onCloseRequested = { [weak self] in self?.dispose() }
        panel.onCommand = { [weak self] in self?.handleCommand($0) }
        panel.onFirstResponderChanged = { [weak self] in self?.updateToolbarVisibility() }
        panel.onCopyTextSelection = { [weak self] event in
            self?.textInteraction.handleCopyKeyEquivalent(event) ?? false
        }
        panel.onImageScroll = { [weak self] event in
            guard let self, !self.isDisposed, !self.controls.showsOpacity, !self.controls.isMenuTracking else { return false }
            let point = self.container.convert(event.locationInWindow, from: nil)
            if self.isToolbarVisible, point.y >= self.container.bounds.maxY - PinnedImagePlacement.toolbarHeight { return false }
            let imagePoint = self.canvas.convert(event.locationInWindow, from: nil)
            guard self.canvas.imageRect.contains(imagePoint) else { return false }
            self.canvas.scrollWheel(with: event)
            return true
        }
        self.textInteraction.onWillCopySelection = { [weak self] in self?.onWillCopySelection?() }
        self.textInteraction.interactionEnabled = true
        self.textInteraction.capturesBlankSpaceWithSelection = false
        self.textInteraction.imageContentView = canvas
        self.textInteraction.allowsTextInteractionAt = { _ in !NSEvent.modifierFlags.contains(.option) }
        canvas.image = image.cgImage
        canvas.displayAspect = captureAnchor.map { $0.width / $0.height }
        canvas.onZoom = { [weak self] factor, point in self?.zoom(factor, at: point) }
        canvas.textInteraction = self.textInteraction
        canvas.setAccessibilityElement(true)
        canvas.setAccessibilityRole(.image)
        canvas.setAccessibilityLabel(image.isOriginal ? image.title : "\(image.title)（缩略图，非原图）")
        canvas.setAccessibilityHelp("划选图中文字后按 Command C 复制；使用设置中的“复制图像全文”快捷键复制全文。空白处或按住 Option 拖动贴图，滚动缩放。")
        installContent()
        updateResizeLimits()
        self.textInteraction.update(image: image, revision: UUID())
        controls.onInteractionChanged = { [weak self] in
            // Menus/popovers can swallow tracking events while open.
            self?.container.resyncPointer()
            self?.updateToolbarVisibility()
        }
        container.onPointerChanged = { [weak self] in self?.updateToolbarVisibility() }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: panel, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateToolbarVisibility() }
            })
        }
    }

    func present() {
        guard !isDisposed else { return }
        textInteraction.interactionEnabled = true
        // Apply compact sizing before ordering to avoid flashing clipped controls.
        setToolbarVisible(true, animated: false)
        // Ordering and hover never activate the application or steal keyboard focus.
        panel.orderFrontRegardless()
        onPresent?()
        container.resyncPointer()
        updateToolbarVisibility()
    }

    func hide() {
        textInteraction.interactionEnabled = false
        cancelToolbarHide()
        controls.cancelMenuTracking?()
        controls.showsOpacity = false
        panel.orderOut(nil)
        cancelToolbarHide()
    }

    func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        cancelToolbarHide()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        controls.onInteractionChanged = nil
        container.invalidateTracking()
        panel.onCloseRequested = nil
        panel.onCommand = nil
        panel.onFirstResponderChanged = nil
        panel.onCopyTextSelection = nil
        panel.onImageScroll = nil
        textInteraction.cancel()
        canvas.textInteraction = nil
        panel.delegate = nil
        hide()
        canvas.onZoom = nil
        canvas.image = nil
        // A retained, layer-backed canvas can otherwise keep its previous draw
        // list (and source CGImage) after it leaves the window. Replace that draw
        // before detaching, then discard the now-unused backing contents too.
        canvas.displayIfNeeded()
        canvas.layer?.contents = nil
        toolbar?.layer?.removeAllAnimations()
        panel.contentView = nil
        toolbar = nil
        image = nil
        onAction = nil
        onPresent = nil
        onCopyFullText = nil
        onWillCopySelection = nil
        panel.close()
        let didClose = onClose
        onClose = nil
        didClose?()
    }

    private func installContent() {
        let toolbar = PinnedImageToolbarHost(rootView: PinnedImageToolbar(
            controls: controls,
            onAction: { [weak self] in self?.perform($0) },
            onClose: { [weak self] in self?.dispose() },
            onToggleTop: { [weak self] in self?.toggleTop() },
            onOpacity: { [weak self] in self?.setOpacity($0) }
        ))
        // A narrow capture may clip controls; their SwiftUI minimum must never
        // enlarge the image canvas or change its screen-space anchor.
        toolbar.sizingOptions = []
        self.toolbar = toolbar
        container.frame = CGRect(origin: .zero, size: panel.frame.size)
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        for view in [canvas, toolbar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: PinnedImagePlacement.toolbarHeight),
            canvas.topAnchor.constraint(equalTo: container.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        panel.contentView = container
        panel.initialFirstResponder = canvas
        container.layoutSubtreeIfNeeded()
    }

    private var toolbarHasKeyboardFocus: Bool {
        guard panel.isKeyWindow, let toolbar,
              let focused = panel.firstResponder as? NSView else { return false }
        return focused === toolbar || focused.isDescendant(of: toolbar)
    }

    private var keepsToolbarVisible: Bool {
        container.isPointerInside || controls.showsOpacity || controls.isMenuTracking || toolbarHasKeyboardFocus
    }

    private func updateToolbarVisibility() {
        guard !isDisposed, panel.isVisible, !isDismissingCompactControls else { return }
        guard PinnedImagePlacement.canShowToolbar(in: panel.frame.size) else {
            cancelToolbarHide()
            // Dismiss native tracking and SwiftUI popovers before their callbacks
            // can try to keep a compact pin's controls alive.
            isDismissingCompactControls = true
            defer { isDismissingCompactControls = false }
            controls.cancelMenuTracking?()
            if controls.showsOpacity { controls.showsOpacity = false }
            setToolbarVisible(false, animated: false)
            return
        }
        if keepsToolbarVisible {
            cancelToolbarHide()
            setToolbarVisible(true)
        } else if isToolbarVisible, toolbarHideTask == nil {
            toolbarHideTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 600_000_000) }
                catch { return }
                guard let self, !self.isDisposed else { return }
                self.toolbarHideTask = nil
                // Also protects native tooltips, whose window can interrupt hover
                // delivery even though the pointer is still over this image.
                self.container.resyncPointer()
                guard self.panel.isVisible, !self.keepsToolbarVisible else { return }
                self.setToolbarVisible(false)
            }
        }
    }

    private func cancelToolbarHide() {
        toolbarHideTask?.cancel()
        toolbarHideTask = nil
    }

    private func setToolbarVisible(_ visible: Bool, animated: Bool = true) {
        let visible = visible && PinnedImagePlacement.canShowToolbar(in: panel.frame.size)
        guard let toolbar else { return }
        guard isToolbarVisible != visible else {
            if !animated {
                toolbar.layer?.removeAllAnimations()
                toolbar.alphaValue = visible ? 1 : 0
            }
            return
        }
        isToolbarVisible = visible
        controls.isToolbarVisible = visible
        toolbar.interactionEnabled = visible
        toolbar.setAccessibilityHidden(!visible)
        if !visible, let focused = panel.firstResponder as? NSView,
           focused === toolbar || focused.isDescendant(of: toolbar) {
            // A non-key panel can still remember its old first responder. Do not
            // leave keyboard focus parked in controls after they become hidden.
            _ = panel.makeFirstResponder(canvas)
        }
        toolbar.layer?.removeAllAnimations()
        // Show immediately so a re-enter never encounters a transparent hitbox.
        // Hide can fade without intercepting the image during the transition.
        if !visible, animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                toolbar.animator().alphaValue = 0
            }
        } else {
            toolbar.alphaValue = visible ? 1 : 0
        }
    }

    /// Only the configured action invokes full-text copy; it never opens capture.
    @discardableResult
    func copyFullText() -> Bool {
        guard !isDisposed, panel.isVisible, panel.isKeyWindow,
              let onCopyFullText else { return false }
        let isCurrent: () -> Bool = { [weak self] in self?.canCopyFullText == true }
        onCopyFullText { [weak interaction = textInteraction] in
            guard isCurrent(), let interaction else { throw CancellationError() }
            let text = try await interaction.recognizedText()
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            return text
        }
        return true
    }

    private var canCopyFullText: Bool { !isDisposed && panel.isVisible && panel.isKeyWindow }

    private func perform(_ action: Action) {
        guard !isDisposed, let image else { return }
        container.layoutSubtreeIfNeeded()
        let local = canvas.convert(canvas.imageRect, to: nil)
        onAction?(action, image, panel.convertToScreen(local))
    }

    private func handleCommand(_ key: String) {
        switch key {
        case "c": perform(.copy)
        case "s": perform(.save)
        case "e": perform(.edit)
        case "t": toggleTop()
        case "[": setOpacity(controls.opacity - 0.1)
        case "]": setOpacity(controls.opacity + 0.1)
        case "+", "=": zoom(1.2)
        case "-": zoom(1 / 1.2)
        default: break
        }
    }

    private func toggleTop() {
        controls.isOnTop.toggle()
        panel.level = controls.isOnTop ? .floating : .normal
        panel.isFloatingPanel = controls.isOnTop
    }

    private func setOpacity(_ value: Double) {
        controls.opacity = min(1, max(0.2, value))
        panel.alphaValue = CGFloat(controls.opacity)
    }

    private func zoom(_ factor: CGFloat, at point: CGPoint? = nil) {
        resizeImage(width: panel.frame.width * factor, anchor: point)
    }

    private var resizeBounds: CGRect {
        if usesCaptureGeometry { return panel.screen?.frame ?? panel.frame }
        return (panel.screen?.visibleFrame ?? panel.frame).insetBy(dx: 8, dy: 8)
    }

    private func resizeImage(width: CGFloat, anchor: CGPoint? = nil) {
        guard !isDisposed else { return }
        container.layoutSubtreeIfNeeded()
        let available = resizeBounds
        let size = PinnedImagePlacement.fittedImageSize(
            CGSize(width: width, height: 0), aspect: canvasAspect, visibleFrame: available,
            minimumWidth: minimumResizeWidth)
        var origin = CGPoint(x: panel.frame.minX, y: panel.frame.maxY - size.height)
        if let anchor, !canvas.imageRect.isEmpty {
            let oldImage = canvas.imageRect
            let unit = CGPoint(x: (anchor.x - oldImage.minX) / oldImage.width,
                               y: (anchor.y - oldImage.minY) / oldImage.height)
            let screenPoint = panel.convertPoint(toScreen: canvas.convert(anchor, to: nil))
            let newImage = canvas.imageRect(in: CGRect(origin: .zero, size: size))
            origin = CGPoint(x: screenPoint.x - newImage.minX - unit.x * newImage.width,
                             y: screenPoint.y - newImage.minY - unit.y * newImage.height)
        }
        origin.x = min(max(origin.x, available.minX), available.maxX - size.width)
        origin.y = min(max(origin.y, available.minY), available.maxY - size.height)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        container.layoutSubtreeIfNeeded()
        container.resyncPointer()
        updateToolbarVisibility()
    }

    func windowDidResize(_ notification: Notification) {
        guard !isDisposed else { return }
        container.layoutSubtreeIfNeeded()
        container.resyncPointer()
        updateToolbarVisibility()
    }

    private func updateResizeLimits() {
        guard !isDisposed else { return }
        let bounds = resizeBounds
        panel.minSize = PinnedImagePlacement.fittedImageSize(
            .zero, aspect: canvasAspect, visibleFrame: bounds, minimumWidth: minimumResizeWidth)
        panel.maxSize = PinnedImagePlacement.fittedImageSize(
            bounds.size, aspect: canvasAspect, visibleFrame: bounds, minimumWidth: minimumResizeWidth)
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        updateResizeLimits()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        updateResizeLimits()
    }
}

@MainActor
final class PinnedImageContainer: NSView {
    var onPointerChanged: (() -> Void)?
    private(set) var isPointerInside = false
    private var pointerTracking: NSTrackingArea?
    private var hasInvalidatedTracking = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // AppKit otherwise defers installation until the next event-loop update.
        // The very first hover must work even when the panel was just presented.
        updateTrackingAreas()
        resyncPointer()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        pointerTracking = nil
        guard window != nil, !hasInvalidatedTracking else { return }
        let tracking = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
        pointerTracking = tracking
        addTrackingArea(tracking)
    }

    override func mouseEntered(with event: NSEvent) { setPointerInside(true) }
    override func mouseExited(with event: NSEvent) { setPointerInside(false) }

    func resyncPointer() {
        guard let window, window.isVisible else { setPointerInside(false); return }
        let local = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        setPointerInside(bounds.contains(local))
    }

    func invalidateTracking() {
        hasInvalidatedTracking = true
        onPointerChanged = nil
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        pointerTracking = nil
        isPointerInside = false
    }

    private func setPointerInside(_ inside: Bool) {
        guard inside != isPointerInside else { return }
        isPointerInside = inside
        onPointerChanged?()
    }
}

@MainActor
final class PinnedImageToolbarHost: NSHostingView<PinnedImageToolbar> {
    var interactionEnabled = true
    override var acceptsFirstResponder: Bool { interactionEnabled && super.acceptsFirstResponder }
    override var canBecomeKeyView: Bool { interactionEnabled && super.canBecomeKeyView }
    override func hitTest(_ point: NSPoint) -> NSView? {
        interactionEnabled ? super.hitTest(point) : nil
    }
}

/// Only the image surface handles dragging and scroll zoom. A hidden toolbar is
/// not a hit target; the canvas remains the full size of the container throughout.
@MainActor
final class PinnedImageCanvas: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var displayAspect: CGFloat? { didSet { needsDisplay = true } }
    var onZoom: ((CGFloat, CGPoint) -> Void)?
    var textInteraction: InlineImageTextInteraction? {
        didSet {
            oldValue?.removeFromSuperview()
            if let textInteraction { addSubview(textInteraction) }
            needsLayout = true
        }
    }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var imageRect: CGRect { imageRect(in: bounds) }

    func imageRect(in bounds: CGRect) -> CGRect {
        guard let image else { return .zero }
        let aspect = displayAspect ?? CGFloat(image.width) / CGFloat(image.height)
        let width = min(bounds.width, bounds.height * aspect)
        let size = CGSize(width: width, height: width / aspect)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    override func layout() {
        super.layout()
        guard let textInteraction else { return }
        let rect = imageRect
        textInteraction.frame = bounds
        if bounds.width > 0, bounds.height > 0 {
            textInteraction.imageContentsRect = CGRect(x: (rect.minX - bounds.minX) / bounds.width,
                                                       y: (rect.minY - bounds.minY) / bounds.height,
                                                       width: rect.width / bounds.width,
                                                       height: rect.height / bounds.height)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .high
        context.draw(image, in: imageRect)
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard imageRect.contains(point), event.momentumPhase.isEmpty,
              let factor = PinnedImageScrollZoom.factor(deltaX: event.scrollingDeltaX,
                                                        deltaY: event.scrollingDeltaY,
                                                        precise: event.hasPreciseScrollingDeltas) else { return }
        onZoom?(factor, point)
    }

    override func mouseDown(with event: NSEvent) {
        textInteraction?.resetSelection()
        window?.makeKey()
        window?.makeFirstResponder(self)
        window?.performDrag(with: event)
    }
}
