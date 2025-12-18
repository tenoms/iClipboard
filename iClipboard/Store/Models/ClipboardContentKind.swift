import Foundation

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
