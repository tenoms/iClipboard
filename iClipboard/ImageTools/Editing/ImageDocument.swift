import AppKit
import Combine

/// Annotation coordinates are always source pixels, with (0, 0) at the top left.
struct ImageAnnotationStyle: Equatable {
    var red: CGFloat = 1
    var green: CGFloat = 0.18
    var blue: CGFloat = 0.16
    var alpha: CGFloat = 1
    var lineWidth: CGFloat = 4
    var fontSize: CGFloat = 28

    var cgColor: CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                components: [red, green, blue, alpha])!
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    mutating func setColor(_ color: NSColor) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return }
        red = rgb.redComponent
        green = rgb.greenComponent
        blue = rgb.blueComponent
        alpha = rgb.alphaComponent
    }
}

struct ImageAnnotation: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case arrow, line, rectangle, ellipse, brush, text, mosaic
    }

    let id: UUID
    var kind: Kind
    var points: [CGPoint]
    var style: ImageAnnotationStyle
    var text: String
    var textSize: CGSize
    var mosaicBlockSize: Int

    init(id: UUID = UUID(), kind: Kind, points: [CGPoint],
         style: ImageAnnotationStyle = ImageAnnotationStyle(), text: String = "",
         textSize: CGSize = .zero, mosaicBlockSize: Int = 14) {
        self.id = id
        self.kind = kind
        self.points = points
        self.style = style
        self.text = text
        self.textSize = textSize
        self.mosaicBlockSize = mosaicBlockSize
    }

    var bounds: CGRect {
        guard let first = points.first else { return .zero }
        if kind == .text { return CGRect(origin: first, size: textSize) }
        return (Array(points.dropFirst()) + arrowHeadPoints).reduce(CGRect(origin: first, size: .zero)) { rect, point in
            CGRect(x: min(rect.minX, point.x), y: min(rect.minY, point.y),
                   width: max(rect.maxX, point.x) - min(rect.minX, point.x),
                   height: max(rect.maxY, point.y) - min(rect.minY, point.y))
        }
    }

    var arrowHeadPoints: [CGPoint] {
        guard kind == .arrow, let start = points.first, let end = points.last, points.count > 1 else { return [] }
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = min(max(12, style.lineWidth * 4), hypot(end.x - start.x, end.y - start.y) * 0.65)
        return ([-1, 1] as [CGFloat]).map { direction in
            CGPoint(x: end.x - length * cos(angle + direction * .pi / 6),
                    y: end.y - length * sin(angle + direction * .pi / 6))
        }
    }

    var visualBounds: CGRect {
        bounds.insetBy(dx: -style.lineWidth / 2, dy: -style.lineWidth / 2)
    }

    func translated(by delta: CGSize) -> ImageAnnotation {
        var copy = self
        copy.points = points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) }
        return copy
    }

    func translated(by delta: CGSize, constrainedTo size: CGSize) -> ImageAnnotation {
        let rect = bounds
        // Text may legitimately extend below the image. A zero-distance click must
        // not snap that existing annotation back into bounds.
        let constrained = CGSize(width: max(min(0, -rect.minX), min(max(0, size.width - rect.maxX), delta.width)),
                                 height: max(min(0, -rect.minY), min(max(0, size.height - rect.maxY), delta.height)))
        return translated(by: constrained)
    }

    func contains(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        switch kind {
        case .text, .rectangle, .ellipse, .mosaic:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .arrow, .line, .brush:
            guard let first = points.first else { return false }
            if points.count == 1 { return hypot(point.x - first.x, point.y - first.y) <= tolerance + style.lineWidth / 2 }
            let segments = Array(zip(points, points.dropFirst())) + arrowHeadPoints.map { (points.last!, $0) }
            return segments.contains { start, end in
                let dx = end.x - start.x, dy = end.y - start.y
                let lengthSquared = dx * dx + dy * dy
                let fraction = lengthSquared == 0 ? 0 : max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
                return hypot(point.x - start.x - fraction * dx, point.y - start.y - fraction * dy) <= tolerance + style.lineWidth / 2
            }
        }
    }
}

