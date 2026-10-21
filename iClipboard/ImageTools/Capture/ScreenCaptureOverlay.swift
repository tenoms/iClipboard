import AppKit

@MainActor
final class ScreenCaptureOverlayPanel: NSPanel {
    let displayID: CGDirectDisplayID
    private var captureView: ScreenCaptureOverlayView?
    private(set) var workspace: ScreenCaptureWorkspace?
    private var sample: ((SampledImageColor) -> Void)?
    private let pixelHUD = CapturePixelHUD(frame: .zero)
    private var hudHoldTask: Task<Void, Never>?
    private var heldPixelPoint: CGPoint?
    var isSelectionStage: Bool { workspace == nil }
    var onSelectionAborted: (() -> Void)?

    var selectionLockedElsewhere: Bool = false {
        didSet { captureView?.selectionLockedElsewhere = selectionLockedElsewhere }
    }

    init(snapshot: ScreenCaptureSnapshot, intent: ScreenCaptureSession.Intent,
         beginSelection: @escaping (CGDirectDisplayID) -> Bool,
         complete: @escaping (ScreenCaptureSnapshot, CGRect) -> Void,
         sample: @escaping (SampledImageColor) -> Void, cancel: @escaping () -> Void,
         hover: ((CGPoint) -> CaptureDetectionCandidate?)? = nil,
         hoverEnded: (() -> Void)? = nil) {
        displayID = snapshot.displayID
        self.sample = sample
        // Take keyboard focus without app activation; the desktop may still be
        // completing an earlier click when these full-screen panels appear.
        super.init(contentRect: snapshot.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
        hasShadow = false
        isOpaque = true
        backgroundColor = .black
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        let view = ScreenCaptureOverlayView(snapshot: snapshot, intent: intent,
                                            beginSelection: beginSelection, complete: complete,
                                            sample: sample, cancel: cancel)
        captureView = view
        contentView = view
        view.addSubview(pixelHUD)
        pixelHUD.hide()
        view.hover = hover
        view.hoverEnded = hoverEnded
        view.onPointerChanged = { [weak self] point, flags in
            self?.updatePixelPreview(at: point, modifiers: flags)
        }
        view.onPointerExited = { [weak self] in self?.hidePixelPreview() }
        view.selectionAborted = { [weak view] in
            guard let panel = view?.window as? ScreenCaptureOverlayPanel else { return }
            panel.onSelectionAborted?()
        }
        setFrame(snapshot.frame, display: false)
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        // A click delivered just before the overlay appeared can finish activating
        // the desktop app afterwards. Recover only a missing selection-stage key
        // window; never take focus back from another display or a native dialog.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, self.isSelectionStage,
                  NSApp.keyWindow == nil, NSApp.modalWindow == nil else { return }
            self.makeKey()
        }
    }

    func confirmSelection() { captureView?.confirmSelection() }

    func shouldSampleRightClick(_ event: NSEvent) -> Bool {
        workspace?.shouldSampleRightClick(event) ?? true
    }

