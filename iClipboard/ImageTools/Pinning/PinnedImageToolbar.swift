import AppKit
import SwiftUI

@MainActor
final class PinnedImageControls: ObservableObject {
    let title: String
    let isOriginal: Bool
    @Published var isOnTop = true
    @Published var opacity: Double = 1
    var opacityPercentage: String { "\(Int((opacity * 100).rounded()))%" }
    @Published var showsOpacity = false {
        didSet { if showsOpacity != oldValue { onInteractionChanged?() } }
    }
    @Published var isToolbarVisible = true
    // Native menu lifetime is not SwiftUI view state. In particular, publishing
    // from dismantleNSView re-enters SwiftUI graph invalidation and can violate
    // its exclusive access during hosting-view teardown.
    private(set) var isMenuTracking = false
    var onInteractionChanged: (() -> Void)?
    var cancelMenuTracking: (() -> Void)?

    init(title: String, isOriginal: Bool) {
        self.title = title.isEmpty ? "贴图" : title
        self.isOriginal = isOriginal
    }

    func setMenuTracking(_ tracking: Bool) {
        guard isMenuTracking != tracking else { return }
        isMenuTracking = tracking
        onInteractionChanged?()
    }
}

/// The host fades these controls without changing the full-size image canvas.
struct PinnedImageToolbar: View {
    @ObservedObject var controls: PinnedImageControls
    var onAction: (PinnedImageWindowController.Action) -> Void
    var onClose: () -> Void
    var onToggleTop: () -> Void
    var onOpacity: (Double) -> Void

    @AppStorage("appTheme") private var appTheme: AppTheme = .system

    var body: some View {
        PinnedImageToolbarContent(controls: controls, onAction: onAction, onClose: onClose,
                                  onToggleTop: onToggleTop, onOpacity: onOpacity)
            .preferredColorScheme(appTheme.colorScheme)
            .disabled(!controls.isToolbarVisible)
            .allowsHitTesting(controls.isToolbarVisible)
            .accessibilityHidden(!controls.isToolbarVisible)
    }
}

private struct PinnedImageToolbarContent: View {
    @ObservedObject var controls: PinnedImageControls
    var onAction: (PinnedImageWindowController.Action) -> Void
    var onClose: () -> Void
    var onToggleTop: () -> Void
    var onOpacity: (Double) -> Void
    @AppStorage("appTheme") private var appTheme: AppTheme = .system
    @Environment(\.appPalette) private var palette

