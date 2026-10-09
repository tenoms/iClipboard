import SwiftUI
import CoreData
import AppKit

struct ContentView: View {
    @EnvironmentObject var windowManager: WindowManager
    @ObservedObject private var store: ClipboardStore
    private let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    @State private var showSidebar = true
    @State private var isSearching = false
    @State private var showClearConfirmation = false
    @State private var isShowingSettings = false
    @State private var hasShownSettings = false
    @State private var historyScrollPosition = ListScrollPosition()
    @State private var copiedID: NSManagedObjectID?
    @State private var pendingDeleteID: NSManagedObjectID?
    @State private var pendingDeleteResetTask: DispatchWorkItem?
    @State private var showAddListPopover = false
    @State private var previewEntry: ClipboardEntry?
    @AppStorage("appTheme") private var appTheme: AppTheme = .system

    init(store: ClipboardStore) {
        self.store = store
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

            // Keep visited settings alive to preserve drafts and selection.
            if isShowingSettings || hasShownSettings {
                backPanel
                    .allowsHitTesting(isShowingSettings)
                    .opacity(isShowingSettings ? 1 : 0)
                    .rotation3DEffect(.degrees(isShowingSettings ? 0 : -180), axis: (x: 0, y: 1, z: 0))
            }
            
        }
        .frame(minWidth: AppConstants.Panel.minimumWidth, maxWidth: AppConstants.Panel.width)
        .frame(height: AppConstants.Panel.height)
        .modifier(PanelThemeStyle())
        .preferredColorScheme(appTheme.colorScheme)
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
        .environmentObject(store)
        .onChange(of: isShowingSettings) { showing in
            if showing { hasShownSettings = true }
        }
        .onChange(of: windowManager.isPanelVisible) { visible in
            if !visible { store.releasePreviews() }
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
                
                ThemeDivider()
                
                HStack(spacing: 12) {
                    if showSidebar { sidebar }
                    if windowManager.isPanelVisible || isPreview {
                        historyList
                    } else {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(.leading, 8)   // 保持左侧间距
                
                ThemeDivider()
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
        .padding(.vertical, 5)
    }

    private var historyList: some View {
        List {
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
                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 2))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                ForEach(store.filteredEntries) { entry in
                    ClipboardRow(
                        entry: entry,
                        isCopied: copiedID == entry.id,
                        isPendingDelete: pendingDeleteID == entry.id,
                        favoriteLists: store.favoriteLists,
                        onCopy: { handleCopy(entry) },
                        onDeleteTapped: { handleDeleteTap(entry) },
                        onPreview: { entry in
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
                    .id(entry.id)
                    .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 2))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .background(ListScrollPositionReader(position: historyScrollPosition))
        .scrollContentBackground(.hidden)
        // Compensate only the native leading cell inset. Keep a small positive
        // trailing inset so card corners and borders stay inside the List's
        // clipping boundary, including when the vertical scroller is visible.
        .padding(.leading, -8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

#Preview {
    ContentView(store: ClipboardStore(
        context: PersistenceController.preview.container.viewContext,
        monitorPasteboard: false
    ))
        .environmentObject(WindowManager.shared)
}
