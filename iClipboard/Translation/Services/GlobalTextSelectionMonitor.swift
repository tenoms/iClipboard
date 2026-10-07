import AppKit
import ApplicationServices
import Foundation
import OSLog

final class GlobalTextSelectionMonitor {
    enum State: Equatable {
        case stopped
        case running
        case accessibilityPermissionMissing
        case eventTapUnavailable
    }

    var onSelection: ((SelectedTextContext) -> Void)?
    var onStateChange: ((State) -> Void)?
    var shouldIgnoreEventAtPoint: ((CGPoint) -> Bool)?

    private struct CaptureTarget {
        let processIdentifier: pid_t
        let sourceApplicationName: String
        let sourceBundleIdentifier: String?
        let quartzPoint: CGPoint
        let appKitPoint: CGPoint
    }

    private struct ResolvedSelection {
        let text: String
        let bounds: CGRect?
    }

    private final class ManagedApplication {
        let processIdentifier: pid_t
        let element: AXUIElement
        var observer: AXObserver?
        var lastActivationAttempt = Date.distantPast

        init(processIdentifier: pid_t, element: AXUIElement) {
            self.processIdentifier = processIdentifier
            self.element = element
        }
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.tenom.iClipboard",
        category: "GlobalTextSelection"
    )

    // These compatibility attributes are intentionally isolated here. Several
    // Chromium/Electron-style applications lazily expose their complete AX
    // hierarchy only after an assistive client asks for enhanced/manual AX.
    // Unsupported native applications simply return kAXErrorAttributeUnsupported.
    private static let manualAccessibilityAttribute = "AXManualAccessibility" as CFString
    private static let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface" as CFString

    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private var systemWideElement: AXUIElement?
    private var workspaceObserverTokens: [NSObjectProtocol] = []
    private var managedApplications: [pid_t: ManagedApplication] = [:]
    private var captureToken: UUID?
    private var lastDeliveredSignature: String?
    private var lastDeliveredAt = Date.distantPast

    private(set) var state: State = .stopped

    var isRunning: Bool {
        eventTap != nil && state == .running
    }

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else {
            primeFrontmostApplication()
            updateState(.running)
            return true
        }

        guard AXIsProcessTrusted() else {
            updateState(.accessibilityPermissionMissing)
            return false
        }

        let systemWideElement = AXUIElementCreateSystemWide()
        _ = AXUIElementSetMessagingTimeout(systemWideElement, 0.4)
        self.systemWideElement = systemWideElement