    var body: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 0) {
                Text(controls.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !controls.isOriginal {
                    Text("缩略图 · 非原图")
                        .font(.system(size: 9))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(controls.isOriginal ? controls.title : "当前为可读取的缩略图，并非原始图片；复制、保存和编辑均使用这张缩略图。")

            tool("复制图片", symbol: "doc.on.doc", action: { onAction(.copy) })
            tool(controls.isOnTop ? "取消置顶（⌘T）" : "置顶（⌘T）", symbol: controls.isOnTop ? "pin.fill" : "pin",
                 action: onToggleTop)
            tool("调整透明度（⌘[ 降低 / ⌘] 提高）", symbol: "circle.lefthalf.filled", action: { controls.showsOpacity.toggle() })
                .popover(isPresented: $controls.showsOpacity, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("透明度")
                            Spacer()
                            Text(controls.opacityPercentage)
                                .monospacedDigit()
                        }
                        .font(.system(size: 12, weight: .medium))
                        Slider(value: Binding(get: { controls.opacity }, set: onOpacity), in: 0.2...1)
                            .accessibilityLabel("贴图透明度")
                            .accessibilityValue(controls.opacityPercentage)
                    }
                    .padding(14)
                    .frame(width: 210)
                    .foregroundStyle(palette.text)
                    .tint(palette.accent)
                    .preferredColorScheme(appTheme.colorScheme)
                }
            PinnedImageActionMenu(controls: controls, tint: NSColor(palette.text),
                                  onAction: onAction, onClose: onClose,
                                  onToggleTop: onToggleTop, onOpacity: onOpacity)
                .frame(width: 24, height: 26)
            tool("关闭此贴图（Esc）", symbol: "xmark", destructive: true, action: onClose)
        }
        .padding(.horizontal, 7)
        .frame(maxHeight: .infinity)
        .foregroundStyle(palette.text)
        .tint(palette.accent)
        .background(PanelBackground(material: .hudWindow, cornerRadius: 0))
        .overlay(alignment: .bottom) { ThemeDivider() }
    }

    private func tool(_ title: String, symbol: String, destructive: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(destructive ? palette.destructive : palette.text)
                .frame(width: 24, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// SwiftUI Menu does not expose native tracking lifetime on macOS 13. Only this
/// one button crosses into AppKit; the remaining toolbar and popover stay SwiftUI.
private struct PinnedImageActionMenu: NSViewRepresentable {
    var controls: PinnedImageControls
    var tint: NSColor
    var onAction: (PinnedImageWindowController.Action) -> Void
    var onClose: () -> Void
    var onToggleTop: () -> Void
    var onOpacity: (Double) -> Void

    func makeNSView(context: Context) -> PinnedImageActionMenuButton {
        PinnedImageActionMenuButton(controls: controls)
    }

    func updateNSView(_ button: PinnedImageActionMenuButton, context: Context) {
        button.contentTintColor = tint
        button.isEnabled = controls.isToolbarVisible
        guard !controls.isMenuTracking else { return }
        button.configure(onAction: onAction, onClose: onClose,
                         onToggleTop: onToggleTop, onOpacity: onOpacity)
    }

    static func dismantleNSView(_ button: PinnedImageActionMenuButton, coordinator: ()) {
        button.stopTracking()
    }
}

@MainActor
final class PinnedImageActionMenuButton: NSButton, NSMenuDelegate {
    private let controls: PinnedImageControls
    private var actions: [() -> Void] = []

    init(controls: PinnedImageControls) {
        self.controls = controls
        super.init(frame: CGRect(x: 0, y: 0, width: 24, height: 26))
        title = ""
        image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "贴图操作")
        imagePosition = .imageOnly
        isBordered = false
        setButtonType(.momentaryPushIn)
        toolTip = "贴图操作：复制、保存和编辑图片"
        setAccessibilityLabel("贴图操作")
        target = self
        action = #selector(showMenu)
        controls.cancelMenuTracking = { [weak self] in self?.stopTracking() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(onAction: @escaping (PinnedImageWindowController.Action) -> Void,
                   onClose: @escaping () -> Void, onToggleTop: @escaping () -> Void,
                   onOpacity: @escaping (Double) -> Void) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        actions.removeAll()
        func add(_ title: String, symbol: String? = nil, key: String, action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(invokeItem(_:)), keyEquivalent: key)
            item.target = self
            item.tag = actions.count
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            actions.append(action)
            menu.addItem(item)
        }
        add("复制图片", symbol: "doc.on.doc", key: "c") { onAction(.copy) }
        add("保存图片…", symbol: "square.and.arrow.down", key: "s") { onAction(.save) }
        add("编辑图片…", symbol: "pencil", key: "e") { onAction(.edit) }
        menu.addItem(.separator())
        add(controls.isOnTop ? "取消置顶" : "置顶", key: "t", action: onToggleTop)
        add("降低透明度", key: "[") { [weak controls] in onOpacity((controls?.opacity ?? 1) - 0.1) }
        add("提高透明度", key: "]") { [weak controls] in onOpacity((controls?.opacity ?? 1) + 0.1) }
        add("关闭此贴图", key: "", action: onClose)
        self.menu = menu
    }

    @objc private func showMenu() {
        guard let menu else { return }
        // Enter before popUp starts its nested tracking run loop.
        controls.setMenuTracking(true)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.minY), in: self)
        controls.setMenuTracking(false)
    }

    @objc private func invokeItem(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }

    func menuWillOpen(_ menu: NSMenu) {
        // A pin toggle can update SwiftUI while the native menu is still tracking.
        // Refresh this dynamic title on the next open without publishing tracking
        // state or replacing a menu from inside its nested event loop.
        menu.items.first { $0.keyEquivalent == "t" }?.title = controls.isOnTop ? "取消置顶" : "置顶"
        controls.setMenuTracking(true)
    }
    func menuDidClose(_ menu: NSMenu) { controls.setMenuTracking(false) }

    func stopTracking() {
        guard controls.isMenuTracking else { return }
        menu?.cancelTracking()
        controls.setMenuTracking(false)
    }
}
