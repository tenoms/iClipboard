import AppKit
import ApplicationServices
import Foundation
import OSLog

struct SelectionGestureTracker {
    private var origin: CGPoint?
    private var processIdentifier: pid_t?
    private var dragged = false

    static func mayStartUserCopy(_ event: NSEvent) -> Bool {
        // A mouse-down may open/invoke a Copy menu. If a fallback is in flight,
        // clipboard ownership becomes ambiguous even without Command-C.
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) { return true }
        return event.type == .keyDown && event.modifierFlags.contains(.command)
            && ["c", "x"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "")
    }

    mutating func applicationDidActivate(_ pid: pid_t?) {
        // Clicking an inactive app can activate it between mouse-down and up.
        if processIdentifier != pid { reset() }
    }

    mutating func reset() {
        origin = nil
        processIdentifier = nil
        dragged = false
    }

    mutating func consume(
        type: NSEvent.EventType, point: CGPoint, clickCount: Int,
        shiftPressed: Bool, processIdentifier pid: pid_t
    ) -> Bool {
        switch type {
        case .leftMouseDown:
            origin = point
            processIdentifier = pid
            dragged = false
        case .leftMouseDragged:
            if let origin, processIdentifier == pid {
                dragged = dragged || hypot(point.x - origin.x, point.y - origin.y) >= 3
            }
        case .leftMouseUp:
            defer { reset() }
            guard let origin, processIdentifier == pid else { return false }
            return dragged || hypot(point.x - origin.x, point.y - origin.y) >= 3
                || clickCount >= 2 || shiftPressed
        default:
            reset()
        }
        return false
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
        let processIdentifier: pid_t
        let sourceApplicationName: String
        let sourceBundleIdentifier: String?
        let quartzPoint: CGPoint
        let appKitPoint: CGPoint
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
            if SelectionGestureTracker.mayStartUserCopy(event) {
                SelectionCopyFallback.shared.noteUserClipboardAction()
            }
            self?.handleEvent(type: type, quartzPoint: point, clickCount: clicks, shiftPressed: shift)
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
            self?.gesture.reset()
            self?.invalidateCapture()
            return event
        }
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    if name == NSWorkspace.activeSpaceDidChangeNotification {
                        self?.gesture.reset()
                    } else {
                        self?.gesture.applicationDidActivate(NSWorkspace.shared.frontmostApplication?.processIdentifier)
                    }
                    self?.invalidateCapture()
                    self?.onSelectionInvalidated?()
                    self?.prepareFrontmostApplication()
                }
            })
        }
        updateState(.running)
        prepareFrontmostApplication()
        Self.logger.info("Global selection monitor started")
        return true
    }

    func stop() {
        invalidateCapture()
        gesture.reset()
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
        guard state == .running, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              preparedProcessIdentifier != app.processIdentifier else { return }
        preparedProcessIdentifier = app.processIdentifier
        let pid = app.processIdentifier
        captureQueue.async { SystemSelectionAccessibility().prepare(AXUIElementCreateApplication(pid)) }
    }

    private func handleEvent(type: NSEvent.EventType, quartzPoint: CGPoint?, clickCount: Int, shiftPressed: Bool) {
        guard state == .running else { return }
        // A keyboard event is unrelated to where the pointer is hovering.
        // Handle it before the owned-surface hit test.
        guard type != .keyDown, let quartzPoint else {
            gesture.reset()
            invalidateCapture()
            onSelectionInvalidated?()
            return
        }
        let appKitPoint = Self.appKitPoint(fromQuartzPoint: quartzPoint)
        let isOwned = shouldIgnoreEventAtPoint?(appKitPoint) == true
        guard !isOwned, let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            gesture.reset()
            invalidateCapture()
            return
        }
        if type != .leftMouseUp && type != .leftMouseDragged {
            invalidateCapture()
            onSelectionInvalidated?()
        }
        if type == .leftMouseDown { prepareFrontmostApplication() }
        let isSelection = gesture.consume(
            type: type, point: quartzPoint, clickCount: clickCount,
            shiftPressed: shiftPressed, processIdentifier: application.processIdentifier
        )
        guard isSelection else { return }
        let target = CaptureTarget(
            processIdentifier: application.processIdentifier,
            sourceApplicationName: application.localizedName ?? "其他应用",
            sourceBundleIdentifier: application.bundleIdentifier,
            quartzPoint: quartzPoint, appKitPoint: appKitPoint
        )
        startCapture(target: target)
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
                        point: target.quartzPoint
                    )
                }
                guard self.isCurrent(target: target, token: token) else { return }
                switch result {
                case let .selected(selection):
                    self.deliver(selection: selection, target: target, token: token)
                    return
                case .blocked:
                    return
                case .unavailable:
                    continue
                }
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
