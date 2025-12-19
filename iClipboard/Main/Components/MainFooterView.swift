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

            if canExport {
                Button {
                    exportData()
                } label: {
                    Label("导出数据", systemImage: "arrow.down.doc")
                        .labelStyle(.iconOnly)
                        .frame(width: 24, height: 20)
                }
                .buttonStyle(IconButtonStyle())
                .help("导出收藏列表(文本)")
            }

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

    private var canExport: Bool {
        // Must have at least one favorite list AND at least one entry assigned to a list
        guard !store.favoriteLists.isEmpty else { return false }
        return store.entries.contains { $0.favoriteListID != nil }
    }

    private func exportData() {
        guard canExport else { return }
        
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "导出"
        panel.message = "选择导出位置 (将创建 iClipboard 文件夹)"
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                let targetFolder = url.appendingPathComponent("iClipboard")
                if FileManager.default.fileExists(atPath: targetFolder.path) {
                    let alert = NSAlert()
                    alert.messageText = "文件夹已存在"
                    alert.informativeText = "“iClipboard”文件夹已存在于所选位置。您想要替换它还是合并内容？"
                    alert.addButton(withTitle: "替换") // Response 1000
                    alert.addButton(withTitle: "合并") // Response 1001
                    alert.addButton(withTitle: "取消") // Response 1002
                    
                    let response = alert.runModal()
                    if response == .alertFirstButtonReturn {
                        // Replace -> Clean = true
                        DataExporter.export(store: store, to: url, clean: true)
                    } else if response == .alertSecondButtonReturn {
                        // Merge -> Clean = false
                        DataExporter.export(store: store, to: url, clean: false)
                    }
                    // Cancel -> Do nothing
                } else {
                    DataExporter.export(store: store, to: url, clean: false)
                }
            }
        }
    }
}
