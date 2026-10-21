import AppKit
import VisionKit

/// A small injection boundary; production always returns a real VisionKit analysis.
/// Tests may return a transcript without manufacturing character geometry.
struct InlineImageTextAnalysis {
    let text: String
    let nativeAnalysis: ImageAnalysis?
}

@MainActor
protocol InlineImageTextAnalyzing {
    var isSupported: Bool { get }
    func analyze(_ image: CGImage) async throws -> InlineImageTextAnalysis
}

@MainActor
private final class NativeInlineImageTextAnalyzer: InlineImageTextAnalyzing {
    private let analyzer = ImageAnalyzer()
    var isSupported: Bool { ImageAnalyzer.isSupported }

    func analyze(_ image: CGImage) async throws -> InlineImageTextAnalysis {
        // The capture source is already orientation-normalized. VisionKit's
        // async API performs analysis off the UI thread, without another image copy.
        let analysis = try await analyzer.analyze(image, orientation: .up,
                                                  configuration: ImageAnalyzer.Configuration(.text))
        return InlineImageTextAnalysis(text: analysis.transcript, nativeAnalysis: analysis)
    }
}

/// Bounds follow the image surface; the content rect can exclude pin letterboxing.
/// Selection and user-initiated copying belong to the native overlay; this adapter
/// never inspects or writes the pasteboard and never invents OCR character boxes.
@MainActor
final class InlineImageTextInteraction: NSView {
    enum Phase: Equatable {
        case idle, analyzing, ready, empty
        case failed(String)
    }

    enum RecognitionError: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self { case .failed(let message): return message }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var fullText = ""
    private(set) var supportsTextSelection: Bool
    var onStateChange: (() -> Void)?
    var onWillCopySelection: (() -> Void)?
    /// The canvas paints pixels. This adapter supplies only native text interaction.
    weak var imageContentView: NSView? {
        didSet {
            guard !isCancelled else { return }
            imageView.isHidden = imageContentView != nil
            overlay.trackingImageView = imageContentView == nil ? imageView : nil
            overlay.setContentsRectNeedsUpdate()
        }
    }
    var allowsTextInteractionAt: ((CGPoint) -> Bool)?
    var capturesBlankSpaceWithSelection = true
    var imageContentsRect = CGRect(x: 0, y: 0, width: 1, height: 1) {
        didSet {
            guard !isCancelled, oldValue != imageContentsRect else { return }
            overlay.setContentsRectNeedsUpdate()
        }
    }

    var interactionEnabled = false {
        didSet {
            guard oldValue != interactionEnabled else { return }
            if !interactionEnabled { overlay.resetSelection() }
            refreshInteraction()
            onStateChange?()
        }
    }

    override var isHidden: Bool {
        didSet {
            guard oldValue != isHidden else { return }
            if isHidden { overlay.resetSelection() }
            refreshPointerCursor()
        }
    }

    var hasActiveTextSelection: Bool {
        canInteract && overlay.hasActiveTextSelection
    }

    /// Explicitly distinguishes full-text OCR fallback from native selection.
    var statusText: String {
        let unavailable = supportsTextSelection ? "" : "原位文字选择不可用；"
        switch phase {
        case .idle: return supportsTextSelection ? "选择工具下可在图片中划选文字" : "原位文字选择不可用"
        case .analyzing: return unavailable + "正在识别文字…"
        case .ready: return supportsTextSelection ? "可直接划选文字并按 ⌘C 复制" : "原位文字选择不可用；可使用全文识别结果"
        case .empty: return unavailable + "未识别到文字"
        case .failed(let message): return unavailable + message
        }
    }

