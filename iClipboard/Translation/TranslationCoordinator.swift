import AppKit
import Combine
import Foundation

@MainActor
protocol TranslationPreferencesProviding {
    var isEnabled: Bool { get }
    var hasSessionID: Bool { get }
    var provider: TranslationProvider { get }
    var monitoringChanges: AnyPublisher<Void, Never> { get }
    func sessionID() throws -> String
}

extension TranslationPreferences: TranslationPreferencesProviding {
    var monitoringChanges: AnyPublisher<Void, Never> {
        Publishers.CombineLatest($isEnabled.removeDuplicates(), $hasSessionID.removeDuplicates())
            .map { _ in () }
            .eraseToAnyPublisher()
    }
}

@MainActor
protocol TranslationAccessibilityAuthorizing {
    var isTrusted: Bool { get }
    var trustChanges: AnyPublisher<Void, Never> { get }
    func refresh()
}

extension AccessibilityAuthorizationService: TranslationAccessibilityAuthorizing {
    var trustChanges: AnyPublisher<Void, Never> {
        $isTrusted.removeDuplicates().map { _ in () }.eraseToAnyPublisher()
    }
}

@MainActor
protocol TranslationSelectionMonitoring: AnyObject {
    var onSelection: ((SelectedTextContext) -> Void)? { get set }
    var onSelectionInvalidated: (() -> Void)? { get set }
    var onStateChange: ((GlobalTextSelectionMonitor.State) -> Void)? { get set }
    var shouldIgnoreEventAtPoint: ((CGPoint) -> Bool)? { get set }
    func start() -> Bool
    func stop()
}

extension GlobalTextSelectionMonitor: TranslationSelectionMonitoring {}

@MainActor
final class TranslationCoordinator {
    static let shared = TranslationCoordinator()

    private enum Source {
        case selection
        case manual
    }

    private let preferences: TranslationPreferencesProviding
    private let accessibilityAuthorization: TranslationAccessibilityAuthorizing
    private let selectionMonitor: TranslationSelectionMonitoring
    private let translationClient: TranslationServicing
    private let panelProvider: () -> TranslationPanelController
    private var existingPanelController: TranslationPanelController?

    private var panelController: TranslationPanelController {
        if let existingPanelController { return existingPanelController }
        let controller = panelProvider()
        controller.viewModel.onRetry = { [weak self] context in
            guard let self, let source = self.presentationSource else { return }
            self.startTranslation(context, source: source)
        }
        controller.viewModel.onTranslate = { [weak self] in
            guard let self, let context = self.pendingSelection else { return }
            self.startTranslation(context, source: .selection)
        }
        controller.onDismiss = { [weak self] in
            self?.cancelTranslation()
            self?.pendingSelection = nil
            self?.presentationSource = nil
        }
        existingPanelController = controller
        if !presentationSuspensions.isEmpty {
            restorePanelPresentation = controller.suspendPresentation()
        }
        return controller
    }

    private var cancellables = Set<AnyCancellable>()
    private var translationTask: Task<Void, Never>?
    private var monitorRetryWorkItem: DispatchWorkItem?
    private var pendingSelection: SelectedTextContext?
    // This belongs to the result, not the latest (possibly pinned-out) selection.
    private var presentationSource: Source?
    private var generation = UUID()
    private var didStart = false
    private var monitoringRequested = false
    private var selectionMonitoringSuspensions = Set<UUID>()
    private var presentationSuspensions = Set<UUID>()
    private var restorePanelPresentation: (@MainActor () -> Void)?

