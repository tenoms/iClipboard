import AppKit
import CoreData

struct ClipboardPreview {
    var image: NSImage?
    var richText: AttributedString?
    static let empty = ClipboardPreview()
}

/// Decoded previews are expendable; the persistent store remains the source of truth.
final class ClipboardPreviewCache {
    private final class CachedPreview: NSObject {
        let value: ClipboardPreview
        init(_ value: ClipboardPreview) { self.value = value }
    }

    private let cache = NSCache<NSManagedObjectID, CachedPreview>()

    init() {
        cache.countLimit = 48
        cache.totalCostLimit = 8 * 1024 * 1024
    }

    func preview(
        for id: NSManagedObjectID,
        load: () -> (image: Data?, richText: Data?)
    ) -> ClipboardPreview {
        if let cached = cache.object(forKey: id) { return cached.value }
        let data = load()
        let image = data.image.flatMap { ImagePreviewLoader.previewImage(from: $0) }
        let attributed = data.richText.flatMap {
            try? NSAttributedString(
                data: $0,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
        }
        let value = ClipboardPreview(
            image: image, richText: attributed.map { AttributedString($0) }
        )
        let imageCost = image.map { Int($0.size.width * $0.size.height) * 4 } ?? 0
        let textCost = (data.richText?.count ?? 0) + (attributed?.length ?? 0) * 2
        cache.setObject(CachedPreview(value), forKey: id, cost: imageCost + textCost)
        return value
    }

    func removeAll() { cache.removeAllObjects() }
}
