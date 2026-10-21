import AppKit
import Combine

/// Placement uses local, bottom-up screen points. Every selection keeps the
/// strip near its release corner, outside the crop when that side has room.
struct ScreenCaptureWorkspacePlacement {
    static func toolbar(imageRect: CGRect, bounds: CGRect, preferredWidth: CGFloat,
                        releasePoint: CGPoint? = nil, height: CGFloat = 58, gap: CGFloat = 8) -> CGRect {
        let margin: CGFloat = 8
        let width = min(preferredWidth, max(0, bounds.width - 2 * margin))
        let point = releasePoint ?? CGPoint(x: imageRect.maxX, y: imageRect.minY)
        let desiredX = point.x < imageRect.midX ? point.x + gap : point.x - gap - width
        let desiredY: CGFloat
        if point.y <= imageRect.midY {
            let below = imageRect.minY - gap - height
            desiredY = below >= bounds.minY + margin ? below : point.y + gap
        } else {
            let above = imageRect.maxY + gap
            desiredY = above + height <= bounds.maxY - margin ? above : point.y - gap - height
        }
        return clampedToolbar(CGRect(x: desiredX, y: desiredY, width: width, height: height), bounds: bounds)
    }

    static func clampedToolbar(_ frame: CGRect, bounds: CGRect) -> CGRect {
        let margin: CGFloat = 8
        let x = max(bounds.minX + margin, min(frame.minX, bounds.maxX - frame.width - margin))
        let y = max(bounds.minY + margin, min(frame.minY, bounds.maxY - frame.height - margin))
        return CGRect(origin: CGPoint(x: x, y: y), size: frame.size)
    }
}

@MainActor
private final class CaptureToolbarStrip: NSView {
    var onDragBegan: (() -> Bool)?
    var onDrag: ((CGPoint) -> Void)?
    private var dragStart: (point: CGPoint, origin: CGPoint)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var view: NSView? = hit
        while let current = view, current !== self {
            if current is NSButton { return hit }
            view = current.superview
        }
        // Status labels and stack spacing drag the strip; buttons stay native.
        return self
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = nil
        guard onDragBegan?() == true, let superview else { return }
        dragStart = (superview.convert(event.locationInWindow, from: nil), frame.origin)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, let superview else { return }
        let point = superview.convert(event.locationInWindow, from: nil)
        // Use the initial position and parent coordinates, never the moving strip.
        onDrag?(CGPoint(x: dragStart.origin.x + point.x - dragStart.point.x,
                        y: dragStart.origin.y + point.y - dragStart.point.y))
    }

    override func mouseUp(with event: NSEvent) { dragStart = nil }
}

/// One view in the existing capture panel: exact-size canvas, Live Text, and a
/// compact tool strip. No editor window, scroll view, or modal text input exists.
@MainActor
final class ScreenCaptureWorkspace: NSView, NSTextViewDelegate {
    let session: ImageEditorSession
    let canvas: ImageEditorCanvasView
    let textInteraction: InlineImageTextInteraction
    let imageRect: CGRect
    private(set) var toolbarFrame = CGRect.zero
    private(set) var isBusy = false
    var onAction: ((ScreenCaptureAction) -> Void)?
    var onReselect: (() -> Void)?
    var onClose: (() -> Void)?
    var onWillCopySelection: (() -> Void)?
    var onSamplePixel: ((NSEvent) -> Void)?
    /// Preview-only observations in global AppKit (bottom-up) screen coordinates.
    /// The panel owns source selection, Option gating, sampling, and HUD lifetime.
    var onPointerChanged: ((CGPoint, NSEvent.ModifierFlags) -> Void)?
    var onPointerExited: (() -> Void)?

