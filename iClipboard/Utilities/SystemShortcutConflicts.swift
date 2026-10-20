import AppKit
import Carbon

/// Only an enabled, exact match from the public symbolic-hotkey API is confirmed.
/// A failed/incomplete query is not evidence that a shortcut is available.
enum SystemShortcutConflictResult: Equatable {
    case conflict
    case noConflict
    case unknown(OSStatus)
}

enum SystemShortcutConflicts {
    typealias Query = () -> (status: OSStatus, hotKeys: [[String: Any]]?)

    // CopySymbolicHotKeys is not thread safe. Production callers are the main-actor
    // HotKeyManager; the injectable query also permits tests without system changes.
    static func check(_ shortcut: KeyboardShortcut,
                      query: Query = copySymbolicHotKeys) -> SystemShortcutConflictResult {
        guard !shortcut.isEmpty else { return .noConflict }
        let result = query()
        guard result.status == noErr else { return .unknown(result.status) }
        guard let hotKeys = result.hotKeys else { return .unknown(OSStatus(paramErr)) }
        let candidate = shortcut.normalized
        var hasIncompleteEntry = false
        for entry in hotKeys {
            guard let enabled = entry[kHISymbolicHotKeyEnabled as String] as? NSNumber else {
                hasIncompleteEntry = true
                continue
            }
            guard enabled.boolValue else { continue }
            guard let keyCode = entry[kHISymbolicHotKeyCode as String] as? NSNumber,
                  let modifiers = entry[kHISymbolicHotKeyModifiers as String] as? NSNumber else {
                hasIncompleteEntry = true
                continue
            }
            if keyCode.intValue == candidate.keyCode,
               modifiers.int64Value == Int64(candidate.carbonModifiers) {
                return .conflict
            }
        }
        return hasIncompleteEntry ? .unknown(OSStatus(paramErr)) : .noConflict
    }

    private static func copySymbolicHotKeys() -> (status: OSStatus, hotKeys: [[String: Any]]?) {
        var array: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&array)
        let values = array?.takeRetainedValue()
        return (status, values as? [[String: Any]])
    }
}