    func samplePixel(with event: NSEvent) {
        guard shouldSampleRightClick(event), workspace?.isBusy != true else { return }
        let globalPoint = convertPoint(toScreen: event.locationInWindow)
        guard let sampling = pixelSample(at: globalPoint), let color = sampling.image.color(at: sampling.point) else { return }
        showPixelPreview(at: globalPoint, sampling: sampling)
        heldPixelPoint = globalPoint
        hudHoldTask?.cancel()
        hudHoldTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 1_500_000_000) } catch { return }
            self?.hudHoldTask = nil
            self?.heldPixelPoint = nil
            self?.hidePixelPreview()
        }
        sample?(color)
    }

    func setDetectionCandidate(_ candidate: CaptureDetectionCandidate?) {
        captureView?.setDetectionCandidate(candidate)
    }

    private func pixelSample(at globalPoint: CGPoint) -> (image: ToolImage, point: CGPoint)? {
        guard frame.contains(globalPoint), let captureView else { return nil }
        if let workspace {
            let local = workspace.convert(convertPoint(fromScreen: globalPoint), from: nil)
            guard workspace.canShowHUD(at: local) else { return nil }
            if workspace.imageRect.contains(local) {
                let canvasPoint = workspace.canvas.convert(convertPoint(fromScreen: globalPoint), from: nil)
                guard let pixel = workspace.canvas.transform.pixelPoint(fromView: canvasPoint) else { return nil }
                return (workspace.session.currentFlattenedImage, pixel)
            }
        }
        return captureView.pixelSample(at: globalPoint)
    }

    func updatePixelPreview(at globalPoint: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard workspace?.isBusy != true else { hidePixelPreview(); return }
        guard workspace == nil || modifiers.contains(.option) || hudHoldTask != nil,
              let sampling = pixelSample(at: globalPoint) else {
            hidePixelPreview()
            return
        }
        showPixelPreview(at: globalPoint, sampling: sampling)
    }

    private func showPixelPreview(at globalPoint: CGPoint, sampling: (image: ToolImage, point: CGPoint)) {
        guard let captureView else { return }
        let local = captureView.convert(convertPoint(fromScreen: globalPoint), from: nil)
        pixelHUD.show(image: sampling.image, pixel: sampling.point, pointer: local, in: captureView.bounds)
    }

    func hidePixelPreview() { pixelHUD.hide() }

    func restoreHeldPixelPreview() {
        guard hudHoldTask != nil, let point = heldPixelPoint,
              let sampling = pixelSample(at: point) else { return }
        showPixelPreview(at: point, sampling: sampling)
    }

    func showFeedback(_ message: String) { captureView?.showFeedback(message) }

    func beginEditing(image: ToolImage, anchor: CGRect,
                      action: @escaping (ScreenCaptureAction) -> Void,
                      reselect: @escaping () -> Void, cancel: @escaping () -> Void,
                      willCopySelection: @escaping () -> Void,
                      textInteraction: InlineImageTextInteraction? = nil) {
        guard let captureView, workspace == nil else { return }
        captureView.editingLocked = true
        let rect = anchor.offsetBy(dx: -frame.minX, dy: -frame.minY)
        let workspace = ScreenCaptureWorkspace(image: image, imageRect: rect, anchor: anchor,
                                               bounds: captureView.bounds, releasePoint: captureView.selectionReleasePoint,
                                               textInteraction: textInteraction)
        workspace.onAction = action
        workspace.onReselect = reselect
        workspace.onClose = cancel
        workspace.onWillCopySelection = willCopySelection
        workspace.onSamplePixel = { [weak self] event in self?.samplePixel(with: event) }
        workspace.onPointerChanged = { [weak self] point, flags in self?.updatePixelPreview(at: point, modifiers: flags) }
        workspace.onPointerExited = { [weak self] in self?.hidePixelPreview() }
        self.workspace = workspace
        captureView.setDetectionCandidate(nil)
        hudHoldTask?.cancel()
        hudHoldTask = nil
        pixelHUD.hide()
        captureView.addSubview(workspace, positioned: .below, relativeTo: pixelHUD)
        makeFirstResponder(workspace.canvas)
    }

    func resetSelection() {
        hudHoldTask?.cancel()
        hudHoldTask = nil
        pixelHUD.hide()
        workspace?.invalidate()
        workspace?.removeFromSuperview()
        workspace = nil
        captureView?.resetSelection()
        selectionLockedElsewhere = false
        makeFirstResponder(captureView)
    }

    func releaseSnapshotAndClose() {
        hudHoldTask?.cancel()
        hudHoldTask = nil
        pixelHUD.hide()
        pixelHUD.removeFromSuperview()
        orderOut(nil)
        workspace?.invalidate()
        workspace?.removeFromSuperview()
        workspace = nil
        sample = nil
        onSelectionAborted = nil
        captureView?.releaseSnapshot()
        contentView = nil
        captureView = nil
        close()
    }
}

@MainActor
private final class ScreenCaptureOverlayView: NSView {
    private var snapshot: ScreenCaptureSnapshot?
    private let intent: ScreenCaptureSession.Intent
    private var beginSelection: ((CGDirectDisplayID) -> Bool)?
    private var complete: ((ScreenCaptureSnapshot, CGRect) -> Void)?
    private var sample: ((SampledImageColor) -> Void)?
    private var cancel: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var selection: CGRect?
    private(set) var selectionReleasePoint: CGPoint?
    private var drag: Drag?
    private var pointer: CGPoint?
    private var sampledColor: SampledImageColor?
    private var feedback: String?
    private var feedbackTask: Task<Void, Never>?
    var hover: ((CGPoint) -> CaptureDetectionCandidate?)?
    var hoverEnded: (() -> Void)?
    var onPointerChanged: ((CGPoint, NSEvent.ModifierFlags) -> Void)?
    var onPointerExited: (() -> Void)?
    var selectionAborted: (() -> Void)?
    private var detectionCandidate: CaptureDetectionCandidate?
    private var pressedCandidate: CaptureDetectionCandidate?
    private var didDrag = false

