import AppKit
import Carbon
import SwiftUI
import XCTest
@testable import iClipboard

private typealias RecordedShortcut = iClipboard.KeyboardShortcut

@MainActor
final class ShortcutRecorderTests: XCTestCase {
    func testCommandCAndUndoReachFirstResponderBeforeMenuCommands() throws {
        let fixture = try makeFixture()
        let commands = RecorderMenuCommands()
        let oldMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = oldMenu }
        let menu = NSMenu()
        for (title, key, action) in [("Copy", "c", #selector(RecorderMenuCommands.copyCommand)),
                                     ("Undo", "z", #selector(RecorderMenuCommands.undoCommand))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = commands
            menu.addItem(item)
        }
        NSApp.mainMenu = menu

        for (keyCode, characters) in [(kVK_ANSI_C, "c"), (kVK_ANSI_Z, "z")] {
            try begin(fixture)
            sendKey(keyCode, characters: characters, modifiers: .command, to: fixture.panel)
            XCTAssertEqual(fixture.manager.currentShortcut, shortcut(keyCode, .command))
            XCTAssertFalse(fixture.recorder.isRecording)
            XCTAssertFalse(fixture.manager.isRegistrationSuspended)
        }
        XCTAssertEqual(commands.copyCalls, 0)
        XCTAssertEqual(commands.undoCalls, 0)
    }

    func testAlreadyRegisteredCombinationIsRecordableAndRestoredOnce() throws {
        let fixture = try makeFixture()
        let original = shortcut(kVK_ANSI_V, [.command, .shift])
        fixture.setShortcut(original)
        let resumes = fixture.carbon.registerCalls

        try begin(fixture)
        XCTAssertTrue(fixture.carbon.registrations.isEmpty)
        sendKey(kVK_ANSI_V, characters: "V", modifiers: [.command, .shift], to: fixture.panel)

        XCTAssertEqual(fixture.manager.currentShortcut, original)
        XCTAssertFalse(fixture.manager.isRegistrationSuspended)
        XCTAssertEqual(fixture.carbon.registerCalls, resumes + 1)
        XCTAssertEqual(fixture.carbon.registrations.count, 1)
    }

    func testEscapeAndUnmodifiedKeyKeepOldShortcut() throws {
        let fixture = try makeFixture()
        let original = shortcut(kVK_ANSI_V, .command)
        fixture.setShortcut(original)
        try begin(fixture)

        sendKey(kVK_ANSI_A, characters: "a", modifiers: [], to: fixture.panel)
        XCTAssertTrue(fixture.recorder.isRecording)
        XCTAssertNotNil(fixture.recorder.hint)
        XCTAssertEqual(fixture.manager.currentShortcut, original)
        sendKey(kVK_Escape, characters: "\u{1b}", modifiers: [], to: fixture.panel)

        XCTAssertFalse(fixture.recorder.isRecording)
        XCTAssertFalse(fixture.manager.isRegistrationSuspended)
        XCTAssertEqual(fixture.manager.currentShortcut, original)
        XCTAssertEqual(fixture.carbon.registrations.count, 1)
    }

    func testModifiedEscapeIsAcceptedWithEachSupportedModifier() throws {
        let fixture = try makeFixture()
        for modifiers: NSEvent.ModifierFlags in [.shift, .control, .option, .command, [.command, .shift]] {
            try begin(fixture)
            sendKey(kVK_Escape, characters: "\u{1b}", modifiers: modifiers, to: fixture.panel)
            XCTAssertEqual(fixture.manager.currentShortcut, shortcut(kVK_Escape, modifiers))
            XCTAssertFalse(fixture.recorder.isRecording)
            XCTAssertFalse(fixture.manager.isRegistrationSuspended)
            XCTAssertEqual(fixture.carbon.registrations.count, 1)
        }
    }

    func testFlagsChangedShiftThenEscapeRecordsTheActualKeyDown() throws {
        let fixture = try makeFixture()
        try begin(fixture)
        sendFlagsChanged(kVK_Shift, modifiers: .shift, to: fixture.panel)
        XCTAssertTrue(fixture.recorder.isRecording)
        XCTAssertEqual(fixture.recorder.recordingModifiers, .shift)
        XCTAssertEqual(fixture.manager.currentShortcut, .empty, "Modifier events cannot guess an ordinary key")
        sendKey(kVK_Escape, characters: "\u{1b}", modifiers: .shift, to: fixture.panel)
        XCTAssertEqual(fixture.manager.currentShortcut, shortcut(kVK_Escape, .shift))
        XCTAssertFalse(fixture.manager.isRegistrationSuspended)
    }

    func testControlOneIsAnOrdinaryCandidateNotHardCodedAsReserved() throws {
        let fixture = try makeFixture()
        try begin(fixture)
        sendFlagsChanged(kVK_Control, modifiers: .control, to: fixture.panel)
        sendKey(kVK_ANSI_1, characters: "1", modifiers: .control, to: fixture.panel)
        XCTAssertEqual(fixture.manager.currentShortcut, shortcut(kVK_ANSI_1, .control))
        XCTAssertNil(fixture.manager.registrationError(for: .history))
        XCTAssertFalse(fixture.recorder.isRecording)
        XCTAssertFalse(fixture.manager.isRegistrationSuspended)
    }

    func testNoInputHintDoesNotCancelHeldShiftOrInventAKey() throws {
        let fixture = try makeFixture()
        try begin(fixture)
        sendFlagsChanged(kVK_Shift, modifiers: .shift, to: fixture.panel)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: ShortcutRecorderControl.noInputHintDelay + 0.1))
        XCTAssertTrue(fixture.recorder.hint?.contains("尚未收到组合") == true)
        XCTAssertTrue(fixture.recorder.isRecording)
        XCTAssertTrue(fixture.manager.isRegistrationSuspended)
        XCTAssertEqual(fixture.manager.currentShortcut, .empty)
        sendKey(kVK_Escape, characters: "\u{1b}", modifiers: .shift, to: fixture.panel)
        XCTAssertEqual(fixture.manager.currentShortcut, shortcut(kVK_Escape, .shift))
        XCTAssertNil(fixture.recorder.hint)
        XCTAssertFalse(fixture.manager.isRegistrationSuspended)
    }

    func testWindowSwitchAndCloseRestoreGlobalRegistrationsAndAllSavedBindings() throws {
        let first = try makeFixture()
        let originalKeys = [kVK_ANSI_V, kVK_ANSI_C, kVK_ANSI_P, kVK_ANSI_O, kVK_ANSI_K]
        for (action, key) in zip(HotKeyAction.allCases, originalKeys) {
            first.manager.setShortcut(shortcut(key, [.command, .shift]), for: action)
        }
        first.update(isInteractive: true)
        try begin(first)
        XCTAssertTrue(first.carbon.registrations.isEmpty)
        let second = try makeFixture()
        XCTAssertFalse(first.recorder.isRecording)
        XCTAssertFalse(first.manager.isRegistrationSuspended)
        XCTAssertEqual(first.carbon.registrations.count, HotKeyAction.allCases.filter(\.isGlobal).count)
        second.panel.orderOut(nil)
        first.panel.makeKeyAndOrderFront(nil)
        try begin(first)
        first.panel.close()
        XCTAssertFalse(first.manager.isRegistrationSuspended)
        XCTAssertEqual(first.carbon.registrations.count, HotKeyAction.allCases.filter(\.isGlobal).count)
        for (action, key) in zip(HotKeyAction.allCases, originalKeys) {
            XCTAssertEqual(first.manager.shortcut(for: action), shortcut(key, [.command, .shift]))
        }
    }

    func testDuplicateAndCarbonFailurePreserveOriginalAfterRealKeyDispatch() throws {
        let fixture = try makeFixture()
        let original = shortcut(kVK_ANSI_V, .command)
        fixture.setShortcut(original)
        fixture.manager.setShortcut(shortcut(kVK_ANSI_C, .command), for: .capture)
        for key in [kVK_ANSI_C, kVK_ANSI_Z] {
            fixture.carbon.failingKeyCodes = key == kVK_ANSI_Z ? [UInt32(key)] : []
            try begin(fixture)
            sendKey(key, characters: key == kVK_ANSI_C ? "c" : "z", modifiers: .command, to: fixture.panel)
            XCTAssertEqual(fixture.manager.currentShortcut, original)
            XCTAssertFalse(fixture.manager.isRegistrationSuspended)
            XCTAssertNotNil(fixture.manager.registrationError(for: .history))
            XCTAssertEqual(fixture.carbon.registrations.count, 2)
        }
    }

    func testLosingFirstResponderCancelsAndDoesNotConsumeLaterKeys() throws {
        let fixture = try makeFixture()
        fixture.setShortcut(shortcut(kVK_ANSI_V, .command))
        try begin(fixture)
        XCTAssertTrue(fixture.panel.makeFirstResponder(fixture.keySink))
        XCTAssertFalse(fixture.recorder.isRecording)
        XCTAssertFalse(fixture.manager.isRegistrationSuspended)

        sendKey(kVK_ANSI_A, characters: "a", modifiers: [], to: fixture.panel)
        XCTAssertEqual(fixture.keySink.keys, [UInt16(kVK_ANSI_A)])
        XCTAssertEqual(fixture.manager.currentShortcut, shortcut(kVK_ANSI_V, .command))
    }

    func testTwoWindowEventsAreIsolatedAndKeyWindowLossCancels() throws {
        let first = try makeFixture()
        let second = try makeFixture()
        first.panel.makeKeyAndOrderFront(nil)
        try begin(first)

        sendKey(kVK_ANSI_C, characters: "c", modifiers: .command, to: second.panel)
        XCTAssertTrue(first.recorder.isRecording, "A foreign window must not commit or cancel this recorder")
        XCTAssertEqual(first.manager.currentShortcut, .empty)
        XCTAssertEqual(second.manager.currentShortcut, .empty)

        second.panel.makeKeyAndOrderFront(nil)
        XCTAssertFalse(first.recorder.isRecording)
        XCTAssertFalse(first.manager.isRegistrationSuspended)
        try begin(second)
        sendKey(kVK_ANSI_Z, characters: "z", modifiers: .command, to: second.panel)
        XCTAssertEqual(second.manager.currentShortcut, shortcut(kVK_ANSI_Z, .command))
        XCTAssertEqual(first.manager.currentShortcut, .empty)
    }

    func testOrderOutCancelsRetainedHostAndRepeatedCancelDoesNotOverResume() throws {
        let fixture = try makeFixture()
        fixture.setShortcut(shortcut(kVK_ANSI_V, .command))
        try begin(fixture)
        fixture.panel.orderOut(nil)
        drainEvents()
        XCTAssertFalse(fixture.recorder.isRecording)
        XCTAssertFalse(fixture.manager.isRegistrationSuspended)
        XCTAssertNotNil(fixture.host.superview, "The SwiftUI/AppKit view need not disappear when hidden")
        let calls = fixture.carbon.registerCalls

        fixture.manager.suspendRegistration()
        fixture.recorder.cancelRecording()
        fixture.recorder.cancelRecording()
        fixture.recorder.invalidate()
        XCTAssertTrue(fixture.manager.isRegistrationSuspended, "Repeated cancellation must not release another owner's hold")
        XCTAssertEqual(fixture.carbon.registerCalls, calls)
        fixture.manager.resumeRegistration()
    }

    func testInactiveSettingsContextCancelsEvenWhileHostStaysVisible() throws {
        let fixture = try makeFixture()
        fixture.setShortcut(shortcut(kVK_ANSI_V, .command))
        try begin(fixture)
        fixture.update(isInteractive: false)
        XCTAssertTrue(fixture.panel.isVisible)
        XCTAssertNotNil(fixture.host.superview)
        XCTAssertFalse(fixture.recorder.isRecording)
        XCTAssertFalse(fixture.manager.isRegistrationSuspended)
        XCTAssertFalse(fixture.recorder.accessibilityPerformPress())
        sendKey(kVK_ANSI_C, characters: "c", modifiers: .command, to: fixture.panel)
        XCTAssertEqual(fixture.manager.currentShortcut, shortcut(kVK_ANSI_V, .command))
    }

    func testHiddenAncestorAndHostRemovalCancel() throws {
        let fixture = try makeFixture()
        try begin(fixture)
        fixture.host.isHidden = true
        XCTAssertFalse(fixture.recorder.isRecording)
        XCTAssertFalse(fixture.manager.isRegistrationSuspended)
        fixture.recorder.beginRecording()
        XCTAssertFalse(fixture.recorder.isRecording)
        fixture.host.isHidden = false

        try begin(fixture)
        fixture.host.removeFromSuperview()
        XCTAssertFalse(fixture.recorder.isRecording)
        XCTAssertFalse(fixture.manager.isRegistrationSuspended)
    }

    func testWindowCloseAndAppDeactivationCancel() throws {
        let fixture = try makeFixture()
        try begin(fixture)
        NotificationCenter.default.post(name: NSApplication.willResignActiveNotification, object: NSApp)
        XCTAssertFalse(fixture.recorder.isRecording)
        XCTAssertFalse(fixture.manager.isRegistrationSuspended)
        try begin(fixture)
        fixture.panel.close()
        XCTAssertFalse(fixture.recorder.isRecording)
        XCTAssertFalse(fixture.manager.isRegistrationSuspended)
    }

    func testClearButtonClickDoesNotStartRecordingOrSuspendRegistration() throws {
        let fixture = try makeFixture()
        fixture.setShortcut(shortcut(kVK_ANSI_V, .command))
        let unregisterCalls = fixture.carbon.unregisterCalls
        fixture.host.layoutSubtreeIfNeeded()
        let clear = fixture.host.clearButton
        let point = clear.convert(NSPoint(x: clear.bounds.midX, y: clear.bounds.midY), to: nil)
        try click(at: point, in: fixture.panel)

        XCTAssertEqual(fixture.manager.currentShortcut, .empty)
        XCTAssertFalse(fixture.recorder.isRecording)
        XCTAssertFalse(fixture.manager.isRegistrationSuspended)
        XCTAssertEqual(fixture.carbon.unregisterCalls, unregisterCalls + 1, "Clear only unregisters its own old shortcut")
        XCTAssertTrue(fixture.carbon.registrations.isEmpty)
    }

    func testAnotherRecorderCannotBeginButCurrentRecorderCanCancel() throws {
        let fixture = try makeFixture()
        let other = ShortcutRecorderHostView(hotKeyManager: fixture.manager)
        other.frame = NSRect(x: 20, y: 100, width: 200, height: 26)
        fixture.panel.contentView!.addSubview(other)
        try begin(fixture)

        other.recorder.beginRecording()
        XCTAssertFalse(other.recorder.isRecording)
        XCTAssertTrue(fixture.recorder.isRecording)
        XCTAssertTrue(fixture.panel.firstResponder === fixture.recorder)
        XCTAssertTrue(fixture.recorder.accessibilityPerformPress())
        XCTAssertFalse(fixture.manager.isRegistrationSuspended)
    }

    func testFocusAndSuspensionFailuresDoNotLeaveRecordingActive() throws {
        let fixture = try makeFixture()
        let rejectingPanel = RejectingRecorderPanel(contentRect: NSRect(x: 100, y: 100, width: 420, height: 460),
                                                    backing: .buffered, defer: false)
        defer { rejectingPanel.close() }
        let control = ShortcutRecorderControl(hotKeyManager: fixture.manager)
        rejectingPanel.contentView = control
        rejectingPanel.makeKeyAndOrderFront(nil)
        control.beginRecording()
        XCTAssertFalse(control.isRecording)
        XCTAssertNotNil(control.hint)
        XCTAssertFalse(fixture.manager.isRegistrationSuspended)

        fixture.panel.makeKeyAndOrderFront(nil)
        fixture.setShortcut(shortcut(kVK_ANSI_V, .command))
        fixture.carbon.failUnregister = true
        fixture.recorder.beginRecording()
        XCTAssertFalse(fixture.recorder.isRecording)
        XCTAssertNotNil(fixture.recorder.hint)
        XCTAssertFalse(fixture.manager.isRegistrationSuspended)
        XCTAssertEqual(fixture.carbon.registrations.count, 1)
        fixture.carbon.failUnregister = false
    }

    func testRepresentableTeardownReleasesSuspension() throws {
        let fixture = try makeFixture()
        let hosting = NSHostingView(rootView: AnyView(KeyRecorderView(
            shortcut: Binding(get: { fixture.manager.currentShortcut }, set: { fixture.manager.currentShortcut = $0 }),
            hotKeyManager: fixture.manager
        )))
        hosting.frame = NSRect(x: 20, y: 100, width: 280, height: 40)
        fixture.panel.contentView!.addSubview(hosting)
        hosting.layoutSubtreeIfNeeded()
        drainEvents()
        let control = try XCTUnwrap(findRecorder(in: hosting))
        control.beginRecording()
        XCTAssertTrue(control.isRecording)
        XCTAssertTrue(fixture.manager.isRegistrationSuspended)

        hosting.rootView = AnyView(EmptyView())
        hosting.layoutSubtreeIfNeeded()
        drainEvents()
        XCTAssertFalse(control.isRecording)
        XCTAssertFalse(fixture.manager.isRegistrationSuspended)
        hosting.removeFromSuperview()
        XCTAssertFalse(fixture.manager.isRegistrationSuspended)
    }

    func testShortcutsSettingsPropagatesInteractionStateToEveryRecorder() throws {
        let fixture = try makeFixture()
        let hosting = NSHostingView(rootView: ShortcutsSettingsView(hotKeyManager: fixture.manager))
        hosting.frame = fixture.panel.contentView!.bounds
        fixture.panel.contentView!.addSubview(hosting)
        hosting.layoutSubtreeIfNeeded()
        drainEvents()
        let controls = findRecorders(in: hosting)
        XCTAssertEqual(controls.count, HotKeyAction.allCases.count)
        let control = try XCTUnwrap(controls.first)
        control.beginRecording()
        XCTAssertTrue(control.isRecording)

        hosting.rootView = ShortcutsSettingsView(hotKeyManager: fixture.manager, isInteractive: false)
        hosting.layoutSubtreeIfNeeded()
        drainEvents()
        XCTAssertFalse(control.isRecording)
        XCTAssertFalse(fixture.manager.isRegistrationSuspended)
        XCTAssertTrue(fixture.panel.isVisible)
        XCTAssertTrue(findRecorders(in: hosting).allSatisfy { !$0.isInteractive && !$0.canStartRecording })
    }

    private func findRecorders(in view: NSView) -> [ShortcutRecorderControl] {
        if let recorder = view as? ShortcutRecorderControl { return [recorder] }
        return view.subviews.flatMap { findRecorders(in: $0) }
    }

    private func findRecorder(in view: NSView) -> ShortcutRecorderControl? {
        if let recorder = view as? ShortcutRecorderControl { return recorder }
        return view.subviews.lazy.compactMap { self.findRecorder(in: $0) }.first
    }

    private func makeFixture() throws -> RecorderFixture {
        _ = NSApplication.shared
        NSApp.activate(ignoringOtherApps: true)
        let fixture = RecorderFixture()
        fixture.panel.makeKeyAndOrderFront(nil)
        drainEvents()
        XCTAssertTrue(fixture.panel.isKeyWindow)
        XCTAssertTrue(NSApp.keyWindow === fixture.panel)
        addTeardownBlock { fixture.panel.close() }
        return fixture
    }

    private func begin(_ fixture: RecorderFixture) throws {
        fixture.host.layoutSubtreeIfNeeded()
        let point = fixture.recorder.convert(NSPoint(x: 12, y: 12), to: nil)
        try click(at: point, in: fixture.panel)
        XCTAssertTrue(fixture.recorder.isRecording)
        XCTAssertTrue(fixture.panel.firstResponder === fixture.recorder)
        XCTAssertTrue(fixture.manager.isRegistrationSuspended)
    }

    private func click(at point: NSPoint, in window: NSWindow) throws {
        let timestamp = ProcessInfo.processInfo.systemUptime
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                                   timestamp: timestamp, windowNumber: window.windowNumber,
                                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                                                 timestamp: timestamp + 0.01, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        // NSButton tracks mouse-up inside mouseDown; queue it before dispatching down.
        NSApp.postEvent(up, atStart: true)
        NSApp.sendEvent(down)
        drainEvents()
    }

    private func sendFlagsChanged(_ keyCode: Int, modifiers: NSEvent.ModifierFlags, to window: NSWindow) {
        let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: modifiers,
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                    context: nil, characters: "", charactersIgnoringModifiers: "",
                                    isARepeat: false, keyCode: UInt16(keyCode))!
        NSApp.sendEvent(event)
    }

    private func sendKey(_ keyCode: Int, characters: String, modifiers: NSEvent.ModifierFlags,
                         to window: NSWindow) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                    context: nil, characters: characters, charactersIgnoringModifiers: characters.lowercased(),
                                    isARepeat: false, keyCode: UInt16(keyCode))!
        NSApp.sendEvent(event)
    }

    private func drainEvents() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
    }

    private func shortcut(_ keyCode: Int, _ modifiers: NSEvent.ModifierFlags) -> RecordedShortcut {
        RecordedShortcut(keyCode: keyCode, modifiers: Int(modifiers.rawValue))
    }
}

