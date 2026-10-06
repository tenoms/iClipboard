import SwiftUI

struct TextPreviewSheet: View {
    @Environment(\.appPalette) private var palette
    let text: String
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("文本预览")
                    .font(.system(.headline))
                    .foregroundStyle(palette.text)
                
                Spacer()
                
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(palette.secondaryText)
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding()
            
            ThemeDivider()
            
            // Text Editor
            TextEditor(text: .constant(text))
                .foregroundStyle(palette.text)
                .font(.system(.body, design: .monospaced)) // Monospaced for better code/text alignment
                .scrollContentBackground(.hidden) // Cleaner look
                .padding(12)
                .background(palette.surface)
        }
        .background(PanelBackground(material: .sheet))
        .tint(palette.accent)
        .frame(minWidth: 500, minHeight: 400)
    }
}

#Preview {
    TextPreviewSheet(text: "Hello, World!\nThis is a preview of the text content.\n\nCode example:\nfunc hello() {\n    print(\"Hi\")\n}")
}
