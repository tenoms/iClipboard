import SwiftUI
import CoreData
import AppKit

struct ContentView: View {
    @StateObject private var store: ClipboardStore
    @State private var showSidebar = true
    @State private var isSearching = false
    @State private var searchText = ""
    @State private var showClearConfirmation = false
    @State private var copiedID: NSManagedObjectID?

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

    var body: some View {
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
        .frame(width: 440, height: 460)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showSidebar)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isSearching)
        .alert("删除所有记录？", isPresented: $showClearConfirmation) {
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) {
                store.deleteAll()
            }
        } message: {
            Text("清空后无法恢复，请确认。")
        }
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

            Button(role: .destructive) {
                showClearConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(IconButtonStyle(tint: .red))
            .help("删除所有历史记录")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
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
                        Button {
                            handleCopy(entry)
                        } label: {
                            ClipboardRow(
                                entry: entry,
                                isCopied: copiedID == entry.id
                            )
                        }
                        .buttonStyle(.plain)
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
                // TODO: open settings window
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
                Text(isCopied ? "已复制" : "点击复制")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(isCopied ? Color.blue : .secondary)
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
