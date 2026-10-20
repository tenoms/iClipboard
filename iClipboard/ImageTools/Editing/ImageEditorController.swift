import AppKit
import Combine
import SwiftUI

@MainActor
final class ImageEditorController: NSWindowController, NSWindowDelegate {
    var onCopy: ((ToolImage) -> Void)? { didSet { session.canCopy = onCopy != nil } }
    var onSave: ((ToolImage) -> Void)? { didSet { session.canSave = onSave != nil } }
    var onPin: ((ToolImage) -> Void)? { didSet { session.canPin = onPin != nil } }
    var onCopyColor: ((SampledImageColor) -> Void)? { didSet { session.canCopyColor = onCopyColor != nil } }
    var onClose: (() -> Void)?

    private let session: ImageEditorSession
    private var deliveredClose = false
    private var allowsDiscard = false
    private var confirmingClose = false
    private var pendingSaveStates: [ObjectIdentifier: [[ImageAnnotation]]] = [:]
    private var lastSaveID: ObjectIdentifier?
    var pendingSaveCount: Int { pendingSaveStates.values.reduce(0) { $0 + $1.count } }

    init(image: ToolImage) {
        session = ImageEditorSession(image: image)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "图片编辑 · \(image.title)"
        window.minSize = NSSize(width: 960, height: 620)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: ImageEditorView(session: session))
        session.copyAction = { [weak self] in self?.sendImage(to: self?.onCopy) }
        session.saveAction = { [weak self] in self?.requestSave() }
        session.pinAction = { [weak self] in self?.sendImage(to: self?.onPin) }
        session.copyColorAction = { [weak self] color in self?.onCopyColor?(color) }
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Acknowledge the exact callback image after it was successfully written.
    /// Edits made while a save panel is open remain unsaved.
    func markSaved(image: ToolImage) { finishSave(image: image, succeeded: true) }

    /// Complete every save attempt, including panel cancellation and write errors.
    func finishSave(image: ToolImage, succeeded: Bool) {
        finishSave(id: ObjectIdentifier(image.cgImage), succeeded: succeeded)
    }

    /// Convenience for callers that allow only one outstanding save request.
    func markSaved() {
        guard let lastSaveID else { return }
        finishSave(id: lastSaveID, succeeded: true)
    }

    private func finishSave(id: ObjectIdentifier, succeeded: Bool) {
        guard var states = pendingSaveStates.removeValue(forKey: id), !states.isEmpty else { return }
        let state = states.removeFirst()
        if !states.isEmpty { pendingSaveStates[id] = states }
        else if lastSaveID == id { lastSaveID = nil }
        if succeeded { session.document.markSaved(annotations: state) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard session.document.isModified, !allowsDiscard else { return true }
        guard !confirmingClose else { return false }
        confirmingClose = true
        let alert = NSAlert()
        alert.messageText = "放弃未保存的图片修改？"
        alert.informativeText = "复制或贴图不会将修改保存为文件。关闭后无法恢复本次编辑。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "继续编辑")
        alert.addButton(withTitle: "放弃修改")
        alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
            guard let self else { return }
            self.confirmingClose = false
            if response == .alertSecondButtonReturn {
                self.allowsDiscard = true
                sender?.performClose(nil)
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard !deliveredClose else { return }
        deliveredClose = true
        onClose?()
    }

    func requestSave() {
        guard let onSave else { return }
        do {
            let image = try session.document.renderedImage()
            let state = session.document.annotations
            pendingSaveStates[ObjectIdentifier(image.cgImage), default: []].append(state)
            lastSaveID = ObjectIdentifier(image.cgImage)
            onSave(image)
        } catch { session.errorMessage = error.localizedDescription }
    }

    private func sendImage(to callback: ((ToolImage) -> Void)?) {
        guard let callback else { return }
        do { callback(try session.document.renderedImage()) }
        catch { session.errorMessage = error.localizedDescription }
    }
}

enum ImageEditorTool: String, CaseIterable, Identifiable {
    case select, arrow, line, rectangle, ellipse, brush, text, mosaic, eyedropper
    var id: String { rawValue }
    var label: String {
        switch self {
        case .select: return "选择 / 移动"
        case .arrow: return "箭头"
        case .line: return "直线"
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .brush: return "画笔"
        case .text: return "文字"
        case .mosaic: return "马赛克"
        case .eyedropper: return "取色"
        }
    }
    var icon: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .ellipse: return "oval"
        case .brush: return "pencil.tip"
        case .text: return "textformat"
        case .mosaic: return "square.grid.3x3.fill"
        case .eyedropper: return "eyedropper"
        }
    }
    var annotationKind: ImageAnnotation.Kind? { ImageAnnotation.Kind(rawValue: rawValue) }
    var hint: String {
        switch self {
        case .select: return "单击选中，拖动移动；Delete 删除；双击文字修改内容。"
        case .text: return "单击画布输入文字；支持换行，确认后成为可移动标注。"
        case .eyedropper: return "单击或拖动读取当前扁平图像的像素颜色。"
        case .mosaic: return "拖出区域将实际像素马赛克化；区域外图像不受影响。"
        default: return "在画布拖动绘制；选择工具可移动或删除已有标注。"
        }
    }
}

