import AppKit
import CoreGraphics

/// Callers hide/restore their own windows and suspend global text selection around run().
/// This service neither reads nor writes the clipboard or history.
@MainActor
final class ScreenCaptureSession {
    enum Intent { case image, color }
    enum Result {
        case image(ToolImage, CGRect)
        case color(SampledImageColor)
        /// The supplied action handler already performed the terminal output.
        case completed
    }

    static var hasScreenCaptureAccess: Bool { CGPreflightScreenCaptureAccess() }

    static func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private static weak var activeSession: ScreenCaptureSession?
    private let providerFactory: () -> ScreenCaptureProviding
    private let accessCheck: () -> Bool
    private let accessRequest: () -> Bool
    private let textInteractionFactory: () -> InlineImageTextInteraction
    private let timeoutSleep: @MainActor (UInt64) async throws -> Void
    private let detectionModeProvider: () -> CaptureDetectionMode
    private let detectionWindowsProvider: (CaptureDetectionCoordinates) -> [CaptureDetectionWindow]
    private var selectionDetector: CaptureSelectionDetector?
    private var detectionDisplayID: CGDirectDisplayID?
    private var provider: ScreenCaptureProviding?
    private var panels = [ScreenCaptureOverlayPanel]()
    private var completion: CheckedContinuation<Result?, Error>?
    private var preparation: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var eventMonitor: Any?
    private var escapeMonitor: Any?
    private var token: UUID?
    private var isRunning = false
    private var lockedDisplayID: CGDirectDisplayID?
    var onWillCopySelection: (() -> Void)?
    var onContextualKeyEvent: ((NSEvent) -> Bool)?
    private var onAction: ScreenCaptureActionHandler?
    private var actionTask: Task<Void, Never>?
    private var actionGeneration = UUID()
    private var didHideForSavePanel = false
    private(set) var isPerformingAction = false
    /// Read-only seams for real AppKit event/lifecycle tests, without screen TCC.
    var capturePanels: [ScreenCaptureOverlayPanel] { panels }

    init() {
        providerFactory = { ScreenCaptureKitProvider() }
        accessCheck = { Self.hasScreenCaptureAccess }
        accessRequest = { CGRequestScreenCaptureAccess() }
        textInteractionFactory = { InlineImageTextInteraction(frame: .zero) }
        timeoutSleep = { try await Task.sleep(nanoseconds: $0) }
        detectionModeProvider = { ImageToolsPreferences.shared.detectionMode }
        detectionWindowsProvider = {
            CaptureDetectionWindow.readOnScreen(excludingPID: ProcessInfo.processInfo.processIdentifier, coordinates: $0)
        }
    }

