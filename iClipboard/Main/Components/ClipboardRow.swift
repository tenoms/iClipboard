import SwiftUI
import CoreData

struct ClipboardRow: View {
    @Environment(\.appPalette) private var palette
    let entry: ClipboardEntry
    let isCopied: Bool
    let isPendingDelete: Bool
    let favoriteLists: [FavoriteListModel]
    let onCopy: () -> Void
    let onDeleteTapped: () -> Void
    let onPreview: (ClipboardEntry) -> Void
    let onSelectFavorite: (NSManagedObjectID?) -> Void
    let onRequestAddList: () -> Void

    @State private var isHovering = false
    @State private var showFavoritePicker = false
    @State private var rtfData: Data?
    @State private var thumbData: Data?
    
    @EnvironmentObject var store: ClipboardStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Label(entry.kind.label, systemImage: entry.kind.icon)
                        .labelStyle(.titleAndIcon)
                        .font(.system(.caption))
                        .padding(.vertical, 3)
                        .padding(.horizontal, 5)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(palette.secondaryText)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(palette.control)
                        )
                }
                Spacer()
                HStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Button {
                            onDeleteTapped()
                        } label: {
                            Image(systemName: isPendingDelete ? "checkmark.circle.fill" : "trash")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(IconButtonStyle(tint: isPendingDelete ? palette.success : palette.destructive))
                        .help(isPendingDelete ? "再次点击以删除" : "删除此记录")

                    }
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(isHovering)

                    favoriteControl
                }
                .layoutPriority(1)
            }

            // Body Content (Image, Text, Footer) handling Right Click
            VStack(alignment: .leading, spacing: 8) {
                if let image = previewImage {
                    Image(nsImage: image)
                    .resizable()
                    .aspectRatio(image.size, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 240, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(palette.border, lineWidth: 0.8)
                    )
                }

                if entry.kind == .richText,
                   let data = rtfData,
                   let nsAttr = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
                    Text(AttributedString(nsAttr))
                        .font(.system(.body))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                } else {
                    Text(displayText)
                        .font(.system(.body))
                        .foregroundStyle(palette.text)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }

                ViewThatFits(in: .horizontal) {
                    HStack {
                        if let listName = entry.favoriteListName {
                            listTagView(listName)
                        }
                        Spacer()
                        timeLabel
                    }
                    
                    HStack {
                        if let listName = entry.favoriteListName {
                            listTagView(listName)
                        }
                        Spacer()
                    }
                }
            }
            .contentShape(Rectangle()) // Ensure entire area is hit testable for the overlay
            .overlay(
                RightClickHandler(
                    onLeftClick: onCopy,
                    onRightClick: {
                        if entry.kind == .text || entry.kind == .richText {
                            onPreview(entry)
                        }
                    }
                )
            )
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isCopied ? palette.selection : (isHovering ? palette.surfaceHover : palette.surface))
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isCopied ? palette.selectionBorder : palette.border, lineWidth: 0.5)
        )
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        // onTapGesture on parent primarily catches clicks on Header (background area)
        .onTapGesture {
            onCopy()
        }
        .task {
            if entry.hasImage && thumbData == nil {
                thumbData = store.getThumbnailData(for: entry.id)
            }
            if entry.hasRichText && rtfData == nil {
                rtfData = store.getRTFData(for: entry.id)
            }
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
        guard let data = thumbData else { return nil }
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
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(IconButtonStyle(tint: palette.favorite))
                .help("取消收藏")
            } else if favoriteLists.count > 1 {
                Button {
                    showFavoritePicker = true
                } label: {
                    Image(systemName: "star")
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(IconButtonStyle())
                .help("选择收藏列表")
                .popover(isPresented: $showFavoritePicker, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("选择收藏列表")
                            .font(.system(.headline))
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
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(IconButtonStyle())
                .help("收藏到 \(list.name)")
            } else {
                Button {
                    onRequestAddList()
                } label: {
                    Image(systemName: "star")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(IconButtonStyle())
                .help("创建收藏列表")
            }
        }
        .opacity(shouldShow ? 1 : 0)
        .allowsHitTesting(shouldShow)
    }

    private func listTagView(_ name: String) -> some View {
        Label {
            Text(name)
                .foregroundStyle(palette.secondaryText)
        } icon: {
            Image(systemName: "tag.fill")
                .foregroundStyle(palette.favorite)
        }
            .labelStyle(.titleAndIcon)
            .font(.system(size: 8, weight: .medium))
            .padding(.vertical, 1)
            .padding(.horizontal, 4)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(palette.favoriteSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(palette.favoriteBorder, lineWidth: 0.6)
            )
    }

    private var timeLabel: some View {
        Text(entry.timestamp, formatter: timeFormatter)
            .font(.system(.caption))
            .foregroundStyle(palette.secondaryText)
            .fixedSize()
    }
}

private struct PopoverMenuItem: View {
    @Environment(\.appPalette) private var palette
    let title: String
    let action: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(.body))
                    .foregroundStyle(palette.text)
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? palette.selection : Color.clear)
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

private struct RightClickHandler: NSViewRepresentable {
    let onLeftClick: () -> Void
    let onRightClick: () -> Void
    
    func makeNSView(context: Context) -> RightClickView {
        let view = RightClickView()
        view.onLeftClick = onLeftClick
        view.onRightClick = onRightClick
        return view
    }
    
    func updateNSView(_ nsView: RightClickView, context: Context) {
        nsView.onLeftClick = onLeftClick
        nsView.onRightClick = onRightClick
    }
    
    class RightClickView: NSView {
        var onLeftClick: (() -> Void)?
        var onRightClick: (() -> Void)?
        
        override func mouseDown(with event: NSEvent) {
            // Actively handle mouse down to ensure we get mouseUp.
            // We don't need to do anything here for now, or maybe provide visual feedback?
        }
        
        override func mouseUp(with event: NSEvent) {
            // Trigger copy on mouse up
            if event.clickCount == 1 {
                onLeftClick?()
            }
        }
        
        override func rightMouseDown(with event: NSEvent) {
            onRightClick?()
        }
    }
}