@MainActor
final class ImageEditorSession: ObservableObject {
    let document: ImageDocument
    @Published var tool: ImageEditorTool = .arrow {
        didSet { if tool != oldValue { cancelGesture() } }
    }
    @Published private(set) var style = ImageAnnotationStyle()
    @Published private(set) var mosaicBlockSize = 14
    @Published var zoom: CGFloat = 1
    @Published private(set) var displayImage: CGImage
    @Published private(set) var previewAnnotation: ImageAnnotation?
    @Published private(set) var sampledColor: SampledImageColor?
    @Published var isEditingText = false
    @Published var textDraft = ""
    @Published var errorMessage: String?
    @Published private(set) var revision = UUID()
    @Published var isInputEnabled = true
    /// Called once before the first effective preview or committed pixel edit.
    var onPixelsWillChange: (() -> Void)?
    /// Balances invalidation after a commit, or restoration of a cancelled preview.
    /// Restoration keeps `revision` unchanged so recognition can reuse its result.
    var onPixelsDidChange: (() -> Void)?
    @Published var canCopy = false
    @Published var canSave = false
    @Published var canPin = false
    @Published var canCopyColor = false
    var copyAction: (() -> Void)?
    var saveAction: (() -> Void)?
    var pinAction: (() -> Void)?
    var copyColorAction: ((SampledImageColor) -> Void)?

    private var flattenedImage: CGImage
    private var subscriptions = Set<AnyCancellable>()
    private var startPoint: CGPoint?
    private var movingAnnotation: ImageAnnotation?
    private var textAnchor: CGPoint?
    private var editingTextID: UUID?
    private var lastPreviewTime: TimeInterval = 0
    private var pixelsInvalidated = false
    private var isAdjustingMosaic = false
    private var mosaicAdjustmentAnnotation: ImageAnnotation?

    init(image: ToolImage) {
        document = ImageDocument(image: image)
        displayImage = image.cgImage
        flattenedImage = image.cgImage
        document.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        document.$annotations.dropFirst().sink { [weak self] annotations in
            guard let self else { return }
            self.refresh(annotations: annotations)
            self.syncMosaicSelection(id: self.document.selectedID, annotations: annotations)
        }.store(in: &subscriptions)
        document.$selectedID.dropFirst().sink { [weak self] id in
            guard let self else { return }
            self.syncMosaicSelection(id: id, annotations: self.document.annotations)
        }.store(in: &subscriptions)
    }

    var textInputAnchor: CGPoint? { textAnchor }
    var currentFlattenedImage: ToolImage {
        ToolImage(cgImage: flattenedImage, title: document.original.title, isOriginal: document.original.isOriginal)
    }

    var selectionBounds: CGRect? {
        if let previewAnnotation { return previewAnnotation.visualBounds }
        return document.selectedAnnotation?.visualBounds
    }

