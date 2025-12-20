import SwiftUI

struct FavoriteListRow: View {
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
                        .font(.system(.callout, design: .rounded))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text("\(list.count)")
                        .font(.system(.footnote, design: .rounded).bold())
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 8)
                        .background(
                            Capsule()
                                .fill(Color.primary.opacity(0.06))
                        )
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.14) : (isHovering ? Color.primary.opacity(0.06) : Color.primary.opacity(0.02)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isSelected ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.05), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            Button {
                showDeletePopover = true
            } label: {
                Image(systemName: "trash")
                    .imageScale(.small)
                    .foregroundStyle(.red)
                    .padding(.leading, 10)
            }
            .buttonStyle(.plain)
            .help("删除列表")
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
            .popover(isPresented: $showDeletePopover, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("删除列表？")
                        .font(.system(.headline, design: .rounded))
                    Text("删除后其中的记录也会被移除。")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(.secondary)
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
    }
}
