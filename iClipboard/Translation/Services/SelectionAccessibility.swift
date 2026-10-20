import AppKit
import ApplicationServices

struct ResolvedTextSelection: Equatable, Sendable {
    let text: String
    let bounds: CGRect?
}

enum SelectionResolution: Equatable {
    case selected(ResolvedTextSelection)
    case unavailable
    case blocked
}

enum SelectionText {
    static let maximumLength = 20_000

    static func nonempty(_ value: Any?) -> String? {
        let string = (value as? String) ?? (value as? NSAttributedString)?.string
        guard let text = string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    static func normalize(_ value: Any?) -> String? {
        guard let text = nonempty(value), text.count <= maximumLength else { return nil }
        return text
    }

    static func substring(_ value: String, range: CFRange) -> String? {
        // AX offsets count UTF-16 code units, not Swift Characters.
        guard range.location >= 0, range.length > 0,
              range.location <= value.utf16.count,
              range.length <= value.utf16.count - range.location,
              let indices = Range(NSRange(location: range.location, length: range.length), in: value)
        else { return nil }
        return normalize(String(value[indices]))
    }

    static func range(_ value: Any?) -> CFRange? {
        guard let value, CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value as CFTypeRef, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        return AXValueGetValue(axValue, .cfRange, &range) ? range : nil
    }

    static func rect(_ value: Any?) -> CGRect? {
        guard let value, CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value as CFTypeRef, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgRect else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(axValue, .cgRect, &rect) ? rect : nil
    }
}

// The reader keeps AX IPC outside the resolver so web-area hierarchies and
// unsupported attributes can be regression-tested without Accessibility access.
protocol SelectionAccessibilityReading {
    associatedtype Element: Equatable
    func value(_ attribute: String, of element: Element) -> Any?
    func value(_ attribute: String, parameter: Any, of element: Element) -> Any?
    func hitTest(_ point: CGPoint, in application: Element) -> Element?
}

struct SystemSelectionAccessibility: SelectionAccessibilityReading {
    func value(_ attribute: String, of element: AXUIElement) -> Any? {
        AXUIElementSetMessagingTimeout(element, 0.08)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }

    func value(_ attribute: String, parameter: Any, of element: AXUIElement) -> Any? {
        AXUIElementSetMessagingTimeout(element, 0.08)
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, attribute as CFString, parameter as CFTypeRef, &value
        ) == .success else { return nil }
        return value
    }

    func hitTest(_ point: CGPoint, in application: AXUIElement) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(application, 0.08)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            application, Float(point.x), Float(point.y), &element
        ) == .success else { return nil }
        return element
    }

    func prepare(_ application: AXUIElement) {
        // Reading AXRole wakes Chromium's lazy AX tree. Electron additionally
        // documents AXManualAccessibility; unsupported apps simply reject it.
        _ = value(kAXRoleAttribute, of: application)
        _ = AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
}

struct SelectionAccessibilityResolver<Reader: SelectionAccessibilityReading> {
    let reader: Reader
    var shouldContinue: () -> Bool = { true }

    func resolve(application: Reader.Element, point: CGPoint) -> SelectionResolution {
        guard shouldContinue() else { return .unavailable }
        let focused = value(kAXFocusedUIElementAttribute, of: application) as? Reader.Element
        // Never fall through to a web-area selection or Copy for password input.
        if let focused, isSecure(focused) { return .blocked }
        guard shouldContinue() else { return .unavailable }
        let hit = reader.hitTest(point, in: application)
        if let hit, isSecure(hit) { return .blocked }

        var visited: [Reader.Element] = []
        // A webpage selection often lives on AXWebArea while focus remains in
        // another control. Start at the release point and walk through iframes.
        for seed in [hit, focused, application].compactMap({ $0 }) {
            var current: Reader.Element? = seed
            for _ in 0..<10 {
                guard shouldContinue(), let element = current else { break }
                guard !visited.contains(element) else { break }
                visited.append(element)
                let result = validated(selection(in: element), near: point)
                if result != .unavailable { return result }
                current = value(kAXParentAttribute, of: element) as? Reader.Element
            }
        }

        // Some viewers return only the containing group from hit-testing.
        // Search a bounded subtree, never the entire application's windows.
        var pending = [hit, focused].compactMap { $0 }.map { ($0, 0) }
        var expanded: [Reader.Element] = []
        while !pending.isEmpty, expanded.count < 32, shouldContinue() {
            let (element, depth) = pending.removeFirst()
            guard !expanded.contains(element) else { continue }
            expanded.append(element)
            if !visited.contains(element) {
                visited.append(element)
                let result = validated(selection(in: element), near: point)
                if result != .unavailable { return result }
            }
            guard depth < 3 else { continue }
            let children = (value(kAXVisibleChildrenAttribute, of: element)
                ?? value(kAXChildrenAttribute, of: element)) as? [Reader.Element] ?? []
            pending.append(contentsOf: children.prefix(32 - expanded.count).map { ($0, depth + 1) })
        }
        return .unavailable
    }