    func changeStyle(_ change: (inout ImageAnnotationStyle) -> Void) {
        guard isInputEnabled else { return }
        var nextStyle = style
        change(&nextStyle)
        guard nextStyle != style else { return }
        style = nextStyle
        guard !isEditingText, let original = document.selectedAnnotation, original.kind != .mosaic else { return }
        var selected = original
        selected.style = style
        // Font size only affects text; line width only affects drawn strokes.
        if selected.kind == .text { selected.style.lineWidth = original.style.lineWidth }
        else { selected.style.fontSize = original.style.fontSize }
        guard selected.style != original.style else { return }
        if selected.kind == .text, selected.style.fontSize != original.style.fontSize,
           let origin = selected.points.first {
            selected.textSize = ImageDocumentRenderer.textSize(selected.text, style: selected.style,
                                                              maximumWidth: document.original.pixelSize.width - origin.x)
        }
        clearGestureState()
        invalidatePixels()
        document.replace(selected)
    }

    /// Slider clients bracket a drag to preview many values with one undo entry.
    /// Unbracketed updates are also supported as a single immediate edit.
    func beginMosaicAdjustment() {
        guard isInputEnabled, !isAdjustingMosaic else { return }
        cancelGesture()
        isAdjustingMosaic = true
        mosaicAdjustmentAnnotation = document.selectedAnnotation.flatMap { $0.kind == .mosaic ? $0 : nil }
    }

    func updateMosaicBlockSize(_ value: Int) {
        guard isInputEnabled else { return }
        let immediate = !isAdjustingMosaic
        if immediate { beginMosaicAdjustment() }
        defer { if immediate { endMosaicAdjustment() } }
        let value = max(4, min(64, value))
        if mosaicBlockSize != value { mosaicBlockSize = value }
        guard let original = mosaicAdjustmentAnnotation else { return }
        var annotation = original
        annotation.mosaicBlockSize = value
        guard annotation != (previewAnnotation ?? original) else { return }
        invalidatePixels()
        previewAnnotation = annotation
        renderPreview(force: true)
    }

    func endMosaicAdjustment() {
        guard isAdjustingMosaic else { return }
        let original = mosaicAdjustmentAnnotation
        let annotation = previewAnnotation
        clearGestureState()
        if let original, let annotation, annotation != original,
           document.annotations.contains(where: { $0.id == original.id }) {
            invalidatePixels()
            document.replace(annotation)
        } else {
            finishPixelChange()
        }
        syncMosaicSelection(id: document.selectedID, annotations: document.annotations)
    }

    func pointerDown(at point: CGPoint, tolerance: CGFloat, clickCount: Int) {
        guard isInputEnabled else { return }
        cancelGesture()
        switch tool {
        case .select:
            let annotation = document.annotation(at: point, tolerance: tolerance)
            document.selectedID = annotation?.id
            if let annotation { style = annotation.style }
            if clickCount > 1, let annotation, annotation.kind == .text {
                beginText(at: annotation.points.first ?? point, annotation: annotation)
            } else {
                movingAnnotation = annotation
                startPoint = point
            }
        case .text:
            beginText(at: point, annotation: nil)
        case .eyedropper:
            sample(at: point)
        default:
            guard let kind = tool.annotationKind else { return }
            startPoint = point
            document.selectedID = nil
            let annotation = ImageAnnotation(kind: kind, points: kind == .brush ? [point] : [point, point],
                                             style: style, mosaicBlockSize: mosaicBlockSize)
            // A brush click draws a real dot. Other tools need an effective drag.
            if kind == .brush { invalidatePixels() }
            previewAnnotation = annotation
            if kind == .brush { renderPreview(force: true) }
        }
    }

    func pointerDragged(to point: CGPoint) {
        guard isInputEnabled else { return }
        if tool == .eyedropper { sample(at: point); return }
        guard let startPoint else { return }
        let annotation: ImageAnnotation
        if let movingAnnotation {
            let delta = CGSize(width: point.x - startPoint.x, height: point.y - startPoint.y)
            annotation = movingAnnotation.translated(by: delta, constrainedTo: document.original.pixelSize)
            guard annotation != (previewAnnotation ?? movingAnnotation) else { return }
        } else if var drawing = previewAnnotation {
            if drawing.kind == .brush {
                if let last = drawing.points.last, hypot(last.x - point.x, last.y - point.y) < 0.5 { return }
                drawing.points.append(point)
            } else {
                drawing.points = [startPoint, point]
            }
            guard drawing != previewAnnotation else { return }
            annotation = drawing
        } else {
            return
        }
        if movingAnnotation != nil || isDrawable(annotation) { invalidatePixels() }
        previewAnnotation = annotation
        if pixelsInvalidated { renderPreview() }
    }