@MainActor
private final class RecorderFixture {
    let panel = ClipboardPanel(contentRect: NSRect(x: 100, y: 100, width: 420, height: 460),
                               backing: .buffered, defer: false)
    let carbon = RecorderCarbonStub()
    let manager: HotKeyManager
    let host: ShortcutRecorderHostView
    let keySink = RecorderKeySink()
    private let defaults: UserDefaults
    private let suite = "ShortcutRecorderTests.\(UUID().uuidString)"
    var recorder: ShortcutRecorderControl { host.recorder }

    init() {
        defaults = UserDefaults(suiteName: suite)!
        let carbon = self.carbon
        manager = HotKeyManager(defaults: defaults,
                                registerHotKey: { carbon.register($0, modifiers: $1, id: $2, ref: &$3) },
                                unregisterHotKey: { carbon.unregister($0) }, installEventHandler: false,
                                conflictChecker: nil)
        host = ShortcutRecorderHostView(hotKeyManager: manager)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 460))
        host.frame = NSRect(x: 20, y: 30, width: 280, height: 26)
        keySink.frame = NSRect(x: 20, y: 180, width: 100, height: 50)
        content.addSubview(host)
        content.addSubview(keySink)
        panel.contentView = content
        recorder.onShortcutChange = { [weak self] in self?.setShortcut($0) }
        update(isInteractive: true)
    }

    deinit { defaults.removePersistentDomain(forName: suite) }

    func setShortcut(_ value: RecordedShortcut) {
        manager.currentShortcut = value
        update(isInteractive: true)
    }

    func update(isInteractive: Bool) {
        host.update(shortcut: manager.currentShortcut, hotKeyManager: manager,
                    isInteractive: isInteractive, palette: AppPalette(colorScheme: .light))
    }
}

