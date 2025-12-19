import SwiftUI
import CoreData
import AppKit

struct ContentView: View {
    @EnvironmentObject var windowManager: WindowManager
    @StateObject private var store: ClipboardStore
    @State private var showSidebar = true
    @State private var isSearching = false
    @State private var showClearConfirmation = false
    @State private var isShowingSettings = false
    @State private var copiedID: NSManagedObjectID?
    @State private var pendingDeleteID: NSManagedObjectID?
    @State private var pendingDeleteResetTask: DispatchWorkItem?
    @State private var showAddListPopover = false
    @State private var previewEntry: ClipboardEntry?

    init(context: NSManagedObjectContext = PersistenceController.shared.container.viewContext) {
        _store = StateObject(wrappedValue: ClipboardStore(context: context))
    }

    private func handleCopy(_ entry: ClipboardEntry) {
        clearPendingDelete()
        store.copyToPasteboard(entry)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            copiedID = entry.id
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedID == entry.id {
                withAnimation(.easeOut(duration: 0.25)) {
                    copiedID = nil
                }
            }
        }
    }

    private func handleDeleteTap(_ entry: ClipboardEntry) {
        if pendingDeleteID == entry.id {
            store.delete(entry)
            clearPendingDelete()
            if copiedID == entry.id { copiedID = nil }
        } else {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                pendingDeleteID = entry.id
            }
            schedulePendingDeleteReset(for: entry)
        }
    }

    private func clearPendingDelete() {
        pendingDeleteResetTask?.cancel()
        pendingDeleteResetTask = nil
        pendingDeleteID = nil
    }

    private func schedulePendingDeleteReset(for entry: ClipboardEntry) {
        pendingDeleteResetTask?.cancel()
        let pendingID = entry.id
        let task = DispatchWorkItem {
            guard pendingDeleteID == pendingID else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                pendingDeleteID = nil
            }
            pendingDeleteResetTask = nil
        }
        pendingDeleteResetTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: task)
    }

    var body: some View {
        ZStack {
            frontPanel
                .allowsHitTesting(!isShowingSettings)
                .opacity(isShowingSettings ? 0 : 1)
                .rotation3DEffect(.degrees(isShowingSettings ? 180 : 0), axis: (x: 0, y: 1, z: 0))

            backPanel
                .allowsHitTesting(isShowingSettings)
                .opacity(isShowingSettings ? 1 : 0)
                .rotation3DEffect(.degrees(isShowingSettings ? 0 : -180), axis: (x: 0, y: 1, z: 0))
            
        }
        .frame(width: AppConstants.Panel.width, height: AppConstants.Panel.height)
        .background(Material.regular)
        .cornerRadius(12)
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: isShowingSettings)
        .sheet(item: $previewEntry) { entry in
            TextPreviewSheet(text: entry.content)
        }
        .alert("确定要清空所有记录吗？", isPresented: $showClearConfirmation) {
            Button("清空", role: .destructive) {
                store.deleteAll()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("此操作无法撤销。")
        }
}
    
    private var frontPanel: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                MainHeaderView(
                    showSidebar: $showSidebar,
                    isSearching: $isSearching,
                    showClearConfirmation: $showClearConfirmation,
                    store: store
                )
                
                if isSearching {
                    SearchField(searchText: $store.searchText)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
                
                Divider().opacity(0.15)
                
                HStack(spacing: 12) {
                    if showSidebar { sidebar }
                    historyList
                }
                .padding(.leading, 8)   // 保持左侧间距
                
                Divider().opacity(0.15)
                MainFooterView(store: store, isShowingSettings: $isShowingSettings)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showSidebar)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isSearching)
    }

    private var backPanel: some View {
        SettingsView(store: store, onBack: {
            withAnimation {
                isShowingSettings = false
            }
        })
    }

    private var sidebar: some View {
        SidebarView(
            store: store,
            isPresentedAddListPopover: $showAddListPopover
        )
    }

    private var historyList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if store.filteredEntries.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                        Text(store.selectedListID == nil ? "暂无记录" : "此列表暂无记录")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
                } else {
                    ForEach(store.filteredEntries) { entry in
                        ClipboardRow(
                            entry: entry,
                            isCopied: copiedID == entry.id,
                            isPendingDelete: pendingDeleteID == entry.id,
                            favoriteLists: store.favoriteLists,
                            onCopy: { handleCopy(entry) },
                            onDeleteTapped: { handleDeleteTap(entry) },
                            onDoubleTap: { entry in
                                previewEntry = entry
                            },
                            onSelectFavorite: { listID in
                                clearPendingDelete()
                                store.setFavorite(for: entry, listID: listID)
                            },
                            onRequestAddList: {
                                clearPendingDelete()
                                withAnimation { showSidebar = true }
                                showAddListPopover = true
                            }
                        )
                    }
                }
            }
            .padding(.vertical, 2)
            .padding(.trailing, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView(context: PersistenceController.preview.container.viewContext)
        .environmentObject(WindowManager.shared)
}