    func pointerUp(at point: CGPoint) {
        guard isInputEnabled, startPoint != nil else { return }
        pointerDragged(to: point)
        let annotation = previewAnnotation
        let moving = movingAnnotation
        clearGestureState()
        if let annotation, moving != nil ? annotation != moving : isDrawable(annotation) {
            invalidatePixels()
            if moving != nil { document.replace(annotation) }
            else { document.add(annotation) }
        } else {
            finishPixelChange()
        }
    }

    /// Discard only the uncommitted gesture. A no-op cancel emits nothing;
    /// an invalidated preview restores the same revision and emits one DidChange.
    func cancelGesture() {
        let wasAdjustingMosaic = isAdjustingMosaic
        clearGestureState()
        if wasAdjustingMosaic { syncMosaicSelection(id: document.selectedID, annotations: document.annotations) }
        finishPixelChange()
    }

    func undo() {
        guard isInputEnabled, document.canUndo else { return }
        clearGestureState()
        invalidatePixels()
        document.undo()
    }
    func redo() {
        guard isInputEnabled, document.canRedo else { return }
        clearGestureState()
        invalidatePixels()
        document.redo()
    }
    func deleteSelection() {
        guard isInputEnabled, document.selectedAnnotation != nil else { return }
        clearGestureState()
        invalidatePixels()
        document.deleteSelected()
    }
    func moveSelection(by delta: CGSize) {
        guard isInputEnabled, let annotation = document.selectedAnnotation else { return }
        let moved = annotation.translated(by: delta, constrainedTo: document.original.pixelSize)
        guard moved != annotation else { return }
        clearGestureState()
        invalidatePixels()
        document.replace(moved)
    }
    func cancelText() {
        isEditingText = false
        textDraft = ""
        textAnchor = nil
        editingTextID = nil
        displayImage = flattenedImage
    }