    private enum Drag {
        case select(CGPoint)
    }

    var editingLocked = false {
        didSet {
            needsDisplay = true
            if oldValue != editingLocked { window?.invalidateCursorRects(for: self) }
        }
    }

    var selectionLockedElsewhere = false {
        didSet {
            needsDisplay = true
            if oldValue != selectionLockedElsewhere { window?.invalidateCursorRects(for: self) }
        }
    }

    init(snapshot: ScreenCaptureSnapshot, intent: ScreenCaptureSession.Intent,
         beginSelection: @escaping (CGDirectDisplayID) -> Bool,
         complete: @escaping (ScreenCaptureSnapshot, CGRect) -> Void,
         sample: @escaping (SampledImageColor) -> Void, cancel: @escaping () -> Void) {
        self.snapshot = snapshot
        self.intent = intent
        self.beginSelection = beginSelection
        self.complete = complete
        self.sample = sample
        self.cancel = cancel
        super.init(frame: CGRect(origin: .zero, size: snapshot.frame.size))
        autoresizingMask = [.width, .height]
        setAccessibilityElement(true)
        setAccessibilityLabel(intent == .color ? "屏幕取色，点击选择颜色，Escape 取消" :
                                "屏幕截图，拖动选择区域，松开鼠标原位编辑，Escape 取消")
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { true }

    override func resetCursorRects() {
        // Only selection owns a whole-screen crosshair. Ready descendants own
        // arrow/tool cursors, while VisionKit supplies its native I-beam.
        if !editingLocked, !selectionLockedElsewhere { addCursorRect(bounds, cursor: .crosshair) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking = tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: .zero,
                                      options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
        self.tracking = tracking
        addTrackingArea(tracking)
    }

    override func mouseEntered(with event: NSEvent) { updatePointer(event) }
    override func mouseMoved(with event: NSEvent) { updatePointer(event) }
    override func mouseExited(with event: NSEvent) {
        detectionCandidate = nil
        hoverEnded?()
        onPointerExited?()
        pointer = nil
        sampledColor = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let snapshot = snapshot, !editingLocked else { return }
        window?.makeKey()
        window?.makeFirstResponder(self)
        let point = globalPoint(event)
        if intent == .color {
            if let pixel = snapshot.geometry.pixelPoint(at: point),
               let color = ToolImage(cgImage: snapshot.image).color(at: pixel) { sample?(color) }
            return
        }
        guard !selectionLockedElsewhere else { return }
        pressedCandidate = detectionCandidate ?? hover?(point)
        hoverEnded?()
        detectionCandidate = nil
        selection = nil
        didDrag = false
        drag = .select(snapshot.geometry.clampedPoint(point))
        onPointerChanged?(point, event.modifierFlags)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let snapshot, let drag else { return }
        let point = snapshot.geometry.clampedPoint(globalPoint(event))
        onPointerChanged?(globalPoint(event), event.modifierFlags)
        switch drag {
        case .select(let start):
            if !didDrag, hypot(point.x - start.x, point.y - start.y) > 3 {
                guard beginSelection?(snapshot.displayID) == true else { return }
                didDrag = true
                pressedCandidate = nil
                detectionCandidate = nil
            }
            if didDrag { selection = snapshot.geometry.selection(from: start, to: point) }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !editingLocked, drag != nil, let snapshot else { return }
        mouseDragged(with: event)
        drag = nil
        if !didDrag, let candidate = pressedCandidate,
           candidate.rect.contains(globalPoint(event)), beginSelection?(snapshot.displayID) == true {
            selection = candidate.rect.intersection(snapshot.frame)
        }
        pressedCandidate = nil
        if let selection, snapshot.geometry.pixelRect(for: selection) != nil {
            let point = snapshot.geometry.clampedPoint(globalPoint(event))
            selectionReleasePoint = CGPoint(x: point.x - snapshot.frame.minX, y: point.y - snapshot.frame.minY)
            confirmSelection()
        } else if didDrag {
            self.selection = nil
            selectionAborted?()
        }
        didDrag = false
    }

    override func rightMouseDown(with event: NSEvent) {
        (window as? ScreenCaptureOverlayPanel)?.samplePixel(with: event)
    }

    func pixelSample(at globalPoint: CGPoint) -> (image: ToolImage, point: CGPoint)? {
        guard let snapshot, snapshot.frame.contains(globalPoint),
              let pixel = snapshot.geometry.pixelPoint(at: globalPoint) else { return nil }
        return (ToolImage(cgImage: snapshot.image), pixel)
    }

    func setDetectionCandidate(_ candidate: CaptureDetectionCandidate?) {
        guard !editingLocked, drag == nil, detectionCandidate != candidate else { return }
        detectionCandidate = candidate
        needsDisplay = true
    }

    func showFeedback(_ message: String) {
        feedbackTask?.cancel()
        feedback = message
        needsDisplay = true
        feedbackTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            self?.feedback = nil
            self?.needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: cancel?()
        case 36, 76: confirmSelection()
        default: break
        }
    }

    func confirmSelection() {
        guard !editingLocked, let snapshot = snapshot, let selection = selection,
              snapshot.geometry.pixelRect(for: selection) != nil else { return }
        complete?(snapshot, selection)
    }

    func resetSelection() {
        editingLocked = false
        selection = nil
        selectionReleasePoint = nil
        drag = nil
        pressedCandidate = nil
        detectionCandidate = nil
        didDrag = false
        needsDisplay = true
    }

    func releaseSnapshot() {
        feedbackTask?.cancel()
        feedbackTask = nil
        feedback = nil
        snapshot = nil
        selection = nil
        selectionReleasePoint = nil
        drag = nil
        pointer = nil
        sampledColor = nil
        detectionCandidate = nil
        pressedCandidate = nil
        hover = nil
        hoverEnded = nil
        onPointerChanged = nil
        onPointerExited = nil
        selectionAborted = nil
        beginSelection = nil
        complete = nil
        sample = nil
        cancel = nil
        if let tracking = tracking { removeTrackingArea(tracking) }
        tracking = nil
    }

    private func globalPoint(_ event: NSEvent) -> CGPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    private func localRect(_ global: CGRect) -> CGRect {
        guard let snapshot = snapshot else { return .zero }
        return global.offsetBy(dx: -snapshot.frame.minX, dy: -snapshot.frame.minY)
    }

    private func updatePointer(_ event: NSEvent) {
        guard let snapshot else { return }
        let previousCandidate = detectionCandidate
        let global = globalPoint(event)
        pointer = CGPoint(x: global.x - snapshot.frame.minX, y: global.y - snapshot.frame.minY)
        onPointerChanged?(global, event.modifierFlags)
        if !editingLocked, !selectionLockedElsewhere, drag == nil, intent != .color {
            detectionCandidate = hover?(global)
        }
        if intent == .color, let pixel = snapshot.geometry.pixelPoint(at: global) {
            sampledColor = ToolImage(cgImage: snapshot.image).color(at: pixel)
            needsDisplay = true
        } else if previousCandidate != detectionCandidate {
            // The pixel HUD is a separate view. Moving it over an unchanged
            // candidate must not repaint the frozen full-screen background.
            needsDisplay = true
        }
    }

    override func flagsChanged(with event: NSEvent) {
        updatePointer(event)
        super.flagsChanged(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let snapshot = snapshot, let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .none
        context.draw(snapshot.image, in: bounds)
        if intent != .color {
            NSColor.black.withAlphaComponent(0.20).setFill()
            bounds.fill(using: .sourceOver)
            if let selection = selection ?? detectionCandidate?.rect,
               let pixels = snapshot.geometry.pixelRect(for: selection) {
                let rect = localRect(selection)
                context.saveGState()
                context.clip(to: rect)
                context.draw(snapshot.image, in: bounds)
                context.restoreGState()
                NSColor.controlAccentColor.setStroke()
                let outline = NSBezierPath(rect: rect)
                outline.lineWidth = 1.5
                outline.stroke()
                if !editingLocked { drawHandles(rect) }
                let sizeText = "\(Int(pixels.width)) × \(Int(pixels.height)) px"
                let labelSize = textSize(sizeText, font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium))
                let label = clampedHUD(CGRect(x: rect.minX, y: rect.maxY + 8,
                                              width: labelSize.width + 20, height: 28))
                drawHUD(label)
                drawText(sizeText, at: CGPoint(x: label.minX + 10, y: label.minY + 7),
                         font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium))
            }
        } else if let pointer = pointer, let color = sampledColor {
            drawMagnifier(at: pointer, color: color, snapshot: snapshot, context: context)
        }
        guard !editingLocked else { return }
        let hint: String
        if let feedback { hint = feedback }
        else if intent == .color { hint = "点击取色 · 右键复制 HEX · Escape 取消" }
        else if selectionLockedElsewhere { hint = "选区已锁定在另一屏幕 · 右键复制 HEX · Escape 取消" }
        else { hint = "拖动框选，松开后标注 / 选字 · 右键复制 HEX · Escape 取消" }
        let hintSize = textSize(hint)
        let hintRect = clampedHUD(CGRect(x: (bounds.width - hintSize.width - 28) / 2,
                                        y: 24, width: hintSize.width + 28, height: 34))
        drawHUD(hintRect)
        drawText(hint, at: CGPoint(x: hintRect.minX + 14, y: hintRect.minY + 10))
    }

    private func drawHandles(_ rect: CGRect) {
        NSColor.controlAccentColor.setFill()
        for x in [rect.minX, rect.midX, rect.maxX] {
            for y in [rect.minY, rect.midY, rect.maxY] where x != rect.midX || y != rect.midY {
                NSBezierPath(roundedRect: CGRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5),
                             xRadius: 1, yRadius: 1).fill()
            }
        }
    }

