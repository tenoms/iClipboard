import SwiftUI
import CoreData

struct MainFooterView: View {
    @ObservedObject var store: ClipboardStore
    @Binding var isShowingSettings: Bool
    
    var body: some View {
        HStack {
            Button {
                withAnimation {
                    isShowingSettings = true
                }
            } label: {
                Label("设置", systemImage: "gearshape.fill")
                    .labelStyle(.iconOnly)
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(IconButtonStyle())
            .help("打开设置")

            Spacer()
            Text(footerText)
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
    
    private var footerText: String {
        let count = store.filteredEntries.count
        if let selected = store.favoriteLists.first(where: { $0.id == store.selectedListID })?.name {
            return "\(count) 条记录 · \(selected)"
        }
        return "\(count) 条记录"
    }
}