private final class RecorderKeySink: NSView {
    var keys: [UInt16] = []
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { keys.append(event.keyCode) }
}

private final class RecorderMenuCommands: NSObject {
    var copyCalls = 0
    var undoCalls = 0
    @objc func copyCommand() { copyCalls += 1 }
    @objc func undoCommand() { undoCalls += 1 }
}

private final class RejectingRecorderPanel: ClipboardPanel {
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if responder is ShortcutRecorderControl { return false }
        return super.makeFirstResponder(responder)
    }
}

private final class RecorderCarbonStub {
    struct Registration {
        let keyCode: UInt32
        let modifiers: UInt32
    }
    var registrations: [EventHotKeyRef: Registration] = [:]
    var registerCalls = 0
    var unregisterCalls = 0
    var failingKeyCodes: Set<UInt32> = []
    var failUnregister = false
    private var nextRef = 1

    func register(_ keyCode: UInt32, modifiers: UInt32, id: EventHotKeyID,
                  ref: inout EventHotKeyRef?) -> OSStatus {
        registerCalls += 1
        if failingKeyCodes.contains(keyCode) || registrations.values.contains(where: {
            $0.keyCode == keyCode && $0.modifiers == modifiers
        }) { return OSStatus(eventHotKeyExistsErr) }
        let value = EventHotKeyRef(bitPattern: nextRef)!
        nextRef += 1
        ref = value
        registrations[value] = Registration(keyCode: keyCode, modifiers: modifiers)
        return noErr
    }

    func unregister(_ ref: EventHotKeyRef) -> OSStatus {
        unregisterCalls += 1
        guard !failUnregister else { return OSStatus(paramErr) }
        registrations[ref] = nil
        return noErr
    }
}
