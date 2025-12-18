import Foundation

extension URL {
    var isImageFile: Bool {
        let ext = self.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "bmp"].contains(ext)
    }
}

extension Data {
    var hashDescription: String {
        var hash = 5381
        for byte in self {
            hash = ((hash << 5) &+ hash) &+ Int(byte)
        }
        return String(hash)
    }
}
