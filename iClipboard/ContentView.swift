import SwiftUI
import CoreData

struct ContentView: View {
    @StateObject private var store: ClipboardStore
    @State private var showSidebar = true
    @State private var isSearching = false
    @State private var searchText = ""
    @State private var showClearConfirmation = false

    init(context: NSManagedObjectContext = PersistenceController.shared.container.viewContext) {
        _store = StateObject(wrappedValue: ClipboardStore(context: context))
    }

    private var filteredEntries: [ClipboardEntry] {
        let keyword = searchText.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return store.entries }
        return store.entries.filter { $0.content.localizedCaseInsensitiveContains(keyword) }
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelArrow()
                .fill(LinearGradient(colors: [Color(nsColor: .windowBackgroundColor), Color.black.opacity(0.08)], startPoint: .top, endPoint: .bottom))
                .frame(width: 24, height: 12)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 4)
                .padding(.bottom, 2)

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
                .padding(12)

                Divider().opacity(0.15)
                footer
            }
            .background(.ultraThickMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.7)
            )
            .shadow(color: .black.opacity(0.18), radius: 20, y: 14)
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .frame(width: 440, height: 460)
        .padding(.top, 6)
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
        HStack(spacing: 12) {
            Button {
                withAnimation { showSidebar.toggle() }
            } label: {
                Image(systemName: showSidebar ? "sidebar.leading" : "sidebar.leading")
                    .symbolVariant(showSidebar ? .fill : .none)
                    .frame(width: 26, height: 24)
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
                    .frame(width: 28, height: 24)
            }
            .buttonStyle(IconButtonStyle())
            .help("搜索剪切板历史")

            Button(role: .destructive) {
                showClearConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .frame(width: 28, height: 24)
            }
            .buttonStyle(IconButtonStyle(tint: .red))
            .help("删除所有历史记录")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
        .padding(12)
        .frame(width: 150, alignment: .topLeading)
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
                        ClipboardRow(entry: entry)
                    }
                }
            }
            .padding(.vertical, 4)
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
                    .frame(width: 28, height: 24)
            }
            .buttonStyle(IconButtonStyle())
            .help("打开设置")

            Spacer()
            Text("\(store.entries.count) 条记录")
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct ClipboardRow: View {
    let entry: ClipboardEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.content)
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
                        colors: [Color.white.opacity(0.05), Color.blue.opacity(0.10)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
        )
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

private struct PanelArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
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
