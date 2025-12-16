import SwiftUI
import CoreData
import AppKit

enum ClipboardContentKind: String {
    case text
    case richText
    case file

    var label: String {
        switch self {
        case .text: return "文本"
        case .richText: return "富文本"
        case .file: return "文件"
        }
    }

    var icon: String {
        switch self {
        case .text: return "text.alignleft"
        case .richText: return "doc.richtext"
        case .file: return "doc"
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

    var fingerprint: String {
        let key: String
        switch kind {
        case .file:
            key = fileURL?.path ?? content.trimmingCharacters(in: .whitespacesAndNewlines)
        case .richText:
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            key = trimmed + (rtfData?.hashDescription ?? "")
        case .text:
            key = content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "\(kind.rawValue)|\(key)"
    }
}

final class ClipboardStore: ObservableObject {
    @Published private(set) var entries: [ClipboardEntry] = []

    private let context: NSManagedObjectContext
    private var monitor: ClipboardMonitor?
    private let maxEntries = 200
    private var lastFingerprint: String?

    init(context: NSManagedObjectContext = PersistenceController.shared.container.viewContext) {
        self.context = context
        refresh()
        startMonitoring()
    }

    func refresh() {
        context.perform { [weak self] in
            guard let self else { return }
            let request: NSFetchRequest<Item> = Item.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(keyPath: \Item.timestamp, ascending: false)]
            request.fetchLimit = self.maxEntries

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
                        fileURL: fileURL
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

            do {
                try self.context.save()
                self.lastFingerprint = fingerprint
                try self.trimOverflow()
                self.refresh()
            } catch {
                NSLog("Failed to save clipboard item: \(error.localizedDescription)")
            }
        }
    }

    private func trimOverflow() throws {
        let request: NSFetchRequest<Item> = Item.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Item.timestamp, ascending: false)]

        let items = try context.fetch(request)
        guard items.count > maxEntries else { return }

        let excess = items.suffix(from: maxEntries)
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
           let url = urls.first {
            let payload = CapturedPayload(kind: .file, content: url.lastPathComponent, rtfData: nil, fileURL: url)
            addCaptured(payload)
            return
        }

        if let rtfData = pasteboard.data(forType: .rtf) {
            let plain = NSAttributedString(rtf: rtfData, documentAttributes: nil)?.string ?? ""
            let payload = CapturedPayload(kind: .richText, content: plain.isEmpty ? "富文本内容" : plain, rtfData: rtfData, fileURL: nil)
            addCaptured(payload)
            return
        }

        if let string = pasteboard.string(forType: .string) {
            let payload = CapturedPayload(kind: .text, content: string, rtfData: nil, fileURL: nil)
            addCaptured(payload)
        }
    }
}

private struct CapturedPayload {
    let kind: ClipboardContentKind
    let content: String
    let rtfData: Data?
    let fileURL: URL?

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

private extension Data {
    var hashDescription: String {
        var hash = 5381
        for byte in self {
            hash = ((hash << 5) &+ hash) &+ Int(byte)
        }
        return String(hash)
    }
}
