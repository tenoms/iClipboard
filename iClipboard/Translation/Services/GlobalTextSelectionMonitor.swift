import AppKit
import ApplicationServices
import Foundation
import OSLog

struct SelectionEventFilter {
    static func shouldCapture(
        type: NSEvent.EventType,
        isInsideOwnedSurface: Bool
    ) -> Bool {
        type == .leftMouseUp && !isInsideOwnedSurface
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
    var shouldIgnoreEventAtPoint: ((CGPoint) -> Bool)?

    private struct CaptureTarget: Sendable {
        let processIdentifier: pid_t
        let sourceApplicationName: String
        let sourceBundleIdentifier: String?
        let quartzPoint: CGPoint
        let appKitPoint: CGPoint
    }

    private struct ResolvedSelection: Sendable {
        let text: String
        let bounds: CGRect?
    }

    private final class CaptureState: @unchecked Sendable {
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

        func claim(_ candidate: UUID) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard token == candidate else { return false }
            token = nil
            return true
        }

        func finish(_ candidate: UUID) {
            lock.lock()
            defer { lock.unlock() }
            if token == candidate {
                token = nil
            }
        }

        func invalidate() {
            lock.lock()
            token = nil
            lock.unlock()
        }
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.tenom.iClipboard",
        category: "GlobalTextSelection"
    )

    private let captureQueue = DispatchQueue(
        label: "com.tenom.iClipboard.translation-selection",
        qos: .userInitiated
    )
    private let captureState = CaptureState()

    private var globalMouseMonitor: Any?
    private var lastDeliveredSignature: String?
    private var lastDeliveredAt = Date.distantPast

    private(set) var state: State = .stopped

    var isRunning: Bool {
        globalMouseMonitor != nil && state == .running
    }

    @discardableResult
    func start() -> Bool {
        guard globalMouseMonitor == nil else {
            updateState(.running)
            return true
        }

        guard AXIsProcessTrusted() else {
            updateState(.accessibilityPermissionMissing)
            return false
        }

        guard let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: .leftMouseUp,
            handler: { [weak self] event in
                guard let quartzPoint = event.cgEvent?.location else {
                    return
                }

                Task { @MainActor [weak self] in
                    self?.handleExternalMouseUp(quartzPoint: quartzPoint)
                }
            }
        ) else {
            Self.logger.error("Unable to create global mouse event monitor")
            updateState(.eventMonitorUnavailable)
            return false
        }

