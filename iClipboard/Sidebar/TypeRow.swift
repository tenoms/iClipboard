import SwiftUI

struct TypeRow: View {
    let kind: ClipboardContentKind
    let isSelected: Bool
    let onSelect: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        Button(action: onSelect) {
            HStack {
                Label(kind.label, systemImage: kind.icon)
                    .font(.system(.callout, design: .rounded))
                Spacer(minLength: 8)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : (isHovering ? Color.primary.opacity(0.06) : Color.primary.opacity(0.02)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.05), lineWidth: 1)
            )
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}
