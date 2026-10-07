import AppKit
import SwiftUI

@MainActor
final class TranslationBubbleViewModel: ObservableObject {
    enum Phase: Equatable {
        case awaitingAction
        case translating(directionLabel: String)
        case translated(TranslationResult)
        case failed(message: String)
    }

    @Published var sourceText = ""
    @Published var sourceApplicationName = ""
    @Published var provider: TranslationProvider = .doubaoAI
    @Published var phase: Phase = .awaitingAction
    @Published var streamedText = ""
    @Published var didCopy = false
    @Published var isPinned = false

    var onTranslate: (() -> Void)?
    var onRetry: (() -> Void)?
    var onPinToggle: (() -> Void)?

    private var revealTask: Task<Void, Never>?

    func prepareSelection(text: String, applicationName: String, provider: TranslationProvider) {
        revealTask?.cancel()
        revealTask = nil
        sourceText = text
        sourceApplicationName = applicationName
        self.provider = provider
        streamedText = ""
        didCopy = false
        phase = .awaitingAction
    }

    func beginTranslation() {
        revealTask?.cancel()
        streamedText = ""
        phase = .translating(directionLabel: "正在识别语言")
    }

    func setDetectedDirection(targetLanguage: String) {
        let label = targetLanguage == "en" ? "中文 → English" : "其他语言 → 中文"
        phase = .translating(directionLabel: label)
    }

    func enqueuePartialText(_ text: String) {
        guard !text.isEmpty else { return }
        revealTask?.cancel()
        revealTask = Task { [weak self] in
            await self?.reveal(to: text)
        }
    }

    func finish(with result: TranslationResult) async {
        revealTask?.cancel()
        revealTask = nil
        await reveal(to: result.translatedText)
        guard !Task.isCancelled else { return }
        phase = .translated(result)
    }

    func fail(message: String) {
        revealTask?.cancel()
        revealTask = nil
        phase = .failed(message: message)
    }

    func copyTranslation() {
        let text: String
        switch phase {
        case let .translated(result):
            text = result.translatedText
        case .translating where !streamedText.isEmpty:
            text = streamedText
        default:
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.didCopy = false
        }
    }

    private func reveal(to target: String) async {
        guard !target.isEmpty else { return }
        if !target.hasPrefix(streamedText) {
            streamedText = ""
        }

        let remainingCount = max(0, target.count - streamedText.count)
        let chunkSize = max(1, Int(ceil(Double(remainingCount) / 150.0)))

        while streamedText.count < target.count, !Task.isCancelled {
            let nextCount = min(target.count, streamedText.count + chunkSize)
            streamedText = String(target.prefix(nextCount))
            try? await Task.sleep(nanoseconds: 14_000_000)
        }
    }
}

struct TranslationTriggerView: View {
    let action: () -> Void

    @Environment(\.appPalette) private var palette
    @AppStorage("appTheme") private var appTheme: AppTheme = .system

