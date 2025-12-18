import SwiftUI

struct MainHeaderView: View {
    @Binding var showSidebar: Bool
    @Binding var isSearching: Bool
    @Binding var showClearConfirmation: Bool
    @ObservedObject var store: ClipboardStore
    @EnvironmentObject var windowManager: WindowManager
    
    var body: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation { showSidebar.toggle() }
            } label: {
                Image(systemName: showSidebar ? "sidebar.leading" : "sidebar.leading")
                    .symbolVariant(showSidebar ? .fill : .none)
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(IconButtonStyle())
            .help(showSidebar ? "隐藏侧边栏" : "展开侧边栏")

            Text("iClipboard")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.primary)
                .allowsHitTesting(false)

            Spacer()

            Button {
                withAnimation {
                    isSearching.toggle()
                    if !isSearching { store.searchText = "" }
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(IconButtonStyle())
            .help("搜索剪切板历史")

            Button {
                windowManager.isPinned.toggle()
            } label: {
                Image(systemName: windowManager.isPinned ? "pin.fill" : "pin")
                    .rotationEffect(.degrees(windowManager.isPinned ? 45 : 0))
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(IconButtonStyle(tint: windowManager.isPinned ? .yellow : .primary))
            .help(windowManager.isPinned ? "取消固定窗口" : "固定窗口")

            Button(role: .destructive) {
                withAnimation(.spring(response: 0.3)) {
                    showClearConfirmation = true
                }
            } label: {
                Image(systemName: "trash")
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(IconButtonStyle(tint: .red))
            .help("删除所有历史记录")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(WindowDragHandler())
    }
}
