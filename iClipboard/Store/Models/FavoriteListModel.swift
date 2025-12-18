import Foundation
import CoreData

struct FavoriteListModel: Identifiable, Hashable {
    let id: NSManagedObjectID
    let name: String
    let createdAt: Date
    let count: Int
}
