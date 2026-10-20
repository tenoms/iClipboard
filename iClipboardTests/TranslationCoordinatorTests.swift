import AppKit
import Combine
import XCTest
@testable import iClipboard

@MainActor
final class TranslationCoordinatorTests: XCTestCase {
    private final class Preferences: TranslationPreferencesProviding {
        var isEnabled = false
        var hasSessionID = true
        var provider = TranslationProvider.microsoft
        let changes = PassthroughSubject<Void, Never>()
        var monitoringChanges: AnyPublisher<Void, Never> { changes.eraseToAnyPublisher() }

        func sessionID() throws -> String {
            guard hasSessionID else { throw TranslationFeatureError.missingSessionID }
            return "offline-test-session"
        }
    }

    private final class Authorization: TranslationAccessibilityAuthorizing {
        var isTrusted = false
        var refreshCount = 0
        var trustChanges: AnyPublisher<Void, Never> {
            Empty(completeImmediately: false).eraseToAnyPublisher()
        }
        func refresh() { refreshCount += 1 }
    }

    private final class Monitor: TranslationSelectionMonitoring {
        var onSelection: ((SelectedTextContext) -> Void)?
        var onSelectionInvalidated: (() -> Void)?
        var onStateChange: ((GlobalTextSelectionMonitor.State) -> Void)?
        var shouldIgnoreEventAtPoint: ((CGPoint) -> Bool)?
        var isRunning = false
        var startCount = 0
        func start() -> Bool {
            startCount += 1
            isRunning = true
            return true
        }
        func stop() { isRunning = false }
    }

