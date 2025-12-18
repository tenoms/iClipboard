import Foundation

struct CapturedPayload {
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
