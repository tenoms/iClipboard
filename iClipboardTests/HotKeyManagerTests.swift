import AppKit
import Carbon
import XCTest
@testable import iClipboard

@MainActor
final class HotKeyManagerTests: XCTestCase {
    func testMigratesLegacyHistoryAndLeavesNewActionsUnassigned() throws {
        let defaults = makeDefaults()
        let legacy = shortcut(kVK_ANSI_V, [.command, .shift, .capsLock, .function])
        defaults.set(try JSONEncoder().encode(legacy), forKey: "globalShortcut")
        let carbon = CarbonStub()
        let manager = makeManager(defaults: defaults, carbon: carbon)

        XCTAssertEqual(manager.currentShortcut, legacy.normalized)
        XCTAssertEqual(HotKeyAction.history.rawValue, 1)
        for action in HotKeyAction.allCases where action != .history {
            XCTAssertEqual(manager.shortcut(for: action), .empty)
        }
        let registration = try XCTUnwrap(carbon.registrations.values.first)
        XCTAssertEqual(registration.id, 1)
        XCTAssertEqual(registration.signature, 0x69436C70)
        XCTAssertEqual(registration.modifiers, UInt32(cmdKey | shiftKey))
        XCTAssertEqual(try storedShortcuts(defaults)["1"], legacy.normalized)
        XCTAssertNil(defaults.object(forKey: "globalShortcut"))
    }

    func testNewHistorySettingTakesPrecedenceOverLegacyValue() throws {
        let defaults = makeDefaults()
        let capture = shortcut(kVK_ANSI_C)
        defaults.set(try JSONEncoder().encode(shortcut(kVK_ANSI_V)), forKey: "globalShortcut")
        defaults.set(
            try JSONEncoder().encode(["1": KeyboardShortcut.empty, "2": capture]),
            forKey: "globalShortcuts"
        )
        let carbon = CarbonStub()
        let manager = makeManager(defaults: defaults, carbon: carbon)

        XCTAssertEqual(manager.currentShortcut, .empty)
        XCTAssertEqual(manager.shortcut(for: .capture), capture)
        XCTAssertEqual(carbon.registrations.values.map(\.id), [HotKeyAction.capture.rawValue])
        XCTAssertNil(defaults.object(forKey: "globalShortcut"))
    }

    func testOnlyGlobalActionsRegisterWhileAllBindingsPersistAcrossInstances() throws {
        let defaults = makeDefaults()
        let carbon = CarbonStub()
        let manager = makeManager(defaults: defaults, carbon: carbon)
        let keyCodes = [kVK_ANSI_V, kVK_ANSI_C, kVK_ANSI_P, kVK_ANSI_O, kVK_ANSI_K]
        for (action, keyCode) in zip(HotKeyAction.allCases, keyCodes) {
            manager.setShortcut(shortcut(keyCode), for: action)
        }

        XCTAssertEqual(Set(carbon.registrations.values.map(\.id)), Set([UInt32(1), 2, 3]))
        let restoredCarbon = CarbonStub()
        let restored = makeManager(defaults: defaults, carbon: restoredCarbon)
        XCTAssertEqual(restoredCarbon.registrations.count, HotKeyAction.allCases.filter(\.isGlobal).count)
        for action in HotKeyAction.allCases {
            XCTAssertEqual(restored.shortcut(for: action), manager.shortcut(for: action))
            XCTAssertNil(restored.registrationError(for: action))
        }
    }

    func testDispatchesByActionIDAndPreservesLegacyHandlerAPI() {
        let manager = makeManager(carbon: CarbonStub())
        var invocations: [HotKeyAction] = []
        for action in HotKeyAction.allCases {
            manager.setHandler(for: action) { invocations.append(action) }
        }
        for action in HotKeyAction.allCases {
            if action.isGlobal { manager.invokeHandler(forHotKeyID: action.rawValue) }
            else { manager.invokeHandler(for: action) }
        }
        manager.invokeHandler(forHotKeyID: 0)
        manager.invokeHandler(forHotKeyID: 99)
        XCTAssertEqual(invocations, HotKeyAction.allCases)

        var legacyCalls = 0
        manager.setHandler(action: { legacyCalls += 1 })
        manager.invokeHandler()
        manager.invokeHandler(forHotKeyID: 1)
        manager.invokeHandler(for: .capture)
        XCTAssertEqual(legacyCalls, 2)
        XCTAssertEqual(invocations.last, .capture)
    }

