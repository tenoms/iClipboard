import SwiftUI

struct ShortcutsSettingsView: View {
    @Environment(\.appPalette) private var palette
    @ObservedObject var hotKeyManager = HotKeyManager.shared
    var isInteractive: Bool = true
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                shortcutCard
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    
    private var shortcutCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("快捷键")
                    .font(.system(.headline))
                Spacer()
            }
            
            Text("点击右侧录制，按下含 ⌘、⌥、⌃ 或 ⇧ 的组合键。单独按 Esc 取消，点击 × 清除。")
                .font(.system(.caption))
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(HotKeyAction.allCases) { action in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(action.title)
                            .font(.system(.body))
                        Spacer()
                        KeyRecorderView(
                            shortcut: Binding(
                                get: { hotKeyManager.shortcut(for: action) },
                                set: { hotKeyManager.setShortcut($0, for: action) }
                            ),
                            hotKeyManager: hotKeyManager,
                            isInteractive: isInteractive
                        )
                    }

                    Text(action.helpText)
                        .font(.system(.caption))
                        .foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    if let error = hotKeyManager.registrationError(for: action) {
                        Text(error)
                            .font(.system(.caption))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("快捷键错误：\(error)")
                    }
                    if let warning = hotKeyManager.systemConflictWarning(for: action) {
                        Text(warning)
                            .font(.system(.caption))
                            .foregroundStyle(palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if hotKeyManager.hasConfirmedSystemConflict(for: action) {
                        Button("打开系统键盘快捷键设置") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.link)
                        .font(.system(.caption))
                    }
                }
                if action != HotKeyAction.allCases.last {
                    Divider()
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(palette.border, lineWidth: 0.5)
        )
    }
}
