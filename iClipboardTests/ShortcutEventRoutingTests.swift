import AppKit
import Carbon
import SwiftUI
import XCTest
@testable import iClipboard

@MainActor
final class ShortcutEventRoutingTests: XCTestCase {
    private final class PanelContent: ObservableObject {
        @Published var shortcut = iClipboard.KeyboardShortcut.empty
    }

    private struct SettingsContent: View {
        @ObservedObject var value: PanelContent
        let manager: HotKeyManager
        var body: some View {
            KeyRecorderView(shortcut: $value.shortcut, hotKeyManager: manager)
                .frame(width: 320, height: 90)
        }
    }

    func testPinnedTranslationCannotConsumeAnotherWindowsModifiedEscapeOrControlOne() async throws {
        let suite = "iClipboard.EventRouting." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = HotKeyManager(defaults: defaults, registerHotKey: { _, _, _, ref in
            ref = EventHotKeyRef(bitPattern: 1)
            return noErr
        }, unregisterHotKey: { _ in noErr }, installEventHandler: false, conflictChecker: nil)
        let value = PanelContent()
        let window = ClipboardPanel(contentRect: CGRect(x: 100, y: 200, width: 420, height: 200),
                                    backing: .buffered, defer: false)
        let host = NSHostingView(rootView: SettingsContent(value: value, manager: manager))
        window.contentView = host
        let translation = TranslationPanelController()
        let context = SelectedTextContext(text: "pinned translation", anchorRect: CGRect(x: 600, y: 500, width: 10, height: 10),
                                          cursorPoint: CGPoint(x: 600, y: 500), sourceApplicationName: "Fixture", sourceBundleIdentifier: nil)
        translation.beginTranslation(context: context, provider: .doubaoAI, dismissOnOutsideClick: false)
        translation.viewModel.togglePin()
        defer { translation.hide(); window.orderOut(nil); window.contentView = nil }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<50 {
            if findRecorder(host) != nil && window.isKeyWindow { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let recorder = try XCTUnwrap(findRecorder(host))
        recorder.beginRecording()
        XCTAssertTrue(recorder.isRecording)
        NSApp.sendEvent(try event(window, code: kVK_Escape, characters: "\u{1b}", modifiers: .shift))
        XCTAssertEqual(value.shortcut, iClipboard.KeyboardShortcut(keyCode: kVK_Escape, modifiers: Int(NSEvent.ModifierFlags.shift.rawValue)))
        XCTAssertFalse(recorder.isRecording)
        XCTAssertTrue(translation.isVisible)
        recorder.beginRecording()
        XCTAssertTrue(recorder.isRecording)
        NSApp.sendEvent(try event(window, code: kVK_ANSI_1, characters: "1", modifiers: .control))
        XCTAssertEqual(value.shortcut, iClipboard.KeyboardShortcut(keyCode: kVK_ANSI_1, modifiers: Int(NSEvent.ModifierFlags.control.rawValue)))
        XCTAssertFalse(recorder.isRecording)
        XCTAssertFalse(manager.isRegistrationSuspended)
    }

    private func findRecorder(_ view: NSView) -> ShortcutRecorderControl? {
        if let recorder = view as? ShortcutRecorderControl { return recorder }
        for child in view.subviews { if let recorder = findRecorder(child) { return recorder } }
        return nil
    }

    private func event(_ window: NSWindow, code: Int, characters: String,
                       modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil,
                                      characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: UInt16(code)))
    }
}
