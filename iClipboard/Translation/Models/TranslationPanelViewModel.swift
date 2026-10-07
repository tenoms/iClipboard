import AppKit
import Foundation

@MainActor
final class TranslationPanelViewModel: ObservableObject {
    struct Presentation: Equatable {
        let context: SelectedTextContext
        let provider: TranslationProvider
        var directionLabel: String
        var translatedText: String
    }

    enum Phase: Equatable {
        case hidden
        case translating(Presentation)
        case translated(Presentation, TranslationResult)
        case failed(Presentation, message: String)
    }

    @Published private(set) var phase: Phase = .hidden
    @Published private(set) var isPinned = false
    @Published private(set) var didCopy = false

    var onTranslate: (() -> Void)?
    var onRetry: (() -> Void)?
    var onPinChange: ((Bool) -> Void)?
    var onDismiss: (() -> Void)?

    private var copyFeedbackTask: Task<Void, Never>?
    private var streamRevealTask: Task<Void, Never>?

    var presentation: Presentation? {
        switch phase {
        case .hidden:
            return nil
        case let .translating(presentation),
             let .translated(presentation, _),
             let .failed(presentation, _):
            return presentation
        }
    }

    func beginTranslation(_ context: SelectedTextContext, provider: TranslationProvider) {
        streamRevealTask?.cancel()
        streamRevealTask = nil
        resetCopyFeedback()
        phase = .translating(
            Presentation(
                context: context,
                provider: provider,
                directionLabel: "正在识别语言",
                translatedText: ""
            )
        )
    }

    func setDetectedDirection(targetLanguage: String) {
        guard case var .translating(presentation) = phase else { return }
        presentation.directionLabel = targetLanguage == "en"
            ? "中文 → English"
            : "其他语言 → 中文"
        phase = .translating(presentation)
    }

    func updatePartialText(_ text: String) {
        guard !text.isEmpty else { return }
        streamRevealTask?.cancel()
        streamRevealTask = Task { [weak self] in
            await self?.reveal(to: text)
        }
    }

    func finish(with result: TranslationResult) async {
        streamRevealTask?.cancel()
        streamRevealTask = nil
        await reveal(to: result.translatedText)
        guard !Task.isCancelled else { return }
        guard var presentation else { return }
        presentation.directionLabel = result.directionLabel
        presentation.translatedText = result.translatedText
        phase = .translated(presentation, result)
    }

    func fail(message: String) {
        streamRevealTask?.cancel()
        streamRevealTask = nil
        guard let presentation else { return }
        phase = .failed(presentation, message: message)
    }

    func requestTranslation() {
        onTranslate?()
    }

    func requestRetry() {
        onRetry?()
    }

    func togglePin() {
        isPinned.toggle()
        onPinChange?(isPinned)
    }

    func requestDismiss() {
        onDismiss?()
    }

    func hide(resetPin: Bool) {
        streamRevealTask?.cancel()
        streamRevealTask = nil
        phase = .hidden
        resetCopyFeedback()
        if resetPin, isPinned {
            isPinned = false
        }
    }

    func copyTranslation() {
        guard let presentation,
              !presentation.translatedText.isEmpty else {
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(presentation.translatedText, forType: .string)
        didCopy = true
        copyFeedbackTask?.cancel()
        copyFeedbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            self?.didCopy = false
        }
    }

    private func resetCopyFeedback() {
        copyFeedbackTask?.cancel()
        copyFeedbackTask = nil
        didCopy = false
    }

    private func reveal(to target: String) async {
        guard case let .translating(initialPresentation) = phase,
              !target.isEmpty else {
            return
        }

        var visibleText = initialPresentation.translatedText
        if !target.hasPrefix(visibleText) {
            visibleText = ""
        }

        let remainingCount = max(0, target.count - visibleText.count)
        let chunkSize = max(1, Int(ceil(Double(remainingCount) / 120.0)))

        while visibleText.count < target.count, !Task.isCancelled {
            guard case var .translating(presentation) = phase else { return }
            let nextCount = min(target.count, visibleText.count + chunkSize)
            visibleText = String(target.prefix(nextCount))
            presentation.translatedText = visibleText
            phase = .translating(presentation)
            try? await Task.sleep(nanoseconds: 14_000_000)
        }
    }
}
