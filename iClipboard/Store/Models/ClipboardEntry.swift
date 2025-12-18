import Foundation
import CoreData

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
