import SwiftUI
import CoreData
import AppKit
import Combine

enum ClipboardContentKind: String, CaseIterable, Codable {
    case text
    case richText
    case file
    case image

    var label: String {
        switch self {
        case .text: return "文本"
        case .richText: return "富文本"
        case .file: return "文件"
        case .image: return "图片"
        }
    }

    var icon: String {
        switch self {
        case .text: return "text.alignleft"
        case .richText: return "doc.richtext"
        case .file: return "doc"
        case .image: return "photo"
        }
    }
}

struct ClipboardEntry: Identifiable, Hashable {
    let id: NSManagedObjectID
    let content: String
    let timestamp: Date
    let kind: ClipboardContentKind
    let rtfData: Data?
    let fileURL: URL?
    let imageData: Data?
    let favoriteListID: NSManagedObjectID?
    let favoriteListName: String?
    let isDeletedFromHistory: Bool

    var fingerprint: String {
        let key: String
        switch kind {
        case .file:
            key = fileURL?.path ?? content.trimmingCharacters(in: .whitespacesAndNewlines)
        case .richText:
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            key = trimmed + (rtfData?.hashDescription ?? "")
        case .image:
            key = (imageData?.hashDescription ?? "") + content
        case .text:
            key = content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "\(kind.rawValue)|\(key)"
    }

    var isFavorited: Bool {
        favoriteListID != nil
    }
}

struct FavoriteListModel: Identifiable, Hashable {
    let id: NSManagedObjectID
    let name: String
    let createdAt: Date
    let count: Int
}

final class ClipboardStore: ObservableObject {
    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var favoriteLists: [FavoriteListModel] = []
    @Published private(set) var historyLimit: Int
    @Published var searchText: String = ""
    @Published private(set) var filteredEntries: [ClipboardEntry] = []
    @Published var selectedListID: NSManagedObjectID?
    @Published var enabledTypes: Set<ClipboardContentKind> = [] {
        didSet {
            if let data = try? JSONEncoder().encode(enabledTypes) {
                UserDefaults.standard.set(data, forKey: Self.enabledTypesDefaultsKey)
            }
        }
    }

    private let context: NSManagedObjectContext
    private var monitor: ClipboardMonitor?
    private let defaultHistoryLimit = 200
    private static let historyLimitDefaultsKey = "historyLimit"
    private static let enabledTypesDefaultsKey = "enabledTypes"
    private var lastFingerprint: String?
    private var cancellables = Set<AnyCancellable>()

    init(context: NSManagedObjectContext = PersistenceController.shared.container.viewContext) {
        self.context = context
        let storedLimit = UserDefaults.standard.integer(forKey: Self.historyLimitDefaultsKey)
        self.historyLimit = storedLimit > 0 ? storedLimit : defaultHistoryLimit
        
        if let data = UserDefaults.standard.data(forKey: Self.enabledTypesDefaultsKey),
           let types = try? JSONDecoder().decode(Set<ClipboardContentKind>.self, from: data) {
            self.enabledTypes = types
        } else {
            self.enabledTypes = Set(ClipboardContentKind.allCases)
        }
        
        // Setup filter pipeline (search + list selection)
        Publishers.CombineLatest3($entries, $searchText, $selectedListID)
            .map { (entries, text, selectedListID) -> [ClipboardEntry] in
                let keyword = text.trimmingCharacters(in: .whitespaces)
                return entries.filter { entry in
                    let matchesList = (selectedListID == nil) || (entry.favoriteListID == selectedListID)
                    guard matchesList else { return false }
                    
                    // If in "All Attributes" (selectedListID == nil), hide items that are soft-deleted
                    if selectedListID == nil, entry.isDeletedFromHistory {
                        return false
                    }
                    
                    guard !keyword.isEmpty else { return true }
                    let fileName = entry.fileURL?.lastPathComponent ?? ""
                    return entry.content.localizedCaseInsensitiveContains(keyword) || fileName.localizedCaseInsensitiveContains(keyword)
                }
            }
            .assign(to: \.filteredEntries, on: self)
            .store(in: &cancellables)
            
        refresh()
        startMonitoring()
    }