    private actor Client: TranslationServicing {
        struct Request {
            let text: String
            let provider: TranslationProvider
            let sessionID: String
        }
        private struct Pending {
            let continuation: CheckedContinuation<TranslationResult, Error>
            let onUpdate: @Sendable (TranslationStreamUpdate) async -> Void
        }
        private(set) var requests: [Request] = []
        private(set) var cancellations = 0
        private var pending: [Int: Pending] = [:]

        func translateStreaming(
            text: String,
            provider: TranslationProvider,
            sessionID: String,
            onUpdate: @escaping @Sendable (TranslationStreamUpdate) async -> Void
        ) async throws -> TranslationResult {
            let id = requests.count
            requests.append(Request(text: text, provider: provider, sessionID: sessionID))
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    pending.updateValue(
                        Pending(continuation: continuation, onUpdate: onUpdate), forKey: id
                    )
                }
            } onCancel: {
                Task { await self.cancel(id) }
            }
        }

        private func cancel(_ id: Int) {
            guard let request = pending.removeValue(forKey: id) else { return }
            cancellations += 1
            request.continuation.resume(throwing: CancellationError())
        }

        func emit(_ update: TranslationStreamUpdate, request id: Int = 0) async {
            let onUpdate = pending[id]?.onUpdate
            await onUpdate?(update)
        }

        func finish(_ id: Int = 0) {
            guard let request = pending.removeValue(forKey: id) else { return }
            request.continuation.resume(returning: TranslationResult(
                sourceText: requests[id].text,
                translatedText: "译文",
                detectedLanguage: "en",
                targetLanguage: "zh",
                provider: requests[id].provider
            ))
        }

        func fail(_ id: Int = 0) {
            pending.removeValue(forKey: id)?.continuation.resume(
                throwing: TranslationFeatureError.transport("Offline failure")
            )
        }
    }

    @MainActor
    private final class Fixture {
        let preferences = Preferences()
        let authorization = Authorization()
        let monitor = Monitor()
        let client = Client()
        let panel = TranslationPanelController()
        lazy var coordinator = TranslationCoordinator(
            panelProvider: { [panel] in panel },
            preferences: preferences,
            accessibilityAuthorization: authorization,
            selectionMonitor: monitor,
            translationClient: client
        )

        init() { _ = NSApplication.shared }
        func dispose() { coordinator.stop() }
    }

    private let anchor = CGRect(x: 150, y: 150, width: 40, height: 20)
    private var selection: SelectedTextContext {
        SelectedTextContext(
            text: "new selection", anchorRect: anchor, cursorPoint: anchor.origin,
            sourceApplicationName: "Tests", sourceBundleIdentifier: "example.tests"
        )
    }

    func testManualTranslationStartsWithoutEnabledMonitoringOrAX() async {
        let fixture = Fixture()
        defer { fixture.dispose() }
        fixture.coordinator.translate(text: "manual OCR", anchor: anchor)
        await waitFor { await fixture.client.requests.count == 1 }
        let requests = await fixture.client.requests
        XCTAssertEqual(requests.first?.text, "manual OCR")
        XCTAssertEqual(requests.first?.provider, .microsoft)
        XCTAssertEqual(requests.first?.sessionID, "offline-test-session")
        XCTAssertEqual(fixture.authorization.refreshCount, 0)
        XCTAssertEqual(fixture.monitor.startCount, 0)
        XCTAssertEqual(fixture.panel.viewModel.presentation?.context.anchorRect, anchor)
        XCTAssertTrue(fixture.panel.isVisible)
        await fixture.client.finish()
        await waitFor { if case .translated = fixture.panel.viewModel.phase { return true }; return false }
    }

    func testMissingManualCredentialsShowNormalErrorWithoutCallingClient() async {
        let fixture = Fixture()
        defer { fixture.dispose() }
        fixture.preferences.hasSessionID = false
        fixture.coordinator.translate(text: "manual OCR", anchor: anchor)
        await waitFor { if case .failed = fixture.panel.viewModel.phase { return true }; return false }
        guard case let .failed(_, message) = fixture.panel.viewModel.phase else { return }
        XCTAssertEqual(message, TranslationFeatureError.missingSessionID.errorDescription)
        let count = await fixture.client.requests.count
        XCTAssertEqual(count, 0)
        fixture.coordinator.refreshMonitoringState()
        fixture.monitor.onSelectionInvalidated?()
        XCTAssertTrue(fixture.panel.isVisible)
        XCTAssertNotNil(fixture.panel.viewModel.presentation)
    }

    func testManualRequestAndResultSurviveRefreshInvalidationAndOutsideClick() async {
        let fixture = Fixture()
        defer { fixture.dispose() }
        fixture.coordinator.start()
        fixture.coordinator.translate(text: "manual OCR", anchor: anchor)
        await waitFor { await fixture.client.requests.count == 1 }
        fixture.coordinator.refreshMonitoringState()
        fixture.monitor.onSelectionInvalidated?()
        let click = NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
        _ = NSApp.sendEvent(click)
        await fixture.client.emit(.partialText("译文"))
        await fixture.client.finish()
        await waitFor { if case .translated = fixture.panel.viewModel.phase { return true }; return false }
        fixture.coordinator.refreshMonitoringState()
        fixture.monitor.onSelectionInvalidated?()
        let cancellations = await fixture.client.cancellations
        XCTAssertEqual(cancellations, 0)
        XCTAssertEqual(fixture.panel.viewModel.presentation?.context.text, "manual OCR")
        XCTAssertTrue(fixture.panel.isVisible)
    }

    func testPinnedNewSelectionDoesNotChangeManualRetrySource() async {
        let fixture = Fixture()
        defer { fixture.dispose() }
        fixture.coordinator.translate(text: "manual OCR", anchor: anchor)
        await waitFor { await fixture.client.requests.count == 1 }
        fixture.panel.viewModel.togglePin()
        fixture.preferences.isEnabled = true
        fixture.monitor.onSelection?(selection)
        await fixture.client.fail()
        await waitFor { if case .failed = fixture.panel.viewModel.phase { return true }; return false }
        fixture.preferences.isEnabled = false
        fixture.coordinator.refreshMonitoringState()
        fixture.panel.viewModel.requestRetry()
        await waitFor { await fixture.client.requests.count == 2 }
        let requests = await fixture.client.requests
        XCTAssertEqual(requests.map(\.text), ["manual OCR", "manual OCR"])
        XCTAssertTrue(fixture.panel.isPinned)
        await fixture.client.finish(1)
        await waitFor { if case .translated = fixture.panel.viewModel.phase { return true }; return false }
    }

    func testUnpinnedSelectionStillReplacesManualAndUsesSelectionEnableGate() async {
        let fixture = Fixture()
        defer { fixture.dispose() }
        fixture.coordinator.translate(text: "manual OCR", anchor: anchor)
        await waitFor { await fixture.client.requests.count == 1 }
        fixture.preferences.isEnabled = true
        fixture.monitor.onSelection?(selection)
        await waitFor { await fixture.client.cancellations == 1 }
        fixture.panel.viewModel.requestTranslation()
        await waitFor { await fixture.client.requests.count == 2 }
        await fixture.client.fail(1)
        await waitFor { if case .failed = fixture.panel.viewModel.phase { return true }; return false }
        fixture.preferences.isEnabled = false
        fixture.panel.viewModel.requestRetry()
        let requests = await fixture.client.requests
        XCTAssertEqual(requests.map(\.text), ["manual OCR", "new selection"])
        fixture.coordinator.refreshMonitoringState()
        XCTAssertEqual(fixture.panel.viewModel.phase, .hidden)
    }

    func testPresentationPauseKeepsPinAndLatestStreamingResultHiddenUntilAllRestores() async throws {
        let fixture = Fixture()
        defer { fixture.dispose() }
        fixture.coordinator.translate(text: "manual OCR", anchor: anchor)
        await waitFor { await fixture.client.requests.count == 1 }
        fixture.panel.viewModel.togglePin()
        let restore = fixture.coordinator.suspendPresentation()
        let restoreNested = fixture.coordinator.suspendPresentation()
        XCTAssertFalse(fixture.panel.isVisible)
        await fixture.client.emit(.partialText(String(repeating: "译文", count: 80)))
        await fixture.client.finish()
        await waitFor { if case .translated = fixture.panel.viewModel.phase { return true }; return false }
        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertFalse(fixture.panel.isVisible, "Late stream/animation updates must not order in")
        XCTAssertTrue(fixture.panel.isPinned)
        XCTAssertEqual(fixture.panel.viewModel.presentation?.translatedText, "译文")
        restore()
        restore()
        XCTAssertFalse(fixture.panel.isVisible)
        restoreNested()
        XCTAssertTrue(fixture.panel.isVisible)
        XCTAssertTrue(fixture.panel.isPinned)
    }

    func testPauseBeforeLazyPanelCreationDefersNewRequestAndDoesNotResurrectDismissal() async {
        let fixture = Fixture()
        defer { fixture.dispose() }
        let restore = fixture.coordinator.suspendPresentation()
        fixture.coordinator.translate(text: "manual OCR", anchor: anchor)
        await waitFor { await fixture.client.requests.count == 1 }
        await fixture.client.fail()
        await waitFor { if case .failed = fixture.panel.viewModel.phase { return true }; return false }
        XCTAssertFalse(fixture.panel.isVisible)
        restore()
        XCTAssertTrue(fixture.panel.isVisible)
        let restoreDismissed = fixture.panel.suspendPresentation()
        fixture.panel.viewModel.requestDismiss()
        restoreDismissed()
        XCTAssertFalse(fixture.panel.isVisible)
        XCTAssertEqual(fixture.panel.viewModel.phase, .hidden)
    }

    func testTriggerPausePreservesSelectionAndHideDuringPauseStaysHidden() {
        let panel = TranslationPanelController()
        defer { panel.hide() }
        panel.showSelection(selection)
        XCTAssertTrue(panel.isVisible)
        let restore = panel.suspendPresentation()
        XCTAssertFalse(panel.isVisible)
        restore()
        XCTAssertTrue(panel.isVisible)
        let restoreHidden = panel.suspendPresentation()
        panel.hide()
        restoreHidden()
        XCTAssertFalse(panel.isVisible)
    }

    func testMonitoringPauseDoesNotCancelManualAndRestoresUsingCurrentPreferences() async {
        let fixture = Fixture()
        defer { fixture.dispose() }
        fixture.preferences.isEnabled = true
        fixture.authorization.isTrusted = true
        fixture.coordinator.start()
        XCTAssertTrue(fixture.monitor.isRunning)
        fixture.coordinator.translate(text: "manual OCR", anchor: anchor)
        await waitFor { await fixture.client.requests.count == 1 }
        let restore = fixture.coordinator.suspendSelectionMonitoring()
        let restoreNested = fixture.coordinator.suspendSelectionMonitoring()
        XCTAssertFalse(fixture.monitor.isRunning)
        fixture.coordinator.refreshMonitoringState()
        fixture.monitor.onSelectionInvalidated?()
        fixture.monitor.onSelection?(selection)
        restore()
        restore()
        XCTAssertFalse(fixture.monitor.isRunning)
        restoreNested()
        XCTAssertTrue(fixture.monitor.isRunning)
        let restoreDisabled = fixture.coordinator.suspendSelectionMonitoring()
        fixture.preferences.isEnabled = false
        restoreDisabled()
        XCTAssertFalse(fixture.monitor.isRunning)
        await fixture.client.finish()
        await waitFor { if case .translated = fixture.panel.viewModel.phase { return true }; return false }
        let cancellations = await fixture.client.cancellations
        XCTAssertEqual(cancellations, 0)
        XCTAssertTrue(fixture.panel.isVisible)
    }

    func testStopDuringPausePreventsMonitoringAndPresentationResurrection() async {
        let fixture = Fixture()
        fixture.preferences.isEnabled = true
        fixture.authorization.isTrusted = true
        fixture.coordinator.start()
        fixture.coordinator.translate(text: "manual OCR", anchor: anchor)
        await waitFor { await fixture.client.requests.count == 1 }
        let restoreMonitoring = fixture.coordinator.suspendSelectionMonitoring()
        let restorePresentation = fixture.coordinator.suspendPresentation()
        fixture.coordinator.stop()
        restoreMonitoring()
        restorePresentation()
        await waitFor { await fixture.client.cancellations == 1 }
        XCTAssertFalse(fixture.monitor.isRunning)
        XCTAssertFalse(fixture.panel.isVisible)
        XCTAssertEqual(fixture.panel.viewModel.phase, .hidden)
    }

    func testUnusedPresentationPauseKeepsPanelsLazy() {
        var creations = 0
        let coordinator = TranslationCoordinator(panelProvider: {
            creations += 1
            return TranslationPanelController.shared
        })
        let restore = coordinator.suspendPresentation()
        restore()
        coordinator.stop()
        XCTAssertEqual(creations, 0)
    }

    func testWindowPauseCancelsOpeningAnimationPreservesPinAndBlocksReopening() async throws {
        let status = NSStatusBar.system.statusItem(withLength: 24)
        let panel = ClipboardPanel(
            contentRect: CGRect(x: 100, y: 100, width: 420, height: 460),
            backing: .buffered, defer: false
        )
        let manager = WindowManager(registerHotKey: false, reduceMotion: { false })
        manager.panel = panel
        manager.statusItem = status
        defer {
            panel.orderOut(nil)
            panel.close()
            NSStatusBar.system.removeStatusItem(status)
        }
        manager.openWindow()
        manager.isPinned = true
        let restore = manager.suspendPresentation()
        let restoreNested = manager.suspendPresentation()
        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(manager.isPanelVisible, "Suspension must not tear down history")
        XCTAssertTrue(manager.isPinned)
        XCTAssertFalse(manager.isPresentationAnimating)
        manager.toggleWindow()
        manager.openWindow()
        manager.closeWindow()
        manager.handleFocusLoss()
        manager.flashIcon()
        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertFalse(panel.isVisible)
        restore()
        restore()
        XCTAssertFalse(panel.isVisible)
        restoreNested()
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(manager.isPanelVisible)
        XCTAssertTrue(status.button!.isHighlighted)
        XCTAssertEqual(panel.alphaValue, 1)
        try await Task.sleep(nanoseconds: 160_000_000)
        XCTAssertTrue(panel.isVisible)
    }

    func testWindowClosedOrTerminatingDuringPauseIsNotRestored() {
        let status = NSStatusBar.system.statusItem(withLength: 24)
        defer { NSStatusBar.system.removeStatusItem(status) }
        for closingAction in 0..<3 {
            let panel = ClipboardPanel(
                contentRect: CGRect(x: 100, y: 100, width: 420, height: 460),
                backing: .buffered, defer: false
            )
            let manager = WindowManager(registerHotKey: false, reduceMotion: { true })
            manager.panel = panel
            manager.statusItem = status
            manager.openWindow()
            let restore = manager.suspendPresentation()
            if closingAction == 0 {
                manager.closeWindow()
            } else if closingAction == 1 {
                panel.close()
            } else {
                NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
            }
            restore()
            XCTAssertFalse(panel.isVisible)
            XCTAssertFalse(manager.isPanelVisible)
            panel.close()
        }
    }

    private func waitFor(_ condition: @MainActor () async -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for the offline translation lifecycle")
    }
}
