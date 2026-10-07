import SwiftUI

struct TypeRow: View {
    let kind: ClipboardContentKind
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        SidebarSelectionRow(
            title: kind.label,
            symbol: kind.icon,
            isSelected: isSelected,
            action: onSelect
        )
    }
}

struct SidebarSelectionRow: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.appPalette) private var palette
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .frame(width: 18)
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .layoutPriority(1)
                Spacer(minLength: 8)
            }
            .font(.system(.callout))
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(isSelected ? palette.selectionText : palette.text)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        isSelected
                            ? palette.selection
                            : (isHovering ? palette.controlHover : Color.clear)
                    )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isSelected ? palette.selectionBorder : Color.clear,
                        lineWidth: 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