    func refresh() {
        context.perform { [weak self] in
            guard let self else { return }
            let request: NSFetchRequest<Item> = Item.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(keyPath: \Item.timestamp, ascending: false)]
            // Fetch everything (except hard-deleted). Filter visibility in memory.


            do {
                let items = try self.context.fetch(request)
                let counts = self.favoriteCounts(from: items)
                let mapped = items.compactMap { item -> ClipboardEntry? in
                    guard let timestamp = item.timestamp else { return nil }
                    let content = item.content ?? ""
                    let kind = ClipboardContentKind(rawValue: item.kind ?? "") ?? .text
                    let fileURL: URL? = item.filePath.flatMap { URL(fileURLWithPath: $0) }
                    let favoriteName: String?
                    if let list = item.favoriteList {
                        favoriteName = list.name ?? "未命名"
                    } else {
                        favoriteName = nil
                    }

                    return ClipboardEntry(
                        id: item.objectID,
                        content: content,
                        timestamp: timestamp,
                        kind: kind,
                        rtfData: item.rtfData,
                        fileURL: fileURL,
                        imageData: item.imageData,
                        favoriteListID: item.favoriteList?.objectID,
                        favoriteListName: favoriteName,
                        isDeletedFromHistory: (item.value(forKey: "isDeletedFromHistory") as? Bool) ?? false
                    )
                }
                DispatchQueue.main.async {
                    self.entries = mapped
                    self.lastFingerprint = mapped.first?.fingerprint
                }
                self.loadFavoriteLists(counts: counts)
            } catch {
                NSLog("Failed to fetch clipboard items: \(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    func addFavoriteList(named name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "列表名称不能为空" }
        if favoriteLists.contains(where: { $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame }) {
            return "已存在同名列表"
        }

        context.perform { [weak self] in
            guard let self else { return }
            let list = FavoriteList(context: self.context)
            list.name = trimmed
            list.createdAt = Date()

            do {
                try self.context.save()
                DispatchQueue.main.async {
                    self.selectedListID = list.objectID
                }
                self.refresh()
            } catch {
                NSLog("Failed to add favorite list: \(error.localizedDescription)")
            }
        }
        return nil
    }

    func deleteFavoriteList(_ list: FavoriteListModel) {
        context.perform { [weak self] in
            guard let self else { return }
            guard let listObject = try? self.context.existingObject(with: list.id) else { return }
            self.context.delete(listObject)

            do {
                try self.context.save()
                DispatchQueue.main.async {
                    if self.selectedListID == list.id {
                        self.selectedListID = nil
                    }
                }
                self.refresh()
            } catch {
                NSLog("Failed to delete favorite list: \(error.localizedDescription)")
            }
        }
    }

    func setFavorite(for entry: ClipboardEntry, listID: NSManagedObjectID?) {
        context.perform { [weak self] in
            guard let self else { return }
            guard let item = try? self.context.existingObject(with: entry.id) as? Item else { return }

            var targetList: FavoriteList?
            if let listID {
                guard let fetched = try? self.context.existingObject(with: listID) as? FavoriteList else { return }
                targetList = fetched
            }

            guard item.favoriteList?.objectID != targetList?.objectID else { return }
            item.favoriteList = targetList
            
            // Check for orphan state: Not in any list AND soft-deleted from history
            // Use KVC to check soft-delete status safely
            let isSoftDeleted = (item.value(forKey: "isDeletedFromHistory") as? Bool) ?? false
            if targetList == nil && isSoftDeleted {
                // Orphaned item. Hard delete it.
                self.context.delete(item)
            }

            do {
                try self.context.save()
                self.refresh()
            } catch {
                NSLog("Failed to update favorite: \(error.localizedDescription)")
            }
        }
    }

    func deleteAll() {
        context.perform { [weak self] in
            guard let self else { return }
            let request: NSFetchRequest<Item> = Item.fetchRequest()
            // We only want to process items currently visible in history
            request.predicate = NSPredicate(format: "isDeletedFromHistory == NO || isDeletedFromHistory == nil")

            do {
                let items = try self.context.fetch(request)
                for item in items {
                    if item.favoriteList != nil {
                        // Soft delete: hide from history, keep for favorite list
                        item.setValue(true, forKey: "isDeletedFromHistory")
                    } else {
                        // Hard delete: remove completely
                        self.context.delete(item)
                    }
                }
                try self.context.save()
                self.refresh()
            } catch {
                NSLog("Failed to delete clipboard items: \(error.localizedDescription)")
            }
        }
    }

    func delete(_ entry: ClipboardEntry) {
        context.perform { [weak self] in
            guard let self else { return }
            let object = self.context.object(with: entry.id)
            self.context.delete(object)
            do {
                try self.context.save()
                DispatchQueue.main.async {
                    self.entries.removeAll { $0.id == entry.id }
                    if self.lastFingerprint == entry.fingerprint {
                        self.lastFingerprint = self.entries.first?.fingerprint
                    }
                }
                self.loadFavoriteLists()
            } catch {
                NSLog("Failed to delete clipboard item: \(error.localizedDescription)")
            }
        }
    }

    func copyToPasteboard(_ entry: ClipboardEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch entry.kind {
        case .file:
            if let url = entry.fileURL {
                pasteboard.writeObjects([url as NSURL])
                pasteboard.setString(url.lastPathComponent, forType: .string)
            }
        case .richText:
            if let data = entry.rtfData {
                pasteboard.setData(data, forType: .rtf)
            }
            pasteboard.setString(entry.content, forType: .string)
        case .image:
            if let url = entry.fileURL {
                // Preserve original file so Finder paste works.
                pasteboard.writeObjects([url as NSURL])
            }
            if let data = entry.imageData {
                pasteboard.setData(data, forType: .tiff)
            }
            pasteboard.setString(entry.content, forType: .string)
        case .text:
            pasteboard.setString(entry.content, forType: .string)
        }

        // Avoid treating programmatic copy-back as a new capture.
        monitor?.ignoreNextChangeSnapshot()
    }

    private func addCaptured(_ captured: CapturedPayload) {
        let trimmed = captured.trimmedContent
        guard !trimmed.isEmpty else { return }

        let fingerprint = captured.fingerprint
        if fingerprint == lastFingerprint { return }

        context.perform { [weak self] in
            guard let self else { return }

            let newItem = Item(context: self.context)
            newItem.timestamp = Date()
            newItem.kind = captured.kind.rawValue
            newItem.content = trimmed
            newItem.filePath = captured.fileURL?.path
            newItem.rtfData = captured.rtfData
            newItem.imageData = captured.imageData

            do {
                try self.context.save()
                self.lastFingerprint = fingerprint
                try self.trimOverflow(limit: self.historyLimit)
                self.refresh()
                
                DispatchQueue.main.async {
                    WindowManager.shared.flashIcon()
                }
            } catch {
                NSLog("Failed to save clipboard item: \(error.localizedDescription)")
            }
        }
    }

    func updateHistoryLimit(_ newLimit: Int) {
        let clamped = max(10, min(newLimit, 500))
        guard clamped != historyLimit else { return }

        historyLimit = clamped
        UserDefaults.standard.set(clamped, forKey: Self.historyLimitDefaultsKey)

        context.perform { [weak self] in
            guard let self else { return }
            do {
                try self.trimOverflow(limit: clamped)
                DispatchQueue.main.async {
                    self.refresh()
                }
            } catch {
                NSLog("Failed to apply history limit: \(error.localizedDescription)")
            }
        }
    }

    private func trimOverflow(limit: Int) throws {
        let request: NSFetchRequest<Item> = Item.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Item.timestamp, ascending: false)]
        // Only count valid history items
        request.predicate = NSPredicate(format: "isDeletedFromHistory == NO || isDeletedFromHistory == nil")

        let items = try context.fetch(request)
        guard items.count > limit else { return }

        let excess = items.suffix(from: limit)
        for item in excess {
            if item.favoriteList != nil {
                // Soft delete
                item.setValue(true, forKey: "isDeletedFromHistory")
            } else {
                // Hard delete
                context.delete(item)
            }
        }
        try context.save()
    }

