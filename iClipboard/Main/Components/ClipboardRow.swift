import SwiftUI
import CoreData

struct ClipboardRow: View {
    let entry: ClipboardEntry
    let isCopied: Bool
    let isPendingDelete: Bool
    let favoriteLists: [FavoriteListModel]
    let onCopy: () -> Void
    let onDeleteTapped: () -> Void
    let onSelectFavorite: (NSManagedObjectID?) -> Void
    let onRequestAddList: () -> Void

    @State private var isHovering = false
    @State private var showFavoritePicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Label(entry.kind.label, systemImage: entry.kind.icon)
                        .labelStyle(.titleAndIcon)
                        .font(.system(.caption, design: .rounded))
                        .padding(.vertical, 3)
                        .padding(.horizontal, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                }
                Spacer()
                HStack(spacing: 6) {
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
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(isHovering)

                    favoriteControl
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
                if let listName = entry.favoriteListName {
                    Label(listName, systemImage: "tag.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .padding(.vertical, 1)
                        .padding(.horizontal, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.yellow.opacity(0.12))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(Color.yellow.opacity(0.28), lineWidth: 0.6)
                        )
                        .foregroundStyle(.primary)
                }
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
                        colors: [
                            Color.mint.opacity(isCopied ? 0.15 : 0.08),
                            Color.blue.opacity(isCopied ? 0.15 : 0.08),
                            Color.purple.opacity(isCopied ? 0.15 : 0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isCopied ? Color.blue.opacity(0.5) : Color.white.opacity(0.12), lineWidth: isCopied ? 1.2 : 0.8)
        )
        .onHover { isHovering = $0 }
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

    @ViewBuilder
    private var favoriteControl: some View {
        let shouldShow = isHovering || entry.isFavorited
        Group {
            if entry.isFavorited {
                Button {
                    onSelectFavorite(nil)
                } label: {
                    Image(systemName: "star.fill")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                }
                .buttonStyle(IconButtonStyle(tint: .yellow))
                .help("取消收藏")
            } else if favoriteLists.count > 1 {
                Button {
                    showFavoritePicker = true
                } label: {
                    Image(systemName: "star")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                }
                .buttonStyle(IconButtonStyle(tint: .primary))
                .help("选择收藏列表")
                .popover(isPresented: $showFavoritePicker, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("选择收藏列表")
                            .font(.system(.headline, design: .rounded))
                            .padding(.horizontal, 8)
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                        
                        ForEach(favoriteLists) { list in
                            PopoverMenuItem(title: list.name) {
                                showFavoritePicker = false
                                onSelectFavorite(list.id)
                            }
                        }
                        
                        Divider()
                            .padding(.vertical, 2)
                        
                        PopoverMenuItem(title: "新建列表…") {
                            showFavoritePicker = false
                            onRequestAddList()
                        }
                    }
                    .padding(6)
                    .frame(width: 200)
                }
            } else if let list = favoriteLists.first {
                Button {
                    onSelectFavorite(list.id)
                } label: {
                    Image(systemName: "star")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                }
                .buttonStyle(IconButtonStyle(tint: .secondary))
                .help("收藏到 \(list.name)")
            } else {
                Button {
                    onRequestAddList()
                } label: {
                    Image(systemName: "star")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                }
                .buttonStyle(IconButtonStyle(tint: .secondary))
                .help("创建收藏列表")
            }
        }
        .opacity(shouldShow ? 1 : 0)
        .allowsHitTesting(shouldShow)
    }
}

private struct PopoverMenuItem: View {
    let title: String
    let action: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

private let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
}()

