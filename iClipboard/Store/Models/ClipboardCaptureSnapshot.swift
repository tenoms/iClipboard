import AppKit

// Freeze the selected representations before dispatching image work. A queued
// capture must never reread a later, programmatic write to the general board.
struct ClipboardCaptureSnapshot {
    let changeCount: Int
    let fileURLs: [URL]
    private let representations: [NSPasteboard.PasteboardType: Data]
    private let text: String?

    init?(pasteboard: NSPasteboard, enabledTypes: Set<ClipboardContentKind> = Set(ClipboardContentKind.allCases)) {
        let count = pasteboard.changeCount
        fileURLs = ((pasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? [])
            .filter(\.isFileURL)
        var values: [NSPasteboard.PasteboardType: Data] = [:]
        var plainText: String?
        if fileURLs.isEmpty {
            if enabledTypes.contains(.image) {
                if let png = pasteboard.data(forType: .png) { values[.png] = png }
                else if let tiff = pasteboard.data(forType: .tiff) { values[.tiff] = tiff }
            }
            if values.isEmpty, enabledTypes.contains(.richText), let rtf = pasteboard.data(forType: .rtf) {
                values[.rtf] = rtf
            }
            if values.isEmpty, enabledTypes.contains(.text) { plainText = pasteboard.string(forType: .string) }
        }
        text = plainText
        guard pasteboard.changeCount == count else { return nil }
        changeCount = count
        representations = values
    }

    func data(forType type: NSPasteboard.PasteboardType) -> Data? { representations[type] }
    func string(forType type: NSPasteboard.PasteboardType) -> String? { type == .string ? text : nil }
}