    private var pointerTrackingArea: NSTrackingArea?
    private var pointerLocationInWindow: CGPoint?
    private let anchor: CGRect
    private let selectionReleasePoint: CGPoint?
    private var toolbarOrigin: CGPoint?
    private let strip = CaptureToolbarStrip()
    private let controls = NSStackView()
    private let status = NSTextField(labelWithString: "")
    private var buttons: [NSButton] = []
    private var toolButtons: [ImageEditorTool: NSButton] = [:]
    private var undoButton: NSButton!
    private var redoButton: NSButton!
    private var fullTextButton: NSButton!
    private(set) var colorButton: NSButton!
    private var input: NSTextView?
    private var inputStyle: ImageAnnotationStyle?
    private var subscriptions = Set<AnyCancellable>()
    private var recognitionRedactions: [ImageAnnotation]?
    private var isChangingPixels = false
    private var lastCursorTool: ImageEditorTool?
    private var popover: NSPopover?
    private var errorMessage: String?
    private var feedbackMessage: String?
    private var feedbackTask: Task<Void, Never>?
    private(set) var customColorPanel: NSColorPanel?
    private var isInvalidated = false
    private(set) var canvasCursorInvalidationCount = 0
    var statusText: String { status.stringValue }

    init(image: ToolImage, imageRect: CGRect, anchor: CGRect, bounds: CGRect,
         releasePoint: CGPoint? = nil, textInteraction injectedInteraction: InlineImageTextInteraction? = nil) {
        self.session = ImageEditorSession(image: image)
        self.textInteraction = injectedInteraction ?? InlineImageTextInteraction(frame: .zero)
        self.canvas = ImageEditorCanvasView(session: session)
        self.imageRect = imageRect
        self.anchor = anchor
        self.selectionReleasePoint = releasePoint
        super.init(frame: bounds)
        autoresizingMask = [.width, .height]
        // The frozen screen belongs to the root. Never install a full-screen
        // windowBackgroundColor layer above it when entering the ready state.
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        session.tool = .select
        canvas.frame = imageRect
        // The editor paints dirtyRect for its scrollable canvas. Constrain that
        // painting to this exact crop when embedded in a full-screen overlay.
        canvas.clipsToBounds = true
        canvas.transform = ImageCanvasTransform(pixelSize: image.pixelSize, exactViewSize: imageRect.size)
        addSubview(canvas)
        textInteraction.frame = imageRect
        addSubview(textInteraction)
        textInteraction.imageContentView = canvas
        textInteraction.allowsTextInteractionAt = { [weak self] point in
            guard let self else { return false }
            let canvasPoint = self.canvas.convert(point, from: self.textInteraction)
            guard let pixel = self.canvas.transform.pixelPoint(fromView: canvasPoint) else { return false }
            // Existing annotations must remain selectable/editable instead of being
            // intercepted by Live Text from the original screenshot underneath.
            return self.session.document.annotation(at: pixel, tolerance: 4 / self.canvas.transform.scale) == nil
        }
        configureStrip()
        addSubview(strip)
        session.onPixelsWillChange = { [weak self] in
            guard let self else { return }
            self.isChangingPixels = true
            // Hide/reset selection during drawing, but keep the crop's shared OCR.
            // The actual preview/document values below identify redaction changes.
            self.refreshControls()
        }
        session.onPixelsDidChange = { [weak self] in
            guard let self else { return }
            self.isChangingPixels = false
            self.canvas.needsDisplay = true
            // A document publisher may still be assigning its new annotations.
            // Its value subscription handles commits; this restores cancelled previews.
            Task { @MainActor [weak self] in self?.scheduleRecognition() }
            self.refreshControls()
        }
        session.$previewAnnotation.dropFirst().sink { [weak self] preview in
            guard let self, self.isChangingPixels, let preview, preview.kind == .mosaic,
                  preview != self.session.document.selectedAnnotation else { return }
            // Inspect the new preview, not the active tool: undoing a text label
            // while the mosaic tool is selected must not invalidate crop OCR.
            self.invalidateRecognition()
        }.store(in: &subscriptions)
        session.document.$annotations.dropFirst().sink { [weak self] annotations in
            // @Published sends the new value before document.annotations changes.
            self?.scheduleRecognition(annotations: annotations)
        }.store(in: &subscriptions)
        session.document.$selectedID.dropFirst().sink { [weak self] id in
            if id != nil { self?.textInteraction.resetSelection() }
        }.store(in: &subscriptions)
        session.objectWillChange.sink { [weak self] in
            // Published values have not yet been assigned when this fires.
            Task { @MainActor [weak self] in self?.refreshControls() }
        }.store(in: &subscriptions)
        textInteraction.onStateChange = { [weak self] in self?.refreshControls() }
        textInteraction.onWillCopySelection = { [weak self] in self?.onWillCopySelection?() }
        layoutWorkspace()
        refreshControls()
        scheduleRecognition()
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshStripAppearance()
    }

