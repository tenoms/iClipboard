import SwiftUI

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
        .help("翻译选中文字")
        .accessibilityLabel("翻译选中文字")
        .preferredColorScheme(appTheme.colorScheme)
        .frame(width: 38, height: 38)
    }
}
