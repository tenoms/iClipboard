import AppKit
import ApplicationServices
import Foundation
import OSLog

struct SelectionGestureTracker {
    private var origin: CGPoint?
    private var dragged = false

    /// A mouse-down started a gesture whose release has not arrived yet.
    var isTracking: Bool { origin != nil }

    static func mayStartUserCopy(_ event: NSEvent) -> Bool {
        // A mouse-down may open/invoke a Copy menu. If a fallback is in flight,
        // clipboard ownership becomes ambiguous even without Command-C.
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) { return true }
        return event.type == .keyDown && event.modifierFlags.contains(.command)
            && ["c", "x"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "")
    }

    mutating func reset() {
        origin = nil
        dragged = false
    }

    /// Returns the press location when a release completes a selection gesture.
    mutating func consume(
        type: NSEvent.EventType, point: CGPoint, clickCount: Int, shiftPressed: Bool
    ) -> CGPoint? {
        switch type {
        case .leftMouseDown:
            origin = point
            dragged = false
        case .leftMouseDragged:
            if let origin, !dragged {
                dragged = hypot(point.x - origin.x, point.y - origin.y) >= 3
            }
        case .scrollWheel:
            // Scrolling with the button held moves text under the pointer,
            // extending the selection even when the pointer stays put.
            if origin != nil { dragged = true }
        case .leftMouseUp:
            defer { reset() }
            guard let origin else { return nil }
            let isSelection = dragged || hypot(point.x - origin.x, point.y - origin.y) >= 3
                || clickCount >= 2 || shiftPressed
            return isSelection ? origin : nil
        default:
            reset()
        }
        return nil
    }
}

/// Window-server facts about the window a mouse-down hits. Owner, layer and bounds
/// need no Screen Recording permission; window titles are never read.
enum SelectionSourceWindow {
    static func hit(at appKitPoint: CGPoint) -> CaptureDetectionWindow? {
        // Unlike the on-screen window list, this skips click-through overlays and
        // returns the window a mouse-down here actually reaches, in any app.
        let number = NSWindow.windowNumber(at: appKitPoint, belowWindowWithWindowNumber: 0)
        guard number > 0, let window = lookup(CGWindowID(number)), isSelectable(window) else { return nil }
        return window
    }

    /// Moving, resizing, zooming or closing the window means the gesture was not a text selection.
    static func isUnchanged(_ window: CaptureDetectionWindow) -> Bool {
        lookup(window.windowID)?.frame == window.frame
    }

    /// Desktop icons, Dock, menu bar and status items are not text surfaces.
    static func isSelectable(_ window: CaptureDetectionWindow) -> Bool {
        window.layer >= 0 && window.layer < Int(CGWindowLevelForKey(.dockWindow))
    }

    private static func lookup(_ id: CGWindowID) -> CaptureDetectionWindow? {
        guard let descriptions = CGWindowListCopyWindowInfo([.optionIncludingWindow], id)
            as? [[String: Any]] else { return nil }
        // Own windows are excluded; their events never reach the global monitor anyway.
        return CaptureDetectionWindow.parse(
            descriptions,
            excludingPID: ProcessInfo.processInfo.processIdentifier,
            coordinates: CaptureDetectionCoordinates(primaryHeight: NSScreen.screens.first?.frame.maxY ?? 0)
        ).first
    }
}

final class SelectionCaptureState: @unchecked Sendable {
    private let lock = NSLock()
    private var token: UUID?

    func replaceToken() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let newToken = UUID()
        token = newToken
        return newToken
    }

    func isActive(_ candidate: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return token == candidate
    }

    func finish(_ candidate: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if token == candidate { token = nil }
    }

    func invalidate() {
        lock.lock()
        token = nil
        lock.unlock()
    }
}

@MainActor
final class GlobalTextSelectionMonitor {
    enum State: Equatable {
        case stopped
        case running
        case accessibilityPermissionMissing
        case eventMonitorUnavailable
    }

    var onSelection: ((SelectedTextContext) -> Void)?
    var onStateChange: ((State) -> Void)?
    var onSelectionInvalidated: (() -> Void)?
    var shouldIgnoreEventAtPoint: ((CGPoint) -> Bool)?