    func commitText() {
        guard isInputEnabled else { return }
        guard let anchor = textAnchor, !textDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            cancelText()
            return
        }
        let original = document.annotations.first(where: { $0.id == editingTextID })
        if editingTextID != nil, original == nil { cancelText(); return }
        var textStyle = style
        if let original { textStyle.lineWidth = original.style.lineWidth }
        let textSize: CGSize
        if let original, original.text == textDraft, original.style.fontSize == textStyle.fontSize {
            textSize = original.textSize
        } else {
            textSize = ImageDocumentRenderer.textSize(textDraft, style: textStyle,
                                                     maximumWidth: document.original.pixelSize.width - anchor.x)
        }
        let annotation = ImageAnnotation(id: editingTextID ?? UUID(), kind: .text, points: [anchor], style: textStyle,
                                         text: textDraft, textSize: textSize)
        cancelText()
        tool = .select
        if annotation != original {
            invalidatePixels()
            if original != nil { document.replace(annotation) } else { document.add(annotation) }
        }
    }

    private func beginText(at point: CGPoint, annotation: ImageAnnotation?) {
        textAnchor = point
        editingTextID = annotation?.id
        textDraft = annotation?.text ?? ""
        if let annotation {
            style = annotation.style
            // The native input paints the draft. Keep the committed bitmap/revision
            // intact, but do not draw the previous text underneath it a second time.
            do {
                displayImage = try ImageDocumentRenderer.render(original: document.original.cgImage,
                                                               annotations: document.annotations.filter { $0.id != annotation.id })
            } catch { errorMessage = error.localizedDescription }
        }
        isEditingText = true
    }

    private func sample(at point: CGPoint) {
        sampledColor = ToolImage(cgImage: flattenedImage).color(at: point)
    }

    private func syncMosaicSelection(id: UUID?, annotations: [ImageAnnotation]) {
        guard !isAdjustingMosaic,
              let annotation = annotations.first(where: { $0.id == id && $0.kind == .mosaic }) else { return }
        let value = max(4, min(64, annotation.mosaicBlockSize))
        if mosaicBlockSize != value { mosaicBlockSize = value }
    }

    private func isDrawable(_ annotation: ImageAnnotation) -> Bool {
        if [.rectangle, .ellipse, .mosaic].contains(annotation.kind) {
            return annotation.bounds.width >= 1 && annotation.bounds.height >= 1
        }
        return annotation.kind == .brush || annotation.bounds.width >= 1 || annotation.bounds.height >= 1
    }

    private func invalidatePixels() {
        guard !pixelsInvalidated else { return }
        pixelsInvalidated = true
        onPixelsWillChange?()
    }

    private func finishPixelChange() {
        guard pixelsInvalidated else { return }
        pixelsInvalidated = false
        onPixelsDidChange?()
    }

    private func clearGestureState() {
        startPoint = nil
        movingAnnotation = nil
        previewAnnotation = nil
        isAdjustingMosaic = false
        mosaicAdjustmentAnnotation = nil
        lastPreviewTime = 0
        displayImage = flattenedImage
    }

    private func renderPreview(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastPreviewTime > 1.0 / 30.0, let previewAnnotation else { return }
        lastPreviewTime = now
        let original: CGImage
        var annotations: [ImageAnnotation]
        if let index = document.annotations.firstIndex(where: { $0.id == previewAnnotation.id }) {
            original = document.original.cgImage
            annotations = document.annotations
            annotations[index] = previewAnnotation
        } else {
            // A new stroke sits above committed pixels; do not replay existing
            // text and mosaics on every preview frame.
            original = flattenedImage
            annotations = isDrawable(previewAnnotation) ? [previewAnnotation] : []
        }
        do { displayImage = try ImageDocumentRenderer.render(original: original, annotations: annotations) }
        catch { errorMessage = error.localizedDescription }
    }

    private func refresh(annotations: [ImageAnnotation]) {
        do {
            let image = try ImageDocumentRenderer.render(original: document.original.cgImage, annotations: annotations)
            invalidatePixels()
            flattenedImage = image
            displayImage = image
            revision = UUID()
        } catch { errorMessage = error.localizedDescription }
        finishPixelChange()
    }
}

private struct ImageEditorView: View {
    @ObservedObject var session: ImageEditorSession
    @AppStorage("appTheme") private var appTheme: AppTheme = .system
    @Environment(\.appPalette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            toolBar
            ThemeDivider()
            propertiesBar
            ThemeDivider()
            if !session.document.original.isOriginal {
                Label("此图片来自低清历史缩略图，编辑和导出无法恢复原始清晰度。", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(palette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 7)
                    .background(palette.control)
            }
            ImageEditorCanvas(session: session)
            ThemeDivider()
            statusBar
        }
        .foregroundStyle(palette.text)
        .tint(palette.accent)
        .background(PanelBackground(material: .windowBackground))
        .preferredColorScheme(appTheme.colorScheme)
        .sheet(isPresented: $session.isEditingText, onDismiss: { session.cancelText() }) { textEditor }
        .alert("无法完成图片操作", isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
            Button("好", role: .cancel) { session.errorMessage = nil }
        } message: { Text(session.errorMessage ?? "") }
    }

