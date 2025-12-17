import SwiftUI
import CoreData
import AppKit

struct ContentView: View {
    @EnvironmentObject var windowManager: WindowManager
    @StateObject private var store: ClipboardStore
    @State private var showSidebar = true
    @State private var isSearching = false
    @State private var searchText = ""
    @State private var showClearConfirmation = false
    @State private var isShowingSettings = false
    @State private var copiedID: NSManagedObjectID?
    @State private var pendingDeleteID: NSManagedObjectID?
    @State private var pendingDeleteResetTask: DispatchWorkItem?

    init(context: NSManagedObjectContext = PersistenceController.shared.container.viewContext) {
        _store = StateObject(wrappedValue: ClipboardStore(context: context))
    }

    private var filteredEntries: [ClipboardEntry] {
        let keyword = searchText.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return store.entries }
        return store.entries.filter { entry in
            let fileName = entry.fileURL?.lastPathComponent ?? ""
            return entry.content.localizedCaseInsensitiveContains(keyword) || fileName.localizedCaseInsensitiveContains(keyword)
        }
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
            if showClearConfirmation {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3)) {
                            showClearConfirmation = false
                        }
                    }

                VStack(spacing: 20) {
                    VStack(spacing: 8) {
                        Image(systemName: "trash.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.red)
                        
                        Text("删除所有记录？")
                            .font(.system(.title3, design: .rounded).bold())
                            .foregroundStyle(.primary)
                        
                        Text("清空后无法恢复，请确认。")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    
                    HStack(spacing: 12) {
                        Button {
                            withAnimation(.spring(response: 0.3)) {
                                showClearConfirmation = false
                            }
                        } label: {
                            Text("取消")
                                .font(.system(.body, design: .rounded))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(Color.secondary.opacity(0.1))
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        
                        Button {
                            withAnimation(.spring(response: 0.3)) {
                                store.deleteAll()
                                showClearConfirmation = false
                            }
                        } label: {
                            Text("删除")
                                .font(.system(.body, design: .rounded).bold())
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(Color.red)
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(24)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Material.thick)
                        .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)
                )
                .padding(40)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .frame(width: 440, height: 460)
        .background(Material.regular)
        .cornerRadius(12)
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: isShowingSettings)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: showClearConfirmation)
    }
    
    private var frontPanel: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                
                if isSearching {
                    searchField
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
                footer
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

    private var header: some View {
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
                    if !isSearching { searchText = "" }
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

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索内容...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .rounded))
            if !searchText.isEmpty {
                Button {
                    searchText.removeAll()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
        )
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("收藏", systemImage: "star.fill")
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(.primary)
            Label("分组", systemImage: "square.grid.2x2.fill")
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(.primary)
            Label("筛选", systemImage: "line.3.horizontal.decrease")
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(.primary)

            Spacer()

            Text("侧边栏功能规划中")
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
        }
        .padding(10)
        .frame(width: 128, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
    }

    private var historyList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if filteredEntries.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                        Text("暂无记录")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
                } else {
                    ForEach(filteredEntries) { entry in
                        ClipboardRow(
                            entry: entry,
                            isCopied: copiedID == entry.id,
                            isPendingDelete: pendingDeleteID == entry.id,
                            onCopy: { handleCopy(entry) },
                            onDeleteTapped: { handleDeleteTap(entry) }
                        )
                    }
                }
            }
            .padding(.vertical, 2)
            .padding(.trailing, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Button {
                withAnimation {
                    isShowingSettings = true
                }
            } label: {
                Label("设置", systemImage: "gearshape.fill")
                    .labelStyle(.iconOnly)
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(IconButtonStyle())
            .help("打开设置")

            Spacer()
            Text("\(store.entries.count) 条记录")
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

private struct ClipboardRow: View {
    let entry: ClipboardEntry
    let isCopied: Bool
    let isPendingDelete: Bool
    let onCopy: () -> Void
    let onDeleteTapped: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(entry.kind.label, systemImage: entry.kind.icon)
                    .labelStyle(.titleAndIcon)
                    .font(.system(.caption, design: .rounded))
                    .padding(.vertical, 3)
                    .padding(.horizontal, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                Spacer()
                HStack(spacing: 6) {
                    Button {
                        onDeleteTapped()
                    } label: {
                        Image(systemName: isPendingDelete ? "checkmark.circle.fill" : "trash")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                    }
                    .buttonStyle(IconButtonStyle(tint: isPendingDelete ? .green : .red))
                    .help(isPendingDelete ? "再次点击以删除" : "删除此记录")

                    Button {
                        onCopy()
                    } label: {
                        Image(systemName: isCopied ? "doc.on.clipboard.fill" : "doc.on.clipboard")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                    }
                    .buttonStyle(IconButtonStyle(tint: isCopied ? .blue : .primary))
                    .help("复制到剪贴板")
                }
            }

            if let image = previewImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(image.size, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 240, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.1), lineWidth: 0.8)
                    )
            }

            Text(displayText)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)

            HStack {
                Spacer()
                Text(entry.timestamp, formatter: timeFormatter)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.05), isCopied ? Color.blue.opacity(0.18) : Color.blue.opacity(0.10)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isCopied ? Color.blue.opacity(0.5) : Color.white.opacity(0.08), lineWidth: isCopied ? 1.2 : 0.8)
        )
        .onTapGesture {
            onCopy()
        }
    }

    private var displayText: String {
        switch entry.kind {
        case .file:
            return entry.fileURL?.lastPathComponent ?? entry.content
        case .image:
            return entry.fileURL?.lastPathComponent ?? entry.content
        case .richText, .text:
            return entry.content
        }
    }

    private var previewImage: NSImage? {
        guard let data = entry.imageData else { return nil }
        return NSImage(data: data)
    }
}

private struct IconButtonStyle: ButtonStyle {
    var tint: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .foregroundStyle(tint)
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? tint.opacity(0.14) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 0.8)
            )
            .dragCursorIgnored()
    }
}

private let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
}()

#Preview {
    ContentView(context: PersistenceController.preview.container.viewContext)
}
