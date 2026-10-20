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
            
            Text("点击录制后直接按下组合键。支持 ⌘、⌥、⌃、⇧ 与普通按键；仅无修饰键的 Esc 取消。历史、截图和贴图是全局快捷键；复制图像全文和关闭贴图仅在对应窗口内生效，不拦截其它应用输入。录制期间暂停所有快捷键，冲突或注册失败会显示在对应设置下方。")
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