    private func validated(_ result: SelectionResolution, near point: CGPoint) -> SelectionResolution {
        // An old selection in another control may still be exposed by AX. When
        // the app gives usable bounds, require them to agree with the gesture.
        // Missing/empty bounds remain supported for apps that cannot supply them.
        if case let .selected(selection) = result, let bounds = selection.bounds,
           bounds.width > 0, bounds.height > 0,
           bounds.minX.isFinite, bounds.minY.isFinite,
           bounds.width.isFinite, bounds.height.isFinite,
           !bounds.insetBy(dx: -120, dy: -120).contains(point) {
            return .unavailable
        }
        return result
    }

    private func selection(in element: Reader.Element) -> SelectionResolution {
        guard !isSecure(element) else { return .blocked }
        if let raw = SelectionText.nonempty(value(kAXSelectedTextAttribute, of: element)) {
            guard let text = SelectionText.normalize(raw) else { return .blocked }
            let range = value(kAXSelectedTextRangeAttribute, of: element)
            return .selected(ResolvedTextSelection(text: text, bounds: range.flatMap {
                SelectionText.rect(value(kAXBoundsForRangeParameterizedAttribute, parameter: $0, of: element))
            }))
        }

        // Chromium/WebKit expose selections spanning DOM nodes using opaque
        // text markers rather than AXSelectedTextRange (CFRange).
        if let marker = value("AXSelectedTextMarkerRange", of: element) {
            let raw = SelectionText.nonempty(value("AXStringForTextMarkerRange", parameter: marker, of: element))
                ?? SelectionText.nonempty(value("AXAttributedStringForTextMarkerRange", parameter: marker, of: element))
            if let raw {
                guard let text = SelectionText.normalize(raw) else { return .blocked }
                let bounds = SelectionText.rect(value("AXBoundsForTextMarkerRange", parameter: marker, of: element))
                return .selected(ResolvedTextSelection(text: text, bounds: bounds))
            }
        }

        if let rangeValue = value(kAXSelectedTextRangeAttribute, of: element),
           let range = SelectionText.range(rangeValue), range.location >= 0, range.length > 0 {
            let raw = value(kAXStringForRangeParameterizedAttribute, parameter: rangeValue, of: element)
            if let raw = SelectionText.nonempty(raw), raw.count > SelectionText.maximumLength { return .blocked }
            let text = SelectionText.normalize(raw) ?? (value(kAXValueAttribute, of: element) as? String)
                .flatMap { SelectionText.substring($0, range: range) }
            if let text {
                let bounds = SelectionText.rect(value(kAXBoundsForRangeParameterizedAttribute, parameter: rangeValue, of: element))
                return .selected(ResolvedTextSelection(text: text, bounds: bounds))
            }
        }
        return .unavailable
    }

    private func isSecure(_ element: Reader.Element) -> Bool {
        value(kAXSubroleAttribute, of: element) as? String == kAXSecureTextFieldSubrole
    }

    private func value(_ attribute: String, of element: Reader.Element) -> Any? {
        shouldContinue() ? reader.value(attribute, of: element) : nil
    }

    private func value(_ attribute: String, parameter: Any, of element: Reader.Element) -> Any? {
        shouldContinue() ? reader.value(attribute, parameter: parameter, of: element) : nil
    }
}