    /// Internal seam for cancellation/cleanup tests; production uses the initializer above.
    init(providerFactory: @escaping () -> ScreenCaptureProviding,
         accessCheck: @escaping () -> Bool,
         accessRequest: @escaping () -> Bool,
         textInteractionFactory: (() -> InlineImageTextInteraction)? = nil,
         detectionModeProvider: @escaping () -> CaptureDetectionMode = { .none },
         detectionWindowsProvider: @escaping (CaptureDetectionCoordinates) -> [CaptureDetectionWindow] = { _ in [] },
         timeoutSleep: @escaping @MainActor (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.providerFactory = providerFactory
        self.accessCheck = accessCheck
        self.accessRequest = accessRequest
        self.textInteractionFactory = textInteractionFactory ?? { InlineImageTextInteraction(frame: .zero) }
        self.timeoutSleep = timeoutSleep
        self.detectionModeProvider = detectionModeProvider
        self.detectionWindowsProvider = detectionWindowsProvider
    }

    func run(_ intent: Intent, onAction: ScreenCaptureActionHandler? = nil) async throws -> Result? {
        guard !isRunning, Self.activeSession == nil else { throw ScreenCaptureError.alreadyRunning }
        guard !Task.isCancelled else { return nil }
        isRunning = true
        Self.activeSession = self
        let token = UUID()
        self.token = token
        self.onAction = onAction
        defer {
            cleanUp()
            self.token = nil
            isRunning = false
            if Self.activeSession === self { Self.activeSession = nil }
        }
        // Permission requests happen only here, in direct response to a user action.
        if !accessCheck(), !accessRequest() {
            showPermissionExplanation()
            return nil
        }
        guard !Task.isCancelled else { return nil }
        if intent != .color {
            let mode = detectionModeProvider()
            if mode != .none {
                let screens = NSScreen.screens
                let coordinates = CaptureDetectionCoordinates(primaryHeight: screens.first?.frame.maxY ?? 0,
                                                               displayFrames: screens.map(\.frame))
                selectionDetector = CaptureSelectionDetector(mode: mode,
                                                            windows: detectionWindowsProvider(coordinates),
                                                            coordinates: coordinates)
                selectionDetector?.onCandidateChange = { [weak self] candidate in
                    guard let self, self.token == token, self.lockedDisplayID == nil,
                          let id = self.detectionDisplayID else { return }
                    self.panels.first(where: { $0.displayID == id })?.setDetectionCandidate(candidate)
                }
            }
        }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                let provider = providerFactory()
                self.provider = provider
                installEventMonitor()
                screenObserver = NotificationCenter.default.addObserver(
                    forName: NSApplication.didChangeScreenParametersNotification,
                    object: nil, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard self?.token == token else { return }
                        self?.cancel()
                    }
                }
                schedulePreparationTimeout(token: token)
                preparation = Task { [weak self] in
                    do {
                        let snapshots = try await provider.snapshots()
                        guard let self = self, self.token == token, self.completion != nil,
                              !Task.isCancelled else { return }
                        guard !snapshots.isEmpty else { throw ScreenCaptureError.noDisplays }
                        self.timeout?.cancel()
                        self.timeout = nil
                        self.showOverlays(snapshots: snapshots, intent: intent)
                    } catch {
                        guard let self = self, self.token == token else { return }
                        if error is CancellationError { self.finish(.success(nil)) }
                        else { self.finish(.failure(error)) }
                    }
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                guard self?.token == token else { return }
                self?.cancel()
            }
        })
    }

    func cancel() { finish(.success(nil)) }

    /// Configured actions target the live crop, never the previous clipboard item.
    /// Preparation, an unfinished selection, and an in-flight output are no-ops.
    public func requestCurrentAction(_ action: ScreenCaptureCurrentAction) {
        guard completion != nil, !isPerformingAction,
              let workspace = panels.first(where: { $0.displayID == lockedDisplayID })?.workspace else { return }
        switch action {
        case .pin: workspace.requestImageAction(.pin)
        case .copyRecognizedText: workspace.requestRecognizedText()
        }
    }

    func canCopyRecognizedText(in window: NSWindow) -> Bool {
        guard completion != nil, !isPerformingAction,
              let panel = panels.first(where: { $0 === window && $0.displayID == lockedDisplayID }) else { return false }
        return panel.workspace?.canRequestRecognizedText == true
    }

    private func showPermissionExplanation() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "截图、截图识字和屏幕取色需要读取屏幕画面。请在系统设置的“隐私与安全性 → 屏幕录制”中允许 iClipboard。授权后可能需要退出并重新打开应用。取消不会更改剪贴板或历史记录。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { Self.openPrivacySettings() }
    }

    private func showOverlays(snapshots: [ScreenCaptureSnapshot], intent: Intent) {
        // No overlay exists until every display has its frozen, independently owned image.
        panels = snapshots.map { snapshot in
            ScreenCaptureOverlayPanel(snapshot: snapshot, intent: intent,
                                      beginSelection: { [weak self] id in
                self?.lockSelection(to: id) ?? false
            }, complete: { [weak self] snapshot, selection in
                self?.complete(snapshot: snapshot, selection: selection, intent: intent)
            }, sample: { [weak self] color in
                guard let self else { return }
                let panel = self.panels.first { $0.displayID == snapshot.displayID }
                self.perform(.copyText(color.hex), feedback: "已复制 \(color.hex)", sourcePanel: panel)
            }, cancel: { [weak self] in self?.cancel() },
               hover: { [weak self] point in self?.updateDetection(at: point, displayID: snapshot.displayID) },
               hoverEnded: { [weak self] in self?.endDetectionHover(displayID: snapshot.displayID) })
        }
        for panel in panels { panel.onSelectionAborted = { [weak self] in self?.reselect() } }
        // Nonactivating panels take keyboard focus without racing app activation.
        for panel in panels { panel.orderFrontRegardless() }
        let mouse = NSEvent.mouseLocation
        let focused = panels.first(where: { $0.frame.contains(mouse) }) ?? panels.first
        focused?.makeKeyAndOrderFront(nil)
        if let focused {
            focused.updatePixelPreview(at: mouse, modifiers: NSEvent.modifierFlags)
            _ = updateDetection(at: mouse, displayID: focused.displayID)
        }
    }

    private func installEventMonitor() {
        // Keep the fallback for the entire selection stage: an early desktop
        // click can finish activating another app after the overlays appear.
        let token = self.token
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor [weak self] in
                guard let self, self.token == token, self.completion != nil,
                      self.panels.allSatisfy({ $0.isSelectionStage }), !self.isPerformingAction,
                      NSApp.keyWindow == nil, NSApp.modalWindow == nil else { return }
                self.cancel()
            }
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .rightMouseDown, .flagsChanged]) { [weak self] event in
            guard let self, self.completion != nil else { return event }
            let eventWindow = event.window ?? (event.type == .keyDown ? NSApp.keyWindow : nil)
            // Preparation has no window yet. A windowless Escape may also arrive
            // during key-window handoff; visible native dialogs keep their keys.
            if event.type == .keyDown, event.keyCode == 53, !self.isPerformingAction,
               self.lockedDisplayID == nil, NSApp.modalWindow == nil,
               eventWindow == nil || (self.panels.isEmpty && eventWindow?.isVisible != true) {
                self.cancel()
                return nil
            }
            guard let eventWindow,
                  let panel = self.panels.first(where: { $0 === eventWindow }) else { return event }
            if event.type == .flagsChanged {
                panel.updatePixelPreview(at: NSEvent.mouseLocation, modifiers: event.modifierFlags)
                return event
            }
            // Route every owned display before native Live Text sees a context
            // click. Save/color panels and unrelated windows remain fully native.
            if event.type == .rightMouseDown {
                guard panel.shouldSampleRightClick(event) else { return event }
                if !self.isPerformingAction { panel.samplePixel(with: event) }
                return nil
            }
            guard !self.isPerformingAction else { return event }
            if let workspace = panel.workspace {
                // Configured crop actions precede built-in shortcuts, but never
                // consume annotation text input or events from native dialogs.
                if panel.isKeyWindow, panel.isVisible, workspace.canRequestRecognizedText,
                   self.onContextualKeyEvent?(event) == true { return nil }
                return workspace.handleKey(event) ? nil : event
            }
            if event.keyCode == 53 {
                self.cancel()
                return nil
            }
            if event.keyCode == 36 || event.keyCode == 76 {
                panel.confirmSelection()
                return nil
            }
            return event
        }
    }

    private func updateDetection(at point: CGPoint, displayID: CGDirectDisplayID) -> CaptureDetectionCandidate? {
        guard lockedDisplayID == nil, !isPerformingAction,
              let panel = panels.first(where: { $0.displayID == displayID }), panel.isSelectionStage else { return nil }
        if detectionDisplayID != displayID {
            selectionDetector?.invalidate()
            panels.forEach { $0.setDetectionCandidate(nil) }
        }
        detectionDisplayID = displayID
        let candidate = selectionDetector?.updatePointer(point, displayFrame: panel.frame)
        panel.setDetectionCandidate(candidate)
        if let status = selectionDetector?.statusText, !status.isEmpty { panel.showFeedback(status) }
        return candidate
    }

    private func endDetectionHover(displayID: CGDirectDisplayID) {
        guard detectionDisplayID == displayID else { return }
        selectionDetector?.invalidate()
        detectionDisplayID = nil
        panels.forEach { $0.setDetectionCandidate(nil) }
    }

    private func lockSelection(to displayID: CGDirectDisplayID) -> Bool {
        if let lockedDisplayID = lockedDisplayID { return lockedDisplayID == displayID }
        selectionDetector?.invalidate()
        detectionDisplayID = nil
        panels.forEach { $0.setDetectionCandidate(nil) }
        lockedDisplayID = displayID
        for panel in panels { panel.selectionLockedElsewhere = panel.displayID != displayID }
        return true
    }

    private func complete(snapshot: ScreenCaptureSnapshot, selection: CGRect, intent: Intent) {
        guard intent != .color, completion != nil, !isPerformingAction,
              let panel = panels.first(where: { $0.displayID == snapshot.displayID }), panel.workspace == nil,
              let pixels = snapshot.geometry.pixelRect(for: selection) else { return }
        do {
            let image = try ScreenCaptureImageRenderer.independentCrop(of: snapshot.image, pixels: pixels)
            let result = ToolImage(cgImage: image, title: "截图")
            panel.beginEditing(image: result, anchor: snapshot.geometry.appKitRect(forPixels: pixels),
                               action: { [weak self] action in self?.perform(action) },
                               reselect: { [weak self] in self?.reselect() },
                               cancel: { [weak self] in self?.cancel() },
                               willCopySelection: { [weak self] in self?.onWillCopySelection?() },
                               textInteraction: textInteractionFactory())
        } catch { finish(.failure(error)) }
    }

    private func reselect() {
        guard completion != nil, !isPerformingAction else { return }
        actionGeneration = UUID()
        selectionDetector?.invalidate()
        detectionDisplayID = nil
        lockedDisplayID = nil
        for panel in panels { panel.resetSelection() }
    }

    /// Output stays in this workspace until its asynchronous side effect succeeds.
    /// Save cancellation deliberately preserves the exact document and undo stack.
    private func perform(_ action: ScreenCaptureAction, feedback: String? = nil,
                         sourcePanel: ScreenCaptureOverlayPanel? = nil) {
        guard completion != nil, !isPerformingAction, let token else { return }
        let panel = panels.first(where: { $0.displayID == lockedDisplayID }) ?? sourcePanel
        let workspace = panel?.workspace
        guard let handler = onAction else {
            switch action {
            case .copyImage(let image), .saveImage(let image, _):
                guard let workspace, let panel else { return }
                finish(.success(.image(image, workspace.imageRect.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY))))
            case .pinImage(let image, let anchor): finish(.success(.image(image, anchor)))
            case .copyText, .copyRecognizedText:
                workspace?.showError("当前调用方不支持复制文字")
                sourcePanel?.showFeedback("当前调用方不支持复制文字")
            }
            return
        }
        isPerformingAction = true
        let generation = UUID()
        actionGeneration = generation
        workspace?.showError(nil)
        workspace?.setBusy(true)
        didHideForSavePanel = false
        let forwardedAction: ScreenCaptureAction
        if case let .saveImage(image, notify) = action {
            forwardedAction = .saveImage(image, willPresentPanel: { [weak self] in
                guard let self, self.token == token, self.actionGeneration == generation,
                      self.completion != nil else { return }
                notify()
                self.didHideForSavePanel = true
                // Quick saves never reach this callback or flash the desktop.
                for panel in self.panels { panel.orderOut(nil) }
            })
        } else { forwardedAction = action }
        actionTask = Task { @MainActor [weak self, weak workspace, weak sourcePanel] in
            do {
                let outcome = try await handler(forwardedAction)
                try Task.checkCancellation()
                guard let self, self.token == token, self.actionGeneration == generation,
                      self.completion != nil else { return }
                self.actionTask = nil
                self.isPerformingAction = false
                if outcome == .completed, action.endsCapture {
                    self.finish(.success(.completed))
                } else {
                    workspace?.setBusy(false)
                    panel?.restoreHeldPixelPreview()
                    if outcome == .completed, !action.endsCapture {
                        let message = feedback ?? "已复制文字"
                        if let workspace { workspace.showFeedback(message) }
                        else { sourcePanel?.showFeedback(message) }
                    }
                    if self.didHideForSavePanel { self.restoreAfterSave(token: token) }
                }
            } catch {
                guard let self, !Task.isCancelled, self.token == token,
                      self.actionGeneration == generation, self.completion != nil else { return }
                self.actionTask = nil
                self.isPerformingAction = false
                workspace?.setBusy(false)
                if !(error is CancellationError) {
                    workspace?.showError(error.localizedDescription)
                    if workspace == nil { sourcePanel?.showFeedback(error.localizedDescription) }
                }
                if self.didHideForSavePanel { self.restoreAfterSave(token: token) }
            }
        }
    }

    private func restoreAfterSave(token: UUID) {
        guard self.token == token, completion != nil else { return }
        didHideForSavePanel = false
        for panel in panels { panel.orderFrontRegardless() }
        let panel = panels.first(where: { $0.displayID == lockedDisplayID })
        panel?.makeKey()
        if let canvas = panel?.workspace?.canvas { panel?.makeFirstResponder(canvas) }
    }

    // Bound screen preparation, never the user's selection, edits, or save dialog.
    private func schedulePreparationTimeout(token: UUID) {
        timeout?.cancel()
        let sleep = timeoutSleep
        timeout = Task { [weak self] in
            do { try await sleep(20_000_000_000) } catch { return }
            guard !Task.isCancelled, let self = self, self.token == token else { return }
            self.finish(.failure(ScreenCaptureError.timedOut))
        }
    }

    private func finish(_ result: Swift.Result<Result?, Error>) {
        guard let continuation = completion else { return }
        completion = nil
        cleanUp()
        continuation.resume(with: result)
    }

    private func cleanUp() {
        selectionDetector?.cancel()
        selectionDetector = nil
        detectionDisplayID = nil
        actionGeneration = UUID()
        actionTask?.cancel()
        actionTask = nil
        isPerformingAction = false
        didHideForSavePanel = false
        onAction = nil
        timeout?.cancel()
        timeout = nil
        preparation?.cancel()
        preparation = nil
        provider?.cancel()
        provider = nil
        if let screenObserver = screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        if let eventMonitor = eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        for panel in panels { panel.releaseSnapshotAndClose() }
        panels.removeAll()
        lockedDisplayID = nil
    }
}
