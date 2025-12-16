import SwiftUI
import CoreData
import AppKit

struct ClipboardEntry: Identifiable, Hashable {
    let id: NSManagedObjectID
    let content: String
    let timestamp: Date
}

final class ClipboardStore: ObservableObject {
    @Published private(set) var entries: [ClipboardEntry] = []

    private let context: NSManagedObjectContext
    private var monitor: ClipboardMonitor?
    private let maxEntries = 200
    private var lastCapturedText: String?

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
                    let text = item.content ?? ""
                    return ClipboardEntry(id: item.objectID, content: text, timestamp: timestamp)
                }
                DispatchQueue.main.async {
                    self.entries = mapped
                    self.lastCapturedText = mapped.first?.content
                }
            } catch {
                NSLog("Failed to fetch clipboard items: \(error.localizedDescription)")
            }
        }
    }

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        context.perform { [weak self] in
            guard let self else { return }
            if let latest = self.entries.first?.content, latest == trimmed { return }

            let newItem = Item(context: self.context)
            newItem.timestamp = Date()
            newItem.content = trimmed

            do {
                try self.context.save()
                self.lastCapturedText = trimmed
                try self.trimOverflow()
                self.refresh()
            } catch {
                NSLog("Failed to save clipboard item: \(error.localizedDescription)")
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
                    self.lastCapturedText = nil
                }
            } catch {
                NSLog("Failed to delete clipboard items: \(error.localizedDescription)")
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
        monitor = ClipboardMonitor { [weak self] text in
            guard let self else { return }
            if text == self.lastCapturedText { return }
            self.add(text)
        }
    }
}

private final class ClipboardMonitor {
    private var timer: Timer?
    private var lastChangeCount: Int
    private let onChange: (String) -> Void

    init(interval: TimeInterval = 0.8, onChange: @escaping (String) -> Void) {
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
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        guard let string = pasteboard.string(forType: .string) else { return }
        onChange(string)
    }

    deinit {
        timer?.invalidate()
    }
}