    private struct CaptureTarget: Sendable {
        let window: CaptureDetectionWindow
        let sourceApplicationName: String
        let sourceBundleIdentifier: String?
        let originQuartzPoint: CGPoint
        let quartzPoint: CGPoint
        let appKitPoint: CGPoint
        let clickCount: Int

        var processIdentifier: pid_t { window.ownerPID }
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.tenom.iClipboard",
        category: "GlobalTextSelection"
    )
    private let captureQueue = DispatchQueue(
        label: "com.tenom.iClipboard.translation-selection", qos: .userInitiated
    )
    private let captureState = SelectionCaptureState()
    private var globalMouseMonitor: Any?
    private var localEventMonitor: Any?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var captureTask: Task<Void, Never>?
    private var gesture = SelectionGestureTracker()
    /// The window hit by the pending gesture's mouse-down.
    private var gestureWindow: CaptureDetectionWindow?
    /// The app owning the latest gesture, capture or shown selection.
    private var sourceProcessIdentifier: pid_t?
    private var preparedProcessIdentifier: pid_t?
    private(set) var state: State = .stopped

    var isRunning: Bool { globalMouseMonitor != nil && state == .running }

    @discardableResult
    func start() -> Bool {
        guard globalMouseMonitor == nil else { return true }
        guard AXIsProcessTrusted() else {
            updateState(.accessibilityPermissionMissing)
            return false
        }
        let events: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseDragged, .leftMouseUp,
            .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown
        ]
        guard let monitor = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] event in
            let type = event.type
            let point = event.cgEvent?.location
            let clicks = type == .leftMouseDown || type == .leftMouseUp ? event.clickCount : 0
            let shift = event.modifierFlags.contains(.shift)
            let momentum = type == .scrollWheel && !event.momentumPhase.isEmpty
            if SelectionGestureTracker.mayStartUserCopy(event) {
                SelectionCopyFallback.shared.noteUserClipboardAction()
            }
            self?.handleEvent(
                type: type, quartzPoint: point, clickCount: clicks,
                shiftPressed: shift, isMomentumScroll: momentum
            )
        }) else {
            updateState(.eventMonitorUnavailable)
            return false
        }
        globalMouseMonitor = monitor
        // Nonactivating translation panels receive local events even while the
        // source application remains frontmost. Cancel in-flight captures there.
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            if SelectionGestureTracker.mayStartUserCopy(event) {
                SelectionCopyFallback.shared.noteUserClipboardAction()
            }
            self?.resetGesture()
            self?.invalidateCapture()
            return event
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = application?.processIdentifier
            Task { @MainActor [weak self] in self?.applicationDidActivate(pid) }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancelSelection()
                self?.prepareFrontmostApplication()
            }
        })
        updateState(.running)
        prepareFrontmostApplication()
        Self.logger.info("Global selection monitor started")
        return true
    }

    func stop() {
        invalidateCapture()
        resetGesture()
        sourceProcessIdentifier = nil
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        globalMouseMonitor = nil
        localEventMonitor = nil
        preparedProcessIdentifier = nil
        updateState(.stopped)
    }

    private func updateState(_ newState: State) {
        guard state != newState else { return }
        state = newState
        onStateChange?(newState)
    }

    private func prepareFrontmostApplication() {
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier { prepare(pid) }
    }

    private func prepare(_ pid: pid_t) {
        guard state == .running, pid != ProcessInfo.processInfo.processIdentifier,
              preparedProcessIdentifier != pid else { return }
        preparedProcessIdentifier = pid
        captureQueue.async { SystemSelectionAccessibility().prepare(AXUIElementCreateApplication(pid)) }
    }

    private func applicationDidActivate(_ pid: pid_t?) {
        // Clicking an inactive window activates its app during, or just after,
        // the gesture. That activation belongs to the selection; others cancel it.
        if pid == nil || pid != sourceProcessIdentifier {
            sourceProcessIdentifier = nil
            cancelSelection()
        }
        prepareFrontmostApplication()
    }

    private func handleEvent(
        type: NSEvent.EventType, quartzPoint: CGPoint?, clickCount: Int,
        shiftPressed: Bool, isMomentumScroll: Bool
    ) {
        guard state == .running else { return }
        // A keyboard event is unrelated to where the pointer is hovering.
        // Handle it before the owned-surface hit test.
        guard type != .keyDown, let quartzPoint else {
            cancelSelection()
            return
        }
        // Until release, drags and scrolls belong to the gesture a mouse-down
        // started in another app, wherever the pointer travels meanwhile.
        let continuesGesture = gesture.isTracking
            && [.leftMouseDragged, .scrollWheel, .leftMouseUp].contains(type)
        // Momentum only continues a scroll whose earlier events already
        // dismissed older selections; it must not cancel a newer one.
        if isMomentumScroll, !continuesGesture { return }
        let appKitPoint = Self.appKitPoint(fromQuartzPoint: quartzPoint)
        guard continuesGesture || shouldIgnoreEventAtPoint?(appKitPoint) != true else {
            resetGesture()
            invalidateCapture()
            return
        }
        switch type {
        case .leftMouseDown:
            invalidateCapture()
            onSelectionInvalidated?()
            // Identify the source by the window hit, not the frontmost app: an
            // inactive app is activated only after this mouse-down reaches it.
            gestureWindow = SelectionSourceWindow.hit(at: appKitPoint)
            sourceProcessIdentifier = gestureWindow?.ownerPID
            guard let gestureWindow else {
                gesture.reset()
                return
            }
            prepare(gestureWindow.ownerPID)
            _ = gesture.consume(type: type, point: quartzPoint, clickCount: clickCount, shiftPressed: shiftPressed)
        case .leftMouseDragged:
            _ = gesture.consume(type: type, point: quartzPoint, clickCount: clickCount, shiftPressed: shiftPressed)
        case .scrollWheel where continuesGesture:
            _ = gesture.consume(type: type, point: quartzPoint, clickCount: clickCount, shiftPressed: shiftPressed)
        case .leftMouseUp:
            let window = gestureWindow
            gestureWindow = nil
            guard let origin = gesture.consume(
                type: type, point: quartzPoint, clickCount: clickCount, shiftPressed: shiftPressed
            ), let window, SelectionSourceWindow.isUnchanged(window) else { return }
            let application = NSRunningApplication(processIdentifier: window.ownerPID)
            startCapture(target: CaptureTarget(
                window: window,
                sourceApplicationName: application?.localizedName ?? "其他应用",
                sourceBundleIdentifier: application?.bundleIdentifier,
                originQuartzPoint: origin, quartzPoint: quartzPoint, appKitPoint: appKitPoint,
                clickCount: clickCount
            ))
        default:
            cancelSelection()
        }
    }

    private func startCapture(target: CaptureTarget) {
        invalidateCapture()
        let token = captureState.replaceToken()
        let captureState = captureState
        captureTask = Task { [weak self] in
            guard let self else { return }
            defer { captureState.finish(token) }
            // One task owns all retries and fallback. Cancellation cannot leave
            // another scheduled attempt that reopens a dismissed button.
            var lastResult = SelectionResolution.unavailable
            for delay in [70, 120, 200] {
                do { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000) }
                catch { return }
                guard self.isCurrent(target: target, token: token) else { return }
                let result = await self.onCaptureQueue {
                    let deadline = CFAbsoluteTimeGetCurrent() + 0.35
                    return SelectionAccessibilityResolver(
                        reader: SystemSelectionAccessibility(),
                        shouldContinue: { captureState.isActive(token) && CFAbsoluteTimeGetCurrent() < deadline }
                    ).resolve(
                        application: AXUIElementCreateApplication(target.processIdentifier),
                        point: target.quartzPoint,
                        origin: target.originQuartzPoint
                    )
                }
                guard self.isCurrent(target: target, token: token) else { return }
                switch result {
                case let .selected(selection):
                    self.deliver(selection: selection, target: target, token: token)
                    return
                case .blocked:
                    return
                case .unavailable, .elsewhere:
                    lastResult = result
                }
            }

            // Copy acts on the app's current selection. When AX still places it away
            // from this gesture, copying would surface that old text, not this gesture's.
            guard lastResult == .unavailable else {
                Self.logger.debug("Selection is elsewhere pid=\(target.processIdentifier, privacy: .public)")
                return
            }
            // A terminal program drew this selection itself; the app has nothing to copy.
            let covered = await self.onCaptureQueue {
                let deadline = CFAbsoluteTimeGetCurrent() + 0.35
                return GestureTextResolver(
                    reader: SystemSelectionAccessibility(),
                    shouldContinue: { captureState.isActive(token) && CFAbsoluteTimeGetCurrent() < deadline }
                ).resolve(
                    application: AXUIElementCreateApplication(target.processIdentifier),
                    origin: target.originQuartzPoint, point: target.quartzPoint, clickCount: target.clickCount
                )
            }
            guard self.isCurrent(target: target, token: token) else { return }
            if let covered {
                self.deliver(selection: covered, target: target, token: token)
                return
            }
            let text = await SelectionCopyFallback.shared.capture(isValid: {
                self.isCurrent(target: target, token: token)
            }, performCopy: {
                await self.onCaptureQueue {
                    SelectionCopyMenu.performCopy(processIdentifier: target.processIdentifier) {
                        captureState.isActive(token)
                    }
                }
            })
            guard self.isCurrent(target: target, token: token) else { return }
            if let text {
                self.deliver(selection: ResolvedTextSelection(text: text, bounds: nil), target: target, token: token)
            } else {
                Self.logger.debug("No readable selection pid=\(target.processIdentifier, privacy: .public)")
            }
        }
    }

    private func onCaptureQueue<Value>(_ operation: @escaping () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            captureQueue.async { continuation.resume(returning: operation()) }
        }
    }

    private func isCurrent(target: CaptureTarget, token: UUID) -> Bool {
        !Task.isCancelled && state == .running && captureState.isActive(token)
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
            // Double-clicking a title bar zooms the window only after mouse-up.
            && SelectionSourceWindow.isUnchanged(target.window)
    }

    private func deliver(selection: ResolvedTextSelection, target: CaptureTarget, token: UUID) {
        // Keep the generation alive until delivery on the main actor. A result
        // queued before a new mouse-down/app switch must not reopen the button.
        guard isCurrent(target: target, token: token) else { return }
        captureState.finish(token)
        let anchorRect = selection.bounds.map(Self.appKitRect(fromQuartzRect:))
            .flatMap { Self.isUsable(rect: $0, near: target.appKitPoint) ? $0 : nil }
            ?? CGRect(origin: target.appKitPoint, size: CGSize(width: 1, height: 1))
        onSelection?(SelectedTextContext(
            text: selection.text, anchorRect: anchorRect, cursorPoint: target.appKitPoint,
            sourceApplicationName: target.sourceApplicationName,
            sourceBundleIdentifier: target.sourceBundleIdentifier
        ))
    }

    private func invalidateCapture() {
        captureState.invalidate()
        captureTask?.cancel()
        captureTask = nil
    }

    private func resetGesture() {
        gesture.reset()
        gestureWindow = nil
    }

    /// Ends the pending gesture and capture, and dismisses the shown selection.
    private func cancelSelection() {
        resetGesture()
        invalidateCapture()
        onSelectionInvalidated?()
    }

    private static func appKitPoint(fromQuartzPoint point: CGPoint) -> CGPoint {
        guard let primaryScreen = NSScreen.screens.first else { return point }
        return CGPoint(x: point.x, y: primaryScreen.frame.maxY - point.y)
    }

    private static func appKitRect(fromQuartzRect rect: CGRect) -> CGRect {
        guard let primaryScreen = NSScreen.screens.first else { return rect }
        return CGRect(x: rect.minX, y: primaryScreen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func isUsable(rect: CGRect, near point: CGPoint) -> Bool {
        rect.width > 0 && rect.height > 0 && rect.width.isFinite && rect.height.isFinite
            && rect.minX.isFinite && rect.minY.isFinite
            && hypot(rect.midX - point.x, rect.midY - point.y) < 1_800
    }
}
