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
                defaults.set(data, forKey: Self.enabledTypesDefaultsKey)
            }
        }
    }

    private let context: NSManagedObjectContext
    private var monitor: ClipboardMonitor?
    private let defaultHistoryLimit = 200
    private static let historyLimitDefaultsKey = "historyLimit"
    private static let enabledTypesDefaultsKey = "enabledTypes"
    private var lastFingerprint: String?
    private let defaults: UserDefaults
    private let onCapture: () -> Void
    private let previewCache = ClipboardPreviewCache()

    init(
        context: NSManagedObjectContext = PersistenceController.shared.container.viewContext,
        defaults: UserDefaults = .standard,
        monitorPasteboard: Bool = true,
        onCapture: @escaping () -> Void = { WindowManager.shared.flashIcon() }
    ) {
        precondition(context.concurrencyType == .mainQueueConcurrencyType)
        self.context = context
        self.defaults = defaults
        self.onCapture = onCapture
        let storedLimit = defaults.integer(forKey: Self.historyLimitDefaultsKey)
        self.historyLimit = storedLimit > 0 ? storedLimit : defaultHistoryLimit
        
        if let data = defaults.data(forKey: Self.enabledTypesDefaultsKey),
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
            .assign(to: &$filteredEntries)
            
        refresh()
        if monitorPasteboard { startMonitoring() }
    }

    func refresh() {
        context.perform { [weak self] in
            guard let self else { return }
            do {
                let listRequest: NSFetchRequest<FavoriteList> = FavoriteList.fetchRequest()
                listRequest.sortDescriptors = [
                    NSSortDescriptor(key: "createdAt", ascending: true),
                    NSSortDescriptor(key: "name", ascending: true)
                ]
                let lists = try self.context.fetch(listRequest)
                let names = Dictionary(uniqueKeysWithValues: lists.map {
                    ($0.objectID, $0.name ?? "未命名")
                })

                let objectID = NSExpressionDescription()
                objectID.name = "objectID"
                objectID.expression = NSExpression.expressionForEvaluatedObject()
                objectID.expressionResultType = .objectIDAttributeType
                let request = NSFetchRequest<NSDictionary>(entityName: "Item")
                request.resultType = .dictionaryResultType
                request.propertiesToFetch = [
                    objectID, "content", "timestamp", "kind", "filePath",
                    "favoriteList", "isDeletedFromHistory"
                ]
                request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
                // Presence queries return IDs without materializing image/RTF blobs.
                let imageIDs = try self.binaryDataIDs(for: "imageData")
                let richTextIDs = try self.binaryDataIDs(for: "rtfData")
                let rows = try self.context.fetch(request)
                let mapped = rows.compactMap { row -> ClipboardEntry? in
                    guard let id = row["objectID"] as? NSManagedObjectID,
                          let timestamp = row["timestamp"] as? Date else { return nil }
                    let listID = row["favoriteList"] as? NSManagedObjectID
                    return ClipboardEntry(
                        id: id,
                        content: row["content"] as? String ?? "",
                        timestamp: timestamp,
                        kind: ClipboardContentKind(rawValue: row["kind"] as? String ?? "") ?? .text,
                        fileURL: (row["filePath"] as? String).map { URL(fileURLWithPath: $0) },
                        favoriteListID: listID,
                        favoriteListName: listID.map { names[$0] ?? "未命名" },
                        isDeletedFromHistory: (row["isDeletedFromHistory"] as? NSNumber)?.boolValue ?? false,
                        hasRichText: richTextIDs.contains(id),
                        hasImage: imageIDs.contains(id)
                    )
                }
                var counts: [NSManagedObjectID: Int] = [:]
                for row in rows {
                    if let id = row["favoriteList"] as? NSManagedObjectID { counts[id, default: 0] += 1 }
                }
                let favoriteLists = lists.map {
                    FavoriteListModel(
                        id: $0.objectID, name: $0.name ?? "未命名",
                        createdAt: $0.createdAt ?? Date(), count: counts[$0.objectID] ?? 0
                    )
                }
                // Only the newest item participates in sequential deduplication.
                let fingerprint = mapped.first(where: { !$0.isDeletedFromHistory }).flatMap { self.fingerprint(for: $0) }
                self.entries = mapped
                self.lastFingerprint = fingerprint
                self.favoriteLists = favoriteLists
                if let selected = self.selectedListID,
                   !favoriteLists.contains(where: { $0.id == selected }) {
                    self.selectedListID = nil
                }
            } catch {
                NSLog("Failed to fetch clipboard items: \(error.localizedDescription)")
            }
        }
    }

    private func binaryDataIDs(for property: String) throws -> Set<NSManagedObjectID> {
        let request = NSFetchRequest<NSManagedObjectID>(entityName: "Item")
        request.resultType = .managedObjectIDResultType
        request.predicate = NSPredicate(format: "%K != nil", property)
        return Set(try context.fetch(request))
    }

    private func fingerprint(for entry: ClipboardEntry) -> String? {
        guard let item = try? context.existingObject(with: entry.id) as? Item else { return nil }
        defer { if !item.hasChanges { context.refresh(item, mergeChanges: false) } }
        return fingerprint(for: item)
    }

    private func fingerprint(for item: Item) -> String {
        let kind = ClipboardContentKind(rawValue: item.kind ?? "") ?? .text
        if kind == .image, let digest = item.imageDigest { return "image|\(digest)" }
        return CapturedPayload(
            kind: kind, content: item.content ?? "", rtfData: item.rtfData,
            fileURL: item.filePath.map { URL(fileURLWithPath: $0) }, imageData: item.imageData
        ).fingerprint
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
            self.context.delete(self.context.object(with: entry.id))
            do {
                try self.context.save()
                self.releasePreviews()
                self.refresh()
            } catch {
                NSLog("Failed to delete clipboard item: \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    func copyToPasteboard(_ entry: ClipboardEntry, to pasteboard: NSPasteboard = .general) {
        context.performAndWait {
            guard let item = try? context.existingObject(with: entry.id) as? Item else { return }
            defer { if !item.hasChanges { context.refresh(item, mergeChanges: false) } }
            
            if pasteboard.name == NSPasteboard.general.name {
                SelectionCopyFallback.shared.noteUserClipboardAction()
            }
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
                let candidates: [() -> Data?] = [
                    { item.originalImageData },
                    { entry.fileURL.flatMap { try? Data(contentsOf: $0) } },
                    { item.imageData }
                ]
                for load in candidates {
                    if let data = load(), let image = try? ToolImage.decode(data), let png = try? image.pngData() {
                        pasteboard.writeObjects([ToolImage.pasteboardItem(pngData: png, sourceFileURL: entry.fileURL)])
                        break
                    }
                }
            case .text:
                pasteboard.setString(entry.content, forType: .string)
            }
        }

        // Avoid treating programmatic copy-back as a new capture.
        if pasteboard.name == NSPasteboard.general.name {
            monitor?.ignoreNextChangeSnapshot()
        }
    }

    func preview(for entry: ClipboardEntry) -> ClipboardPreview {
        previewCache.preview(for: entry.id) {
            var data: (image: Data?, richText: Data?) = (nil, nil)
            context.performAndWait {
                guard let item = try? context.existingObject(with: entry.id) as? Item else { return }
                data = (entry.hasImage ? item.imageData : nil, entry.hasRichText ? item.rtfData : nil)
                if !item.hasChanges { context.refresh(item, mergeChanges: false) }
            }
            return data
        }
    }

    func releasePreviews() {
        previewCache.removeAll()
        context.performAndWait {
            if !context.hasChanges { context.refreshAllObjects() }
        }
    }

    func record(_ payloads: [CapturedPayload]) {
        guard !payloads.isEmpty else { return }
        context.perform { [weak self] in
            guard let self else { return }
            do { _ = try self.savePayloads(payloads) }
            catch { NSLog("Failed to save clipboard items: \(error.localizedDescription)") }
        }
    }

    func submit(_ payload: CapturedPayload) async throws -> NSManagedObjectID {
        try await context.perform {
            guard let id = try self.savePayloads([payload]).first else {
                throw ImageToolsError.invalidImage
            }
            return id
        }
    }

    private func savePayloads(_ payloads: [CapturedPayload]) throws -> [NSManagedObjectID] {
        var pendingFingerprint = lastFingerprint
        var inserted: [Item] = []
        var results: [Item] = []
        for payload in payloads where !payload.trimmedContent.isEmpty {
            if payload.fingerprint == pendingFingerprint {
                if let previous = results.last {
                    results.append(previous)
                    continue
                }
                let request: NSFetchRequest<Item> = Item.fetchRequest()
                request.predicate = NSPredicate(format: "isDeletedFromHistory == NO || isDeletedFromHistory == nil")
                request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
                request.fetchLimit = 1
                if let previous = try context.fetch(request).first,
                   fingerprint(for: previous) == payload.fingerprint {
                    results.append(previous)
                    continue
                }
            }
            let item = Item(context: context)
            item.timestamp = Date()
            item.kind = payload.kind.rawValue
            item.content = payload.trimmedContent
            item.filePath = payload.fileURL?.path
            item.rtfData = payload.rtfData
            item.imageData = payload.imageData
            item.originalImageData = payload.originalImageData
            item.imageDigest = payload.imageDigest
            inserted.append(item)
            results.append(item)
            pendingFingerprint = payload.fingerprint
        }
        guard !inserted.isEmpty else { return results.map(\.objectID) }
        do {
            try context.save()
        } catch {
            // Discard only this operation's insertions, not unrelated favorite edits.
            inserted.forEach { context.delete($0) }
            throw error
        }
        lastFingerprint = pendingFingerprint
        let ids = results.map(\.objectID)
        do { try trimOverflow(limit: historyLimit) }
        catch { NSLog("Items saved, but history trimming failed: \(error.localizedDescription)") }
        refresh()
        DispatchQueue.main.async { self.onCapture() }
        return ids
    }

    func ignoreProgrammaticCopy() {
        monitor?.ignoreNextChangeSnapshot()
    }

    func contains(_ id: NSManagedObjectID) -> Bool {
        var exists = false
        context.performAndWait {
            exists = (try? context.existingObject(with: id)).map { !$0.isDeleted } ?? false
        }
        return exists
    }

    func containsInHistory(_ id: NSManagedObjectID) -> Bool {
        var exists = false
        context.performAndWait {
            let request = NSFetchRequest<NSManagedObjectID>(entityName: "Item")
            request.resultType = .managedObjectIDResultType
            request.predicate = NSPredicate(format: "SELF == %@ AND (isDeletedFromHistory == NO || isDeletedFromHistory == nil)", id)
            request.fetchLimit = 1
            exists = (try? context.fetch(request).isEmpty) == false
        }
        return exists
    }

    func loadImage(for entry: ClipboardEntry) async throws -> ToolImage {
        let stored: (Data?, Data?) = try await context.perform {
            guard let item = try self.context.existingObject(with: entry.id) as? Item else {
                throw ImageToolsError.noImage
            }
            defer { if !item.hasChanges { self.context.refresh(item, mergeChanges: false) } }
            return (item.originalImageData, item.imageData)
        }
        return try await Task.detached(priority: .userInitiated) {
            if let original = stored.0 {
                return try ToolImage.decode(original, title: entry.content)
            }
            if let url = entry.fileURL, let data = try? Data(contentsOf: url),
               let image = try? ToolImage.decode(data, title: entry.content) { return image }
            guard let preview = stored.1 else { throw ImageToolsError.noImage }
            return try ToolImage.decode(preview, title: entry.content, isOriginal: false)
        }.value
    }

    func updateHistoryLimit(_ newLimit: Int) {
        let clamped = max(10, min(newLimit, 500))
        guard clamped != historyLimit else { return }

        historyLimit = clamped
        defaults.set(clamped, forKey: Self.historyLimitDefaultsKey)

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

    private let captureQueue = DispatchQueue(label: "com.tenom.iClipboard.capture", qos: .userInitiated)

    private func startMonitoring() {
        monitor = ClipboardMonitor { [weak self] in
            guard let self else { return }
            let enabledTypes = self.enabledTypes
            guard !enabledTypes.isEmpty,
                  let snapshot = ClipboardCaptureSnapshot(pasteboard: .general, enabledTypes: enabledTypes) else { return }
            self.captureQueue.async { [weak self] in
                let payloads = autoreleasepool {
                    Self.capturePasteboard(snapshot, enabledTypes: enabledTypes)
                }
                self?.record(payloads)
            }
        }
    }

    static func capturePasteboard(_ pasteboard: ClipboardCaptureSnapshot, enabledTypes: Set<ClipboardContentKind>) -> [CapturedPayload] {
        
        // 1. Files & Image Files
        // We always check for file URLs first. If they exist, we process them and DO NOT fall through to other types.
        let fileURLs = pasteboard.fileURLs
        if !fileURLs.isEmpty {
            var batch: [CapturedPayload] = []
            
            for url in fileURLs {
                let isImage = url.isImageFile
                
                if isImage {
                    // It is an image file. Check if .image is enabled.
                    if enabledTypes.contains(.image) {
                        let plainName = url.lastPathComponent
                        if let data = try? Data(contentsOf: url),
                           let payload = CapturedPayload.capturedImage(data: data, title: plainName, fileURL: url) {
                            batch.append(payload)
                        }
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
            return batch
        }

        // 2. Images (Data) - Only if not handled as file URL
        if enabledTypes.contains(.image), let imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            let plainName = "图片 \(Date().formatted(date: .omitted, time: .standard))"
            guard let payload = CapturedPayload.capturedImage(data: imageData, title: plainName) else { return [] }
            return [payload]
        }

        // 3. Rich Text
        if enabledTypes.contains(.richText), let rtfData = pasteboard.data(forType: .rtf) {
            let plain = NSAttributedString(rtf: rtfData, documentAttributes: nil)?.string ?? ""
            let payload = CapturedPayload(kind: .richText, content: plain.isEmpty ? "富文本内容" : plain, rtfData: rtfData, fileURL: nil, imageData: nil)
            return [payload]
        }

        // 4. Plain Text
        if enabledTypes.contains(.text), let string = pasteboard.string(forType: .string) {
            let payload = CapturedPayload(kind: .text, content: string, rtfData: nil, fileURL: nil, imageData: nil)
            return [payload]
        }
        return []
    }
}