    func testRetiredColorBindingIsRemovedWithoutBecomingClosePin() throws {
        let defaults = makeDefaults()
        let capture = shortcut(kVK_ANSI_C)
        let oldColor = shortcut(kVK_ANSI_K)
        defaults.set(try JSONEncoder().encode(["2": capture, "5": oldColor]), forKey: "globalShortcuts")
        let carbon = CarbonStub()
        let manager = makeManager(defaults: defaults, carbon: carbon)
        XCTAssertEqual(manager.shortcut(for: .capture), capture)
        XCTAssertEqual(manager.shortcut(for: .closePin), .empty)
        XCTAssertNil(HotKeyAction(rawValue: 5))
        XCTAssertEqual(HotKeyAction.pinClipboard.rawValue, 3)
        XCTAssertEqual(HotKeyAction.recognizeScreen.rawValue, 4)
        XCTAssertEqual(HotKeyAction.closePin.rawValue, 6)
        XCTAssertFalse(carbon.registrations.values.contains { $0.id == 5 || $0.id == 6 })
        XCTAssertNil(try storedShortcuts(defaults)["5"])
        var closeCalls = 0
        manager.setHandler(for: .closePin) { closeCalls += 1 }
        manager.invokeHandler(forHotKeyID: 5)
        XCTAssertEqual(closeCalls, 0)
        manager.setShortcut(oldColor, for: .closePin)
        XCTAssertEqual(try storedShortcuts(defaults)["6"], oldColor)
        manager.invokeHandler(forHotKeyID: 6)
        XCTAssertEqual(closeCalls, 0, "Context actions must never dispatch from a global Carbon event")
        manager.invokeHandler(for: .closePin)
        XCTAssertEqual(closeCalls, 1)
    }

    func testCopyImageFullTextKeepsConfiguredRecognitionIDAndCombinationWithoutMigration() throws {
        let defaults = makeDefaults()
        let capture = shortcut(kVK_ANSI_C)
        let pin = shortcut(kVK_ANSI_P)
        let recognition = shortcut(kVK_ANSI_O, [.control, .option])
        let close = shortcut(kVK_ANSI_K)
        defaults.set(try JSONEncoder().encode([
            "2": capture, "3": pin, "4": recognition, "6": close
        ]), forKey: "globalShortcuts")
        let saved = defaults.data(forKey: "globalShortcuts")
        let carbon = CarbonStub()
        let manager = makeManager(defaults: defaults, carbon: carbon)

        XCTAssertEqual(HotKeyAction.recognizeScreen.rawValue, 4)
        XCTAssertEqual(HotKeyAction.recognizeScreen.title, "复制图像全文")
        XCTAssertTrue(HotKeyAction.recognizeScreen.helpText.contains("当前选区"))
        XCTAssertTrue(HotKeyAction.recognizeScreen.helpText.contains("当前选中贴图"))
        XCTAssertEqual(manager.shortcut(for: .recognizeScreen), recognition)
        XCTAssertFalse(carbon.registrations.values.contains { $0.id == 4 || $0.id == 6 },
                       "Context-only bindings must not reserve keys outside their windows")
        XCTAssertEqual(defaults.data(forKey: "globalShortcuts"), saved)
        var calls = 0
        manager.setHandler(for: .recognizeScreen) { calls += 1 }
        manager.invokeHandler(forHotKeyID: 4)
        XCTAssertEqual(calls, 0)
        manager.invokeHandler(for: .recognizeScreen)
        XCTAssertEqual(calls, 1)

        manager.setShortcut(shortcut(kVK_ANSI_V), for: .history)
        XCTAssertEqual(try storedShortcuts(defaults)["4"], recognition)
        XCTAssertEqual(manager.shortcut(for: .capture), capture)
        XCTAssertEqual(manager.shortcut(for: .pinClipboard), pin)
        XCTAssertEqual(manager.shortcut(for: .closePin), close)
        XCTAssertNil(HotKeyAction(rawValue: 5), "Full-text copying must not restore the retired color shortcut")
        XCTAssertEqual(HotKeyAction.allCases.map(\.rawValue), [1, 2, 3, 4, 6],
                       "The renamed action must not introduce another shortcut or action ID")
    }