/// History stores only value annotations, never a bitmap per undo step.
@MainActor
final class ImageDocument: ObservableObject {
    let original: ToolImage
    @Published private(set) var annotations: [ImageAnnotation] = []
    @Published var selectedID: UUID?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var isModified = false
    private var undoStates: [[ImageAnnotation]] = []
    private var redoStates: [[ImageAnnotation]] = []
    private var savedAnnotations: [ImageAnnotation] = []

    init(image: ToolImage) { original = image }

    var selectedAnnotation: ImageAnnotation? { annotations.first { $0.id == selectedID } }

    func add(_ annotation: ImageAnnotation) {
        commit(annotations + [annotation])
        selectedID = annotation.id
    }

    func replace(_ annotation: ImageAnnotation) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        var next = annotations
        next[index] = annotation
        commit(next)
    }

    func deleteSelected() {
        guard let selectedID else { return }
        commit(annotations.filter { $0.id != selectedID })
        self.selectedID = nil
    }

    func annotation(at point: CGPoint, tolerance: CGFloat = 6) -> ImageAnnotation? {
        annotations.reversed().first { $0.contains(point, tolerance: tolerance) }
    }

    func undo() {
        guard let state = undoStates.popLast() else { return }
        redoStates.append(annotations)
        annotations = state
        updateFlags()
    }

    func redo() {
        guard let state = redoStates.popLast() else { return }
        undoStates.append(annotations)
        annotations = state
        updateFlags()
    }

    func markSaved() { markSaved(annotations: annotations) }

    func markSaved(annotations saved: [ImageAnnotation]) {
        savedAnnotations = saved
        updateFlags()
    }

    func renderedImage() throws -> ToolImage {
        ToolImage(cgImage: try ImageDocumentRenderer.render(original: original.cgImage, annotations: annotations),
                  title: original.title, isOriginal: original.isOriginal)
    }

    func renderedImage(croppedTo pixelRect: CGRect) throws -> ToolImage {
        let flattened = try renderedImage()
        return ToolImage(cgImage: try ImageDocumentRenderer.independentCrop(flattened.cgImage, to: pixelRect),
                         title: original.title, isOriginal: original.isOriginal)
    }

    private func commit(_ next: [ImageAnnotation]) {
        guard next != annotations else { return }
        undoStates.append(annotations)
        // Keep memory bounded even for very long editing sessions.
        if undoStates.count > 100 { undoStates.removeFirst() }
        redoStates.removeAll()
        annotations = next
        updateFlags()
    }

    private func updateFlags() {
        canUndo = !undoStates.isEmpty
        canRedo = !redoStates.isEmpty
        isModified = annotations != savedAnnotations
        if !annotations.contains(where: { $0.id == selectedID }) { selectedID = nil }
    }
}

