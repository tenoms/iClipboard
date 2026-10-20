import AppKit
import CoreData
import UniformTypeIdentifiers

@MainActor
protocol ScreenCapturing: AnyObject {
    var onWillCopySelection: (() -> Void)? { get set }
    var onContextualKeyEvent: ((NSEvent) -> Bool)? { get set }
    func run(_ intent: ScreenCaptureSession.Intent,
             onAction: ScreenCaptureActionHandler?) async throws -> ScreenCaptureSession.Result?
    func requestCurrentAction(_ action: ScreenCaptureCurrentAction)
    func canCopyRecognizedText(in window: NSWindow) -> Bool
    func cancel()
}

extension ScreenCaptureSession: ScreenCapturing {}

@MainActor
final class ImageToolsCoordinator: NSObject {
    enum Command: String {
        case capture, pinClipboard, recognizeScreen, closePin, togglePins, closePins
    }

    enum ImageAction { case copy, edit, pin, save }
    private enum Output { case copy, pin, save }
    private struct CopyTicket {
        let generation: UUID
        let changeCount: Int
    }

    private let store: ClipboardStore
    private let pasteboard: NSPasteboard
    private let windowManager: WindowManager
    private let captureSession: ScreenCapturing
    private let selectSaveURL: @MainActor (String) async throws -> URL?
    private let preferences: ImageToolsPreferences
    private let prepareImage: @Sendable (ToolImage) throws -> CapturedPayload
    private let pins = PinnedImageManager()
    private var editors: [UUID: ImageEditorController] = [:]
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var captureTask: Task<Void, Never>?
    private var committedImages: [String: NSManagedObjectID] = [:]
    private struct HistoryImageReference {
        weak var image: CGImage?
        let id: NSManagedObjectID
    }
    private var historyImages: [ObjectIdentifier: HistoryImageReference] = [:]
    private var copyGeneration = UUID()
    private var stopped = false
    private var presentationSuspended = false
    private var pendingPresentations: [() -> Void] = []
    private var ordinarySaveCount = 0
    private var pendingCapture = false
    private let shortcutMonitor = ImageToolsShortcutMonitor()

    init(store: ClipboardStore, windowManager: WindowManager, pasteboard: NSPasteboard = .general,
         captureSession: ScreenCapturing? = nil,
         selectSaveURL: (@MainActor (String) async throws -> URL?)? = nil,
         preferences: ImageToolsPreferences? = nil,
         prepareImage: @escaping @Sendable (ToolImage) throws -> CapturedPayload = {
             .image(data: try $0.pngData(), title: $0.title)
         }) {
        self.store = store
        self.pasteboard = pasteboard
        self.windowManager = windowManager
        self.captureSession = captureSession ?? ScreenCaptureSession()
        let preferences = preferences ?? ImageToolsPreferences.shared
        self.preferences = preferences
        self.prepareImage = prepareImage
        self.selectSaveURL = selectSaveURL ?? { name in
            try await ImageSaveDestination.choose(name: name, preferences: preferences)
        }
        super.init()
        self.captureSession.onWillCopySelection = { [weak self] in _ = self?.beginCopy() }
        pins.onCopy = { [weak self] in self?.output($0, as: .copy) }
        pins.onSave = { [weak self] in self?.output($0, as: .save) }
        pins.onEdit = { [weak self] in self?.edit($0) }
        pins.onCopyFullText = { [weak self] in self?.copyText($0) }
        pins.onWillCopySelection = { [weak self] in _ = self?.beginCopy() }
    }

