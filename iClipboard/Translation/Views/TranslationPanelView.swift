import AppKit
import SwiftUI

struct TranslationPanelView: View {
    @ObservedObject var model: TranslationPanelViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TranslationPanelContent(
            phase: model.phase,
            isPinned: model.isPinned,
            didCopy: model.didCopy,
            actions: TranslationPanelContent.Actions(
                togglePin: { model.togglePin() },
                copyTranslation: { model.copyTranslation() },
                retry: { model.requestRetry() }
            )
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: model.phase)
        .onExitCommand { model.requestDismiss() }
    }
}

/// Value-driven panel layout. The live panel and `TranslationPanelSizing` render
/// this same view, so the window height follows SwiftUI's real layout.
struct TranslationPanelContent: View {
    struct Actions {
        var togglePin: () -> Void = {}
        var copyTranslation: () -> Void = {}
        var retry: () -> Void = {}
    }

    let phase: TranslationPanelViewModel.Phase
    var isPinned = false
    var didCopy = false
    var actions = Actions()

    @Environment(\.appPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let presentation = phase.presentation {
                header(presentation)
                ThemeDivider()
                sourcePreview(presentation)
                ThemeDivider()
                phaseContent
            }
        }
        .background(PanelBackground(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(palette.panelEdge, lineWidth: 0.6)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("划词翻译")
        .foregroundStyle(palette.text)
    }

    private func header(_ presentation: TranslationPanelViewModel.Presentation) -> some View {
        HStack(spacing: 9) {
            Image(systemName: presentation.provider.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.accent)
                .frame(width: 24, height: 24)
                .background(
                    palette.selection,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text("划词翻译")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("\(presentation.context.sourceApplicationName) · \(presentation.provider.shortTitle)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(WindowDragArea())
            .help("拖动窗口")

            PanelIconButton(
                symbol: isPinned ? "pin.fill" : "pin",
                accessibilityLabel: isPinned ? "取消固定" : "固定翻译窗口",
                isSelected: isPinned,
                action: actions.togglePin
            )

        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func sourcePreview(_ presentation: TranslationPanelViewModel.Presentation) -> some View {
        Text(presentation.context.text)
            .font(.system(size: 12.5))
            .foregroundStyle(palette.secondaryText)
            .lineLimit(2)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .accessibilityLabel("原文")
            .accessibilityValue(presentation.context.text)
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch phase {
        case .hidden:
            EmptyView()

        case let .translating(presentation):
            translatingContent(presentation)

        case let .translated(presentation, _):
            resultContent(presentation)

        case let .failed(_, message):
            failureContent(message)
        }
    }

    private func translatingContent(
        _ presentation: TranslationPanelViewModel.Presentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text(presentation.directionLabel)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
                Spacer()
                Text("正在翻译")
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.secondaryText)
            }

            if presentation.translatedText.isEmpty {
                Text("等待翻译服务响应…")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                StreamingTranslationView(text: presentation.translatedText)
            }
        }
        .padding(14)
    }

    private func resultContent(
        _ presentation: TranslationPanelViewModel.Presentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.swap")
                    .font(.system(size: 10, weight: .semibold))
                Text(presentation.directionLabel)
                    .font(.system(size: 10.5, weight: .medium))
                Spacer()
            }
            .foregroundStyle(palette.secondaryText)

            translationText(presentation.translatedText)

            HStack {
                Spacer()
                PanelIconButton(
                    symbol: didCopy ? "checkmark" : "doc.on.doc",
                    accessibilityLabel: didCopy ? "译文已复制" : "复制译文",
                    isSelected: didCopy,
                    action: actions.copyTranslation
                )
            }
        }
        .padding(14)
    }

    private func failureContent(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(palette.destructive)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("重试", action: actions.retry)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(14)
    }

    private func translationText(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 15.5, weight: .medium, design: .rounded))
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
        }
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("译文")
        .accessibilityValue(text)
    }
}

/// Sizes the panel from SwiftUI's own layout of `TranslationPanelContent`, so the
/// translation only scrolls once the panel reaches its maximum height.
@MainActor
enum TranslationPanelSizing {
    static let width: CGFloat = 440
    static let maximumHeight: CGFloat = 540

    private static let probe = NSHostingView(rootView: Probe(phase: .hidden))

    static func size(for phase: TranslationPanelViewModel.Phase) -> CGSize {
        // Reassigning the root view lays out synchronously, unlike the live panel,
        // whose observed model only re-renders on the next run-loop pass.
        probe.rootView = Probe(phase: phase)
        let idealHeight = ceil(probe.fittingSize.height)
        return CGSize(
            width: width,
            height: min(maximumHeight, max(minimumHeight(for: phase), idealHeight))
        )
    }

    private static func minimumHeight(for phase: TranslationPanelViewModel.Phase) -> CGFloat {
        switch phase {
        case .hidden, .translating:
            return 220
        case .translated:
            return 230
        case .failed:
            return 218
        }
    }

    private struct Probe: View {
        let phase: TranslationPanelViewModel.Phase

        var body: some View {
            TranslationPanelContent(phase: phase)
                .frame(width: TranslationPanelSizing.width)
        }
    }
}

private struct StreamingTranslationView: View {
    let text: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.system(size: 15.5, weight: .medium, design: .rounded))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    StreamingCursor()
                    Text("正在接收译文")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("流式译文")
        .accessibilityValue(text)
    }
}

private struct StreamingCursor: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = true

    var body: some View {
        Capsule()
            .fill(.secondary)
            .frame(width: 8, height: 3)
            .opacity(isVisible ? 0.9 : 0.25)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                    isVisible = false
                }
            }
            .accessibilityHidden(true)
    }
}

private struct PanelIconButton: View {
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
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .background(
                    isSelected
                        ? palette.selection
                        : (isHovering ? palette.controlHover : Color.clear),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
}
