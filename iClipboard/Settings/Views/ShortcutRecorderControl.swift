import AppKit
import Carbon
import SwiftUI

/// The native view owns the recording lifetime; SwiftUI only supplies the accepted value.
struct ShortcutRecorderRepresentable: NSViewRepresentable {
    @Binding var shortcut: KeyboardShortcut
    var hotKeyManager: HotKeyManager
    var isInteractive: Bool
    var palette: AppPalette

    func makeNSView(context: Context) -> ShortcutRecorderHostView {
        ShortcutRecorderHostView(hotKeyManager: hotKeyManager)
    }

    func updateNSView(_ view: ShortcutRecorderHostView, context: Context) {
        view.recorder.onShortcutChange = { shortcut = $0 }
        view.update(shortcut: shortcut, hotKeyManager: hotKeyManager,
                    isInteractive: isInteractive, palette: palette)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShortcutRecorderHostView,
                      context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    static func dismantleNSView(_ view: ShortcutRecorderHostView, coordinator: ()) {
        view.recorder.invalidate()
    }
}

/// Keep clear outside the recorder's hit target and responder handling.
final class ShortcutRecorderHostView: NSView {
    let recorder: ShortcutRecorderControl
    let clearButton = NSButton()

    init(hotKeyManager: HotKeyManager) {
        recorder = ShortcutRecorderControl(hotKeyManager: hotKeyManager)
        super.init(frame: .zero)
        addSubview(recorder)
        addSubview(clearButton)
        clearButton.isBordered = false
        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
        clearButton.imagePosition = .imageOnly
        clearButton.bezelStyle = .inline
        clearButton.target = self
        clearButton.action = #selector(clearShortcut)
        clearButton.toolTip = "清除快捷键"
        clearButton.setAccessibilityLabel("清除快捷键")
        recorder.onStateChange = { [weak self] in self?.refreshLayout() }
        refreshLayout()
    }

    required init?(coder: NSCoder) { nil }

    func update(shortcut: KeyboardShortcut, hotKeyManager: HotKeyManager,
                isInteractive: Bool, palette: AppPalette) {
        recorder.update(shortcut: shortcut, hotKeyManager: hotKeyManager,
                        isInteractive: isInteractive, palette: palette)
        clearButton.contentTintColor = NSColor(palette.secondaryText)
        refreshLayout()
    }

    override var intrinsicContentSize: NSSize {
        let size = recorder.intrinsicContentSize
        return NSSize(width: size.width + (clearButton.isHidden ? 0 : 20), height: size.height)
    }

    override func layout() {
        super.layout()
        let clearWidth: CGFloat = clearButton.isHidden ? 0 : 20
        recorder.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - clearWidth), height: bounds.height)
        clearButton.frame = NSRect(x: max(0, bounds.width - 16), y: (bounds.height - 16) / 2,
                                   width: 16, height: 16)
    }

    private func refreshLayout() {
        clearButton.isHidden = recorder.shortcut.isEmpty || recorder.isRecording
        clearButton.isEnabled = recorder.canStartRecording
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    @objc private func clearShortcut() {
        guard !recorder.isRecording, recorder.canStartRecording else { return }
        recorder.onShortcutChange?(.empty)
    }
}

/// A real first responder, scoped to one window. No event monitor or global input access.
final class ShortcutRecorderControl: NSControl {
    private(set) var shortcut = KeyboardShortcut.empty
    private(set) var isRecording = false
    private(set) var hint: String?
    private(set) var isInteractive = true
    var onShortcutChange: ((KeyboardShortcut) -> Void)?
    var onStateChange: (() -> Void)?

    private var hotKeyManager: HotKeyManager
    private var ownsRegistrationSuspension = false
    private var noInputHintWorkItem: DispatchWorkItem?
    private(set) var recordingModifiers: NSEvent.ModifierFlags = []

    static let noInputHintDelay: TimeInterval = 2.5
    private var palette = AppPalette(colorScheme: .light)

    var canStartRecording: Bool {
        isInteractive && !hotKeyManager.isRegistrationSuspended
    }

    init(hotKeyManager: HotKeyManager) {
        self.hotKeyManager = hotKeyManager
        super.init(frame: .zero)
        focusRingType = .none
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        refreshAppearance()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        NotificationCenter.default.removeObserver(self)
        noInputHintWorkItem?.cancel()
        // Moving out of a window and representable teardown normally cancel first.
        if ownsRegistrationSuspension { hotKeyManager.resumeRegistration() }
    }

