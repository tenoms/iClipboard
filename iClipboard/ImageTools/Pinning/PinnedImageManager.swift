import AppKit

/// Owns pinned images independently of the history panel. Image callbacks use the
/// original ToolImage supplied to open; text-copy intent is delegated to the host.
/// No pasteboard or history writes happen here.
@MainActor
final class PinnedImageManager {
    var onCopy: ((ToolImage) -> Void)?
    var onSave: ((ToolImage) -> Void)?
    var onEdit: ((ToolImage) -> Void)?
    var onCopyFullText: ((@escaping @MainActor () async throws -> String) -> Void)?
    var onWillCopySelection: (() -> Void)?

    var count: Int { windows.count }

    private var windows: [UUID: PinnedImageWindowController] = [:]
    /// Oldest to most recently presented; contains only pins still owned here.
    private var orderedIDs: [UUID] = []
    private var suspensions: Set<UUID> = []
    private var restorationCandidates: Set<UUID> = []

    func open(_ image: ToolImage, anchor: CGRect? = nil) {
        let id = UUID()
        let controller = PinnedImageWindowController(image: image, anchor: anchor)
        controller.onCopyFullText = { [weak self] in self?.onCopyFullText?($0) }
        controller.onWillCopySelection = { [weak self] in self?.onWillCopySelection?() }
        controller.onClose = { [weak self] in
            self?.windows.removeValue(forKey: id)
            self?.orderedIDs.removeAll { $0 == id }
            self?.restorationCandidates.remove(id)
        }
        controller.onAction = { [weak self] action, image, _ in
            guard let self else { return }
            switch action {
            case .copy: self.onCopy?(image)
            case .save: self.onSave?(image)
            case .edit: self.onEdit?(image)
            }
        }
        controller.onPresent = { [weak self] in
            guard let self else { return }
            self.orderedIDs.removeAll { $0 == id }
            self.orderedIDs.append(id)
        }
        windows[id] = controller
        orderedIDs.append(id)
        if suspensions.isEmpty { controller.present() }
    }

    /// Copy follows keyboard focus only, never the pointer or last-presented pin.
    @discardableResult
    func copyFullTextFromFocusedPin(keyWindow: NSWindow? = nil) -> Bool {
        guard let controller = focusedController(keyWindow: keyWindow) else { return false }
        return controller.copyFullText()
    }

    func ownsFocusedPin(_ window: NSWindow) -> Bool {
        focusedController(keyWindow: window) != nil
    }

    @discardableResult
    func closeFocusedPin(keyWindow: NSWindow? = nil) -> Bool {
        guard let controller = focusedController(keyWindow: keyWindow) else { return false }
        controller.dispose()
        return true
    }

    private func focusedController(keyWindow: NSWindow?) -> PinnedImageWindowController? {
        guard suspensions.isEmpty, let focused = keyWindow ?? NSApp.keyWindow,
              NSApp.keyWindow === focused, focused.isKeyWindow, focused.isVisible else { return nil }
        return windows.values.first { $0.panel === focused }
    }

    /// Close one visible pin without activating it. Hover wins over keyboard
    /// focus, then the most recently presented visible pin is the fallback.
    /// Capture suspension makes this a no-op, including for pending restorations.
    func closeCurrent(mouseLocation: CGPoint? = nil, keyWindow: NSWindow? = nil) {
        guard suspensions.isEmpty else { return }
        let visible = windows.filter { $0.value.panel.isVisible }
        guard !visible.isEmpty else { return }
        let point = mouseLocation ?? NSEvent.mouseLocation
        let hovered = Dictionary(uniqueKeysWithValues: visible.compactMap { id, controller in
            controller.panel.frame.contains(point) ? (ObjectIdentifier(controller.panel), id) : nil
        })
        var targetID: UUID?
        if !hovered.isEmpty {
            // AppKit's onscreen app-only list includes nonactivating panels and
            // respects actual front order, including each pin's current level.
            NSApp.enumerateWindows(options: .orderedFrontToBack) { window, stop in
                guard let id = hovered[ObjectIdentifier(window)] else { return }
                targetID = id
                stop.pointee = true
            }
        }
        if targetID == nil, let focused = keyWindow ?? NSApp.keyWindow {
            targetID = visible.first { $0.value.panel === focused }?.key
        }
        if targetID == nil {
            targetID = orderedIDs.reversed().first { visible[$0] != nil }
        }
        if let targetID { windows[targetID]?.dispose() }
    }

    func closeAll() {
        let closing = Array(windows.values)
        windows.removeAll()
        orderedIDs.removeAll()
        restorationCandidates.removeAll()
        for controller in closing { controller.dispose() }
    }

    /// Hides all visible pins, or shows all pins when none is visible.
    /// Presentation commands cannot reveal windows while a capture is suspended.
    func toggleVisibility() {
        guard suspensions.isEmpty else { return }
        let shouldHide = windows.values.contains { $0.panel.isVisible }
        for id in orderedIDs {
            if shouldHide { windows[id]?.hide() }
            else { windows[id]?.present() }
        }
    }

    /// Hide visible pins during capture, including pins opened while suspended.
    /// Call the returned closure on the main actor when capture ends (also on cancel).
    /// It is idempotent, supports overlapping captures in either completion order,
    /// and never keeps this manager, its windows, or their images alive.
    func suspendPresentation() -> @MainActor () -> Void {
        let token = UUID()
        if suspensions.isEmpty {
            restorationCandidates = Set(windows.compactMap { id, controller in
                controller.panel.isVisible ? id : nil
            })
        }
        suspensions.insert(token)
        for controller in windows.values { controller.hide() }
        return { [weak self] in self?.resumePresentation(token) }
    }

    private func resumePresentation(_ token: UUID) {
        guard suspensions.remove(token) != nil, suspensions.isEmpty else { return }
        let candidates = orderedIDs.filter { restorationCandidates.contains($0) }
        restorationCandidates.removeAll()
        for id in candidates { windows[id]?.present() }
    }

    deinit {
        // Swift 5 deinitializers are nonisolated. Schedule AppKit teardown on
        // the main actor (also on macOS 13, where assumeIsolated is unavailable).
        // This captures only the windows, never the manager.
        let closing = Array(windows.values)
        Task { @MainActor in
            // A Swift concurrency job does not itself establish an autorelease
            // pool. Drain AppKit's temporary teardown references before returning.
            autoreleasepool {
                for controller in closing { controller.dispose() }
            }
        }
    }
}