    private func favoriteCounts(from items: [Item]) -> [NSManagedObjectID: Int] {
        var counts: [NSManagedObjectID: Int] = [:]
        for item in items {
            if let listID = item.favoriteList?.objectID {
                counts[listID, default: 0] += 1
            }
        }
        return counts
    }

    private func loadFavoriteLists(counts: [NSManagedObjectID: Int]? = nil) {
        context.perform { [weak self] in
            guard let self else { return }
            let request: NSFetchRequest<FavoriteList> = FavoriteList.fetchRequest()
            request.sortDescriptors = [
                NSSortDescriptor(key: "createdAt", ascending: true),
                NSSortDescriptor(key: "name", ascending: true)
            ]

            do {
                let lists = try self.context.fetch(request)
                let mapped = lists.map { list in
                    FavoriteListModel(
                        id: list.objectID,
                        name: list.name ?? "未命名",
                        createdAt: list.createdAt ?? Date(),
                        count: counts?[list.objectID] ?? (list.items?.count ?? 0)
                    )
                }
                DispatchQueue.main.async {
                    self.favoriteLists = mapped
                    if let selected = self.selectedListID, mapped.contains(where: { $0.id == selected }) == false {
                        self.selectedListID = nil
                    }
                }
            } catch {
                NSLog("Failed to load favorite lists: \(error.localizedDescription)")
            }
        }
    }

    private func startMonitoring() {
        monitor = ClipboardMonitor { [weak self] in
            self?.capturePasteboard()
        }
    }