    private let imageView = NSImageView(frame: .zero)
    private let overlay = ImageAnalysisOverlayView(frame: .zero)
    private let analyzer: InlineImageTextAnalyzing
    private let fallbackRecognizer: TextRecognizer
    private let debounceNanoseconds: UInt64
    private var task: Task<Void, Never>?
    private var pendingImage: ToolImage?
    private var pendingImageProvider: (@MainActor () throws -> ToolImage)?
    private var cachedResult: Result<String, Error>?
    private var waiters: [UUID: CheckedContinuation<String, Error>] = [:]
    private var pointerTrackingArea: NSTrackingArea?
    private var lastLayoutBounds: CGRect?
    private var isTextCursor = false
    private var isResettingAnalysis = false
    private var generation = UUID()
    private var revision: UUID?
    private var isCancelled = false
    private var isSendingCopy = false
    private var didNotifyCopyIntent = false
    private static let copyAction = NSSelectorFromString("copy:")

    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, analyzer: NativeInlineImageTextAnalyzer(),
                  fallbackRecognizer: ImageTextRecognizer(includeBoundingBoxes: false))
    }

    /// Internal dependencies keep lifecycle tests independent of Live Text hardware.
    init(frame: NSRect = .zero, analyzer: InlineImageTextAnalyzing,
         fallbackRecognizer: TextRecognizer, debounceNanoseconds: UInt64 = 180_000_000) {
        self.analyzer = analyzer
        self.fallbackRecognizer = fallbackRecognizer
        self.debounceNanoseconds = debounceNanoseconds
        supportsTextSelection = analyzer.isSupported
        super.init(frame: frame)
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageAlignment = .alignCenter
        imageView.isEditable = false
        imageView.animates = false
        imageView.frame = bounds
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        overlay.trackingImageView = imageView
        overlay.delegate = self
        overlay.isSupplementaryInterfaceHidden = true
        refreshInteraction()
        NotificationCenter.default.addObserver(self, selector: #selector(menuWillSendAction(_:)),
                                               name: NSMenu.willSendActionNotification, object: nil)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        task?.cancel()
        for waiter in waiters.values { waiter.resume(throwing: CancellationError()) }
        NotificationCenter.default.removeObserver(self)
    }

    /// A caller only owns its subscription, never the revision's shared analysis.
    /// Ready, empty and failed results are cached until the owner invalidates them.
    func recognizedText() async throws -> String {
        try Task.checkCancellation()
        guard !isCancelled, let revision else { throw CancellationError() }
        if let cachedResult { return try cachedResult.get() }
        guard phase == .analyzing, task != nil else { throw CancellationError() }
        let generation = self.generation
        let id = UUID()
        let text: String = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                installWaiter(continuation, id: id, generation: generation, revision: revision)
            }
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isCurrent(generation, revision) else { return }
                self.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        })
        try Task.checkCancellation()
        guard isCurrent(generation, revision) else { throw CancellationError() }
        return text
    }

    func update(image: ToolImage, revision: UUID, forceRefresh: Bool = false) {
        update(revision: revision, forceRefresh: forceRefresh, displayImage: image, imageProvider: nil)
    }

    /// Source preparation shares the analysis debounce. Superseded redactions
    /// never allocate a full-size bitmap just to have their OCR task cancelled.
    func update(revision: UUID, imageProvider: @escaping @MainActor () throws -> ToolImage) {
        update(revision: revision, forceRefresh: false, displayImage: nil, imageProvider: imageProvider)
    }

    private func update(revision: UUID, forceRefresh: Bool, displayImage: ToolImage?,
                        imageProvider: (@MainActor () throws -> ToolImage)?) {
        guard !isCancelled, forceRefresh || self.revision != revision else { return }
        clearAnalysis()
        self.revision = revision
        let generation = self.generation
        imageView.image = imageContentView == nil ? displayImage?.nsImage : nil
        pendingImage = displayImage
        pendingImageProvider = imageProvider
        supportsTextSelection = analyzer.isSupported
        phase = .analyzing

        let analyzer = self.analyzer
        let fallback = fallbackRecognizer
        let delay = debounceNanoseconds
        // Keep weak-to-strong promotion in a synchronous scope. In a debug Swift
        // 5 async frame, optional-chaining temporaries may otherwise survive the
        // following suspension and keep a dismissed adapter alive until OCR ends.
        let isRequestCurrent: () -> Bool = { [weak self] in
            self?.isCurrent(generation, revision) == true
        }
        let takePendingImage: () throws -> ToolImage? = { [weak self] in
            guard let self, self.isCurrent(generation, revision) else { return nil }
            defer { self.pendingImage = nil; self.pendingImageProvider = nil }
            return try self.pendingImageProvider?() ?? self.pendingImage
        }
        let prepareFallback: () -> Void = { [weak self] in
            guard let self, self.isCurrent(generation, revision) else { return }
            self.supportsTextSelection = false
            self.onStateChange?()
        }
        task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
                guard isRequestCurrent(), let image = try takePendingImage() else { return }
                if analyzer.isSupported {
                    do {
                        let result = try await analyzer.analyze(image.cgImage)
                        try Task.checkCancellation()
                        self?.finish(text: result.text, analysis: result.nativeAnalysis,
                                     generation: generation, revision: revision)
                        return
                    } catch {
                        // Cancellation is not an OCR failure and must never start
                        // a second recognizer for a canceled native request.
                        if error is CancellationError { throw error }
                        guard !Task.isCancelled, isRequestCurrent() else { return }
                        prepareFallback()
                    }
                }
                guard isRequestCurrent() else { return }
                let result = try await fallback.recognize(image)
                try Task.checkCancellation()
                self?.finish(text: result.text, analysis: nil, generation: generation, revision: revision)
            } catch {
                guard !Task.isCancelled else { return }
                self?.finishFailure(error, generation: generation, revision: revision)
            }
        }
        // Register the only debounce/analysis task before notifying the owner.
        // A synchronous callback may invalidate, cancel, force-refresh, or await it.
        refreshInteraction()
        onStateChange?()
    }

    /// Called at the *start* of a pixel-changing gesture, not after its render.
    func invalidate() {
        guard !isCancelled else { return }
        clearAnalysis()
        imageView.image = nil
        phase = .idle
        refreshInteraction()
        onStateChange?()
    }

    func resetSelection() {
        guard !isCancelled else { return }
        overlay.resetSelection()
    }

    /// Terminal: neither a late result nor a subsequent update can reopen this view.
    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        clearAnalysis()
        imageView.image = nil
        phase = .idle
        overlay.delegate = nil
        overlay.trackingImageView = nil
        overlay.removeFromSuperview()
        imageView.removeFromSuperview()
        refreshInteraction()
        NotificationCenter.default.removeObserver(self)
        onStateChange = nil
        onWillCopySelection = nil
        allowsTextInteractionAt = nil
        imageContentView = nil
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        overlay.frame = bounds
        guard lastLayoutBounds != bounds else { return }
        lastLayoutBounds = bounds
        overlay.setContentsRectNeedsUpdate()
        refreshPointerCursor()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        pointerTrackingArea = nil
        guard canInteract else { return }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate,
                                            .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { updatePointerCursor(with: event) }
    override func mouseEntered(with event: NSEvent) { updatePointerCursor(with: event) }
    override func cursorUpdate(with event: NSEvent) { updatePointerCursor(with: event) }

    override func mouseExited(with event: NSEvent) { releaseTextCursor() }

    private func updatePointerCursor(with event: NSEvent) {
        updatePointerCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func updatePointerCursor(at point: NSPoint) {
        guard canInteract, bounds.contains(point), allowsTextInteractionAt?(point) != false else {
            releaseTextCursor()
            return
        }
        let nativePoint = analysisPoint(from: point)
        isTextCursor = overlay.analysisHasText(at: nativePoint)
        // The full crop is never registered as I-beam. Blank pixels still hit
        // the annotation canvas, and its own tool cursor wins when disabled.
        (isTextCursor ? NSCursor.iBeam : NSCursor.arrow).set()
    }

    private func releaseTextCursor() {
        guard isTextCursor else { return }
        isTextCursor = false
        NSCursor.arrow.set()
    }

    private func refreshPointerCursor() {
        guard let window else { releaseTextCursor(); return }
        updatePointerCursor(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    /// VisionKit's analysis queries use top-left image-view coordinates, even
    /// though ImageAnalysisOverlayView itself is an unflipped AppKit view.
    private func analysisPoint(from local: CGPoint) -> CGPoint {
        let point = overlay.convert(local, from: self)
        return overlay.isFlipped ? point
            : CGPoint(x: point.x, y: overlay.bounds.minY + overlay.bounds.maxY - point.y)
    }

    private func localPoint(fromAnalysis point: CGPoint) -> CGPoint {
        let native = overlay.isFlipped ? point
            : CGPoint(x: point.x, y: overlay.bounds.minY + overlay.bounds.maxY - point.y)
        return convert(native, from: overlay)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard canInteract else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local), allowsTextInteractionAt?(local) != false else { return nil }
        let nativePoint = analysisPoint(from: local)
        guard (capturesBlankSpaceWithSelection && overlay.hasActiveTextSelection) ||
                overlay.analysisHasText(at: nativePoint) else { return nil }
        // Never return the image view: blank pixels must remain canvas events.
        return overlay.hitTest(local)
    }

    /// Capture invokes this before its image-copy shortcut. Send the standard copy:
    /// action only to a native responder, never re-send the event/key equivalent.
    @discardableResult
    func handleCopyKeyEquivalent(_ event: NSEvent) -> Bool {
        guard Self.isCopyEvent(event), hasActiveTextSelection, !isSendingCopy,
              !unrelatedTextInputHasFocus else { return false }
        let target = nativeCopyTarget()
        isSendingCopy = true
        didNotifyCopyIntent = false
        defer { isSendingCopy = false; didNotifyCopyIntent = false }
        if let target {
            notifyCopyIntent()
            // A callback may close/invalidate the session. Consume the text intent
            // but never dispatch a stale selection or copy the image instead.
            guard hasActiveTextSelection else { return true }
            return NSApp.sendAction(Self.copyAction, to: target, from: self)
        }
        // Some OS releases handle this inside the native view rather than expose
        // copy: on the overlay itself. The delegate notifies immediately before
        // native handling; an unhandled key must not claim a completed copy.
        // Direct native dispatch cannot re-enter NSApp/Capture's event loop.
        let handled = overlay.performKeyEquivalent(with: event)
        return handled || didNotifyCopyIntent
    }

    private var canInteract: Bool {
        !isCancelled && interactionEnabled && !isHiddenOrHasHiddenAncestor
            && phase == .ready && supportsTextSelection && overlay.analysis != nil
    }

    private func refreshInteraction() {
        let enabled = !isCancelled && interactionEnabled && phase == .ready && supportsTextSelection
        overlay.preferredInteractionTypes = enabled ? .textSelection : []
        overlay.isHidden = !enabled
        updateTrackingAreas()
        refreshPointerCursor()
    }

    private func clearAnalysis() {
        generation = UUID()
        revision = nil
        task?.cancel()
        task = nil
        pendingImage = nil
        pendingImageProvider = nil
        cachedResult = nil
        let oldWaiters = waiters
        waiters.removeAll()
        oldWaiters.values.forEach { $0.resume(throwing: CancellationError()) }
        // VisionKit may synchronously notify its delegate while resetting. Never
        // let that callback observe a ready phase or text from the old pixels, or
        // reenter an owner update halfway through clearing the previous analysis.
        fullText = ""
        phase = .idle
        isResettingAnalysis = true
        defer { isResettingAnalysis = false }
        overlay.resetSelection()
        overlay.analysis = nil
    }

    private func isCurrent(_ generation: UUID, _ revision: UUID) -> Bool {
        !isCancelled && self.generation == generation && self.revision == revision
    }

    private func finish(text: String, analysis: ImageAnalysis?, generation: UUID, revision: UUID) {
        guard isCurrent(generation, revision) else { return }
        fullText = text
        cachedResult = .success(text)
        supportsTextSelection = analysis != nil
        phase = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : .ready
        task = nil
        overlay.analysis = analysis
        guard isCurrent(generation, revision) else { return }
        refreshInteraction()
        guard isCurrent(generation, revision) else { return }
        resumeWaiters(with: .success(text))
        onStateChange?()
    }

    private func finishFailure(_ error: Error, generation: UUID, revision: UUID) {
        guard isCurrent(generation, revision) else { return }
        let failure: Error = error is CancellationError ? CancellationError()
            : RecognitionError.failed(error.localizedDescription)
        cachedResult = .failure(failure)
        phase = .failed(failure.localizedDescription)
        task = nil
        refreshInteraction()
        guard isCurrent(generation, revision) else { return }
        resumeWaiters(with: .failure(failure))
        onStateChange?()
    }

    private func installWaiter(_ continuation: CheckedContinuation<String, Error>, id: UUID,
                               generation: UUID, revision: UUID) {
        // No suspension: owner changes and cancellation removal are serialized
        // on MainActor, including cancellation before registration.
        guard !Task.isCancelled, isCurrent(generation, revision) else {
            continuation.resume(throwing: CancellationError())
            return
        }
        waiters[id] = continuation
    }

    private func resumeWaiters(with result: Result<String, Error>) {
        let completed = waiters
        waiters.removeAll()
        completed.values.forEach { $0.resume(with: result) }
    }

    private static func isCopyEvent(_ event: NSEvent) -> Bool {
        event.type == .keyDown
            && event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command
            && event.charactersIgnoringModifiers?.lowercased() == "c"
    }

    private func belongsToOverlay(_ responder: NSResponder) -> Bool {
        var current: NSResponder? = responder
        while let candidate = current, candidate !== self {
            if let view = candidate as? NSView,
               view === overlay || view.isDescendant(of: overlay) { return true }
            current = candidate.nextResponder
        }
        return false
    }

    private var unrelatedTextInputHasFocus: Bool {
        guard let first = window?.firstResponder, !belongsToOverlay(first) else { return false }
        return first is NSTextView || first is NSTextField
    }

    private func nativeCopyTarget() -> NSResponder? {
        var visited = Set<ObjectIdentifier>()
        func copyResponder(startingAt responder: NSResponder) -> NSResponder? {
            var current: NSResponder? = responder
            while let candidate = current, candidate !== self,
                  candidate !== window, visited.insert(ObjectIdentifier(candidate)).inserted {
                if candidate.responds(to: Self.copyAction) { return candidate }
                current = candidate.nextResponder
            }
            return nil
        }
        if let first = window?.firstResponder, belongsToOverlay(first),
           let target = copyResponder(startingAt: first) { return target }
        // Walk only views owned by our native overlay. No private class names,
        // selectors, KVC, or guessed text geometry are involved.
        func search(_ view: NSView) -> NSResponder? {
            for child in view.subviews.reversed() {
                if let target = search(child) { return target }
            }
            return copyResponder(startingAt: view)
        }
        return search(overlay)
    }

    private func notifyCopyIntent() {
        if isSendingCopy {
            guard !didNotifyCopyIntent else { return }
            didNotifyCopyIntent = true
        }
        onWillCopySelection?()
    }

    @objc private func menuWillSendAction(_ notification: Notification) {
        guard !isSendingCopy, hasActiveTextSelection,
              let item = notification.userInfo?["MenuItem"] as? NSMenuItem,
              item.action == Self.copyAction else { return }
        let target = NSApp.target(forAction: Self.copyAction, to: item.target, from: item) as? NSResponder
        guard let target, belongsToOverlay(target) else { return }
        onWillCopySelection?()
    }
}

extension InlineImageTextInteraction: ImageAnalysisOverlayViewDelegate {
    func contentsRect(for overlayView: ImageAnalysisOverlayView) -> CGRect {
        // Capture fills its view; a pin may letterbox inside a differently shaped canvas.
        imageContentsRect
    }

    func contentView(for overlayView: ImageAnalysisOverlayView) -> NSView? { imageContentView ?? imageView }

    func overlayView(_ overlayView: ImageAnalysisOverlayView, shouldBeginAt point: CGPoint,
                     forAnalysisType analysisType: ImageAnalysisOverlayView.InteractionTypes) -> Bool {
        let local = localPoint(fromAnalysis: point)
        return canInteract && analysisType.contains(.textSelection)
            && bounds.contains(local) && allowsTextInteractionAt?(local) != false
    }

    func overlayView(_ overlayView: ImageAnalysisOverlayView,
                     shouldHandleKeyDownEvent event: NSEvent) -> Bool {
        guard canInteract else { return false }
        if Self.isCopyEvent(event) {
            guard hasActiveTextSelection else { return false }
            notifyCopyIntent()
            guard hasActiveTextSelection else { return false }
        }
        // Cmd-A, arrows, and other native selection commands stay native. This
        // delegate is never consulted for an unrelated text input's key events.
        return true
    }

    func overlayView(_ overlayView: ImageAnalysisOverlayView, highlightSelectedItemsDidChange highlightSelectedItems: Bool) {
        guard !isResettingAnalysis, !isCancelled else { return }
        onStateChange?()
    }

    @available(macOS 14.0, *)
    func textSelectionDidChange(_ overlayView: ImageAnalysisOverlayView) {
        guard !isResettingAnalysis, !isCancelled else { return }
        onStateChange?()
    }
}
