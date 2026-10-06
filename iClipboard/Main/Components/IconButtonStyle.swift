import SwiftUI

struct IconButtonStyle: ButtonStyle {
    @Environment(\.appPalette) private var palette
    @State private var isHovering = false
    var tint: Color?
    var padding: CGFloat = 6

    private var foreground: Color { tint ?? palette.secondaryText }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .foregroundStyle(foreground)
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? foreground.opacity(0.12) : (isHovering ? palette.controlHover : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(palette.hasIncreasedContrast ? palette.border : Color.clear, lineWidth: 0.5)
            )
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .dragCursorIgnored()
    }
}
