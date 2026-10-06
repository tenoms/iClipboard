import SwiftUI

struct FavoriteListRow: View {
    @Environment(\.appPalette) private var palette
    let list: FavoriteListModel
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @State private var showDeletePopover = false

    var body: some View {
        ZStack(alignment: .leading) {
            Button(action: onSelect) {
                HStack {
                    Image(systemName: "tag")
                        .font(.system(size: 8))
                        .opacity(isHovering ? 0 : 1)
                    Text(list.name)
                        .font(.system(.callout))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text("\(list.count)")
                        .font(.system(.footnote).bold())
                        .foregroundStyle(palette.secondaryText)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 8)
                        .background(
                            Capsule()
                                .fill(palette.control)
                        )
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity)
                .foregroundStyle(isSelected ? palette.selectionText : palette.text)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? palette.selection : (isHovering ? palette.controlHover : Color.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isSelected ? palette.selectionBorder : Color.clear, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            Button {
                showDeletePopover = true
            } label: {
                Image(systemName: "trash")
                    .imageScale(.small)
                    .foregroundStyle(palette.destructive)
                    .padding(.leading, 10)
            }
            .buttonStyle(.plain)
            .help("删除列表")
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
            .popover(isPresented: $showDeletePopover, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("删除列表？")
                        .font(.system(.headline))
                    Text("删除后其中的记录也会被移除。")
                        .font(.system(.footnote))
                        .foregroundStyle(palette.secondaryText)
                    HStack {
                        Spacer()
                        Button("取消") { showDeletePopover = false }
                        Button("删除", role: .destructive) {
                            showDeletePopover = false
                            onDelete()
                        }
                    }
                }
                .padding(14)
                .frame(width: 220)
            }
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }
}