    private func drawMagnifier(at point: CGPoint, color: SampledImageColor,
                               snapshot: ScreenCaptureSnapshot, context: CGContext) {
        let card = clampedHUD(CGRect(x: point.x + 22, y: point.y - 190, width: 190, height: 184))
        drawHUD(card)
        let lens = CGRect(x: card.minX + 41, y: card.minY + 64, width: 108, height: 108)
        let global = CGPoint(x: point.x + snapshot.frame.minX, y: point.y + snapshot.frame.minY)
        guard let pixel = snapshot.geometry.pixelPoint(at: global) else { return }
        let pixels = CGRect(x: pixel.x - 4, y: pixel.y - 4, width: 9, height: 9)
        let cropRect = pixels.intersection(CGRect(x: 0, y: 0, width: snapshot.image.width,
                                                 height: snapshot.image.height))
        NSColor.separatorColor.setFill()
        lens.fill()
        if let crop = snapshot.image.cropping(to: cropRect) {
            let destination = CGRect(x: lens.minX + (cropRect.minX - pixels.minX) * 12,
                                     y: lens.minY + (pixels.maxY - cropRect.maxY) * 12,
                                     width: cropRect.width * 12, height: cropRect.height * 12)
            context.interpolationQuality = .none
            context.draw(crop, in: destination)
        }
        NSColor.controlAccentColor.setStroke()
        let pixelOutline = NSBezierPath(rect: CGRect(x: lens.midX - 6, y: lens.midY - 6,
                                                     width: 12, height: 12))
        pixelOutline.lineWidth = 2
        pixelOutline.stroke()
        drawText(color.hex, at: CGPoint(x: card.minX + 12, y: card.minY + 38),
                 font: .monospacedSystemFont(ofSize: 14, weight: .semibold))
        drawText(color.rgb, at: CGPoint(x: card.minX + 12, y: card.minY + 16),
                 font: .monospacedSystemFont(ofSize: 11, weight: .regular))
        let swatch = CGRect(x: card.maxX - 30, y: card.minY + 35, width: 18, height: 18)
        NSColor(srgbRed: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255,
                blue: CGFloat(color.blue) / 255, alpha: 1).setFill()
        NSBezierPath(roundedRect: swatch, xRadius: 4, yRadius: 4).fill()
    }

    private func clampedHUD(_ rect: CGRect) -> CGRect {
        CGRect(x: max(8, min(rect.minX, bounds.width - rect.width - 8)),
               y: max(8, min(rect.minY, bounds.height - rect.height - 8)),
               width: rect.width, height: rect.height)
    }

    private func drawHUD(_ rect: CGRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.97).setFill()
        let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    private func textSize(_ text: String, font: NSFont = .systemFont(ofSize: 12)) -> CGSize {
        (text as NSString).size(withAttributes: [.font: font])
    }

    private func drawText(_ text: String, at point: CGPoint, font: NSFont = .systemFont(ofSize: 12)) {
        (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: NSColor.labelColor])
    }
}
