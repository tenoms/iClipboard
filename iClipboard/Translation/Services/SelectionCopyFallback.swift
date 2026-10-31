import AppKit
import ApplicationServices

enum SelectionCopyMenu {
    static func performCopy(processIdentifier: pid_t, shouldContinue: @escaping () -> Bool) -> Bool {
        let deadline = CFAbsoluteTimeGetCurrent() + 0.3
        let isValid = { shouldContinue() && CFAbsoluteTimeGetCurrent() < deadline }
        guard isValid() else { return false }
        let application = AXUIElementCreateApplication(processIdentifier)
        let reader = SystemSelectionAccessibility()
        if let focus = reader.value(kAXFocusedUIElementAttribute, of: application),
           CFGetTypeID(focus as CFTypeRef) == AXUIElementGetTypeID() {
            let element = unsafeBitCast(focus as CFTypeRef, to: AXUIElement.self)
            if reader.value(kAXSubroleAttribute, of: element) as? String == kAXSecureTextFieldSubrole {
                return false
            }
        }
        guard let item = find(application: application, reader: reader, shouldContinue: isValid),
              isValid() else { return false }
        // Use the source app's enabled menu action, never a global key event.
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    static func find<Reader: SelectionAccessibilityReading>(
        application: Reader.Element,
        reader: Reader,
        shouldContinue: () -> Bool
    ) -> Reader.Element? {
        guard shouldContinue(),
              let menu = reader.value(kAXMenuBarAttribute, of: application) as? Reader.Element
        else { return nil }
        var pending = [(menu, 0)]
        var visited: [Reader.Element] = []
        while !pending.isEmpty, visited.count < 100, shouldContinue() {
            let (element, depth) = pending.removeFirst()
            guard !visited.contains(element) else { continue }
            visited.append(element)
            // Match the standard Command-C action without depending on locale.
            if (reader.value(kAXMenuItemCmdCharAttribute, of: element) as? String)?.lowercased() == "c" {
                guard shouldContinue(),
                      reader.value(kAXMenuItemCmdModifiersAttribute, of: element) as? Int == 0,
                      reader.value(kAXEnabledAttribute, of: element) as? Bool == true
                else { continue }
                return element
            }
            guard depth < 3, shouldContinue() else { continue }
            let children = reader.value(kAXChildrenAttribute, of: element) as? [Reader.Element] ?? []
            pending.append(contentsOf: children.prefix(100 - visited.count).map { ($0, depth + 1) })
        }
        return nil
    }
}

struct SelectionPasteboardSnapshot {
    let changeCount: Int
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init?(pasteboard: NSPasteboard) {
        changeCount = pasteboard.changeCount
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        var totalBytes = 0
        for item in pasteboard.pasteboardItems ?? [] {
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                // Skip fallback if a promised representation cannot be saved,
                // or a large clipboard would make a selection expensive.
                guard let data = item.data(forType: type) else { return nil }
                totalBytes += data.count
                guard totalBytes <= 16 * 1_024 * 1_024 else { return nil }
                representations[type] = data
            }
            items.append(representations)
        }
        guard pasteboard.changeCount == changeCount else { return nil }
        self.items = items
    }

    @discardableResult
    func restore(to pasteboard: NSPasteboard, ifUnchangedSince copiedChangeCount: Int) -> Bool {
        guard pasteboard.changeCount == copiedChangeCount else { return false }
        let objects = items.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        pasteboard.clearContents()
        return objects.isEmpty || pasteboard.writeObjects(objects)
    }
}

@MainActor
final class SelectionCopyFallback {
    static let shared = SelectionCopyFallback()

    private let pasteboard: NSPasteboard
    private var isCapturing = false
    private var restoredChangeCount: Int?
    private var userClipboardAction = 0

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func noteUserClipboardAction() {
        userClipboardAction &+= 1
    }

    func shouldIgnoreClipboardChange(_ changeCount: Int) -> Bool {
        isCapturing || restoredChangeCount == changeCount
    }

    func capture(isValid: () -> Bool, performCopy: () async -> Bool) async -> String? {
        guard isValid(), !Task.isCancelled, !isCapturing,
              let snapshot = SelectionPasteboardSnapshot(pasteboard: pasteboard) else { return nil }
        let userActionAtStart = userClipboardAction
        isCapturing = true
        defer { isCapturing = false }
        guard isValid(), await performCopy() else { return nil }

        // Cleanup has a separate lifetime from delivering a selection. Cancelling
        // a gesture must still restore our temporary copy, unless the user copied
        // or another pasteboard owner intervened. A cancelled Task.sleep would
        // spin here, so use a bounded, non-cancelling asynchronous delay.
        let deadline = ContinuousClock.now + .milliseconds(350)
        while ContinuousClock.now < deadline, userClipboardAction == userActionAtStart {
            let count = pasteboard.changeCount
            if count != snapshot.changeCount {
                guard count == snapshot.changeCount + 1 else { return nil }
                if SelectionText.nonempty(pasteboard.string(forType: .string)) != nil { break }
            }
            await withCheckedContinuation { continuation in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { continuation.resume() }
            }
        }
        let copiedChangeCount = pasteboard.changeCount
        guard userClipboardAction == userActionAtStart,
              copiedChangeCount == snapshot.changeCount + 1 else { return nil }
        // Copying files (for example, Finder items) also writes their names as
        // text. That is an item selection, not selected text.
        let copiedFiles = pasteboard.types?.contains(.fileURL) == true
        let text = copiedFiles ? nil : SelectionText.normalize(pasteboard.string(forType: .string))
        guard snapshot.restore(to: pasteboard, ifUnchangedSince: copiedChangeCount) else { return nil }
        restoredChangeCount = pasteboard.changeCount
        return isValid() && !Task.isCancelled ? text : nil
    }
}