    func testContextualShiftBindingsNeverRegisterGloballyAcrossLoadChangeAndRecording() throws {
        let defaults = makeDefaults()
        let fullText = shortcut(kVK_ANSI_C, .shift)
        let close = shortcut(kVK_ANSI_W, .shift)
        defaults.set(try JSONEncoder().encode(["4": fullText, "6": close]), forKey: "globalShortcuts")
        let carbon = CarbonStub()
        let manager = makeManager(defaults: defaults, carbon: carbon, conflictChecker: { _ in
            XCTFail("A window-local binding must not query global system conflicts")
            return .conflict
        })
        XCTAssertTrue(carbon.operations.isEmpty)
        XCTAssertEqual(manager.shortcut(for: .recognizeScreen), fullText)
        XCTAssertEqual(manager.shortcut(for: .closePin), close)
        manager.setShortcut(shortcut(kVK_ANSI_X, .shift), for: .closePin)
        manager.suspendRegistration()
        manager.setShortcut(close, for: .closePin)
        manager.resumeRegistration()
        XCTAssertEqual(manager.shortcut(for: .closePin), close)
        XCTAssertEqual(try storedShortcuts(defaults)["4"], fullText)
        XCTAssertEqual(try storedShortcuts(defaults)["6"], close)
        XCTAssertTrue(carbon.operations.isEmpty, "Neither startup nor recording may reserve contextual keys with Carbon")
    }