    var body: some View {
        Button(action: action) {
            Image(systemName: "character.book.closed.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.accent)
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(PanelBackground(material: .hudWindow))
        .clipShape(Circle())
        .overlay {
            Circle()
                .strokeBorder(palette.panelEdge, lineWidth: 0.7)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .help("翻译选中文字")
        .accessibilityLabel("翻译选中文字")
        .preferredColorScheme(appTheme.colorScheme)
    }
}

struct TranslationBubbleView: View {
    @ObservedObject var model: TranslationBubbleViewModel
    @Environment(\.appPalette) private var palette
    @AppStorage("appTheme") private var appTheme: AppTheme = .system

    var body: some View {
        expandedPanel
            .preferredColorScheme(appTheme.colorScheme)
            .foregroundStyle(palette.text)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("划词翻译")
    }

    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            sourcePreview
            phaseContent
        }
        .padding(14)
        .frame(minWidth: 420, idealWidth: 440, maxWidth: .infinity, alignment: .topLeading)
        .background(PanelBackground(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(palette.panelEdge, lineWidth: 0.6)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.18), radius: 22, y: 9)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: model.provider.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.accent)
                .frame(width: 22, height: 22)
                .background(palette.selection, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text("划词翻译")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("\(model.sourceApplicationName) · \(model.provider.shortTitle)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(WindowDragArea())
            .help("拖动窗口")

            BubbleIconButton(
                symbol: model.isPinned ? "pin.fill" : "pin",
                accessibilityLabel: model.isPinned ? "取消固定" : "固定翻译窗口",
                isSelected: model.isPinned,
                action: { model.onPinToggle?() }
            )
        }
    }

    private var sourcePreview: some View {
        Text(model.sourceText)
            .font(.system(size: 12.5, weight: .regular))
            .foregroundStyle(palette.secondaryText)
            .lineLimit(2)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch model.phase {
        case .awaitingAction:
            EmptyView()

        case .translating, .translated:
            translationContent

        case let .failed(message):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(palette.destructive)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()
                    Button("重试") { model.onRetry?() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    private var translationContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                if model.streamedText.isEmpty && !isTranslationComplete {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.triangle.swap")
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(directionLabel)
                    .font(.system(size: 10.5, weight: .medium))
                Spacer()
            }
            .foregroundStyle(palette.secondaryText)

            if displayedTranslation.isEmpty {
                Text("等待翻译服务响应…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
                    .frame(height: 34)
            } else if isTranslationComplete {
                AdaptiveTranslationTextView(
                    text: displayedTranslation,
                    foregroundColor: NSColor(palette.text)
                )
            } else {
                translationScrollView(
                    text: displayedTranslation,
                    showsStreamingCursor: true
                )
            }
            if isTranslationComplete {
                HStack {
                    Spacer()
                    BubbleIconButton(
                        symbol: model.didCopy ? "checkmark" : "doc.on.doc",
                        accessibilityLabel: model.didCopy ? "已复制" : "复制译文",
                        isSelected: model.didCopy,
                        action: { model.copyTranslation() }
                    )
                }
            }
        }
    }

    private var displayedTranslation: String {
        guard model.streamedText.isEmpty else { return model.streamedText }
        if case let .translated(result) = model.phase {
            return result.translatedText
        }
        return ""
    }

    private var directionLabel: String {
        switch model.phase {
        case let .translating(label):
            return label
        case let .translated(result):
            return result.directionLabel
        default:
            return ""
        }
    }

    private var isTranslationComplete: Bool {
        if case .translated = model.phase { return true }
        return false
    }

    private func translationScrollView(text: String, showsStreamingCursor: Bool) -> some View {
        ScrollView {
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(text)
                    .font(.system(size: 15.5, weight: .medium, design: .rounded))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if showsStreamingCursor {
                    StreamingCursor()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
        .frame(minHeight: 46, maxHeight: 290)
        .scrollIndicators(.automatic)
    }
}

private struct AdaptiveTranslationTextView: NSViewRepresentable {
    let text: String
    let foregroundColor: NSColor

    private let minimumHeight: CGFloat = 46
    private let maximumHeight: CGFloat = 290
    private let verticalPadding: CGFloat = 4

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        let attributedText = makeAttributedString()
        if textView.attributedString() != attributedText {
            let selectedRanges = textView.selectedRanges
            textView.textStorage?.setAttributedString(attributedText)
            textView.selectedRanges = selectedRanges
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView scrollView: NSScrollView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }

        let textWidth = max(1, width)
        let measuredBounds = makeAttributedString().boundingRect(
            with: NSSize(
                width: textWidth,
                height: CGFloat.greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let contentHeight = ceil(measuredBounds.height) + verticalPadding
        let viewportHeight = min(
            maximumHeight,
            max(minimumHeight, contentHeight)
        )

        if let textView = scrollView.documentView as? NSTextView {
            textView.frame.size = CGSize(
                width: textWidth,
                height: max(contentHeight, viewportHeight)
            )
            textView.textContainer?.containerSize = CGSize(
                width: textWidth,
                height: CGFloat.greatestFiniteMagnitude
            )
        }

        scrollView.hasVerticalScroller = contentHeight > maximumHeight
        return CGSize(width: width, height: viewportHeight)
    }

    private func makeAttributedString() -> NSAttributedString {
        let baseFont = NSFont.systemFont(ofSize: 15.5, weight: .medium)
        let descriptor = baseFont.fontDescriptor.withDesign(.rounded)
            ?? baseFont.fontDescriptor
        let font = NSFont(descriptor: descriptor, size: 15.5) ?? baseFont

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4

        return NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: foregroundColor,
                .paragraphStyle: paragraphStyle
            ]
        )
    }
}

private struct BubbleIconButton: View {
    let symbol: String
    let accessibilityLabel: String
    var isSelected = false
    let action: () -> Void

    @Environment(\.appPalette) private var palette
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isSelected ? palette.accent : palette.text)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .background(
                    isSelected ? palette.selection : (isHovering ? palette.controlHover : Color.clear),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct StreamingCursor: View {
    @State private var isVisible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(.primary)
            .frame(width: 2, height: 17)
            .opacity(isVisible ? 0.85 : 0.12)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.48).repeatForever(autoreverses: true)) {
                    isVisible = false
                }
            }
            .accessibilityHidden(true)
    }
}

private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
}