    private func capturePasteboard() {
        let pasteboard = NSPasteboard.general
        
        // 1. Files & Image Files
        // We always check for file URLs first. If they exist, we process them and DO NOT fall through to other types.
        // This prevents "Copy File" from falling back to capturing the file's icon as an Image when .file is disabled.
        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !fileURLs.isEmpty {
            for url in fileURLs {
                let isImage = url.isImageFile
                
                if isImage {
                    // It is an image file. Check if .image is enabled.
                    if enabledTypes.contains(.image) {
                        let plainName = url.lastPathComponent
                        let thumb = ImagePreviewLoader.thumbnailData(from: url)
                        let payload = CapturedPayload(
                            kind: .image,
                            content: plainName,
                            rtfData: nil,
                            fileURL: url,
                            imageData: thumb
                        )
                        addCaptured(payload)
                    }
                } else {
                    // It is a non-image file. Check if .file is enabled.
                    if enabledTypes.contains(.file) {
                        let plainName = url.lastPathComponent
                        let thumb = ImagePreviewLoader.thumbnailData(from: url)
                        let payload = CapturedPayload(
                            kind: .file,
                            content: plainName,
                            rtfData: nil,
                            fileURL: url,
                            imageData: thumb
                        )
                        addCaptured(payload)
                    }
                }
            }
            return
        }

        // 2. Images (Data) - Only if not handled as file URL
        if enabledTypes.contains(.image), let imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            let plainName = "图片 \(Date().formatted(date: .omitted, time: .standard))"
            let thumb = ImagePreviewLoader.thumbnailData(from: imageData)
            let payload = CapturedPayload(kind: .image, content: plainName, rtfData: nil, fileURL: nil, imageData: thumb ?? imageData)
            addCaptured(payload)
            return
        }

        // 3. Rich Text
        if enabledTypes.contains(.richText), let rtfData = pasteboard.data(forType: .rtf) {
            let plain = NSAttributedString(rtf: rtfData, documentAttributes: nil)?.string ?? ""
            let payload = CapturedPayload(kind: .richText, content: plain.isEmpty ? "富文本内容" : plain, rtfData: rtfData, fileURL: nil, imageData: nil)
            addCaptured(payload)
            return
        }

        // 4. Plain Text
        if enabledTypes.contains(.text), let string = pasteboard.string(forType: .string) {
            let payload = CapturedPayload(kind: .text, content: string, rtfData: nil, fileURL: nil, imageData: nil)
            addCaptured(payload)
        }
    }
}

private struct CapturedPayload {
    let kind: ClipboardContentKind
    let content: String
    let rtfData: Data?
    let fileURL: URL?
    let imageData: Data?

    var trimmedContent: String {
        content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var fingerprint: String {
        let key: String
        switch kind {
        case .file:
            key = fileURL?.path ?? trimmedContent
        case .richText:
            key = trimmedContent + (rtfData?.hashDescription ?? "")
        case .image:
            key = (imageData?.hashDescription ?? "") + trimmedContent
        case .text:
            key = trimmedContent
        }
        return "\(kind.rawValue)|\(key)"
    }
}

private final class ClipboardMonitor {
    private var timer: Timer?
    private var lastChangeCount: Int
    private var ignoredChangeCount: Int?
    private let onChange: () -> Void

    init(interval: TimeInterval = 0.8, onChange: @escaping () -> Void) {
        self.onChange = onChange
        let pasteboard = NSPasteboard.general
        lastChangeCount = pasteboard.changeCount

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkPasteboard()
        }

        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func checkPasteboard() {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        if let ignored = ignoredChangeCount, ignored == changeCount {
            ignoredChangeCount = nil
            return
        }
        ignoredChangeCount = nil
        onChange()
    }

    func ignoreNextChangeSnapshot() {
        ignoredChangeCount = NSPasteboard.general.changeCount
        lastChangeCount = ignoredChangeCount ?? lastChangeCount
    }

    deinit {
        timer?.invalidate()
    }
}

enum ImagePreviewLoader {
    static func thumbnailData(from url: URL, maxDimension: CGFloat = 320) -> Data? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        return thumbnailData(from: image, maxDimension: maxDimension)
    }

    static func thumbnailData(from data: Data, maxDimension: CGFloat = 320) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        return thumbnailData(from: image, maxDimension: maxDimension)
    }

    private static func thumbnailData(from image: NSImage, maxDimension: CGFloat) -> Data? {
        let targetSize = scaledSize(for: image.size, maxDimension: maxDimension)
        let thumbnail = NSImage(size: targetSize)
        thumbnail.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: targetSize), from: .zero, operation: .copy, fraction: 1.0)
        thumbnail.unlockFocus()
        return thumbnail.tiffRepresentation
    }

    private static func scaledSize(for size: CGSize, maxDimension: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: maxDimension, height: maxDimension) }
        let scale = min(maxDimension / max(size.width, size.height), 1.0)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

private extension URL {
    var isImageFile: Bool {
        let ext = self.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "bmp"].contains(ext)
    }
}

private extension Data {
    var hashDescription: String {
        var hash = 5381
        for byte in self {
            hash = ((hash << 5) &+ hash) &+ Int(byte)
        }
        return String(hash)
    }
}