    override func draw(_ dirtyRect: NSRect) {
        // NSView's default implementation paints the window background even
        // when its layer is clear. Leave the frozen root visible outside crop.
    }

    override func resetCursorRects() {
        addCursorRect(toolbarFrame, cursor: .arrow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        pointerTrackingArea = nil
        guard !isInvalidated else { return }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate,
                                            .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        pointerTrackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        notifyPointer(at: event.locationInWindow, flags: event.modifierFlags)
        super.mouseEntered(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        notifyPointer(at: event.locationInWindow, flags: event.modifierFlags)
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        pointerLocationInWindow = nil
        onPointerExited?()
        super.mouseExited(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        // Parent tracking must never set/push a cursor over native Live Text's
        // I-beam or over the canvas/tool strip's own cursor rectangles.
        notifyPointer(at: event.locationInWindow, flags: event.modifierFlags)
    }

    override func flagsChanged(with event: NSEvent) {
        // Modifiers can change without mouse motion. Preserve the responder chain
        // so holding Option/Control never becomes a new capture keyboard shortcut.
        let location = pointerLocationInWindow ?? window?.mouseLocationOutsideOfEventStream ?? event.locationInWindow
        notifyPointer(at: location, flags: event.modifierFlags)
        super.flagsChanged(with: event)
    }

    /// Crop pixels may preview the current flatten; controls retain their native
    /// interactions and never preview pixels hidden underneath UI chrome.
    func canShowHUD(at localPoint: CGPoint) -> Bool {
        let isOverInput = input.map { $0.bounds.contains($0.convert(localPoint, from: self)) } ?? false
        return !isBusy && !isInvalidated && localPoint.x.isFinite && localPoint.y.isFinite &&
            bounds.contains(localPoint) && !toolbarFrame.contains(localPoint) &&
            !isOverInput && popover?.isShown != true && customColorPanel?.isVisible != true
    }

    private func notifyPointer(at location: CGPoint, flags: NSEvent.ModifierFlags) {
        guard !isInvalidated else { return }
        pointerLocationInWindow = location
        let localPoint = convert(location, from: nil)
        guard canShowHUD(at: localPoint) else { onPointerExited?(); return }
        let globalPoint = window?.convertPoint(toScreen: location) ?? localPoint
        onPointerChanged?(globalPoint, flags)
    }

    override func layout() {
        super.layout()
        layoutWorkspace()
    }

    private func layoutWorkspace() {
        let previousFrame = toolbarFrame
        let initial = ScreenCaptureWorkspacePlacement.toolbar(imageRect: imageRect, bounds: bounds,
                                                               preferredWidth: 548, releasePoint: selectionReleasePoint)
        toolbarFrame = ScreenCaptureWorkspacePlacement.clampedToolbar(
            CGRect(origin: toolbarOrigin ?? initial.origin, size: initial.size), bounds: bounds)
        if toolbarOrigin != nil { toolbarOrigin = toolbarFrame.origin }
        if previousFrame != toolbarFrame { window?.invalidateCursorRects(for: self) }
        strip.frame = toolbarFrame
        controls.frame = CGRect(x: 8, y: 27, width: toolbarFrame.width - 16, height: 27)
        status.frame = CGRect(x: 11, y: 7, width: toolbarFrame.width - 22, height: 15)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isInvalidated else { return nil }
        return super.hitTest(point)
    }

    func setBusy(_ busy: Bool) {
        isBusy = busy
        session.isInputEnabled = !busy
        if busy {
            pointerLocationInWindow = nil
            onPointerExited?()
            popover?.close()
            restoreColorPanel()
        }
        refreshControls()
    }

    func showError(_ message: String?) {
        errorMessage = message
        refreshControls()
    }

    func showFeedback(_ message: String) {
        feedbackTask?.cancel()
        feedbackMessage = message
        refreshControls()
        feedbackTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            self?.feedbackMessage = nil
            self?.refreshControls()
        }
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        pointerLocationInWindow = nil
        onPointerExited?()
        onPointerChanged = nil
        onPointerExited = nil
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        pointerTrackingArea = nil
        feedbackTask?.cancel()
        feedbackTask = nil
        strip.onDragBegan = nil
        strip.onDrag = nil
        restoreColorPanel()
        textInteraction.cancel()
        textInteraction.onStateChange = nil
        textInteraction.onWillCopySelection = nil
        session.onPixelsWillChange = nil
        session.onPixelsDidChange = nil
        subscriptions.removeAll()
        popover?.close()
        popover = nil
        onAction = nil
        onReselect = nil
        onClose = nil
        onWillCopySelection = nil
        onSamplePixel = nil
        input?.delegate = nil
        input?.removeFromSuperview()
        input = nil
        inputStyle = nil
    }

    /// Only called for this capture's events, never for an NSSavePanel event.
    func handleKey(_ event: NSEvent) -> Bool {
        guard !isBusy, !isInvalidated else { return false }
        if input != nil {
            // Native field-editor copy/paste and IME get the first chance.
            if event.keyCode == 53 { endTextInput(commit: false); return true }
            if event.keyCode == 36 || event.keyCode == 76 {
                if let editor = window?.firstResponder as? NSTextView {
                    if editor.hasMarkedText() { return false }
                    if event.modifierFlags.contains(.shift) {
                        editor.insertNewlineIgnoringFieldEditor(nil)
                        return true
                    }
                }
                endTextInput(commit: true)
                return true
            }
            return false
        }
        let flags = event.modifierFlags.intersection(KeyboardShortcut.supportedModifiers)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags == .command, key == "c" {
            if textInteraction.hasActiveTextSelection {
                return textInteraction.handleCopyKeyEquivalent(event)
            }
            requestImageAction(.copy)
            return true
        }
        if flags.contains(.command), key == "s" { requestImageAction(.save); return true }
        if flags.contains(.command), key == "z" {
            if flags.contains(.shift) { session.redo() } else { session.undo() }
            return true
        }
        switch event.keyCode {
        case 36, 76: requestImageAction(.copy); return true
        case 53: onClose?(); return true
        case 51, 117: session.deleteSelection(); return true
        default: return false
        }
    }

    override func keyDown(with event: NSEvent) {
        if !handleKey(event) { super.keyDown(with: event) }
    }

    /// Pixel clicks, including native word pixels, copy HEX. Controls and the
    /// field editor retain standard context menus. Escape/button alone cancel.
    func shouldSampleRightClick(_ event: NSEvent) -> Bool {
        guard !isInvalidated else { return false }
        let point = convert(event.locationInWindow, from: nil)
        let isOverInput = input.map { $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) } ?? false
        return !toolbarFrame.contains(point) && !isOverInput
    }

    override func rightMouseDown(with event: NSEvent) {
        if !isBusy, shouldSampleRightClick(event) { onSamplePixel?(event) }
    }

    private func invalidateRecognition() {
        textInteraction.invalidate()
        refreshControls()
    }

    private func scheduleRecognition(annotations: [ImageAnnotation]? = nil) {
        guard !isInvalidated else { return }
        // OCR belongs to the captured content, not the annotation renderer. Text,
        // arrows, colors, and their undo steps never become newly recognized words.
        // Redactions alone change this source so obscured text cannot be copied.
        let redactions = (annotations ?? session.document.annotations).filter { $0.kind == .mosaic }
        guard recognitionRedactions != redactions || textInteraction.phase == .idle else { return }
        recognitionRedactions = redactions
        if redactions.isEmpty {
            textInteraction.update(image: session.document.original, revision: UUID())
        } else {
            textInteraction.update(revision: UUID()) { [weak self] in
                guard let self, !self.isInvalidated else { throw CancellationError() }
                let original = self.session.document.original
                return ToolImage(cgImage: try ImageDocumentRenderer.render(original: original.cgImage, annotations: redactions),
                                 title: original.title, isOriginal: original.isOriginal)
            }
        }
    }

    private func refreshControls() {
        guard !isInvalidated else { return }
        canvas.needsDisplay = true
        if lastCursorTool != session.tool {
            lastCursorTool = session.tool
            canvasCursorInvalidationCount += 1
            canvas.window?.invalidateCursorRects(for: canvas)
        }
        colorButton.contentTintColor = session.style.nsColor
        for button in buttons { button.isEnabled = !isBusy }
        for (tool, button) in toolButtons where tool != .rectangle && tool != .ellipse {
            button.state = session.tool == tool ? .on : .off
        }
        toolButtons[.rectangle]?.state = [.rectangle, .ellipse].contains(session.tool) ? .on : .off
        undoButton.isEnabled = !isBusy && session.document.canUndo
        redoButton.isEnabled = !isBusy && session.document.canRedo
        fullTextButton.isEnabled = !isBusy && !textInteraction.fullText.isEmpty
        let useText = session.tool == .select && !session.isEditingText && !isBusy && !isChangingPixels
        textInteraction.isHidden = session.tool != .select || session.isEditingText || isChangingPixels
        textInteraction.interactionEnabled = useText
        if session.isEditingText, input == nil { beginTextInput() }
        if !session.isEditingText, input != nil {
            input?.delegate = nil
            input?.removeFromSuperview()
            input = nil
            inputStyle = nil
        }
        if let input, inputStyle != session.style {
            let attributes = ImageDocumentRenderer.textAttributes(style: session.style)
            input.textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: (input.string as NSString).length))
            input.typingAttributes = attributes
            input.insertionPointColor = session.style.nsColor
            inputStyle = session.style
            layoutTextInput()
        }
        status.stringValue = isBusy ? "正在完成操作…" : (errorMessage ?? session.errorMessage ?? feedbackMessage ?? (textInteraction.statusText + " · 右键复制 HEX · 全文使用已配置快捷键"))
        status.textColor = errorMessage == nil && session.errorMessage == nil ? .secondaryLabelColor : .systemRed
        status.toolTip = status.stringValue
    }

    private func refreshStripAppearance() {
        // CALayer stores resolved CGColors, not AppKit's dynamic semantic colors.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            strip.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.98).cgColor
            strip.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    private func configureStrip() {
        strip.toolTip = "拖动空白处或状态文字移动工具栏"
        strip.onDragBegan = { [weak self] in
            guard let self, !self.isBusy, !self.isInvalidated else { return false }
            self.onPointerExited?()
            self.popover?.close()
            return true
        }
        strip.onDrag = { [weak self] origin in
            guard let self, !self.isBusy, !self.isInvalidated else { return }
            self.toolbarOrigin = origin
            self.layoutWorkspace()
        }
        strip.wantsLayer = true
        strip.layer?.cornerRadius = 10
        refreshStripAppearance()
        strip.layer?.borderWidth = 0.5
        controls.orientation = .horizontal
        controls.spacing = 2
        controls.alignment = .centerY
        controls.distribution = .fillEqually
        strip.addSubview(controls)
        status.font = .systemFont(ofSize: 10)
        status.lineBreakMode = .byTruncatingTail
        strip.addSubview(status)
        addTool(.select)
        let shape = addButton("rectangle", "形状：矩形 / 椭圆", #selector(showShapes(_:)))
        toolButtons[.rectangle] = shape
        toolButtons[.ellipse] = shape
        for tool in [ImageEditorTool.arrow, .line, .brush, .text, .mosaic] { addTool(tool) }
        undoButton = addButton("arrow.uturn.backward", "撤销 ⌘Z", #selector(undoAction))
        redoButton = addButton("arrow.uturn.forward", "重做 ⇧⌘Z", #selector(redoAction))
        colorButton = addButton("circle.fill", "标注颜色", #selector(showColors(_:)))
        _ = addButton("slider.horizontal.3", "线宽 / 字号 / 马赛克色块", #selector(showWidths(_:)))
        _ = addButton("doc.on.doc", "复制图片 · Enter / ⌘C", #selector(copyImage))
        _ = addButton("square.and.arrow.down", "保存图片… · ⌘S", #selector(saveImage))
        _ = addButton("pin", "贴图", #selector(pinImage))
        fullTextButton = addButton("text.badge.checkmark", "复制图像全文", #selector(copyAllText))
        fullTextButton.title = "全文"
        fullTextButton.imagePosition = .noImage
        fullTextButton.font = .systemFont(ofSize: 11, weight: .medium)
        _ = addButton("selection.pin.in.out", "重新框选（清除标注和识字结果）", #selector(reselect))
        _ = addButton("xmark", "关闭 · Escape", #selector(closeAction))
    }

    @discardableResult
    private func addButton(_ icon: String, _ label: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: icon, accessibilityDescription: label) ?? NSImage(),
                              target: self, action: action)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = label
        button.setAccessibilityLabel(label)
        controls.addArrangedSubview(button)
        buttons.append(button)
        return button
    }

    private func addTool(_ tool: ImageEditorTool) {
        let button = addButton(tool.icon, tool.label, #selector(selectTool(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(tool.rawValue)
        button.setButtonType(.toggle)
        toolButtons[tool] = button
    }

    private func select(_ tool: ImageEditorTool) {
        guard !isBusy else { return }
        if input != nil { endTextInput(commit: true) }
        session.cancelGesture()
        session.tool = tool
        errorMessage = nil
        refreshControls()
        window?.makeFirstResponder(canvas)
    }

    @objc private func selectTool(_ sender: NSButton) {
        if let raw = sender.identifier?.rawValue, let tool = ImageEditorTool(rawValue: raw) { select(tool) }
    }
    @objc private func undoAction() { session.undo() }
    @objc private func redoAction() { session.redo() }
    @objc private func copyImage() { requestImageAction(.copy) }
    @objc private func saveImage() { requestImageAction(.save) }
    @objc private func pinImage() { requestImageAction(.pin) }
    @objc private func reselect() { guard !isBusy else { return }; onReselect?() }
    @objc private func closeAction() { onClose?() }
    @objc private func copyAllText() {
        guard !isBusy, !textInteraction.fullText.isEmpty else { return }
        onAction?(.copyText(textInteraction.fullText))
    }

    var canRequestRecognizedText: Bool {
        !isBusy && !isInvalidated && !isChangingPixels && !session.isEditingText && input == nil
    }

    func requestRecognizedText() {
        guard canRequestRecognizedText else { return }
        session.cancelGesture()
        scheduleRecognition()
        onAction?(.copyRecognizedText { [weak self] in
            guard let self, !self.isInvalidated else { throw CancellationError() }
            let text = try await self.textInteraction.recognizedText()
            try Task.checkCancellation()
            guard !self.isInvalidated else { throw CancellationError() }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ScreenCaptureTextError.empty
            }
            return text
        })
    }

    enum ImageAction { case copy, save, pin }
    func requestImageAction(_ action: ImageAction) {
        guard !isBusy, !isInvalidated else { return }
        if input != nil { endTextInput(commit: true) }
        do {
            let image = try session.document.renderedImage()
            switch action {
            case .copy: onAction?(.copyImage(image))
            case .save: onAction?(.saveImage(image))
            case .pin: onAction?(.pinImage(image, anchor))
            }
        } catch { showError(error.localizedDescription) }
    }

    private func beginTextInput() {
        guard let point = session.textInputAnchor else { return }
        onPointerExited?()
        let pixelSize = session.document.original.pixelSize
        let size = CGSize(width: max(1, pixelSize.width - point.x),
                          height: max(session.style.fontSize * 2, pixelSize.height - point.y))
        let storage = ImageDocumentRenderer.textStorage(session.textDraft, style: session.style, maximumWidth: size.width)
        let textView = NSTextView(frame: CGRect(origin: .zero, size: size),
                                  textContainer: storage.layoutManagers[0].textContainers[0])
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.typingAttributes = ImageDocumentRenderer.textAttributes(style: session.style)
        textView.insertionPointColor = session.style.nsColor
        textView.focusRingType = .none
        textView.delegate = self
        textView.setAccessibilityLabel("文字标注，Shift Enter 换行，Enter 放置")
        // Lay out in source pixels, then scale the entire view into screen points.
        // The top-left anchor never moves to make room for an input-field bezel.
        textView.frame = canvas.transform.viewRect(fromPixel: CGRect(origin: point, size: size))
        textView.setBoundsSize(size)
        input = textView
        inputStyle = session.style
        canvas.addSubview(textView)
        layoutTextInput()
        textInteraction.interactionEnabled = false
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    private func layoutTextInput() {
        guard let input, let point = session.textInputAnchor,
              let layout = input.layoutManager, let container = input.textContainer else { return }
        layout.ensureLayout(for: container)
        let height = max(session.style.fontSize * 1.5,
                         max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY) + 4)
        let size = CGSize(width: max(1, session.document.original.pixelSize.width - point.x), height: height)
        input.frame = canvas.transform.viewRect(fromPixel: CGRect(origin: point, size: size))
        input.setBoundsSize(size)
    }

    func textDidChange(_ notification: Notification) {
        layoutTextInput()
    }

    private func endTextInput(commit: Bool) {
        guard let textView = input else { return }
        session.textDraft = textView.string
        input = nil
        inputStyle = nil
        textView.delegate = nil
        textView.removeFromSuperview()
        if commit { session.commitText() } else { session.cancelText() }
        window?.makeFirstResponder(canvas)
        refreshControls()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if textView.hasMarkedText() { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else { endTextInput(commit: true) }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { endTextInput(commit: false); return true }
        return false
    }

    private func showPopover(_ content: NSView, from button: NSButton) {
        guard !isBusy else { return }
        onPointerExited?()
        popover?.close()
        let controller = NSViewController()
        controller.view = content
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = content.frame.size
        self.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    @objc private func showShapes(_ sender: NSButton) {
        let content = NSStackView(frame: CGRect(x: 0, y: 0, width: 150, height: 42))
        content.orientation = .horizontal
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        for tool in [ImageEditorTool.rectangle, .ellipse] {
            let button = NSButton(title: tool.label, target: self, action: #selector(shapeSelected(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(tool.rawValue)
            content.addArrangedSubview(button)
        }
        showPopover(content, from: sender)
    }
    @objc private func shapeSelected(_ sender: NSButton) { selectTool(sender); popover?.close() }

    @objc private func showColors(_ sender: NSButton) {
        let content = NSStackView(frame: CGRect(x: 0, y: 0, width: 310, height: 42))
        content.orientation = .horizontal
        content.spacing = 4
        content.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        for (index, color) in Self.colors.enumerated() {
            let button = NSButton(title: "●", target: self, action: #selector(colorSelected(_:)))
            button.tag = index
            button.isBordered = false
            button.contentTintColor = color
            button.font = .systemFont(ofSize: 22)
            button.setAccessibilityLabel(["红色", "橙色", "黄色", "绿色", "蓝色", "紫色", "白色", "黑色"][index])
            content.addArrangedSubview(button)
        }
        let custom = NSButton(title: "自定义…", target: self, action: #selector(showCustomColors))
        custom.setAccessibilityLabel("打开自定义颜色面板")
        content.addArrangedSubview(custom)
        showPopover(content, from: sender)
    }

    /// A capture-owned public AppKit panel avoids hijacking the shared panel's
    /// unreadable target/action and cannot recolor an unrelated editor window.
    @objc func showCustomColors() {
        guard !isBusy, !isInvalidated, let window else { return }
        onPointerExited?()
        popover?.close()
        let panel: NSColorPanel
        if let existing = customColorPanel { panel = existing }
        else {
            panel = NSColorPanel(contentRect: CGRect(x: 0, y: 0, width: 280, height: 340),
                                 styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.isContinuous = true
            panel.showsAlpha = true
            panel.setTarget(self)
            panel.setAction(#selector(customColorChanged(_:)))
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            customColorPanel = panel
        }
        panel.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
        panel.color = session.style.nsColor
        let screen = window.screen?.visibleFrame ?? window.frame
        let desired = window.convertToScreen(toolbarFrame)
        panel.setFrameOrigin(CGPoint(x: max(screen.minX, min(desired.minX, screen.maxX - panel.frame.width)),
                                     y: max(screen.minY, min(desired.maxY + 8, screen.maxY - panel.frame.height))))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func customColorChanged(_ sender: NSColorPanel) {
        guard sender === customColorPanel, !isBusy, !isInvalidated else { return }
        session.changeStyle { $0.setColor(sender.color) }
    }

    private func restoreColorPanel() {
        guard let panel = customColorPanel else { return }
        customColorPanel = nil
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.orderOut(nil)
        panel.close()
    }

    private static let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen,
                                          .systemBlue, .systemPurple, .white, .black]
    @objc private func colorSelected(_ sender: NSButton) {
        session.changeStyle { $0.setColor(Self.colors[sender.tag]) }
        popover?.close()
    }

    @objc private func showWidths(_ sender: NSButton) {
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 296, height: 112))
        let settings: [(String, Double, Double, Double)] = [
            ("线宽", Double(session.style.lineWidth), 1, 40),
            ("字号", Double(session.style.fontSize), 8, 144),
            ("色块", Double(session.mosaicBlockSize), 4, 64)
        ]
        for (index, item) in settings.enumerated() {
            let y = CGFloat(78 - index * 31)
            let label = NSTextField(labelWithString: item.0)
            label.frame = CGRect(x: 10, y: y, width: 40, height: 20)
            content.addSubview(label)
            let slider: NSSlider
            if index == 2 {
                let mosaic = ScreenCaptureAdjustmentSlider(value: item.1, minValue: item.2, maxValue: item.3,
                                                           target: self, action: #selector(widthChanged(_:)))
                mosaic.onBegin = { [weak self] in self?.session.beginMosaicAdjustment() }
                mosaic.onEnd = { [weak self] in self?.session.endMosaicAdjustment() }
                slider = mosaic
            } else {
                slider = NSSlider(value: item.1, minValue: item.2, maxValue: item.3,
                                  target: self, action: #selector(widthChanged(_:)))
            }
            slider.isContinuous = true
            slider.tag = index
            slider.identifier = NSUserInterfaceItemIdentifier("annotation-slider-\(index)")
            slider.frame = CGRect(x: 52, y: y, width: 176, height: 20)
            slider.setAccessibilityLabel(item.0)
            let valueLabel = NSTextField(labelWithString: "\(Int(item.1.rounded())) px")
            valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            valueLabel.alignment = .right
            valueLabel.frame = CGRect(x: 232, y: y, width: 54, height: 20)
            valueLabel.identifier = NSUserInterfaceItemIdentifier("annotation-value-\(index)")
            valueLabel.setAccessibilityLabel("\(item.0)当前值")
            slider.setAccessibilityValue(valueLabel.stringValue)
            content.addSubview(valueLabel)
            content.addSubview(slider)
        }
        showPopover(content, from: sender)
    }
    @objc private func widthChanged(_ sender: NSSlider) {
        let value = CGFloat(sender.doubleValue.rounded())
        sender.doubleValue = Double(value)
        let identifier = NSUserInterfaceItemIdentifier("annotation-value-\(sender.tag)")
        let label = sender.superview?.subviews.compactMap { $0 as? NSTextField }.first { $0.identifier == identifier }
        label?.stringValue = "\(Int(value)) px"
        sender.setAccessibilityValue(label?.stringValue ?? "\(Int(value)) px")
        switch sender.tag {
        case 0: session.changeStyle { $0.lineWidth = value }
        case 1: session.changeStyle { $0.fontSize = value }
        default: session.updateMosaicBlockSize(Int(value))
        }
    }
}

@MainActor
private final class ScreenCaptureAdjustmentSlider: NSSlider {
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onBegin?()
        defer { onEnd?() }
        super.mouseDown(with: event)
    }
}

private enum ScreenCaptureTextError: LocalizedError {
    case empty
    var errorDescription: String? { "未识别到文字，可重新框选" }
}