    func testContextualMatcherUsesPhysicalKeyAndNormalizedModifiersAndPausesForRecorder() throws {
        let manager = makeManager(carbon: CarbonStub())
        manager.setShortcut(shortcut(kVK_ANSI_C, .shift), for: .recognizeScreen)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.shift, .capsLock, .function], timestamp: 0, windowNumber: 0, context: nil,
            characters: "C", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: UInt16(kVK_ANSI_C)))
        XCTAssertEqual(manager.contextualAction(for: event), .recognizeScreen)
        manager.suspendRegistration()
        XCTAssertNil(manager.contextualAction(for: event))
        manager.resumeRegistration()
        XCTAssertEqual(manager.contextualAction(for: event), .recognizeScreen)
    }

    func testStaleNativeContextEventsNeverInvokeWindowLocalActions() async {
        let manager = makeManager(carbon: CarbonStub())
        var calls = 0
        manager.setHandler(for: .recognizeScreen) { calls += 1 }
        manager.setHandler(for: .closePin) { calls += 1 }
        manager.enqueueNativeInvocation(forHotKeyID: 4)
        manager.enqueueNativeInvocation(forHotKeyID: 6)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(calls, 0)
    }

    func testQueuedNativeEventIsInvalidatedByRecordingEvenAfterRegistrationResumes() async {
        let manager = makeManager(carbon: CarbonStub())
        var calls = 0
        manager.setHandler(for: .history) { calls += 1 }
        manager.enqueueNativeInvocation(forHotKeyID: HotKeyAction.history.rawValue)
        manager.suspendRegistration()
        manager.resumeRegistration()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(calls, 0)
        manager.enqueueNativeInvocation(forHotKeyID: HotKeyAction.history.rawValue)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(calls, 1)
    }

    func testNormalizesModifiersAndRejectsDuplicateWithoutChangingEitherRegistration() {
        let defaults = makeDefaults()
        let carbon = CarbonStub()
        let manager = makeManager(defaults: defaults, carbon: carbon)
        manager.currentShortcut = shortcut(kVK_ANSI_V)
        manager.setShortcut(shortcut(kVK_ANSI_C), for: .capture)
        let originalRefs = Set(carbon.registrations.keys)
        let originalData = defaults.data(forKey: "globalShortcuts")
        let operationCount = carbon.operations.count

        let noisyHistory = shortcut(kVK_ANSI_V, [.command, .shift, .capsLock, .function, .numericPad])
        manager.setShortcut(noisyHistory, for: .capture)
        XCTAssertEqual(manager.shortcut(for: .capture), shortcut(kVK_ANSI_C))
        XCTAssertEqual(Set(carbon.registrations.keys), originalRefs)
        XCTAssertEqual(defaults.data(forKey: "globalShortcuts"), originalData)
        XCTAssertEqual(carbon.operations.count, operationCount)
        XCTAssertTrue(manager.registrationError(for: .capture)?.contains(HotKeyAction.history.title) == true)

        manager.currentShortcut = noisyHistory
        XCTAssertEqual(manager.currentShortcut, noisyHistory.normalized)
        XCTAssertEqual(carbon.operations.count, operationCount, "Equivalent modifiers must not re-register")
        XCTAssertNil(manager.registrationError(for: .history))
    }

    func testRejectsCapsLockOnlyUnmodifiedAndModifierOnlyShortcuts() {
        let carbon = CarbonStub()
        let manager = makeManager(carbon: carbon)
        let invalid = [
            shortcut(kVK_ANSI_A, [.capsLock]),
            shortcut(kVK_ANSI_A, [.function, .numericPad]),
            shortcut(kVK_ANSI_A, []),
            shortcut(kVK_Command, [.command]),
            shortcut(-2),
            shortcut(128)
        ]
        for candidate in invalid {
            manager.setShortcut(candidate, for: .capture)
            XCTAssertEqual(manager.shortcut(for: .capture), .empty)
            XCTAssertNotNil(manager.registrationError(for: .capture))
        }
        XCTAssertTrue(carbon.operations.isEmpty)

        manager.setShortcut(shortcut(kVK_ANSI_A, [.option, .control, .capsLock]), for: .capture)
        XCTAssertEqual(manager.shortcut(for: .capture), shortcut(kVK_ANSI_A, [.option, .control]))
        XCTAssertEqual(carbon.registrations.values.first?.modifiers, UInt32(optionKey | controlKey))
        XCTAssertNil(manager.registrationError(for: .capture))
    }

    func testCarbonRegistrationFailureKeepsOldRegistrationAndDefaults() throws {
        let defaults = makeDefaults()
        let carbon = CarbonStub()
        let manager = makeManager(defaults: defaults, carbon: carbon)
        manager.setShortcut(shortcut(kVK_ANSI_V))
        let originalRef = try XCTUnwrap(carbon.registrations.keys.first)
        let originalData = defaults.data(forKey: "globalShortcuts")
        carbon.failingKeyCodes.insert(UInt32(kVK_ANSI_C))
        carbon.operations.removeAll()

        manager.setShortcut(shortcut(kVK_ANSI_C))

        XCTAssertEqual(manager.currentShortcut, shortcut(kVK_ANSI_V))
        XCTAssertNotNil(carbon.registrations[originalRef])
        XCTAssertEqual(carbon.registrations.count, 1)
        XCTAssertEqual(defaults.data(forKey: "globalShortcuts"), originalData)
        XCTAssertEqual(carbon.operations, [.register(id: 1, keyCode: UInt32(kVK_ANSI_C))])
        XCTAssertTrue(manager.registrationError(for: .history)?.contains(String(eventHotKeyExistsErr)) == true)
    }

    func testSuccessfulReplacementRegistersBeforeUnregisteringOldKey() throws {
        let carbon = CarbonStub()
        let manager = makeManager(carbon: carbon)
        manager.currentShortcut = shortcut(kVK_ANSI_V)
        let originalRef = try XCTUnwrap(carbon.registrations.keys.first)
        carbon.operations.removeAll()

        manager.currentShortcut = shortcut(kVK_ANSI_C)

        XCTAssertEqual(carbon.operations, [
            .register(id: 1, keyCode: UInt32(kVK_ANSI_C)), .unregister(originalRef)
        ])
        XCTAssertEqual(manager.currentShortcut, shortcut(kVK_ANSI_C))
        XCTAssertNil(carbon.registrations[originalRef])
        XCTAssertEqual(carbon.registrations.count, 1)
    }

    func testUnregisterFailureRollsBackReplacementAndKeepsDefaults() throws {
        let defaults = makeDefaults()
        let carbon = CarbonStub()
        let manager = makeManager(defaults: defaults, carbon: carbon)
        manager.currentShortcut = shortcut(kVK_ANSI_V)
        let originalRef = try XCTUnwrap(carbon.registrations.keys.first)
        let originalData = defaults.data(forKey: "globalShortcuts")
        carbon.failingUnregisterRefs.insert(originalRef)

        manager.currentShortcut = shortcut(kVK_ANSI_C)

        XCTAssertEqual(manager.currentShortcut, shortcut(kVK_ANSI_V))
        XCTAssertEqual(Set(carbon.registrations.keys), [originalRef])
        XCTAssertEqual(defaults.data(forKey: "globalShortcuts"), originalData)
        XCTAssertNotNil(manager.registrationError(for: .history))
    }

    func testSuccessWithoutAReferenceIsRejectedWithoutLosingOldKey() throws {
        let carbon = CarbonStub()
        let manager = makeManager(carbon: carbon)
        manager.currentShortcut = shortcut(kVK_ANSI_V)
        let originalRef = try XCTUnwrap(carbon.registrations.keys.first)
        carbon.returnMissingReference = true

        manager.currentShortcut = shortcut(kVK_ANSI_C)

        XCTAssertEqual(manager.currentShortcut, shortcut(kVK_ANSI_V))
        XCTAssertEqual(Set(carbon.registrations.keys), [originalRef])
        XCTAssertNotNil(manager.registrationError(for: .history))
    }

    func testRecordingSuspendsAllActionsAndBalancedResumeRestoresThem() {
        let defaults = makeDefaults()
        let carbon = CarbonStub()
        let manager = makeManager(defaults: defaults, carbon: carbon)
        manager.currentShortcut = shortcut(kVK_ANSI_V)
        manager.setShortcut(shortcut(kVK_ANSI_C), for: .capture)
        let originalData = defaults.data(forKey: "globalShortcuts")
        var invocations = 0
        manager.setHandler { invocations += 1 }

        manager.suspendRegistration()
        manager.suspendRegistration()
        XCTAssertTrue(manager.isRegistrationSuspended)
        XCTAssertTrue(carbon.registrations.isEmpty, "Registered combinations must reach the recorder")
        XCTAssertEqual(manager.currentShortcut, shortcut(kVK_ANSI_V))
        manager.invokeHandler()
        XCTAssertEqual(invocations, 0)

        manager.resumeRegistration()
        XCTAssertTrue(carbon.registrations.isEmpty)
        manager.resumeRegistration()
        XCTAssertFalse(manager.isRegistrationSuspended)
        XCTAssertEqual(Set(carbon.registrations.values.map(\.id)), [1, 2])
        XCTAssertEqual(defaults.data(forKey: "globalShortcuts"), originalData)
        manager.invokeHandler()
        XCTAssertEqual(invocations, 1)
        let operationCount = carbon.operations.count
        manager.resumeRegistration()
        XCTAssertEqual(carbon.operations.count, operationCount, "Extra stops must not register twice")
    }

    func testSuspensionFailureAbortsRecordingAndRestoresOtherRegistrations() throws {
        let defaults = makeDefaults()
        let carbon = CarbonStub()
        let manager = makeManager(defaults: defaults, carbon: carbon)
        manager.currentShortcut = shortcut(kVK_ANSI_V)
        manager.setShortcut(shortcut(kVK_ANSI_C), for: .capture)
        let historyRef = try XCTUnwrap(carbon.registrations.first { $0.value.id == 1 }?.key)
        let originalData = defaults.data(forKey: "globalShortcuts")
        carbon.failingUnregisterRefs.insert(historyRef)

        manager.suspendRegistration()

        XCTAssertFalse(manager.isRegistrationSuspended, "Do not record while Carbon still owns a combination")
        XCTAssertEqual(Set(carbon.registrations.values.map(\.id)), [1, 2])
        XCTAssertNotNil(manager.registrationError(for: .history))
        XCTAssertEqual(defaults.data(forKey: "globalShortcuts"), originalData)
        carbon.failingUnregisterRefs.removeAll()
    }

    func testFailedShortcutStagedDuringRecordingRestoresOriginalBeforeAttemptingChange() {
        let defaults = makeDefaults()
        let carbon = CarbonStub()
        let manager = makeManager(defaults: defaults, carbon: carbon)
        manager.currentShortcut = shortcut(kVK_ANSI_V)
        let originalData = defaults.data(forKey: "globalShortcuts")
        manager.suspendRegistration()
        carbon.operations.removeAll()
        carbon.failingKeyCodes.insert(UInt32(kVK_ANSI_C))

        manager.setShortcut(shortcut(kVK_ANSI_C), for: .history)
        XCTAssertTrue(carbon.operations.isEmpty)
        XCTAssertEqual(manager.currentShortcut, shortcut(kVK_ANSI_V))
        manager.resumeRegistration()

        XCTAssertEqual(carbon.operations, [
            .register(id: 1, keyCode: UInt32(kVK_ANSI_V)),
            .register(id: 1, keyCode: UInt32(kVK_ANSI_C))
        ])
        XCTAssertEqual(carbon.registrations.values.first?.keyCode, UInt32(kVK_ANSI_V))
        XCTAssertEqual(manager.currentShortcut, shortcut(kVK_ANSI_V))
        XCTAssertEqual(defaults.data(forKey: "globalShortcuts"), originalData)
        XCTAssertNotNil(manager.registrationError(for: .history))
    }

    func testSuccessfulChangeStagedDuringRecordingCommitsOnResumeAndReservesItsCombination() {
        let carbon = CarbonStub()
        let manager = makeManager(carbon: carbon)
        manager.currentShortcut = shortcut(kVK_ANSI_V)
        manager.suspendRegistration()
        manager.setShortcut(shortcut(kVK_ANSI_C), for: .history)
        manager.setShortcut(shortcut(kVK_ANSI_C, [.command, .shift, .capsLock]), for: .capture)
        XCTAssertNotNil(manager.registrationError(for: .capture))
        XCTAssertTrue(carbon.registrations.isEmpty)

        manager.resumeRegistration()

        XCTAssertEqual(manager.currentShortcut, shortcut(kVK_ANSI_C))
        XCTAssertEqual(manager.shortcut(for: .capture), .empty)
        XCTAssertEqual(carbon.registrations.count, 1)
        XCTAssertEqual(carbon.registrations.values.first?.keyCode, UInt32(kVK_ANSI_C))
    }

    func testResumeFailurePreservesConfigurationAndCanBeRetried() {
        let defaults = makeDefaults()
        let carbon = CarbonStub()
        let manager = makeManager(defaults: defaults, carbon: carbon)
        manager.currentShortcut = shortcut(kVK_ANSI_V)
        let originalData = defaults.data(forKey: "globalShortcuts")
        manager.suspendRegistration()
        carbon.failingKeyCodes.insert(UInt32(kVK_ANSI_V))
        manager.resumeRegistration()
        XCTAssertEqual(manager.currentShortcut, shortcut(kVK_ANSI_V))
        XCTAssertEqual(defaults.data(forKey: "globalShortcuts"), originalData)
        XCTAssertNotNil(manager.registrationError(for: .history))

        carbon.failingKeyCodes.removeAll()
        manager.suspendRegistration()
        manager.resumeRegistration()
        XCTAssertEqual(carbon.registrations.count, 1)
        XCTAssertNil(manager.registrationError(for: .history))
    }

    func testClearingHistoryUnregistersOnlyHistoryAndPersistsEmptyShortcut() throws {
        let defaults = makeDefaults()
        let carbon = CarbonStub()
        let manager = makeManager(defaults: defaults, carbon: carbon)
        manager.currentShortcut = shortcut(kVK_ANSI_V)
        manager.setShortcut(shortcut(kVK_ANSI_C), for: .capture)

        manager.currentShortcut = .empty

        XCTAssertEqual(manager.currentShortcut, .empty)
        XCTAssertEqual(manager.shortcut(for: .capture), shortcut(kVK_ANSI_C))
        XCTAssertEqual(carbon.registrations.values.map(\.id), [2])
        XCTAssertEqual(try storedShortcuts(defaults)["1"], .empty)
    }

    func testLoadingRejectsNormalizedDuplicateAndCapsLockOnlyShortcut() throws {
        let defaults = makeDefaults()
        defaults.set(try JSONEncoder().encode([
            "1": shortcut(kVK_ANSI_V),
            "2": shortcut(kVK_ANSI_V, [.command, .shift, .capsLock]),
            "3": shortcut(kVK_ANSI_P, [.capsLock])
        ]), forKey: "globalShortcuts")
        let carbon = CarbonStub()
        let manager = makeManager(defaults: defaults, carbon: carbon)

        XCTAssertEqual(carbon.registrations.count, 1)
        XCTAssertEqual(manager.currentShortcut, shortcut(kVK_ANSI_V))
        XCTAssertEqual(manager.shortcut(for: .capture), .empty)
        XCTAssertEqual(manager.shortcut(for: .pinClipboard), .empty)
        XCTAssertNotNil(manager.registrationError(for: .capture))
        XCTAssertNotNil(manager.registrationError(for: .pinClipboard))
    }

    func testCommonKeyNamesIncludePunctuationNavigationKeypadAndFunctionKeys() {
        XCTAssertEqual(SpecialKey(rawValue: kVK_ANSI_A)?.description, "A")
        XCTAssertEqual(SpecialKey(rawValue: kVK_ANSI_9)?.description, "9")
        XCTAssertEqual(SpecialKey(rawValue: kVK_ANSI_Slash)?.description, "/")
        XCTAssertEqual(SpecialKey(rawValue: kVK_LeftArrow)?.description, "←")
        XCTAssertEqual(SpecialKey(rawValue: kVK_ANSI_Keypad7)?.description, "小键盘 7")
        XCTAssertEqual(SpecialKey(rawValue: kVK_F12)?.description, "F12")
    }

    func testSystemQueryRequiresEnabledAndExactCarbonMatch() {
        let controlOne = shortcut(kVK_ANSI_1, .control)
        let disabled = symbolicEntry(kVK_ANSI_1, UInt32(controlKey), enabled: false)
        let wrongKey = symbolicEntry(kVK_ANSI_2, UInt32(controlKey), enabled: true)
        let extraModifier = symbolicEntry(kVK_ANSI_1, UInt32(controlKey | shiftKey), enabled: true)
        XCTAssertEqual(SystemShortcutConflicts.check(controlOne, query: {
            (noErr, [disabled, wrongKey, extraModifier])
        }), .noConflict, "A disabled Ctrl+1 is not a confirmed system conflict")
        let enabled = symbolicEntry(kVK_ANSI_1, UInt32(controlKey), enabled: true)
        XCTAssertEqual(SystemShortcutConflicts.check(
            shortcut(kVK_ANSI_1, [.control, .capsLock, .function]), query: { (noErr, [enabled]) }
        ), .conflict)
        XCTAssertEqual(controlOne.carbonModifiers, 4096)
    }

    func testSystemQueryFailureAndIncompleteResultsRemainUnknown() {
        let candidate = shortcut(kVK_ANSI_1, .control)
        XCTAssertEqual(SystemShortcutConflicts.check(candidate, query: {
            (OSStatus(memFullErr), nil)
        }), .unknown(OSStatus(memFullErr)))
        XCTAssertEqual(SystemShortcutConflicts.check(candidate, query: { (noErr, nil) }), .unknown(OSStatus(paramErr)))
        XCTAssertEqual(SystemShortcutConflicts.check(candidate, query: { (noErr, [[:]]) }), .unknown(OSStatus(paramErr)))
        XCTAssertEqual(SystemShortcutConflicts.check(candidate, query: {
            (noErr, [[kHISymbolicHotKeyEnabled as String: true]])
        }), .unknown(OSStatus(paramErr)))
    }

    func testDisabledSystemControlOneStillUsesRealRegistrationPath() {
        let carbon = CarbonStub()
        let disabled = symbolicEntry(kVK_ANSI_1, UInt32(controlKey), enabled: false)
        let manager = makeManager(carbon: carbon, conflictChecker: {
            SystemShortcutConflicts.check($0, query: { (noErr, [disabled]) })
        })
        let candidate = shortcut(kVK_ANSI_1, .control)
        manager.setShortcut(candidate, for: .capture)
        XCTAssertEqual(manager.shortcut(for: .capture), candidate)
        XCTAssertEqual(carbon.registrations.values.first?.keyCode, 18)
        XCTAssertEqual(carbon.registrations.values.first?.modifiers, 4096)
        XCTAssertNil(manager.registrationError(for: .capture))
        XCTAssertFalse(manager.hasConfirmedSystemConflict(for: .capture))
    }

    func testConfirmedSystemConflictRejectsSubmissionAndKeepsOldBinding() {
        let defaults = makeDefaults()
        let carbon = CarbonStub()
        let candidate = shortcut(kVK_ANSI_1, .control)
        let manager = makeManager(defaults: defaults, carbon: carbon, conflictChecker: {
            $0 == candidate ? .conflict : .noConflict
        })
        manager.currentShortcut = shortcut(kVK_ANSI_V)
        let originalData = defaults.data(forKey: "globalShortcuts")
        let refs = Set(carbon.registrations.keys)
        carbon.operations.removeAll()
        manager.currentShortcut = candidate
        XCTAssertEqual(manager.currentShortcut, shortcut(kVK_ANSI_V))
        XCTAssertEqual(Set(carbon.registrations.keys), refs)
        XCTAssertEqual(defaults.data(forKey: "globalShortcuts"), originalData)
        XCTAssertTrue(carbon.operations.isEmpty)
        XCTAssertTrue(manager.hasConfirmedSystemConflict(for: .history))
        XCTAssertTrue(manager.registrationError(for: .history)?.contains("系统设置") == true)
    }

    func testConfirmedSystemConflictBlocksInitialAndResumeRegistrationWithoutDeletingSavedBinding() throws {
        let defaults = makeDefaults()
        let candidate = shortcut(kVK_ANSI_1, .control)
        defaults.set(try JSONEncoder().encode(["1": candidate]), forKey: "globalShortcuts")
        let originalData = defaults.data(forKey: "globalShortcuts")
        let carbon = CarbonStub()
        var result: SystemShortcutConflictResult = .conflict
        let manager = makeManager(defaults: defaults, carbon: carbon, conflictChecker: { _ in result })
        XCTAssertEqual(manager.currentShortcut, candidate)
        XCTAssertTrue(carbon.operations.isEmpty)
        XCTAssertTrue(manager.hasConfirmedSystemConflict(for: .history))
        XCTAssertEqual(defaults.data(forKey: "globalShortcuts"), originalData)

        result = .noConflict
        manager.suspendRegistration()
        manager.resumeRegistration()
        XCTAssertEqual(carbon.registrations.count, 1)
        XCTAssertNil(manager.registrationError(for: .history))
        manager.suspendRegistration()
        carbon.operations.removeAll()
        result = .conflict
        manager.resumeRegistration()
        XCTAssertTrue(carbon.registrations.isEmpty)
        XCTAssertTrue(carbon.operations.isEmpty)
        XCTAssertEqual(manager.currentShortcut, candidate)
        XCTAssertEqual(defaults.data(forKey: "globalShortcuts"), originalData)
        XCTAssertTrue(manager.hasConfirmedSystemConflict(for: .history))
    }

    func testUnknownSystemQueryDoesNotPretendConflictFreeOrPreventCarbonAttempt() {
        let carbon = CarbonStub()
        let manager = makeManager(carbon: carbon, conflictChecker: { _ in .unknown(OSStatus(memFullErr)) })
        manager.currentShortcut = shortcut(kVK_ANSI_1, .control)
        XCTAssertEqual(carbon.registrations.count, 1)
        XCTAssertNil(manager.registrationError(for: .history))
        XCTAssertFalse(manager.hasConfirmedSystemConflict(for: .history))
        XCTAssertTrue(manager.systemConflictWarning(for: .history)?.contains("暂时无法检查") == true)
        XCTAssertTrue(manager.systemConflictWarning(for: .history)?.contains("-108") == true)
        manager.currentShortcut = .empty
        XCTAssertNil(manager.systemConflictWarning(for: .history))
    }

    private func symbolicEntry(_ keyCode: Int, _ modifiers: UInt32, enabled: Bool) -> [String: Any] {
        [kHISymbolicHotKeyCode as String: keyCode,
         kHISymbolicHotKeyModifiers as String: modifiers,
         kHISymbolicHotKeyEnabled as String: enabled]
    }

    private func shortcut(
        _ keyCode: Int,
        _ modifiers: NSEvent.ModifierFlags = [.command, .shift]
    ) -> KeyboardShortcut {
        KeyboardShortcut(keyCode: keyCode, modifiers: Int(modifiers.rawValue))
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "HotKeyManagerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func makeManager(defaults: UserDefaults? = nil, carbon: CarbonStub,
                             conflictChecker: HotKeyManager.SystemConflictChecker? = nil) -> HotKeyManager {
        HotKeyManager(
            defaults: defaults ?? makeDefaults(),
            registerHotKey: { carbon.register($0, modifiers: $1, id: $2, ref: &$3) },
            unregisterHotKey: { carbon.unregister($0) },
            installEventHandler: false,
            conflictChecker: conflictChecker
        )
    }

    private func storedShortcuts(_ defaults: UserDefaults) throws -> [String: KeyboardShortcut] {
        try JSONDecoder().decode(
            [String: KeyboardShortcut].self,
            from: XCTUnwrap(defaults.data(forKey: "globalShortcuts"))
        )
    }
}