/// Both the canvas and every exported image use this one renderer.
enum ImageDocumentRenderer {
    static func render(original: CGImage, annotations: [ImageAnnotation]) throws -> CGImage {
        guard !annotations.isEmpty else { return original }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: original.width, height: original.height,
                                      bitsPerComponent: 8, bytesPerRow: original.width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                        CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw ImageToolsError.encodingFailed
        }
        let size = CGSize(width: original.width, height: original.height)
        context.interpolationQuality = .none
        context.draw(original, in: CGRect(origin: .zero, size: size))
        for annotation in annotations {
            if annotation.kind == .mosaic {
                pixelate(annotation.bounds, blockSize: annotation.mosaicBlockSize, in: context)
            } else {
                draw(annotation, in: context, imageHeight: size.height)
            }
        }
        guard let image = context.makeImage() else { throw ImageToolsError.encodingFailed }
        return image
    }

    /// Materialize only flattened selected pixels in a fresh allocation, rather
    /// than returning CGImage.cropping's potentially shared parent data provider.
    static func independentCrop(_ image: CGImage, to pixelRect: CGRect) throws -> CGImage {
        guard [pixelRect.origin.x, pixelRect.origin.y, pixelRect.width, pixelRect.height].allSatisfy({ $0.isFinite }) else {
            throw ImageToolsError.invalidImage
        }
        let rect = pixelRect.standardized.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard !rect.isNull, !rect.isEmpty,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(rect.width), height: Int(rect.height),
                                      bitsPerComponent: 8, bytesPerRow: Int(rect.width) * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                        CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw ImageToolsError.invalidImage
        }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: -rect.minX, y: rect.maxY - CGFloat(image.height),
                                      width: CGFloat(image.width), height: CGFloat(image.height)))
        guard let result = context.makeImage() else { throw ImageToolsError.encodingFailed }
        return result
    }

    static func textAttributes(style: ImageAnnotationStyle) -> [NSAttributedString.Key: Any] {
        [.font: NSFont(name: "Helvetica", size: style.fontSize) ?? NSFont.systemFont(ofSize: style.fontSize),
         .foregroundColor: style.nsColor]
    }

    /// Editing and export share TextKit's glyph metrics, fallback fonts, and wrapping.
    /// All dimensions here are source pixels, including the live NSTextView's bounds.
    static func textStorage(_ text: String, style: ImageAnnotationStyle, maximumWidth: CGFloat) -> NSTextStorage {
        let storage = NSTextStorage(string: text, attributes: textAttributes(style: style))
        let layout = NSLayoutManager()
        layout.usesFontLeading = true
        let container = NSTextContainer(size: CGSize(width: max(1, maximumWidth), height: 100_000))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        return storage
    }

    static func textSize(_ text: String, style: ImageAnnotationStyle, maximumWidth: CGFloat) -> CGSize {
        let storage = textStorage(text, style: style, maximumWidth: maximumWidth)
        let layout = storage.layoutManagers[0]
        let container = layout.textContainers[0]
        layout.ensureLayout(for: container)
        let size = layout.usedRect(for: container).size
        return CGSize(width: min(max(1, maximumWidth), ceil(size.width) + 2), height: ceil(size.height) + 4)
    }

    private static func draw(_ annotation: ImageAnnotation, in context: CGContext, imageHeight: CGFloat) {
        guard let first = annotation.points.first else { return }
        context.saveGState()
        defer { context.restoreGState() }
        if annotation.kind == .text {
            context.translateBy(x: first.x, y: imageHeight - first.y)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            let storage = textStorage(annotation.text, style: annotation.style, maximumWidth: annotation.textSize.width)
            let layout = storage.layoutManagers[0]
            let range = layout.glyphRange(for: layout.textContainers[0])
            layout.drawBackground(forGlyphRange: range, at: .zero)
            layout.drawGlyphs(forGlyphRange: range, at: .zero)
            return
        }
        context.translateBy(x: 0, y: imageHeight)
        context.scaleBy(x: 1, y: -1)
        context.setStrokeColor(annotation.style.cgColor)
        context.setFillColor(annotation.style.cgColor)
        context.setLineWidth(annotation.style.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch annotation.kind {
        case .rectangle:
            context.stroke(annotation.bounds)
        case .ellipse:
            context.strokeEllipse(in: annotation.bounds)
        case .line, .arrow, .brush:
            if annotation.points.count == 1 {
                let radius = annotation.style.lineWidth / 2
                context.fillEllipse(in: CGRect(x: first.x - radius, y: first.y - radius, width: radius * 2, height: radius * 2))
                return
            }
            context.beginPath()
            context.move(to: first)
            for point in annotation.points.dropFirst() { context.addLine(to: point) }
            // One combined stroke avoids stacking alpha where the arrow joins the shaft.
            if let end = annotation.points.last {
                for point in annotation.arrowHeadPoints {
                    context.move(to: end)
                    context.addLine(to: point)
                }
            }
            context.strokePath()
        case .text, .mosaic:
            break
        }
    }

    /// Average premultiplied RGBA in-place. No original detail survives inside a block,
    /// no filter bleeds beyond the selected region, and transparency is preserved.
    private static func pixelate(_ rect: CGRect, blockSize: Int, in context: CGContext) {
        let clipped = rect.standardized.intersection(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        guard !clipped.isNull, !clipped.isEmpty, let data = context.data else { return }
        context.flush()
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let left = max(0, Int(floor(clipped.minX))), top = max(0, Int(floor(clipped.minY)))
        let right = min(context.width, Int(ceil(clipped.maxX))), bottom = min(context.height, Int(ceil(clipped.maxY)))
        let block = max(2, min(128, blockSize))
        for y in stride(from: top, to: bottom, by: block) {
            for x in stride(from: left, to: right, by: block) {
                let endX = min(x + block, right), endY = min(y + block, bottom)
                var red = 0, green = 0, blue = 0, alpha = 0
                for row in y..<endY {
                    var pixel = bytes.advanced(by: row * context.bytesPerRow + x * 4)
                    for _ in x..<endX {
                        red += Int(pixel[0]); green += Int(pixel[1])
                        blue += Int(pixel[2]); alpha += Int(pixel[3])
                        pixel += 4
                    }
                }
                let count = (endX - x) * (endY - y)
                let r = UInt8((red + count / 2) / count), g = UInt8((green + count / 2) / count)
                let b = UInt8((blue + count / 2) / count), a = UInt8((alpha + count / 2) / count)
                for row in y..<endY {
                    var pixel = bytes.advanced(by: row * context.bytesPerRow + x * 4)
                    for _ in x..<endX {
                        pixel[0] = r; pixel[1] = g; pixel[2] = b; pixel[3] = a
                        pixel += 4
                    }
                }
            }
        }
    }
}

/// Shared, testable conversion for the AppKit canvas; zoom is relative to fit.
struct ImageCanvasTransform {
    let scale: CGFloat
    private let verticalScale: CGFloat
    let imageRect: CGRect
    let contentSize: CGSize

    init(pixelSize: CGSize, viewportSize: CGSize, zoom: CGFloat = 1, padding: CGFloat = 20) {
        let available = CGSize(width: max(1, viewportSize.width - padding * 2), height: max(1, viewportSize.height - padding * 2))
        let fit = min(available.width / max(1, pixelSize.width), available.height / max(1, pixelSize.height))
        scale = max(0.0001, fit * max(0.1, zoom))
        verticalScale = scale
        let displayed = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
        contentSize = CGSize(width: max(viewportSize.width, displayed.width + padding * 2),
                             height: max(viewportSize.height, displayed.height + padding * 2))
        imageRect = CGRect(x: (contentSize.width - displayed.width) / 2, y: (contentSize.height - displayed.height) / 2,
                           width: displayed.width, height: displayed.height)
    }

    /// Capture crops occupy their exact screen rectangle, including displays with
    /// independent delivered horizontal/vertical pixel scales. No fit or padding.
    init(pixelSize: CGSize, exactViewSize: CGSize) {
        scale = max(0.0001, exactViewSize.width / max(1, pixelSize.width))
        verticalScale = max(0.0001, exactViewSize.height / max(1, pixelSize.height))
        imageRect = CGRect(origin: .zero, size: exactViewSize)
        contentSize = exactViewSize
    }

    func viewPoint(fromPixel point: CGPoint) -> CGPoint {
        CGPoint(x: imageRect.minX + point.x * scale, y: imageRect.minY + point.y * verticalScale)
    }

    func pixelPoint(fromView point: CGPoint, clamped: Bool = false) -> CGPoint? {
        guard clamped || imageRect.contains(point) else { return nil }
        return CGPoint(x: max(0, min(imageRect.width, point.x - imageRect.minX)) / scale,
                       y: max(0, min(imageRect.height, point.y - imageRect.minY)) / verticalScale)
    }

    func viewRect(fromPixel rect: CGRect) -> CGRect {
        CGRect(origin: viewPoint(fromPixel: rect.origin), size: CGSize(width: rect.width * scale, height: rect.height * verticalScale))
    }
}
