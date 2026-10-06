import SwiftUI

struct SearchField: View {
    @Binding var searchText: String
    @Environment(\.appPalette) private var palette
    @FocusState private var isFocused: Bool
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass")
                .foregroundStyle(palette.secondaryText)
            TextField("搜索内容...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(.body))
                .foregroundStyle(palette.text)
                .focused($isFocused)
            if !searchText.isEmpty {
                Button {
                    searchText.removeAll()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(palette.secondaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isFocused ? palette.accent : palette.border, lineWidth: isFocused ? 1.4 : 0.8)
        )
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}