    func update(shortcut: KeyboardShortcut, hotKeyManager: HotKeyManager,
                isInteractive: Bool, palette: AppPalette) {
        if self.hotKeyManager !== hotKeyManager || !isInteractive {
            cancelRecording()
        }
        self.hotKeyManager = hotKeyManager
        self.shortcut = shortcut
        self.isInteractive = isInteractive
        self.palette = palette
        refreshAppearance()
    }

    override var acceptsFirstResponder: Bool { isRecording || canStartRecording }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard event.window === window else { return }
        toggleRecording()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isRecording || canStartRecording else { return false }
        toggleRecording()
        return true
    }

    func toggleRecording() {
        if isRecording { cancelRecording() } else { beginRecording() }
    }

    func beginRecording() {
        guard !isRecording, canStartRecording else { return }
        guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor else {
            showHint("录制器不可见，请重新打开设置")
            return
        }
        // Only an explicit recorder press activates the app; hovering never does.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        guard window.isKeyWindow, NSApp.keyWindow === window,
              window.makeFirstResponder(self), window.firstResponder === self else {
            relinquishFirstResponder()
            showHint("无法取得键盘焦点，请重试")
            return
        }

        hotKeyManager.suspendRegistration()
        guard hotKeyManager.isRegistrationSuspended else {
            relinquishFirstResponder()
            showHint("无法暂停全局快捷键，请重试")
            return
        }
        ownsRegistrationSuspension = true
        isRecording = true
        hint = nil
        recordingModifiers = []
        scheduleNoInputHint()
        observeRecordingLifetime(in: window)
        refreshAppearance()
    }

    func cancelRecording() {
        finishRecording()
    }

    func invalidate() {
        cancelRecording()
        onShortcutChange = nil
        onStateChange = nil
    }

    override func resignFirstResponder() -> Bool {
        finishRecording(relinquishFocus: false)
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { cancelRecording() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil { cancelRecording() }
        super.viewWillMove(toSuperview: newSuperview)
    }

    override func viewDidHide() {
        super.viewDidHide()
        cancelRecording()
    }

    override func keyDown(with event: NSEvent) {
        if !handleRecordingKey(event) { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // AppKit sends Command combinations here before keyDown (e.g. Copy/Undo).
        handleRecordingKey(event) || super.performKeyEquivalent(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording, event.window === window else {
            super.flagsChanged(with: event)
            return
        }
        // Modifier-only events are useful feedback, never a guessed ordinary key.
        recordingModifiers = event.modifierFlags.intersection(KeyboardShortcut.supportedModifiers)
        refreshAppearance()
    }

    private func handleRecordingKey(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }
        guard isInteractive, let window, window.isVisible, window.isKeyWindow,
              NSApp.keyWindow === window, window.firstResponder === self,
              !isHiddenOrHasHiddenAncestor else {
            cancelRecording()
            return false
        }
        guard event.type == .keyDown, event.window === window else { return false }
        let modifiers = event.modifierFlags.intersection(KeyboardShortcut.supportedModifiers)
        if event.keyCode == kVK_Escape, modifiers.isEmpty {
            cancelRecording()
            return true
        }
        if (54...63).contains(Int(event.keyCode)) { return true }
        let candidate = KeyboardShortcut(keyCode: Int(event.keyCode), modifiers: Int(modifiers.rawValue))
        guard candidate.isValid else {
            showHint("请包含 ⌘、⌥、⌃ 或 ⇧ 修饰键")
            return true
        }

        // Restore the original registrations before the binding attempts a replacement.
        // A duplicate or Carbon error must leave the previous shortcut intact.
        finishRecording()
        onShortcutChange?(candidate)
        return true
    }

    private func finishRecording(relinquishFocus: Bool = true) {
        let wasRecording = isRecording
        isRecording = false
        hint = nil
        recordingModifiers = []
        noInputHintWorkItem?.cancel()
        noInputHintWorkItem = nil
        NotificationCenter.default.removeObserver(self)
        if ownsRegistrationSuspension {
            ownsRegistrationSuspension = false
            hotKeyManager.resumeRegistration()
        }
        if wasRecording && relinquishFocus { relinquishFirstResponder() }
        refreshAppearance()
    }

    private func relinquishFirstResponder() {
        if let window, window.firstResponder === self { window.makeFirstResponder(nil) }
    }

    private func observeRecordingLifetime(in window: NSWindow) {
        let center = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                     NSWindow.willMiniaturizeNotification] {
            center.addObserver(self, selector: #selector(cancelFromNotification), name: name, object: window)
        }
        // orderOut has no dedicated notification. Key loss normally cancels immediately;
        // visibility/occlusion updates also cover an ordered-out retained host view.
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didUpdateNotification] {
            center.addObserver(self, selector: #selector(checkHostContext), name: name, object: window)
        }
        center.addObserver(self, selector: #selector(cancelFromNotification),
                           name: NSApplication.willResignActiveNotification, object: nil)
    }

    @objc private func cancelFromNotification(_ notification: Notification) {
        cancelRecording()
    }

    @objc private func checkHostContext(_ notification: Notification) {
        guard let window, window.isVisible, window.isKeyWindow,
              window.firstResponder === self, !isHiddenOrHasHiddenAncestor else {
            cancelRecording()
            return
        }
    }

    private func scheduleNoInputHint() {
        noInputHintWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.showNoInputHint() }
        noInputHintWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noInputHintDelay, execute: item)
    }

    private func showNoInputHint() {
        guard isRecording else { return }
        showHint("尚未收到组合…")
    }

    private func showHint(_ message: String) {
        hint = message
        refreshAppearance()
    }

    private var displayText: String {
        if let hint { return hint }
        if isRecording { return "输入快捷键..." }
        return shortcut.isEmpty ? "点击录制" : Self.shortcutString(for: shortcut)
    }

    override var intrinsicContentSize: NSSize {
        let width = (displayText as NSString).size(withAttributes: [.font: displayFont]).width
        return NSSize(width: ceil(width) + 16, height: 26)
    }

    private var displayFont: NSFont {
        NSFont.systemFont(ofSize: 13, weight: shortcut.isEmpty || isRecording || hint != nil ? .regular : .medium)
    }

    override func draw(_ dirtyRect: NSRect) {
        let enabled = isRecording || canStartRecording
        let background = NSColor(isRecording ? palette.selection : palette.control)
        let border = NSColor(isRecording ? palette.accent : palette.border)
        let text = NSColor(shortcut.isEmpty || isRecording || hint != nil ? palette.secondaryText : palette.text)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        background.withAlphaComponent(enabled ? background.alphaComponent : background.alphaComponent * 0.5).setFill()
        path.fill()
        border.setStroke()
        path.lineWidth = 1
        path.stroke()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: displayFont, .foregroundColor: text.withAlphaComponent(enabled ? 1 : 0.5)
        ]
        let size = (displayText as NSString).size(withAttributes: attributes)
        (displayText as NSString).draw(at: NSPoint(x: 8, y: (bounds.height - size.height) / 2),
                                       withAttributes: attributes)
    }

    private func refreshAppearance() {
        setAccessibilityLabel(isRecording ? "取消录制快捷键" : "录制快捷键")
        setAccessibilityValue(hint ?? (shortcut.isEmpty ? "未设置" : Self.shortcutString(for: shortcut)))
        setAccessibilityEnabled(isRecording || canStartRecording)
        let inputState = recordingModifiers.isEmpty ? "等待组合键" : "已收到修饰键，等待普通按键"
        toolTip = isRecording
            ? "\(inputState)。录制只暂停本应用快捷键；可继续按键或单击取消后重新录制。仅无修饰键的 Esc 取消。"
            : (hint ?? "点击录制快捷键，仅无修饰键的 Esc 取消")
        needsDisplay = true
        invalidateIntrinsicContentSize()
        onStateChange?()
    }

    static func shortcutString(for shortcut: KeyboardShortcut) -> String {
        var result = ""
        let flags = NSEvent.ModifierFlags(rawValue: UInt(shortcut.normalized.modifiers))
        if flags.contains(.control) { result += "⌃ " }
        if flags.contains(.option) { result += "⌥ " }
        if flags.contains(.shift) { result += "⇧ " }
        if flags.contains(.command) { result += "⌘ " }
        return result + (SpecialKey(rawValue: shortcut.keyCode)?.description ?? "键码 \(shortcut.keyCode)")
    }
}
