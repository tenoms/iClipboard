import SwiftUI

struct ClearConfirmationView: View {
    @Binding var isPresented: Bool
    let onConfirm: () -> Void
    
    var body: some View {
        if isPresented {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .transition(.opacity)
                .onTapGesture {
                    withAnimation(.spring(response: 0.3)) {
                        isPresented = false
                    }
                }

            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Image(systemName: "trash.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.red)
                    
                    Text("删除所有记录？")
                        .font(.system(.title3, design: .rounded).bold())
                        .foregroundStyle(.primary)
                    
                    Text("清空后无法恢复，请确认。")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    
                    Text("收藏列表中的记录不会被删除。")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                
                HStack(spacing: 12) {
                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            isPresented = false
                        }
                    } label: {
                        Text("取消")
                            .font(.system(.body, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    
                    Button {
                        onConfirm()
                    } label: {
                        Text("删除")
                            .font(.system(.body, design: .rounded).bold())
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.red)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Material.thick)
                    .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)
            )
            .padding(40)
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }
}