    func start(hotKeyManager: HotKeyManager? = nil) {
        let keys = hotKeyManager ?? .shared
        keys.setHandler(for: .capture) { [weak self] in self?.perform(.capture) }
        keys.setHandler(for: .pinClipboard) { [weak self] in self?.perform(.pinClipboard) }
        keys.setHandler(for: .recognizeScreen) { [weak self] in self?.perform(.recognizeScreen) }
        keys.setHandler(for: .closePin) { [weak self] in _ = self?.pins.closeFocusedPin() }
        captureSession.onContextualKeyEvent = { [weak self, weak keys] event in
            guard let self, let keys else { return false }
            return self.handleContextualShortcut(event, keys: keys)
        }
        shortcutMonitor.stop()
        shortcutMonitor.token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak keys] event in
            guard let self, let keys, self.captureTask == nil else { return event }
            return self.handleContextualShortcut(event, keys: keys) ? nil : event
        }
    }

    private func handleContextualShortcut(_ event: NSEvent, keys: HotKeyManager) -> Bool {
        guard !stopped, let action = keys.contextualAction(for: event),
              let window = event.window, window.isKeyWindow, window.isVisible,
              NSApp.keyWindow === window else { return false }
        switch action {
        case .recognizeScreen:
            if captureTask != nil {
                guard captureSession.canCopyRecognizedText(in: window) else { return false }
            } else {
                guard pins.ownsFocusedPin(window) else { return false }
            }
            if !event.isARepeat { perform(.recognizeScreen) }
            return true
        case .closePin:
            guard captureTask == nil, pins.ownsFocusedPin(window) else { return false }
            if !event.isARepeat { _ = pins.closeFocusedPin(keyWindow: window) }
            return true
        default: return false
        }
    }

    func perform(_ command: Command) {
        guard !stopped else { return }
        switch command {
        case .capture: capture()
        case .recognizeScreen:
            // Capture always owns this shortcut, including preparation/no crop.
            // Outside capture, only the key visible pin may copy its full text.
            if captureTask != nil {
                captureSession.requestCurrentAction(.copyRecognizedText)
            } else {
                _ = pins.copyFullTextFromFocusedPin()
            }
        case .pinClipboard:
            if captureTask != nil {
                captureSession.requestCurrentAction(.pin)
                return
            }
            guard let snapshot = ClipboardCaptureSnapshot(pasteboard: pasteboard, enabledTypes: [.image]) else { return }
            run { [weak self] in
                let image = try await Task.detached(priority: .userInitiated) {
                    let data = snapshot.data(forType: .png) ?? snapshot.data(forType: .tiff)
                        ?? snapshot.fileURLs.first.flatMap { try? Data(contentsOf: $0) }
                    guard let data else { throw ImageToolsError.noImage }
                    return try ToolImage.decode(data, title: "剪贴板图片")
                }.value
                try Task.checkCancellation()
                self?.output(image, as: .pin)
            }
        case .closePin: pins.closeCurrent()
        case .togglePins: pins.toggleVisibility()
        case .closePins: pins.closeAll()
        }
    }

    func perform(_ action: ImageAction, on entry: ClipboardEntry, completion: (() -> Void)? = nil) {
        guard !stopped else { return }
        if case .save = action, deferUntilCaptureEnds({ [weak self] in
            self?.perform(action, on: entry, completion: completion)
        }) { return }
        let isSave: Bool
        if case .save = action { isSave = true; ordinarySaveCount += 1 } else { isSave = false }
        let ticket: CopyTicket?
        if case .copy = action { ticket = beginCopy() } else { ticket = nil }
        run { [weak self] in
            guard let self else { return }
            defer { if isSave { self.finishOrdinarySave() } }
            let image = try await self.store.loadImage(for: entry)
            try Task.checkCancellation()
            guard !self.stopped else { return }
            // Opening an image never needs PNG encoding, a new thumbnail or a hash.
            // Weak identity also lets an unchanged pin/editor output reuse its record.
            if self.historyImages.count >= 64 { self.historyImages = self.historyImages.filter { $0.value.image != nil } }
            if self.historyImages.count >= 64 { self.historyImages.removeAll() }
            self.historyImages[ObjectIdentifier(image.cgImage)] = HistoryImageReference(image: image.cgImage, id: entry.id)
            switch action {
            case .copy: self.output(image, as: .copy, didComplete: completion, copyTicket: ticket, sourceFileURL: entry.fileURL)
            case .edit: self.edit(image)
            case .pin: self.openPin(image)
            case .save: self.output(image, as: .save)
            }
        }
    }

    func makeMenuItems() -> [NSMenuItem] {
        let specifications: [(String, String, Command)] = [
            ("区域截图…", "viewfinder", .capture),
            ("贴出剪贴板图片", "pin", .pinClipboard),
            ("关闭贴图", "xmark", .closePin),
            ("显示 / 隐藏全部贴图", "eye", .togglePins),
            ("关闭全部贴图", "xmark.rectangle", .closePins)
        ]
        return specifications.map { title, symbol, command in
            let item = NSMenuItem(title: title, action: #selector(menuCommand(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command.rawValue
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            if command == .togglePins || command == .closePins || command == .closePin {
                item.isEnabled = pins.count > 0
            }
            return item
        }
    }

    @objc private func menuCommand(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let command = Command(rawValue: value) else { return }
        // Wait for menu tracking to end before displaying a capture overlay.
        DispatchQueue.main.async { [weak self] in self?.perform(command) }
    }

    private func capture() {
        guard captureTask == nil else { return }
        guard ordinarySaveCount == 0 else { pendingCapture = true; return }
        pendingCapture = false
        guard !NSApp.windows.contains(where: { $0.isVisible && $0.attachedSheet != nil }),
              NSApp.modalWindow == nil else {
            showError("请先完成当前保存或确认对话框，再开始截图。")
            return
        }
        captureTask = Task { [weak self] in
            guard let self else { return }
            let restore = self.suspendPresentation()
            let result: ScreenCaptureSession.Result?
            do {
                result = try await self.captureSession.run(.image, onAction: { [weak self] action in
                    guard let self, !self.stopped else { throw CancellationError() }
                    return try await self.performCaptureAction(action)
                })
            } catch {
                self.captureTask = nil
                restore()
                if !(error is CancellationError), !self.stopped { self.showError(error.localizedDescription) }
                return
            }
            self.captureTask = nil
            restore()
            guard !Task.isCancelled, !self.stopped, let result else { return }
            switch result {
            case let .image(image, _): self.output(image, as: .copy)
            case .completed: break
            case let .color(color): self.copyText(color.hex)
            }
        }
    }

    private func suspendPresentation() -> () -> Void {
        presentationSuspended = true
        let restores = [
            windowManager.suspendPresentation(),
            TranslationCoordinator.shared.suspendSelectionMonitoring(),
            TranslationCoordinator.shared.suspendPresentation(),
            NotchDropManager.shared.suspendPresentation(),
            pins.suspendPresentation()
        ]
        let visible = editors.values.compactMap(\.window).filter(\.isVisible)
        visible.forEach { $0.orderOut(nil) }
        var restored = false
        return { [weak self] in
            guard !restored else { return }
            restored = true
            restores.reversed().forEach { $0() }
            guard let self, !self.stopped else { return }
            self.presentationSuspended = false
            let owned = self.editors.values.compactMap(\.window)
            visible.forEach { window in
                if owned.contains(where: { $0 === window }), window.contentView != nil { window.orderFrontRegardless() }
            }
            let pending = self.pendingPresentations
            self.pendingPresentations.removeAll()
            pending.forEach { $0() }
        }
    }

    private func deferUntilCaptureEnds(_ presentation: @escaping () -> Void) -> Bool {
        guard captureTask != nil || presentationSuspended else { return false }
        pendingPresentations.append(presentation)
        return true
    }

    private func finishOrdinarySave() {
        ordinarySaveCount -= 1
        if ordinarySaveCount == 0, pendingCapture, !stopped { capture() }
    }

    private func openPin(_ image: ToolImage, anchor: CGRect? = nil) {
        guard !presentationSuspended else {
            pendingPresentations.append { [weak self] in self?.openPin(image, anchor: anchor) }
            return
        }
        pins.open(image, anchor: anchor)
    }

    private func edit(_ image: ToolImage) {
        guard !presentationSuspended else {
            pendingPresentations.append { [weak self] in self?.edit(image) }
            return
        }
        let id = UUID()
        let editor = ImageEditorController(image: image)
        editor.onCopy = { [weak self] in self?.output($0, as: .copy) }
        editor.onSave = { [weak self, weak editor] image in
            self?.output(image, as: .save, saveFinished: { editor?.finishSave(image: image, succeeded: $0) })
        }
        editor.onCopyColor = { [weak self] in self?.copyText($0.hex) }
        editor.onPin = { [weak self] in self?.output($0, as: .pin) }
        editor.onClose = { [weak self] in self?.editors.removeValue(forKey: id) }
        editors[id] = editor
        editor.present()
    }

    private func prepare(_ image: ToolImage) async throws -> CapturedPayload {
        let prepareImage = self.prepareImage
        return try await Task.detached(priority: .userInitiated) {
            try autoreleasepool { try prepareImage(image) }
        }.value
    }

    private func output(_ image: ToolImage, as output: Output,
                        saveFinished: ((Bool) -> Void)? = nil, didComplete: (() -> Void)? = nil,
                        copyTicket: CopyTicket? = nil, sourceFileURL: URL? = nil) {
        guard !stopped else { saveFinished?(false); return }
        if case .save = output, deferUntilCaptureEnds({ [weak self] in
            self?.output(image, as: output, saveFinished: saveFinished, didComplete: didComplete,
                         copyTicket: copyTicket, sourceFileURL: sourceFileURL)
        }) { return }
        let isSave: Bool
        if case .save = output { isSave = true; ordinarySaveCount += 1 } else { isSave = false }
        let ticket: CopyTicket?
        if case .copy = output { ticket = copyTicket ?? beginCopy() } else { ticket = nil }
        run { [weak self] in
            var savedFile = false
            defer { saveFinished?(savedFile) }
            guard let self else { return }
            defer { if isSave { self.finishOrdinarySave() } }
            let result = try await self.writeImage(image, as: output, copyTicket: ticket,
                                                   sourceFileURL: sourceFileURL, didSaveFile: { savedFile = true })
            if case .completed = result { didComplete?() }
        }
    }

    func performCaptureAction(_ action: ScreenCaptureAction) async throws -> ScreenCaptureActionOutcome {
        guard !stopped else { throw CancellationError() }
        switch action {
        case let .copyImage(image):
            return try await writeImage(image, as: .copy, copyTicket: beginCopy())
        case let .saveImage(image, willPresentPanel):
            return try await writeImage(image, as: .save, willPresentSavePanel: willPresentPanel)
        case let .pinImage(image, anchor):
            return try await writeImage(image, as: .pin, anchor: anchor)
        case let .copyText(text):
            return try await writeText(text, ticket: beginCopy())
        case let .copyRecognizedText(readText):
            return try await writeRecognizedText(readText, ticket: beginCopy())
        }
    }

    private func writeImage(_ image: ToolImage, as output: Output, copyTicket: CopyTicket? = nil,
                            anchor: CGRect? = nil, sourceFileURL: URL? = nil, didSaveFile: (() -> Void)? = nil,
                            willPresentSavePanel: @escaping @MainActor () -> Void = {}) async throws -> ScreenCaptureActionOutcome {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        // Freeze the destination and timestamp before encoding suspends this action.
        let saveRequest: ImageSaveRequest?
        if case .save = output { saveRequest = ImageSaveDestination.request(preferences: preferences) }
        else { saveRequest = nil }
        let payload = try await prepare(image)
        try Task.checkCancellation()
        guard let data = payload.originalImageData else { throw ImageToolsError.encodingFailed }
        var savedFile = false
        if let saveRequest {
            guard try await ImageSaveDestination.savePNG(data, request: saveRequest,
                                                         chooseURL: selectSaveURL,
                                                         willPresentPanel: willPresentSavePanel) != nil else {
                return .cancelled
            }
            savedFile = true
            didSaveFile?()
        }
        if !savedFile {
            try Task.checkCancellation()
            guard !stopped else { throw CancellationError() }
        }
        do {
            if let reference = historyImages[ObjectIdentifier(image.cgImage)], reference.image === image.cgImage,
               store.containsInHistory(reference.id) {
                if let digest = payload.imageDigest { remember(digest, id: reference.id) }
            } else if let digest = payload.imageDigest,
               let existing = committedImages[digest], store.containsInHistory(existing) {
                // This document version has already been committed.
            } else {
                let id = try await store.submit(payload)
                if let digest = payload.imageDigest { remember(digest, id: id) }
            }
        } catch {
            if savedFile { throw ImageOutputError.savedFileButHistoryFailed(error.localizedDescription) }
            throw error
        }
        if !savedFile { try Task.checkCancellation() }
        switch output {
        case .copy:
            guard let copyTicket, canCompleteCopy(copyTicket) else { return .cancelled }
            if pasteboard.name == NSPasteboard.general.name {
                SelectionCopyFallback.shared.noteUserClipboardAction()
            }
            let item = ToolImage.pasteboardItem(pngData: data, sourceFileURL: sourceFileURL)
            pasteboard.clearContents()
            guard pasteboard.writeObjects([item]) else { throw ImageToolsError.clipboardWriteFailed }
            if pasteboard.name == NSPasteboard.general.name { store.ignoreProgrammaticCopy() }
        case .pin: openPin(image, anchor: anchor)
        case .save: break
        }
        return .completed
    }

    private func remember(_ digest: String, id: NSManagedObjectID) {
        if committedImages.count >= 64 { committedImages.removeAll() }
        committedImages[digest] = id
    }

    private func beginCopy() -> CopyTicket {
        copyGeneration = UUID()
        if pasteboard.name == NSPasteboard.general.name {
            SelectionCopyFallback.shared.noteUserClipboardAction()
        }
        return CopyTicket(generation: copyGeneration, changeCount: pasteboard.changeCount)
    }

    private func canCompleteCopy(_ ticket: CopyTicket) -> Bool {
        !stopped && ticket.generation == copyGeneration && pasteboard.changeCount == ticket.changeCount
    }

    private func copyText(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let ticket = beginCopy()
        run { [weak self] in _ = try await self?.writeText(text, ticket: ticket) }
    }

    private func copyText(_ readText: @escaping @MainActor () async throws -> String) {
        guard !stopped else { return }
        // Claim the clipboard intent synchronously, before OCR or a queued task
        // can yield to a newer user copy. Never rebuild this ticket after OCR.
        let ticket = beginCopy()
        run { [weak self] in
            guard let self else { return }
            _ = try await self.writeRecognizedText(readText, ticket: ticket)
        }
    }

    private func writeRecognizedText(_ readText: @MainActor () async throws -> String,
                                     ticket: CopyTicket) async throws -> ScreenCaptureActionOutcome {
        try Task.checkCancellation()
        let text = try await readText()
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImageOutputError.noRecognizedText
        }
        return try await writeText(text, ticket: ticket)
    }

    private func writeText(_ text: String, ticket: CopyTicket) async throws -> ScreenCaptureActionOutcome {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .cancelled }
        try Task.checkCancellation()
        _ = try await store.submit(CapturedPayload(kind: .text, content: text,
                                                  rtfData: nil, fileURL: nil, imageData: nil))
        try Task.checkCancellation()
        guard canCompleteCopy(ticket) else { return .cancelled }
        if pasteboard.name == NSPasteboard.general.name {
            SelectionCopyFallback.shared.noteUserClipboardAction()
        }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { throw ImageToolsError.clipboardWriteFailed }
        if pasteboard.name == NSPasteboard.general.name { store.ignoreProgrammaticCopy() }
        return .completed
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !stopped else { return }
        let id = UUID()
        jobs[id] = Task { [weak self] in
            defer { self?.jobs.removeValue(forKey: id) }
            do { try await operation() }
            catch is CancellationError { }
            catch { if self?.stopped == false { self?.showError(error.localizedDescription) } }
        }
    }

    private func showError(_ message: String) {
        guard !stopped else { return }
        if deferUntilCaptureEnds({ [weak self] in self?.showError(message) }) { return }
        let alert = NSAlert()
        alert.messageText = "图像工具"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    func stop() {
        stopped = true
        shortcutMonitor.stop()
        captureSession.onContextualKeyEvent = nil
        pendingCapture = false
        captureTask?.cancel()
        captureSession.cancel()
        jobs.values.forEach { $0.cancel() }
        jobs.removeAll()
        Array(editors.values).forEach { $0.window?.orderOut(nil); $0.window?.contentView = nil }
        editors.removeAll()
        pins.closeAll()
        committedImages.removeAll()
        historyImages.removeAll()
        pendingPresentations.removeAll()
    }
}

/// Keep the native token independent of actor deinitialization; the monitor's
/// callback holds the coordinator weakly and stop() removes it synchronously.
private final class ImageToolsShortcutMonitor {
    var token: Any?

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }

    deinit { stop() }
}
