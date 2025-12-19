import SwiftUI

struct TextPreviewSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("文本预览")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.primary)
                
                Spacer()
                
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
            
            Divider()
            
            // Text Editor
            TextEditor(text: .constant(text))
                .font(.system(.body, design: .monospaced)) // Monospaced for better code/text alignment
                .scrollContentBackground(.hidden) // Cleaner look
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}

#Preview {
    TextPreviewSheet(text: "Hello, World!\nThis is a preview of the text content.\n\nCode example:\nfunc hello() {\n    print(\"Hi\")\n}")
}
