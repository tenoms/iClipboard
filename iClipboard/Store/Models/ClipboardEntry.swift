import Foundation
import CoreData

struct ClipboardEntry: Identifiable, Hashable {
    let id: NSManagedObjectID
    let content: String
    let timestamp: Date
    let kind: ClipboardContentKind
    let fileURL: URL?
    let favoriteListID: NSManagedObjectID?
    let favoriteListName: String?
    let isDeletedFromHistory: Bool
    
    // Lightweight metadata
    let hasRichText: Bool
    let hasImage: Bool
    let fingerprint: String

    // Optimized hashing
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ClipboardEntry, rhs: ClipboardEntry) -> Bool {
        lhs.id == rhs.id
    }

    var isFavorited: Bool {
        favoriteListID != nil
    }
}