    private var toolBar: some View {
        HStack(spacing: 5) {
            ForEach(ImageEditorTool.allCases) { tool in
                Button {
                    session.cancelGesture()
                    session.tool = tool
                } label: {
                    Image(systemName: tool.icon).frame(width: 29, height: 29)
                        .background(session.tool == tool ? palette.selection : .clear)
                        .foregroundStyle(session.tool == tool ? palette.selectionText : palette.text)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain).help(tool.label).accessibilityLabel(tool.label)
            }
            Divider().frame(height: 23).padding(.horizontal, 4)
            Button { session.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!session.document.canUndo).keyboardShortcut("z", modifiers: .command).help("撤销 ⌘Z")
            Button { session.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!session.document.canRedo).keyboardShortcut("z", modifiers: [.command, .shift]).help("重做 ⇧⌘Z")
            Button { session.deleteSelection() } label: { Image(systemName: "trash") }
                .disabled(session.document.selectedID == nil).help("删除选中标注")
            Spacer(minLength: 12)
            Button("复制") { session.copyAction?() }.disabled(!session.canCopy)
            Button("保存…") { session.saveAction?() }.disabled(!session.canSave)
                .keyboardShortcut("s", modifiers: .command)
            Button("贴图") { session.pinAction?() }.disabled(!session.canPin)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var propertiesBar: some View {
        HStack(spacing: 12) {
            ColorPicker("颜色", selection: Binding(get: { Color(nsColor: session.style.nsColor) }, set: { color in
                session.changeStyle { $0.setColor(NSColor(color)) }
            }), supportsOpacity: true).fixedSize()
            Text("线宽").font(.caption)
            Slider(value: Binding(get: { Double(session.style.lineWidth) }, set: { value in
                session.changeStyle { $0.lineWidth = CGFloat(value) }
            }), in: 1...40, step: 1).frame(width: 88)
            Text("\(Int(session.style.lineWidth)) px").font(.caption.monospacedDigit()).frame(width: 38)
            Stepper(value: Binding(get: { Int(session.style.fontSize) }, set: { value in
                session.changeStyle { $0.fontSize = CGFloat(value) }
            }), in: 8...144) { Text("字号 \(Int(session.style.fontSize))").font(.caption.monospacedDigit()) }.fixedSize()
            if session.tool == .mosaic || session.document.selectedAnnotation?.kind == .mosaic {
                Text("色块 \(session.mosaicBlockSize) px").font(.caption.monospacedDigit())
                Slider(value: Binding(get: { Double(session.mosaicBlockSize) }, set: { value in
                    session.updateMosaicBlockSize(Int(value))
                }), in: 4...64, step: 1, onEditingChanged: { editing in
                    if editing { session.beginMosaicAdjustment() }
                    else { session.endMosaicAdjustment() }
                }).frame(width: 88)
            }
            Spacer(minLength: 8)
            Image(systemName: "magnifyingglass").foregroundStyle(palette.secondaryText)
            Slider(value: $session.zoom, in: 0.25...4).frame(width: 92)
            Text("\(Int(session.zoom * 100))%").font(.caption.monospacedDigit()).frame(width: 38)
            Button("适应") { session.zoom = 1 }.help("100% 表示适应窗口；放大后可滚动查看")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Text(session.tool.hint).lineLimit(1)
            Spacer(minLength: 8)
            if let color = session.sampledColor {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(.sRGB, red: Double(color.red) / 255, green: Double(color.green) / 255,
                                blue: Double(color.blue) / 255, opacity: color.alpha))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(palette.border)).frame(width: 20, height: 16)
                Text("\(color.hex) · \(color.rgb) · A \(Int((color.alpha * 100).rounded()))%")
                    .font(.caption.monospaced())
                if session.canCopyColor { Button("复制色值") { session.copyColorAction?(color) } }
            } else {
                Text("\(session.document.original.cgImage.width) × \(session.document.original.cgImage.height) px")
            }
            if session.document.isModified { Text("未保存").foregroundStyle(palette.accent) }
        }
        .font(.caption).foregroundStyle(palette.secondaryText)
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private var textEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("编辑文字").font(.headline)
            Text("支持多行。字号和颜色使用工具栏当前设置。")
                .font(.caption).foregroundStyle(palette.secondaryText)
            TextEditor(text: $session.textDraft).font(.system(size: 16))
                .frame(minHeight: 160).border(palette.border)
            HStack {
                Button("取消", role: .cancel) { session.cancelText() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("放置文字") { session.commitText() }
                    .disabled(session.textDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 460)
        .foregroundStyle(palette.text).background(PanelBackground(material: .sheet))
        .preferredColorScheme(appTheme.colorScheme)
    }
}
