import SwiftUI
import CoreData
import AppKit
import Combine



final class ClipboardStore: ObservableObject {
    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var favoriteLists: [FavoriteListModel] = []
    @Published private(set) var historyLimit: Int
    @Published var searchText: String = ""
    @Published private(set) var filteredEntries: [ClipboardEntry] = []
    @Published var selectedListID: NSManagedObjectID? {
        didSet { if selectedListID != nil { selectedKind = nil } }
    }
    @Published var selectedKind: ClipboardContentKind? {
        didSet { if selectedKind != nil { selectedListID = nil } }
    }
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
        
        // Setup filter pipeline (search + list selection + kind selection)
        Publishers.CombineLatest4($entries, $searchText, $selectedListID, $selectedKind)
            .map { (entries, text, selectedListID, selectedKind) -> [ClipboardEntry] in
                let keyword = text.trimmingCharacters(in: .whitespaces)
                return entries.filter { entry in
                    let matchesList = (selectedListID == nil) || (entry.favoriteListID == selectedListID)
                    guard matchesList else { return false }
                    
                    if let kind = selectedKind {
                        guard entry.kind == kind else { return false }
                    }
                    
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
            request.fetchBatchSize = 20

            do {
                let items = try self.context.fetch(request)
                let counts = self.favoriteCounts(from: items)
                let mapped = items.compactMap { item -> ClipboardEntry? in
                    guard let timestamp = item.timestamp else { return nil }
                    let content = item.content ?? ""
                    let kind = ClipboardContentKind(rawValue: item.kind ?? "") ?? .text
                    let fileURL: URL? = item.filePath.flatMap { URL(fileURLWithPath: $0) }
                    
                    // Fingerprint calculation (Temporary data access)
                    let key: String
                    switch kind {
                    case .file:
                        key = fileURL?.path ?? content.trimmingCharacters(in: .whitespacesAndNewlines)
                    case .richText:
                        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                        key = trimmed + (item.rtfData?.hashDescription ?? "")
                    case .image:
                        key = (item.imageData?.hashDescription ?? "") + content
                    case .text:
                        key = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    let fingerprint = "\(kind.rawValue)|\(key)"

                    let favoriteName: String? = item.favoriteList?.name ?? (item.favoriteList != nil ? "未命名" : nil)

                    return ClipboardEntry(
                        id: item.objectID,
                        content: content,
                        timestamp: timestamp,
                        kind: kind,
                        fileURL: fileURL,
                        favoriteListID: item.favoriteList?.objectID,
                        favoriteListName: favoriteName,
                        isDeletedFromHistory: (item.value(forKey: "isDeletedFromHistory") as? Bool) ?? false,
                        hasRichText: item.rtfData != nil,
                        hasImage: item.imageData != nil,
                        fingerprint: fingerprint
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
        context.performAndWait {
            guard let item = try? context.existingObject(with: entry.id) as? Item else { return }
            
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()

            switch entry.kind {
            case .file:
                if let url = entry.fileURL {
                    pasteboard.writeObjects([url as NSURL])
                    pasteboard.setString(url.lastPathComponent, forType: .string)
                }
            case .richText:
                if let data = item.rtfData {
                    pasteboard.setData(data, forType: .rtf)
                }
                pasteboard.setString(entry.content, forType: .string)
            case .image:
                if let url = entry.fileURL {
                    pasteboard.writeObjects([url as NSURL])
                }
                if let data = item.imageData {
                    pasteboard.setData(data, forType: .tiff)
                }
                pasteboard.setString(entry.content, forType: .string)
            case .text:
                pasteboard.setString(entry.content, forType: .string)
            }
        }

        // Avoid treating programmatic copy-back as a new capture.
        monitor?.ignoreNextChangeSnapshot()
    }

    func getRTFData(for id: NSManagedObjectID) -> Data? {
        var result: Data?
        context.performAndWait {
            if let item = try? context.existingObject(with: id) as? Item {
                result = item.rtfData
            }
        }
        return result
    }

    func getThumbnailData(for id: NSManagedObjectID) -> Data? {
        var result: Data?
        context.performAndWait {
            if let item = try? context.existingObject(with: id) as? Item {
                result = item.imageData
            }
        }
        return result
    }

    private func addCaptured(_ payloads: [CapturedPayload]) {
        guard !payloads.isEmpty else { return }

        context.perform { [weak self] in
            guard let self else { return }
            
            var didAdd = false
            
            for payload in payloads {
                let trimmed = payload.trimmedContent
                guard !trimmed.isEmpty else { continue }

                let fingerprint = payload.fingerprint
                
                // Avoid sequential duplicates.
                if fingerprint == self.lastFingerprint { continue }

                let newItem = Item(context: self.context)
                newItem.timestamp = Date()
                newItem.kind = payload.kind.rawValue
                newItem.content = trimmed
                newItem.filePath = payload.fileURL?.path
                newItem.rtfData = payload.rtfData
                newItem.imageData = payload.imageData
                
                self.lastFingerprint = fingerprint
                didAdd = true
            }

            guard didAdd else { return }

            do {
                try self.context.save()
                try self.trimOverflow(limit: self.historyLimit)
                self.refresh()
                
                DispatchQueue.main.async {
                    WindowManager.shared.flashIcon()
                }
            } catch {
                NSLog("Failed to save clipboard items: \(error.localizedDescription)")
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
        // Only count valid history items
        request.predicate = NSPredicate(format: "isDeletedFromHistory == NO || isDeletedFromHistory == nil")
        
        let count = try context.count(for: request)
        guard count > limit else { return }
        
        // Fetch candidates for deletion (the ones AFTER the limit)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Item.timestamp, ascending: false)]
        request.fetchOffset = limit
        request.resultType = .managedObjectIDResultType
        
        // Cast to NSFetchRequest<NSManagedObjectID> is tricky in Swift generics context directly sometimes,
        // but fetching ANY returning [Any] casted to [NSManagedObjectID] works.
        // We reuse logical request.
        let idRequest = NSFetchRequest<NSManagedObjectID>(entityName: "Item")
        idRequest.predicate = request.predicate
        idRequest.sortDescriptors = request.sortDescriptors
        idRequest.fetchOffset = limit
        idRequest.resultType = .managedObjectIDResultType
        
        let excessIDs = try context.fetch(idRequest)
        guard !excessIDs.isEmpty else { return }
        
        for id in excessIDs {
            guard let item = try? context.existingObject(with: id) as? Item else { continue }
            
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

    private let captureQueue = DispatchQueue(label: "com.tenom.iClipboard.capture", qos: .userInitiated)

    private func startMonitoring() {
        monitor = ClipboardMonitor { [weak self] in
            guard let self else { return }
            self.captureQueue.async {
                self.capturePasteboard()
            }
        }
    }

    private func capturePasteboard() {
        let pasteboard = NSPasteboard.general
        
        // 1. Files & Image Files
        // We always check for file URLs first. If they exist, we process them and DO NOT fall through to other types.
        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !fileURLs.isEmpty {
            var batch: [CapturedPayload] = []
            
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
                        batch.append(payload)
                    }
                } else {
                    // It is an non-image file. Check if .file is enabled.
                    if enabledTypes.contains(.file) {
                        let plainName = url.lastPathComponent
                        // User request: No cover for files (e.g. PDF)
                        let payload = CapturedPayload(
                            kind: .file,
                            content: plainName,
                            rtfData: nil,
                            fileURL: url,
                            imageData: nil
                        )
                        batch.append(payload)
                    }
                }
            }
            addCaptured(batch)
            return
        }

        // 2. Images (Data) - Only if not handled as file URL
        if enabledTypes.contains(.image), let imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            let plainName = "图片 \(Date().formatted(date: .omitted, time: .standard))"
            let thumb = ImagePreviewLoader.thumbnailData(from: imageData)
            let payload = CapturedPayload(kind: .image, content: plainName, rtfData: nil, fileURL: nil, imageData: thumb ?? imageData)
            addCaptured([payload])
            return
        }

        // 3. Rich Text
        if enabledTypes.contains(.richText), let rtfData = pasteboard.data(forType: .rtf) {
            let plain = NSAttributedString(rtf: rtfData, documentAttributes: nil)?.string ?? ""
            let payload = CapturedPayload(kind: .richText, content: plain.isEmpty ? "富文本内容" : plain, rtfData: rtfData, fileURL: nil, imageData: nil)
            addCaptured([payload])
            return
        }

        // 4. Plain Text
        if enabledTypes.contains(.text), let string = pasteboard.string(forType: .string) {
            let payload = CapturedPayload(kind: .text, content: string, rtfData: nil, fileURL: nil, imageData: nil)
            addCaptured([payload])
        }
    }
}

