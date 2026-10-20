import AppKit
import ApplicationServices

struct CaptureElementRequest: Equatable, Sendable {
    let window: CaptureDetectionWindow
    let point: CGPoint
    let displayFrame: CGRect
    let coordinates: CaptureDetectionCoordinates
}

/// Synchronous by design: CaptureSelectionDetector invokes this on its one serial worker, never MainActor.
protocol CaptureElementResolving {
    func resolve(_ request: CaptureElementRequest,
                 shouldContinue: () -> Bool) -> CaptureDetectionCandidate?
}

struct SystemCaptureElementResolver: CaptureElementResolving {
    func resolve(_ request: CaptureElementRequest,
                 shouldContinue: () -> Bool) -> CaptureDetectionCandidate? {
        guard shouldContinue(), request.window.ownerPID > 0 else { return nil }
        // The overlay belongs to this app. An application-specific root avoids hitting it, without
        // activating the target, preparing its AX tree, or setting AXManualAccessibility.
        let application = AXUIElementCreateApplication(request.window.ownerPID)
        return CaptureElementResolver(reader: SystemSelectionAccessibility(), processID: { element in
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success else { return nil }
            return pid
        }).resolve(request, application: application, shouldContinue: shouldContinue)
    }
}

/// Read-only, bounded ancestor traversal. The injected reader is shared with text selection, but
/// only hitTest and ordinary geometry/role/parent attribute reads are used here.
struct CaptureElementResolver<Reader: SelectionAccessibilityReading> {
    let reader: Reader
    let processID: (Reader.Element) -> pid_t?
    // Stop starting IPC after 160 ms: the reader's final 80 ms timeout still keeps
    // worst-case work below 250 ms, since a C call cannot be interrupted.
    var budget: TimeInterval = 0.16
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    func resolve(_ request: CaptureElementRequest, application: Reader.Element,
                 shouldContinue: () -> Bool = { true }) -> CaptureDetectionCandidate? {
        guard budget.isFinite, budget > 0, request.coordinates.primaryHeight.isFinite,
              request.window.ownerPID > 0, request.window.windowID != kCGNullWindowID,
              CaptureDetectionGeometry.contains(request.point, in: request.window.frame),
              CaptureDetectionGeometry.contains(request.point, in: request.displayFrame) else { return nil }
        let startedAt = now()
        let deadline = startedAt + min(budget, 0.25)
        func canRead() -> Bool {
            let time = now()
            return shouldContinue() && time.isFinite && time >= startedAt && time < deadline
        }
        func value(_ attribute: String, of element: Reader.Element) -> Any? {
            guard canRead() else { return nil }
            let result = reader.value(attribute, of: element)
            return canRead() ? result : nil
        }
        func owns(_ element: Reader.Element) -> Bool {
            guard canRead() else { return false }
            let pid = processID(element)
            return canRead() && pid == request.window.ownerPID
        }
        func frame(of element: Reader.Element) -> CGRect? {
            // AXFrame and text-selection bounds are intentionally not used. Reject incorrectly
            // typed AXValues instead of coercing NSValue, CGRect, or a cgRect into point/size.
            guard let position = CaptureElementGeometry.point(value(kAXPositionAttribute, of: element)),
                  let size = CaptureElementGeometry.size(value(kAXSizeAttribute, of: element)) else { return nil }
            let quartzFrame = CGRect(origin: position, size: size)
            guard CaptureDetectionGeometry.isValid(quartzFrame) else { return nil }
            let rect = request.coordinates.globalAppKitRect(fromQuartz: quartzFrame)
            return CaptureDetectionGeometry.isValid(rect) ? rect : nil
        }

        guard owns(application), canRead() else { return nil }
        let hit = reader.hitTest(request.coordinates.quartzPoint(fromGlobalAppKit: request.point),
                                 in: application)
        guard canRead(), let hit else { return nil }
        var current: Reader.Element? = hit
        var visited: [Reader.Element] = []
        var candidate: CGRect?
        var promotableLeafFrame: CGRect?

        // A candidate cannot escape until an AXWindow ancestor agrees with the source CG window.
        // This rejects another window of the same PID without any private window-ID AX APIs.
        // Layout-heavy interfaces can exceed eight ancestors; the IPC budget still bounds work.
        for _ in 0..<16 {
            guard canRead(), let element = current, !visited.contains(element), owns(element) else { return nil }
            visited.append(element)
            let role = value(kAXRoleAttribute, of: element) as? String
            let subrole = value(kAXSubroleAttribute, of: element) as? String
            guard canRead() else { return nil }
            if role == kAXSecureTextFieldSubrole || subrole == kAXSecureTextFieldSubrole ||
                role == "AXPasswordField" || subrole == "AXPasswordField" {
                return nil
            }
            if role == kAXApplicationRole { return nil }
            if role == kAXWindowRole {
                guard let windowFrame = frame(of: element), canRead(),
                      CaptureElementGeometry.matchesSourceWindow(windowFrame, request.window.frame),
                      let candidate else { return nil }
                return CaptureDetectionCandidate(rect: candidate, windowID: request.window.windowID,
                                                 ownerPID: request.window.ownerPID, kind: .element)
            }
            if candidate == nil, let role, role != kAXUnknownRole,
               let rect = frame(of: element), rect.contains(request.point) {
                let clipped = rect.intersection(request.window.frame).intersection(request.displayFrame)
                if CaptureDetectionGeometry.contains(request.point, in: clipped) {
                    candidate = clipped
                    if role == kAXStaticTextRole || role == kAXImageRole { promotableLeafFrame = rect }
                }
            } else if let leaf = promotableLeafFrame, let role, isActionableRole(role) {
                // Only the nearest semantic control may replace its label/icon. If its geometry
                // is missing or inconsistent, keep the leaf instead of jumping to an outer control.
                promotableLeafFrame = nil
                if let rect = frame(of: element), rect.contains(leaf) {
                    let clipped = rect.intersection(request.window.frame).intersection(request.displayFrame)
                    if CaptureDetectionGeometry.contains(request.point, in: clipped) { candidate = clipped }
                }
            }
            current = value(kAXParentAttribute, of: element) as? Reader.Element
        }
        return nil
    }

    private func isActionableRole(_ role: String) -> Bool {
        // The public AXLink role has no matching named constant in older macOS SDKs.
        switch role {
        case kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole,
             kAXMenuButtonRole, "AXLink", kAXMenuItemRole, kAXDisclosureTriangleRole:
            return true
        default:
            return false
        }
    }
}

enum CaptureElementGeometry {
    static func point(_ value: Any?) -> CGPoint? {
        guard let value, CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value as CFTypeRef, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point), point.x.isFinite, point.y.isFinite else { return nil }
        return point
    }

    static func size(_ value: Any?) -> CGSize? {
        guard let value, CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value as CFTypeRef, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size), size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        return size
    }

    static func matchesSourceWindow(_ frame: CGRect, _ source: CGRect) -> Bool {
        // AX and CG can round outer window edges slightly differently. Compare the original
        // window, not its display-clipped portion (important for windows crossing displays).
        let tolerance: CGFloat = 3
        return abs(frame.minX - source.minX) <= tolerance && abs(frame.minY - source.minY) <= tolerance &&
            abs(frame.maxX - source.maxX) <= tolerance && abs(frame.maxY - source.maxY) <= tolerance
    }
}
