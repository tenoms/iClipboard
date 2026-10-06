import SwiftUI

struct ShortcutsSettingsView: View {
    @Environment(\.appPalette) private var palette
    @ObservedObject var hotKeyManager = HotKeyManager.shared
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                globalShortcutCard
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    
    private var globalShortcutCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("全局快捷键")
                    .font(.system(.headline))
                Spacer()
            }
            
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("显示/隐藏面板")
                        .font(.system(.body))
                    Spacer()
                    KeyRecorderView(shortcut: $hotKeyManager.currentShortcut)
                }
                
                Text("设置一个全局快捷键来快速呼出或隐藏 iClipboard 面板")
                    .font(.system(.caption))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(nil)
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