private final class CarbonStub {
    struct Registration {
        let keyCode: UInt32
        let modifiers: UInt32
        let signature: OSType
        let id: UInt32
    }

    enum Operation: Equatable {
        case register(id: UInt32, keyCode: UInt32)
        case unregister(EventHotKeyRef)
    }

    var registrations: [EventHotKeyRef: Registration] = [:]
    var operations: [Operation] = []
    var failingKeyCodes: Set<UInt32> = []
    var failingUnregisterRefs: Set<EventHotKeyRef> = []
    var returnMissingReference = false
    private var nextRef = 1

    func register(_ keyCode: UInt32, modifiers: UInt32, id: EventHotKeyID, ref: inout EventHotKeyRef?) -> OSStatus {
        operations.append(.register(id: id.id, keyCode: keyCode))
        if failingKeyCodes.contains(keyCode) || registrations.values.contains(where: {
            $0.keyCode == keyCode && $0.modifiers == modifiers
        }) {
            return OSStatus(eventHotKeyExistsErr)
        }
        guard !returnMissingReference else { return noErr }
        let newRef = EventHotKeyRef(bitPattern: nextRef)!
        nextRef += 1
        registrations[newRef] = Registration(
            keyCode: keyCode, modifiers: modifiers, signature: id.signature, id: id.id
        )
        ref = newRef
        return noErr
    }

    func unregister(_ ref: EventHotKeyRef) -> OSStatus {
        operations.append(.unregister(ref))
        guard !failingUnregisterRefs.contains(ref) else { return OSStatus(paramErr) }
        registrations[ref] = nil
        return noErr
    }
}
