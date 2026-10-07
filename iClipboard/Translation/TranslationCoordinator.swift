import AppKit
import Combine
import Foundation

@MainActor
final class TranslationCoordinator {
    static let shared = TranslationCoordinator()

    private let preferences = TranslationPreferences.shared
    private let selectionMonitor = GlobalTextSelectionMonitor()
    private let translationClient = DoubaoTranslationClient()
    private let panelController = TranslationPanelController.shared

    private var cancellables = Set<AnyCancellable>()
    private var translationTask: Task<Void, Never>?
    private var monitorRetryWorkItem: DispatchWorkItem?
    private var currentContext: SelectedTextContext?
    private var generation = UUID()
    private var didStart = false

    private init() {
        selectionMonitor.onSelection = { [weak self] context in
            Task { @MainActor in self?.handleSelection(context) }
        }

        selectionMonitor.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.handleMonitorStateChange(state)
            }
        }

        selectionMonitor.shouldIgnoreEventAtPoint = { point in
            TranslationPanelController.shared.containsScreenPoint(point)
        }

        panelController.viewModel.onRetry = { [weak self] in
            self?.startTranslation()
        }

        panelController.viewModel.onTranslate = { [weak self] in
            self?.startTranslation()
        }

        panelController.onDismiss = { [weak self] in
            self?.translationTask?.cancel()
            self?.translationTask = nil
            self?.generation = UUID()
            self?.currentContext = nil
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true

        Publishers.CombineLatest3(
            preferences.$isEnabled.removeDuplicates(),
            preferences.$accessibilityTrusted.removeDuplicates(),
            preferences.$hasSessionID.removeDuplicates()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] enabled, accessibilityTrusted, hasSessionID in
            self?.updateMonitoring(
                enabled: enabled,
                accessibilityTrusted: accessibilityTrusted,
                hasSessionID: hasSessionID
            )
        }
        .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshMonitoringState()
            }
            .store(in: &cancellables)

        preferences.refreshAccessibilityStatus()
        updateMonitoring(
            enabled: preferences.isEnabled,
            accessibilityTrusted: preferences.accessibilityTrusted,
            hasSessionID: preferences.hasSessionID
        )
    }

    func stop() {
        monitorRetryWorkItem?.cancel()
        monitorRetryWorkItem = nil
        translationTask?.cancel()
        translationTask = nil
        selectionMonitor.stop()
        panelController.hide()
        cancellables.removeAll()
        didStart = false
    }

    func refreshMonitoringState() {
        preferences.refreshAccessibilityStatus()
        updateMonitoring(
            enabled: preferences.isEnabled,
            accessibilityTrusted: preferences.accessibilityTrusted,
            hasSessionID: preferences.hasSessionID
        )
    }

    private func updateMonitoring(
        enabled: Bool,
        accessibilityTrusted: Bool,
        hasSessionID: Bool
    ) {
        if enabled && accessibilityTrusted && hasSessionID {
            if selectionMonitor.start() {
                monitorRetryWorkItem?.cancel()
                monitorRetryWorkItem = nil
            } else {
                scheduleMonitoringRetry()
            }
        } else {
            monitorRetryWorkItem?.cancel()
            monitorRetryWorkItem = nil
            selectionMonitor.stop()
            currentContext = nil
            translationTask?.cancel()
            panelController.hide()
        }
    }

    private func handleMonitorStateChange(_ state: GlobalTextSelectionMonitor.State) {
        if state == .eventTapUnavailable {
            scheduleMonitoringRetry()
        }
    }

    private func scheduleMonitoringRetry() {
        guard monitorRetryWorkItem == nil,
              preferences.isEnabled,
              preferences.accessibilityTrusted,
              preferences.hasSessionID else {
            return
        }

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.monitorRetryWorkItem = nil
            self.refreshMonitoringState()
        }
        monitorRetryWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
    }

    private func handleSelection(_ context: SelectedTextContext) {
        guard preferences.isEnabled, preferences.hasSessionID else { return }
        currentContext = context
        if !panelController.isPinned {
            translationTask?.cancel()
            translationTask = nil
            generation = UUID()
        }

        panelController.showSelection(context)
    }

    private func startTranslation() {
        guard preferences.isEnabled, let context = currentContext else { return }
        translationTask?.cancel()

        let requestGeneration = UUID()
        generation = requestGeneration
        let provider = preferences.provider
        panelController.beginTranslation(
            context: context,
            provider: provider
        )

        translationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let sessionID = try self.preferences.sessionID()
                let result = try await self.translationClient.translateStreaming(
                    text: context.text,
                    provider: provider,
                    sessionID: sessionID,
                    onUpdate: { [weak self] update in
                        await MainActor.run {
                            guard let self, self.generation == requestGeneration else { return }
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
                guard self.generation == requestGeneration else { return }
                let message = (error as? LocalizedError)?.errorDescription
                    ?? "翻译失败，请稍后重试"
                self.panelController.showError(message)
            }
        }
    }
}
