import SwiftUI
import CoreData
import AppKit

enum ClipboardContentKind: String {
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
}

final class ClipboardStore: ObservableObject {
    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var historyLimit: Int

    private let context: NSManagedObjectContext
    private var monitor: ClipboardMonitor?
    private let defaultHistoryLimit = 200
    private static let historyLimitDefaultsKey = "historyLimit"
    private var lastFingerprint: String?

    init(context: NSManagedObjectContext = PersistenceController.shared.container.viewContext) {
        self.context = context
        let storedLimit = UserDefaults.standard.integer(forKey: Self.historyLimitDefaultsKey)
        self.historyLimit = storedLimit > 0 ? storedLimit : defaultHistoryLimit
        refresh()
        startMonitoring()
    }

    func refresh() {
        context.perform { [weak self] in
            guard let self else { return }
            let request: NSFetchRequest<Item> = Item.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(keyPath: \Item.timestamp, ascending: false)]
            request.fetchLimit = self.historyLimit

            do {
                let items = try self.context.fetch(request)
                let mapped = items.compactMap { item -> ClipboardEntry? in
                    guard let timestamp = item.timestamp else { return nil }
                    let content = item.content ?? ""
                    let kind = ClipboardContentKind(rawValue: item.kind ?? "") ?? .text
                    let fileURL: URL?
                    if let path = item.filePath {
                        fileURL = URL(fileURLWithPath: path)
                    } else {
                        fileURL = nil
                    }

                    return ClipboardEntry(
                        id: item.objectID,
                        content: content,
                        timestamp: timestamp,
                        kind: kind,
                        rtfData: item.rtfData,
                        fileURL: fileURL,
                        imageData: item.imageData
                    )
                }
                DispatchQueue.main.async {
                    self.entries = mapped
                    self.lastFingerprint = mapped.first?.fingerprint
                }
            } catch {
                NSLog("Failed to fetch clipboard items: \(error.localizedDescription)")
            }
        }
    }

    func deleteAll() {
        context.perform { [weak self] in
            guard let self else { return }
            let request: NSFetchRequest<Item> = Item.fetchRequest()

            do {
                let items = try self.context.fetch(request)
                items.forEach { self.context.delete($0) }
                try self.context.save()
                DispatchQueue.main.async {
                    self.entries.removeAll()
                    self.lastFingerprint = nil
                }
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

        let items = try context.fetch(request)
        guard items.count > limit else { return }

        let excess = items.suffix(from: limit)
        excess.forEach { context.delete($0) }
        try context.save()
    }

    private func startMonitoring() {
        monitor = ClipboardMonitor { [weak self] in
            self?.capturePasteboard()
        }
    }

    private func capturePasteboard() {
        let pasteboard = NSPasteboard.general

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !urls.isEmpty {
            urls.forEach { url in
                let isImageFile = url.isImageFile
                let imageData = isImageFile ? ImagePreviewLoader.thumbnailData(from: url) : nil
                let payload = CapturedPayload(
                    kind: isImageFile ? .image : .file,
                    content: url.lastPathComponent,
                    rtfData: nil,
                    fileURL: url,
                    imageData: imageData
                )
                addCaptured(payload)
            }
            return
        }

        if let imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            let plainName = "图片 \(Date().formatted(date: .omitted, time: .standard))"
            let thumb = ImagePreviewLoader.thumbnailData(from: imageData)
            let payload = CapturedPayload(kind: .image, content: plainName, rtfData: nil, fileURL: nil, imageData: thumb ?? imageData)
            addCaptured(payload)
            return
        }

        if let rtfData = pasteboard.data(forType: .rtf) {
            let plain = NSAttributedString(rtf: rtfData, documentAttributes: nil)?.string ?? ""
            let payload = CapturedPayload(kind: .richText, content: plain.isEmpty ? "富文本内容" : plain, rtfData: rtfData, fileURL: nil, imageData: nil)
            addCaptured(payload)
            return
        }

        if let string = pasteboard.string(forType: .string) {
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
