import Foundation
import CryptoKit

struct CapturedPayload {
    let kind: ClipboardContentKind
    let content: String
    let rtfData: Data?
    let fileURL: URL?
    let imageData: Data?
    var originalImageData: Data? = nil
    var imageDigest: String? = nil

    static func image(data: Data, title: String, fileURL: URL? = nil) -> CapturedPayload {
        CapturedPayload(kind: .image, content: title, rtfData: nil, fileURL: fileURL,
                        imageData: ImagePreviewLoader.thumbnailData(from: data),
                        originalImageData: data,
                        imageDigest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    /// Passive capture keeps encoded originals but validates through a bounded
    /// preview, rather than decoding and discarding the entire source bitmap.
    static func capturedImage(data: Data, title: String, fileURL: URL? = nil) -> CapturedPayload? {
        guard let source = try? ToolImage.validatedSource(data),
              let preview = ImagePreviewLoader.thumbnailData(from: source) else { return nil }
        return CapturedPayload(kind: .image, content: title, rtfData: nil, fileURL: fileURL,
                               imageData: preview, originalImageData: data,
                               imageDigest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

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
            key = imageDigest ?? ((imageData?.hashDescription ?? "") + trimmedContent)
        case .text:
            key = trimmedContent
        }
        return "\(kind.rawValue)|\(key)"
    }
}