        globalMouseMonitor = monitor
        updateState(.running)
        Self.logger.info("Global selection monitor started")
        return true
    }

    func stop() {
        invalidateCapture()

        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }

        globalMouseMonitor = nil
        lastDeliveredSignature = nil
        updateState(.stopped)
    }

    private func updateState(_ newState: State) {
        guard state != newState else { return }
        state = newState
        onStateChange?(newState)
    }

    private func handleExternalMouseUp(quartzPoint: CGPoint) {
        let appKitPoint = Self.appKitPoint(fromQuartzPoint: quartzPoint)
        let isInsideOwnedSurface = shouldIgnoreEventAtPoint?(appKitPoint) == true
        guard SelectionEventFilter.shouldCapture(
            type: .leftMouseUp,
            isInsideOwnedSurface: isInsideOwnedSurface
        ) else {
            invalidateCapture()
            return
        }

        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              application.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return
        }

        scheduleCapture(
            target: CaptureTarget(
                processIdentifier: application.processIdentifier,
                sourceApplicationName: application.localizedName ?? "其他应用",
                sourceBundleIdentifier: application.bundleIdentifier,
                quartzPoint: quartzPoint,
                appKitPoint: appKitPoint
            )
        )
    }

    private func scheduleCapture(target: CaptureTarget) {
        let captureState = captureState
        let token = captureState.replaceToken()
        let delays: [TimeInterval] = [0.07, 0.18, 0.36]

        for (attempt, delay) in delays.enumerated() {
            captureQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard captureState.isActive(token) else { return }

                guard let selection = Self.resolveSelection(
                    processIdentifier: target.processIdentifier,
                    atQuartzPoint: target.quartzPoint
                ) else {
                    if attempt == delays.count - 1 {
                        captureState.finish(token)
                        Task { @MainActor in
                            Self.logger.debug(
                                "No readable AX selection pid=\(target.processIdentifier, privacy: .public)"
                            )
                        }
                    }
                    return
                }

                guard captureState.claim(token) else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.state == .running else { return }
                    self.deliver(selection: selection, target: target)
                }
            }
        }
    }

    private func deliver(selection: ResolvedSelection, target: CaptureTarget) {
        let anchorRect = selection.bounds
            .map(Self.appKitRect(fromQuartzRect:))
            .flatMap { Self.isUsable(rect: $0, near: target.appKitPoint) ? $0 : nil }
            ?? CGRect(origin: target.appKitPoint, size: CGSize(width: 1, height: 1))

        let signature = [
            String(target.processIdentifier),
            selection.text,
            String(format: "%.0f,%.0f", anchorRect.midX, anchorRect.midY)
        ].joined(separator: "|")

        let now = Date()
        guard signature != lastDeliveredSignature
                || now.timeIntervalSince(lastDeliveredAt) >= 0.7 else {
            return
        }

        lastDeliveredSignature = signature
        lastDeliveredAt = now
        onSelection?(
            SelectedTextContext(
                text: selection.text,
                anchorRect: anchorRect,
                cursorPoint: target.appKitPoint,
                sourceApplicationName: target.sourceApplicationName,
                sourceBundleIdentifier: target.sourceBundleIdentifier
            )
        )
    }

    private func invalidateCapture() {
        captureState.invalidate()
    }

    nonisolated private static func resolveSelection(
        processIdentifier: pid_t,
        atQuartzPoint point: CGPoint
    ) -> ResolvedSelection? {
        let deadline = CFAbsoluteTimeGetCurrent() + 0.9
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        configureTimeout(for: applicationElement)

        var visited: [AXUIElement] = []
        if let focusedElement = copyAXElement(
            attribute: kAXFocusedUIElementAttribute as CFString,
            from: applicationElement
        ), let selection = selectionInHierarchy(
            from: focusedElement,
            maximumDepth: 4,
            visited: &visited,
            deadline: deadline
        ) {
            return selection
        }

        guard CFAbsoluteTimeGetCurrent() < deadline else { return nil }

        var hitElement: AXUIElement?
        if AXUIElementCopyElementAtPosition(
            applicationElement,
            Float(point.x),
            Float(point.y),
            &hitElement
        ) == .success,
           let hitElement,
           let selection = selectionInHierarchy(
               from: hitElement,
               maximumDepth: 2,
               visited: &visited,
               deadline: deadline
           ) {
            return selection
        }

        guard CFAbsoluteTimeGetCurrent() < deadline else { return nil }
        return selection(from: applicationElement)
    }

    nonisolated private static func selectionInHierarchy(
        from seed: AXUIElement,
        maximumDepth: Int,
        visited: inout [AXUIElement],
        deadline: CFAbsoluteTime
    ) -> ResolvedSelection? {
        var current: AXUIElement? = seed
        var depth = 0

        while let element = current,
              depth <= maximumDepth,
              CFAbsoluteTimeGetCurrent() < deadline {
            configureTimeout(for: element)
            if !visited.contains(where: { CFEqual($0, element) }) {
                visited.append(element)
                if let selection = selection(from: element) {
                    return selection
                }
            }
            current = copyAXElement(
                attribute: kAXParentAttribute as CFString,
                from: element
            )
            depth += 1
        }
        return nil
    }

    nonisolated private static func selection(from element: AXUIElement) -> ResolvedSelection? {
        configureTimeout(for: element)
        if let directText = normalizedSelectionText(
            copyString(attribute: kAXSelectedTextAttribute as CFString, from: element)
        ) {
            return ResolvedSelection(
                text: directText,
                bounds: selectionBounds(for: element, rangeValue: nil)
            )
        }

        guard let rangeValue = copyValue(
            attribute: kAXSelectedTextRangeAttribute as CFString,
            from: element
        ),
        let rangeText = normalizedSelectionText(
            copyString(
                parameterizedAttribute: kAXStringForRangeParameterizedAttribute as CFString,
                parameter: rangeValue,
                from: element
            )
        ) else {
            return nil
        }

        return ResolvedSelection(
            text: rangeText,
            bounds: selectionBounds(for: element, rangeValue: rangeValue)
        )
    }

    nonisolated private static func configureTimeout(for element: AXUIElement) {
        _ = AXUIElementSetMessagingTimeout(element, 0.18)
    }

    nonisolated private static func normalizedSelectionText(_ candidate: String?) -> String? {
        guard let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              text.count <= 20_000 else {
            return nil
        }
        return text
    }

    nonisolated private static func copyAXElement(
        attribute: CFString,
        from element: AXUIElement
    ) -> AXUIElement? {
        guard let value = copyValue(attribute: attribute, from: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    nonisolated private static func copyValue(
        attribute: CFString,
        from element: AXUIElement
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value
    }

    nonisolated private static func copyString(
        attribute: CFString,
        from element: AXUIElement
    ) -> String? {
        guard let value = copyValue(attribute: attribute, from: element) else {
            return nil
        }
        if let string = value as? String { return string }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return nil
    }

    nonisolated private static func copyString(
        parameterizedAttribute attribute: CFString,
        parameter: CFTypeRef,
        from element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            attribute,
            parameter,
            &value
        ) == .success,
        let value else {
            return nil
        }

        if let string = value as? String { return string }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return nil
    }

    nonisolated private static func selectionBounds(
        for element: AXUIElement,
        rangeValue: CFTypeRef?
    ) -> CGRect? {
        let rangeValue = rangeValue ?? copyValue(
            attribute: kAXSelectedTextRangeAttribute as CFString,
            from: element
        )
        guard let rangeValue else { return nil }

        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsValue
        ) == .success,
        let boundsValue,
        CFGetTypeID(boundsValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeBitCast(boundsValue, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
        return rect
    }

    private static func appKitPoint(fromQuartzPoint point: CGPoint) -> CGPoint {
        guard let primaryScreen = NSScreen.screens.first else { return point }
        return CGPoint(x: point.x, y: primaryScreen.frame.maxY - point.y)
    }

    private static func appKitRect(fromQuartzRect rect: CGRect) -> CGRect {
        guard let primaryScreen = NSScreen.screens.first else { return rect }
        return CGRect(
            x: rect.minX,
            y: primaryScreen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private static func isUsable(rect: CGRect, near point: CGPoint) -> Bool {
        guard rect.width > 0,
              rect.height > 0,
              rect.width.isFinite,
              rect.height.isFinite,
              rect.minX.isFinite,
              rect.minY.isFinite else {
            return false
        }
        return hypot(rect.midX - point.x, rect.midY - point.y) < 1_800
    }
}
