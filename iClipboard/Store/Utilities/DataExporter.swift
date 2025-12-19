import UserNotifications

struct DataExporter {
    struct ExportItem: Encodable {
        let type: String
        let content: String // Text content or Image Index
        let date: String
    }
    
    static func export(store: ClipboardStore, to directoryURL: URL, clean: Bool = false) {
        let rootURL = directoryURL.appendingPathComponent("iClipboard")
        let fileManager = FileManager.default
        
        do {
            // Check if directory exists
            if fileManager.fileExists(atPath: rootURL.path) {
                if clean {
                    // Remove existing directory if clean export is requested
                    try fileManager.removeItem(at: rootURL)
                    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: nil)
                }
                
                if !fileManager.fileExists(atPath: rootURL.path) {
                     try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: nil)
                }
            } else {
                try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: nil)
            }
            
            var exportedFileCount = 0
            
            for list in store.favoriteLists {
                // Filter entries for this list
                let entries = store.entries.filter { $0.favoriteListID == list.id }
                guard !entries.isEmpty else { continue }
                
                var exportItems: [ExportItem] = []
                
                for entry in entries {
                    let dateString = entry.timestamp.formatted(date: .numeric, time: .standard)
                    
                    switch entry.kind {
                    case .text, .richText:
                        let item = ExportItem(type: "text", content: entry.content, date: dateString)
                        exportItems.append(item)
                        
                    case .image, .file:
                        // Exclude images and files as requested
                        continue
                    }
                }
                
                // Write JSON
                if !exportItems.isEmpty {
                    let jsonEncoder = JSONEncoder()
                    jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let jsonData = try jsonEncoder.encode(exportItems)
                    let jsonURL = rootURL.appendingPathComponent("\(list.name).json")
                    try jsonData.write(to: jsonURL)
                    exportedFileCount += 1
                }
            }
            
            // Send Notification instead of auto-opening
            let content = UNMutableNotificationContent()
            content.title = "导出成功"
            content.body = "已成功导出 \(exportedFileCount) 个文件到 \(rootURL.lastPathComponent)"
            content.sound = .default
            content.categoryIdentifier = "EXPORT_CATEGORY"
            content.userInfo = ["path": rootURL.path]
            
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
            
        } catch {
            print("Export failed: \(error)")
        }
    }
}