        let interestedEvents: [CGEventType] = [.leftMouseUp, .keyUp]
        let mask = interestedEvents.reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << CGEventMask($1.rawValue))
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<GlobalTextSelectionMonitor>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()
                monitor.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else {
            Self.logger.error("Unable to create global listen-only event tap")
            updateState(.eventTapUnavailable)
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        eventTapRunLoopSource = source
        installWorkspaceObservers()
        updateState(.running)

        // LSUIElement applications frequently start without becoming the
        // frontmost application. Prime whatever application the user is
        // currently working in immediately, then keep priming on activation.
        primeFrontmostApplication()
        Self.logger.info("Global selection monitor started")
        return true
    }

    func stop() {
        captureToken = nil
        removeWorkspaceObservers()
        clearManagedApplications()

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
        }

        eventTap = nil
        eventTapRunLoopSource = nil

        if let systemWideElement {
            _ = AXUIElementSetMessagingTimeout(systemWideElement, 0)
        }
        systemWideElement = nil

        lastDeliveredSignature = nil
        updateState(.stopped)
    }

    private func updateState(_ newState: State) {
        guard state != newState else { return }
        state = newState
        onStateChange?(newState)
    }

    // MARK: - Target application lifecycle

    private func installWorkspaceObservers() {
        guard workspaceObserverTokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter

        let activateToken = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication else {
                return
            }
            self?.prime(application: application)
        }

        let terminateToken = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication else {
                return
            }
            self?.removeManagedApplication(processIdentifier: application.processIdentifier)
        }

        workspaceObserverTokens = [activateToken, terminateToken]
    }

    private func removeWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObserverTokens.forEach(center.removeObserver)
        workspaceObserverTokens.removeAll()
    }

    private func primeFrontmostApplication() {
        guard let application = NSWorkspace.shared.frontmostApplication else { return }
        prime(application: application)
    }

    private func prime(application: NSRunningApplication, forceActivation: Bool = false) {
        let pid = application.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier,
              application.bundleIdentifier != Bundle.main.bundleIdentifier,
              !application.isTerminated,
              AXIsProcessTrusted() else {
            return
        }

        if let managed = managedApplications[pid] {
            if forceActivation {
                activateAccessibility(for: managed, minimumInterval: 5)
            }
            return
        }

        let element = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(element, 0.35)
        let managed = ManagedApplication(processIdentifier: pid, element: element)
        managedApplications[pid] = managed

        // Doubao Browser performs the same two-step shape: activate AX for
        // the target process, then register an AX observer. Doing this
        // ourselves removes the accidental dependency on another assistive
        // application having touched the process first.
        activateAccessibility(for: managed, minimumInterval: 0)
        installAXObserver(for: managed)
    }

    private func activateAccessibility(
        for managed: ManagedApplication,
        minimumInterval: TimeInterval
    ) {
        let now = Date()
        guard now.timeIntervalSince(managed.lastActivationAttempt) >= minimumInterval else {
            return
        }
        managed.lastActivationAttempt = now
        let manualResult = AXUIElementSetAttributeValue(
            managed.element,
            Self.manualAccessibilityAttribute,
            kCFBooleanTrue
        )
        let enhancedResult = AXUIElementSetAttributeValue(
            managed.element,
            Self.enhancedUserInterfaceAttribute,
            kCFBooleanTrue
        )

        Self.logger.info(
            "Primed AX pid=\(managed.processIdentifier, privacy: .public) manual=\(manualResult.rawValue, privacy: .public) enhanced=\(enhancedResult.rawValue, privacy: .public)"
        )
    }

    private func installAXObserver(for managed: ManagedApplication) {
        guard managed.observer == nil else { return }

        var observer: AXObserver?
        let createResult = AXObserverCreate(
            managed.processIdentifier,
            { _, _, _, _ in
                // Registration itself keeps us participating as an assistive
                // client. Selection resolution remains event-driven so the
                // callback intentionally does no work.
            },
            &observer
        )

        guard createResult == .success, let observer else {
            Self.logger.debug(
                "AXObserverCreate failed pid=\(managed.processIdentifier, privacy: .public) error=\(createResult.rawValue, privacy: .public)"
            )
            return
        }

        let notifications: [CFString] = [
            kAXFocusedUIElementChangedNotification as CFString,
            kAXFocusedWindowChangedNotification as CFString,
            kAXApplicationActivatedNotification as CFString,
            kAXApplicationDeactivatedNotification as CFString
        ]

        for notification in notifications {
            let result = AXObserverAddNotification(
                observer,
                managed.element,
                notification,
                nil
            )
            if result != .success && result != .notificationAlreadyRegistered {
                Self.logger.debug(
                    "AX notification registration skipped pid=\(managed.processIdentifier, privacy: .public) error=\(result.rawValue, privacy: .public)"
                )
            }
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        managed.observer = observer
    }

    private func removeManagedApplication(processIdentifier: pid_t) {
        guard let managed = managedApplications.removeValue(forKey: processIdentifier) else {
            return
        }

        if let observer = managed.observer {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }
    }

    private func clearManagedApplications() {
        for processIdentifier in Array(managedApplications.keys) {
            removeManagedApplication(processIdentifier: processIdentifier)
        }
    }

    // MARK: - Global interaction capture

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
                Self.logger.notice("Re-enabled disabled global event tap")
            }
            return
        }

        let shouldCapture: Bool
        switch type {
        case .leftMouseUp:
            shouldCapture = true
        case .keyUp:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            shouldCapture = flags.contains(.maskShift)
                || (flags.contains(.maskCommand) && keyCode == 0) // Command-A
        default:
            shouldCapture = false
        }

        guard shouldCapture else { return }

        let quartzPoint = event.location
        let appKitPoint = Self.appKitPoint(fromQuartzPoint: quartzPoint)
        if shouldIgnoreEventAtPoint?(appKitPoint) == true {
            return
        }

        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              application.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return
        }

        // Capture the application identity at mouse-up time rather than looking
        // it up after the delay; a panel or another app may become frontmost in
        // the meantime.
        prime(application: application)

        let target = CaptureTarget(
            processIdentifier: application.processIdentifier,
            sourceApplicationName: application.localizedName ?? "其他应用",
            sourceBundleIdentifier: application.bundleIdentifier,
            quartzPoint: quartzPoint,
            appKitPoint: appKitPoint
        )
        scheduleCapture(target: target)
    }

    private func scheduleCapture(target: CaptureTarget) {
        let token = UUID()
        captureToken = token

        // AX selection publication timing varies significantly between AppKit,
        // WebKit, Chromium and Electron. A few short attempts are cheap and
        // avoid treating a transient "no value yet" as a permanent failure.
        let delays: [TimeInterval] = [0.07, 0.16, 0.32]

        for (attempt, delay) in delays.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.captureToken == token else { return }

                if self.captureSelection(target: target) {
                    self.captureToken = nil
                    return
                }

                if attempt == 0,
                   let application = NSRunningApplication(
                    processIdentifier: target.processIdentifier
                   ) {
                    self.prime(application: application, forceActivation: true)
                }

                if attempt == delays.count - 1 {
                    Self.logger.debug(
                        "No readable AX selection pid=\(target.processIdentifier, privacy: .public)"
                    )
                }
            }
        }
    }

    @discardableResult
    private func captureSelection(target: CaptureTarget) -> Bool {
        guard AXIsProcessTrusted(),
              let application = NSRunningApplication(
                processIdentifier: target.processIdentifier
              ),
              !application.isTerminated else {
            return false
        }

        prime(application: application)
        guard let managed = managedApplications[target.processIdentifier],
              let selection = resolveSelection(
                in: managed.element,
                atQuartzPoint: target.quartzPoint
              ) else {
            return false
        }

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
        if signature == lastDeliveredSignature,
           now.timeIntervalSince(lastDeliveredAt) < 0.7 {
            return true
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
        return true
    }

    // MARK: - Selection resolution

    private func resolveSelection(
        in applicationElement: AXUIElement,
        atQuartzPoint point: CGPoint
    ) -> ResolvedSelection? {
        var seedElements: [AXUIElement] = []

        if let focusedElement = copyAXElement(
            attribute: kAXFocusedUIElementAttribute as CFString,
            from: applicationElement
        ) {
            appendUnique(focusedElement, to: &seedElements)
        }

        var hitElement: AXUIElement?
        if AXUIElementCopyElementAtPosition(
            applicationElement,
            Float(point.x),
            Float(point.y),
            &hitElement
        ) == .success, let hitElement {
            appendUnique(hitElement, to: &seedElements)
        }

        var candidates: [AXUIElement] = []
        for seed in seedElements {
            var current: AXUIElement? = seed
            var depth = 0

            while let element = current, depth < 10 {
                appendUnique(element, to: &candidates)
                current = copyAXElement(
                    attribute: kAXParentAttribute as CFString,
                    from: element
                )
                depth += 1
            }
        }

        // Some applications expose selection on the application element itself.
        appendUnique(applicationElement, to: &candidates)

        for element in candidates {
            if let selection = selection(from: element) {
                return selection
            }
        }

        return nil
    }

    private func selection(from element: AXUIElement) -> ResolvedSelection? {
        let rangeValue = copyValue(
            attribute: kAXSelectedTextRangeAttribute as CFString,
            from: element
        )

        let directText = copyString(
            attribute: kAXSelectedTextAttribute as CFString,
            from: element
        )

        let rangeText: String?
        if let rangeValue {
            rangeText = copyString(
                parameterizedAttribute: kAXStringForRangeParameterizedAttribute as CFString,
                parameter: rangeValue,
                from: element
            )
        } else {
            rangeText = nil
        }

        guard let text = normalizedSelectionText(directText)
            ?? normalizedSelectionText(rangeText) else {
            return nil
        }

        let bounds = selectionBounds(for: element, rangeValue: rangeValue)
        return ResolvedSelection(text: text, bounds: bounds)
    }

    private func normalizedSelectionText(_ candidate: String?) -> String? {
        guard let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              text.count <= 20_000 else {
            return nil
        }
        return text
    }

    private func appendUnique(_ element: AXUIElement, to elements: inout [AXUIElement]) {
        guard !elements.contains(where: { CFEqual($0, element) }) else { return }
        elements.append(element)
    }

    private func copyAXElement(attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        guard let value = copyValue(attribute: attribute, from: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func copyValue(attribute: CFString, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value
    }

    private func copyString(attribute: CFString, from element: AXUIElement) -> String? {
        guard let value = copyValue(attribute: attribute, from: element) else {
            return nil
        }
        if let string = value as? String { return string }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return nil
    }

    private func copyString(
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
        ) == .success, let value else {
            return nil
        }

        if let string = value as? String { return string }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return nil
    }

    private func selectionBounds(
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

    // CGEvent/AX hit testing use top-left-relative Quartz coordinates, while
    // AppKit windows use bottom-left-relative global coordinates.
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
        guard rect.width > 0, rect.height > 0,
              rect.width.isFinite, rect.height.isFinite,
              rect.minX.isFinite, rect.minY.isFinite else {
            return false
        }
        return hypot(rect.midX - point.x, rect.midY - point.y) < 1_800
    }
}
