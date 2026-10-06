import SwiftUI

struct TypeRow: View {
    @Environment(\.appPalette) private var palette
    let kind: ClipboardContentKind
    let isSelected: Bool
    let onSelect: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        Button(action: onSelect) {
            HStack {
                Label(kind.label, systemImage: kind.icon)
                    .font(.system(.callout))
                Spacer(minLength: 8)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(isSelected ? palette.selectionText : palette.text)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? palette.selection : (isHovering ? palette.controlHover : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? palette.selectionBorder : Color.clear, lineWidth: 1)
            )
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }
}