    init(
        panelProvider: @escaping () -> TranslationPanelController = { .shared },
        preferences: TranslationPreferencesProviding? = nil,
        accessibilityAuthorization: TranslationAccessibilityAuthorizing? = nil,
        selectionMonitor: TranslationSelectionMonitoring? = nil,
        translationClient: TranslationServicing = DoubaoTranslationClient()
    ) {
        self.panelProvider = panelProvider
        self.preferences = preferences ?? TranslationPreferences.shared
        self.accessibilityAuthorization = accessibilityAuthorization ?? AccessibilityAuthorizationService.shared
        let selectionMonitor = selectionMonitor ?? GlobalTextSelectionMonitor()
        self.selectionMonitor = selectionMonitor
        self.translationClient = translationClient
        selectionMonitor.onSelection = { [weak self] context in
            self?.handleSelection(context)
        }

        selectionMonitor.onSelectionInvalidated = { [weak self] in
            guard let self, self.selectionMonitoringSuspensions.isEmpty else { return }
            self.pendingSelection = nil
            self.existingPanelController?.dismissTransientSurfaces(
                preservingResult: self.presentationSource == .manual
            )
        }

        selectionMonitor.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.handleMonitorStateChange(state)
            }
        }

        selectionMonitor.shouldIgnoreEventAtPoint = { [weak self] point in
            self?.existingPanelController?.containsScreenPoint(point) ?? false
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        monitoringRequested = true

        Publishers.Merge(preferences.monitoringChanges, accessibilityAuthorization.trustChanges)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                self.updateMonitoring(
                    enabled: self.preferences.isEnabled,
                    accessibilityTrusted: self.accessibilityAuthorization.isTrusted,
                    hasSessionID: self.preferences.hasSessionID
                )
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshMonitoringState()
            }
            .store(in: &cancellables)

        refreshMonitoringState()
    }

    func stop() {
        monitoringRequested = false
        cancelMonitoringRetry()
        cancelTranslation()
        pendingSelection = nil
        presentationSource = nil
        selectionMonitor.stop()
        existingPanelController?.hide()
        cancellables.removeAll()
        didStart = false
    }

    /// Explicit translation (for example, OCR) does not require selection monitoring or AX access.
    func translate(
        text: String,
        anchor: CGRect = CGRect(origin: NSEvent.mouseLocation, size: CGSize(width: 1, height: 1))
    ) {
        pendingSelection = nil
        let context = SelectedTextContext(
            text: text,
            anchorRect: anchor,
            cursorPoint: CGPoint(x: anchor.midX, y: anchor.midY),
            sourceApplicationName: "手动翻译",
            sourceBundleIdentifier: nil
        )
        startTranslation(context, source: .manual)
    }

    /// Keep lazy panel creation lazy, including when a request starts during capture.
    func suspendPresentation() -> @MainActor () -> Void {
        let token = UUID()
        if presentationSuspensions.isEmpty {
            restorePanelPresentation = existingPanelController?.suspendPresentation()
        }
        presentationSuspensions.insert(token)
        return { [weak self] in
            guard let self, self.presentationSuspensions.remove(token) != nil,
                  self.presentationSuspensions.isEmpty else { return }
            let restore = self.restorePanelPresentation
            self.restorePanelPresentation = nil
            restore?()
        }
    }

    func suspendSelectionMonitoring() -> @MainActor () -> Void {
        let token = UUID()
        selectionMonitoringSuspensions.insert(token)
        cancelMonitoringRetry()
        selectionMonitor.stop()
        return { [weak self] in
            guard let self, self.selectionMonitoringSuspensions.remove(token) != nil,
                  self.selectionMonitoringSuspensions.isEmpty,
                  self.monitoringRequested else { return }
            self.refreshMonitoringState()
        }
    }

    func refreshMonitoringState() {
        monitoringRequested = true
        accessibilityAuthorization.refresh()
        updateMonitoring(
            enabled: preferences.isEnabled,
            accessibilityTrusted: accessibilityAuthorization.isTrusted,
            hasSessionID: preferences.hasSessionID
        )
    }

    private func updateMonitoring(
        enabled: Bool,
        accessibilityTrusted: Bool,
        hasSessionID: Bool
    ) {
        guard selectionMonitoringSuspensions.isEmpty else {
            cancelMonitoringRetry()
            selectionMonitor.stop()
            return
        }
        if enabled && accessibilityTrusted && hasSessionID {
            if selectionMonitor.start() {
                cancelMonitoringRetry()
            } else {
                scheduleMonitoringRetry()
            }
        } else {
            cancelMonitoringRetry()
            selectionMonitor.stop()
            pendingSelection = nil
            if presentationSource == .manual {
                existingPanelController?.dismissTransientSurfaces(preservingResult: true)
            } else {
                cancelTranslation()
                existingPanelController?.hide()
            }
        }
    }

    private func cancelMonitoringRetry() {
        monitorRetryWorkItem?.cancel()
        monitorRetryWorkItem = nil
    }

    private func cancelTranslation() {
        translationTask?.cancel()
        translationTask = nil
        generation = UUID()
    }

    private func handleMonitorStateChange(_ state: GlobalTextSelectionMonitor.State) {
        if state == .eventMonitorUnavailable {
            scheduleMonitoringRetry()
        }
    }

    private func scheduleMonitoringRetry() {
        guard monitorRetryWorkItem == nil,
              monitoringRequested,
              selectionMonitoringSuspensions.isEmpty,
              preferences.isEnabled,
              accessibilityAuthorization.isTrusted,
              preferences.hasSessionID else {
            return
        }

        let item = DispatchWorkItem { [weak self] in
            guard let self, self.monitoringRequested,
                  self.selectionMonitoringSuspensions.isEmpty else { return }
            self.monitorRetryWorkItem = nil
            self.refreshMonitoringState()
        }
        monitorRetryWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
    }

    private func handleSelection(_ context: SelectedTextContext) {
        guard selectionMonitoringSuspensions.isEmpty,
              preferences.isEnabled, preferences.hasSessionID else { return }
        pendingSelection = context
        if !panelController.isPinned {
            cancelTranslation()
        }

        panelController.showSelection(context)
    }

    private func startTranslation(_ context: SelectedTextContext, source: Source) {
        guard source == .manual || preferences.isEnabled else { return }
        cancelTranslation()

        let requestGeneration = UUID()
        generation = requestGeneration
        presentationSource = source
        let provider = preferences.provider
        panelController.beginTranslation(
            context: context,
            provider: provider,
            dismissOnOutsideClick: source == .selection
        )

        translationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let sessionID = try self.preferences.sessionID()
                try Task.checkCancellation()
                let result = try await self.translationClient.translateStreaming(
                    text: context.text,
                    provider: provider,
                    sessionID: sessionID,
                    onUpdate: { update in
                        await MainActor.run {
                            guard !Task.isCancelled, self.generation == requestGeneration else { return }
                            switch update {
                            case let .detected(_, targetLanguage):
                                self.panelController.updateDetectedDirection(
                                    targetLanguage: targetLanguage
                                )
                            case let .partialText(text):
                                self.panelController.updateStreamingText(text)
                            }
                        }
                    }
                )
                try Task.checkCancellation()
                guard self.generation == requestGeneration else { return }
                await self.panelController.finish(result: result)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.generation == requestGeneration else { return }
                let message = (error as? LocalizedError)?.errorDescription
                    ?? "翻译失败，请稍后重试"
                self.panelController.showError(message)
            }
        }
    }
}
