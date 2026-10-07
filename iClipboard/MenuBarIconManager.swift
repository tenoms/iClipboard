import AppKit
import ApplicationServices
import Foundation
import OSLog

struct MenuBarItemGeometry: Sendable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }

    static let unknown = MenuBarItemGeometry(
        rect: CGRect(
            x: CGFloat.greatestFiniteMagnitude,
            y: 0,
            width: 0,
            height: 0
        )
    )
}

struct ManagedMenuBarEntry: Sendable, Equatable {
    let processIdentifier: pid_t
    let applicationName: String
    let sourceTitle: String
    let displayTitle: String
    let itemIndex: Int
    let geometry: MenuBarItemGeometry
}

struct MenuBarCandidateIdentity: Sendable, Equatable {
    let title: String
    let geometry: MenuBarItemGeometry
}

enum MenuBarEntryPresenter {
    static func disambiguated(
        _ entries: [ManagedMenuBarEntry]
    ) -> [ManagedMenuBarEntry] {
        var counts: [String: Int] = [:]

        return entries.map { entry in
            let occurrence = counts[entry.sourceTitle, default: 0] + 1
            counts[entry.sourceTitle] = occurrence

            guard occurrence > 1 else { return entry }
            return ManagedMenuBarEntry(
                processIdentifier: entry.processIdentifier,
                applicationName: entry.applicationName,
                sourceTitle: entry.sourceTitle,
                displayTitle: "\(entry.sourceTitle) (\(occurrence))",
                itemIndex: entry.itemIndex,
                geometry: entry.geometry
            )
        }
    }

    static func truncatedTitle(_ title: String, limit: Int = 30) -> String {
        guard title.count > limit else { return title }
        return String(title.prefix(limit - 1)) + "…"
    }
}

enum MenuBarEntryMatcher {
    static func bestCandidateIndex(
        for entry: ManagedMenuBarEntry,
        candidates: [MenuBarCandidateIdentity]
    ) -> Int? {
        if candidates.indices.contains(entry.itemIndex),
           candidates[entry.itemIndex].title == entry.sourceTitle {
            return entry.itemIndex
        }

        return candidates.enumerated().filter {
            $0.element.title == entry.sourceTitle
        }.min(by: { lhs, rhs in
            abs(lhs.element.geometry.x - entry.geometry.x)
                < abs(rhs.element.geometry.x - entry.geometry.x)
        })?.offset
    }
}

private struct MenuBarApplicationSnapshot: Sendable {
    let processIdentifier: pid_t
    let name: String
}

private enum MenuBarAction: Sendable {
    case press
    case showMenu

    var accessibilityAction: String {
        switch self {
        case .press:
            return kAXPressAction as String
        case .showMenu:
            return kAXShowMenuAction as String
        }
    }
}

private let menuBarScannerLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.tenom.iClipboard",
    category: "MenuBar"
)

private final class SynchronizedMenuBarResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[ManagedMenuBarEntry]]

    init(workerCount: Int) {
        storage = Array(repeating: [], count: workerCount)
    }

    func set(_ entries: [ManagedMenuBarEntry], at index: Int) {
        lock.lock()
        defer { lock.unlock() }
        storage[index] = entries
    }

    var flattened: [ManagedMenuBarEntry] {
        lock.lock()
        defer { lock.unlock() }
        return storage.flatMap { $0 }
    }
}

private enum MenuBarAXReader {
    private static let attributeTimeout: Float = 0.18
    private static let actionTimeout: Float = 1

    static func scan(
        applications: [MenuBarApplicationSnapshot],
        maximumConcurrentApplications: Int
    ) -> [ManagedMenuBarEntry] {
        guard !applications.isEmpty else { return [] }

        let workerCount = min(
            max(1, maximumConcurrentApplications),
            applications.count
        )
        let results = SynchronizedMenuBarResults(workerCount: workerCount)

        DispatchQueue.concurrentPerform(iterations: workerCount) { workerIndex in
            var workerEntries: [ManagedMenuBarEntry] = []

            for applicationIndex in stride(
                from: workerIndex,
                to: applications.count,
                by: workerCount
            ) {
                workerEntries.append(
                    contentsOf: scanApplication(applications[applicationIndex])
                )
            }

            results.set(workerEntries, at: workerIndex)
        }

        let sorted = results.flattened.sorted { lhs, rhs in
            if lhs.geometry.x == rhs.geometry.x {
                return lhs.sourceTitle.localizedCaseInsensitiveCompare(
                    rhs.sourceTitle
                ) == .orderedAscending
            }
            return lhs.geometry.x < rhs.geometry.x
        }
        return MenuBarEntryPresenter.disambiguated(sorted)
    }

    static func perform(
        _ action: MenuBarAction,
        on entry: ManagedMenuBarEntry
    ) -> Bool {
        guard let children = menuBarChildren(
            processIdentifier: entry.processIdentifier
        ) else {
            return false
        }

        let candidates = children.map { element in
            MenuBarCandidateIdentity(
                title: resolvedTitle(
                    of: element,
                    applicationName: entry.applicationName
                ),
                geometry: geometry(of: element)
            )
        }

        guard let candidateIndex = MenuBarEntryMatcher.bestCandidateIndex(
            for: entry,
            candidates: candidates
        ) else {
            return false
        }

        let target = children[candidateIndex]
        configureTimeout(for: target, timeout: actionTimeout)
        let result = AXUIElementPerformAction(
            target,
            action.accessibilityAction as CFString
        )

        if result == .cannotComplete {
            menuBarScannerLogger.debug(
                "Menu bar action exceeded the AX timeout for pid \(entry.processIdentifier, privacy: .public)"
            )
        }
        return result == .success || result == .cannotComplete
    }

    private static func scanApplication(
        _ application: MenuBarApplicationSnapshot
    ) -> [ManagedMenuBarEntry] {
        guard let children = menuBarChildren(
            processIdentifier: application.processIdentifier
        ) else {
            return []
        }

        return children.enumerated().map { index, item in
            let title = resolvedTitle(
                of: item,
                applicationName: application.name
            )
            return ManagedMenuBarEntry(
                processIdentifier: application.processIdentifier,
                applicationName: application.name,
                sourceTitle: title,
                displayTitle: title,
                itemIndex: index,
                geometry: geometry(of: item)
            )
        }
    }

    private static func menuBarChildren(
        processIdentifier: pid_t
    ) -> [AXUIElement]? {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)

        guard let menuBarValue = copyAttribute(
            applicationElement,
            kAXExtrasMenuBarAttribute
        ) as CFTypeRef?,
              CFGetTypeID(menuBarValue) == AXUIElementGetTypeID() else {
            return nil
        }

        let menuBarElement = unsafeBitCast(
            menuBarValue,
            to: AXUIElement.self
        )

        return copyAttribute(
            menuBarElement,
            kAXChildrenAttribute
        ) as? [AXUIElement]
    }

    private static func resolvedTitle(
        of item: AXUIElement,
        applicationName: String
    ) -> String {
        if let title = stringAttribute(item, kAXTitleAttribute) {
            return title
        }
        if let description = stringAttribute(
            item,
            kAXDescriptionAttribute
        ) {
            return description
        }

        if let children = copyAttribute(
            item,
            kAXChildrenAttribute
        ) as? [AXUIElement],
           let child = children.first {
            if let title = stringAttribute(child, kAXTitleAttribute) {
                return title
            }
            if let description = stringAttribute(
                child,
                kAXDescriptionAttribute
            ) {
                return description
            }
        }

        return applicationName
    }

    private static func geometry(
        of element: AXUIElement
    ) -> MenuBarItemGeometry {
        configureTimeout(for: element, timeout: attributeTimeout)

        var positionReference: CFTypeRef?
        var sizeReference: CFTypeRef?

        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionReference
        ) == .success,
              let positionValue = positionReference,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              AXUIElementCopyAttributeValue(
                element,
                kAXSizeAttribute as CFString,
                &sizeReference
              ) == .success,
              let sizeValue = sizeReference,
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return .unknown
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(
            unsafeBitCast(positionValue, to: AXValue.self),
            .cgPoint,
            &point
        ),
              AXValueGetValue(
                unsafeBitCast(sizeValue, to: AXValue.self),
                .cgSize,
                &size
              ) else {
            return .unknown
        }

        return MenuBarItemGeometry(
            rect: CGRect(origin: point, size: size)
        )
    }

    private static func configureTimeout(
        for element: AXUIElement,
        timeout: Float
    ) {
        AXUIElementSetMessagingTimeout(element, timeout)
    }

    private static func copyAttribute(
        _ element: AXUIElement,
        _ attribute: String
    ) -> AnyObject? {
        configureTimeout(for: element, timeout: attributeTimeout)

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value
    }

    private static func stringAttribute(
        _ element: AXUIElement,
        _ attribute: String
    ) -> String? {
        guard let value = copyAttribute(element, attribute) as? String else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}


@MainActor
private final class MenuBarIconScanner {
    private static let deniedBundleIdentifiers: Set<String> = [
        "com.apple.controlcenter",
        "com.apple.systemuiserver"
    ]
    private static let maximumConcurrentApplications = 3
    private static let cacheFreshnessInterval: TimeInterval = 2

    private(set) var cachedEntries: [ManagedMenuBarEntry] = []
    private(set) var hasScanned = false

    private let scanQueue = DispatchQueue(
        label: "com.tenom.iClipboard.menu-bar-scan",
        qos: .userInitiated
    )
    private let actionQueue = DispatchQueue(
        label: "com.tenom.iClipboard.menu-bar-action",
        qos: .userInitiated
    )

    private var refreshInFlight = false
    private var needsForcedRescan = false
    private var pendingCompletions: [() -> Void] = []
    private var lastScanFinishedAt = Date.distantPast

    func refreshIfNeeded(
        force: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        if let completion {
            pendingCompletions.append(completion)
        }

        if !force,
           hasScanned,
           Date().timeIntervalSince(lastScanFinishedAt)
                < Self.cacheFreshnessInterval {
            finishPendingCompletions()
            return
        }

        guard !refreshInFlight else {
            if force {
                needsForcedRescan = true
            }
            return
        }

        startScan()
    }

    func perform(
        _ action: MenuBarAction,
        on entry: ManagedMenuBarEntry,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        actionQueue.async {
            let succeeded = MenuBarAXReader.perform(action, on: entry)
            Task { @MainActor in
                completion(succeeded)
            }
        }
    }

    private func startScan() {
        refreshInFlight = true
        needsForcedRescan = false

        let ownProcessIdentifier = getpid()
        let candidates: [MenuBarApplicationSnapshot] =
            NSWorkspace.shared.runningApplications.compactMap { application in
                guard application.processIdentifier != ownProcessIdentifier,
                      !application.isTerminated else {
                    return nil
                }

                if let bundleIdentifier = application.bundleIdentifier,
                   Self.deniedBundleIdentifiers.contains(bundleIdentifier) {
                    return nil
                }

                return MenuBarApplicationSnapshot(
                    processIdentifier: application.processIdentifier,
                    name: application.localizedName ?? "Unknown"
                )
            }

        let startedAt = Date()
        scanQueue.async { [weak self] in
            let entries = MenuBarAXReader.scan(
                applications: candidates,
                maximumConcurrentApplications:
                    Self.maximumConcurrentApplications
            )
            let elapsedMilliseconds = Int(
                Date().timeIntervalSince(startedAt) * 1_000
            )

            menuBarScannerLogger.debug(
                "Scanned \(candidates.count, privacy: .public) apps, found \(entries.count, privacy: .public) menu bar items in \(elapsedMilliseconds, privacy: .public)ms"
            )

            Task { @MainActor [weak self] in
                self?.finishScan(with: entries)
            }
        }
    }

    private func finishScan(with entries: [ManagedMenuBarEntry]) {
        if needsForcedRescan {
            startScan()
            return
        }

        cachedEntries = entries
        hasScanned = true
        refreshInFlight = false
        lastScanFinishedAt = Date()
        finishPendingCompletions()
    }

    private func finishPendingCompletions() {
        let completions = pendingCompletions
        pendingCompletions.removeAll(keepingCapacity: true)
        completions.forEach { $0() }
    }
}

@MainActor
final class MenuBarIconManager: NSObject, NSMenuDelegate {
    private let scanner = MenuBarIconScanner()
    private let accessibilityAuthorization =
        AccessibilityAuthorizationService.shared
    private var isMenuOpen = false
    private var iconCache: [pid_t: NSImage] = [:]

    override init() {
        super.init()

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(workspaceApplicationsDidChange(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(workspaceApplicationsDidChange(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        accessibilityAuthorization.refresh()
        if accessibilityAuthorization.isTrusted {
            scanner.refreshIfNeeded(force: true)
        }
    }

    @objc private func workspaceApplicationsDidChange(
        _ notification: Notification
    ) {
        iconCache.removeAll(keepingCapacity: true)

        guard accessibilityAuthorization.isTrusted else {
            return
        }
        scanner.refreshIfNeeded(force: true)
    }

    func makeMenu() -> NSMenu {
        accessibilityAuthorization.refresh()

        let menu = NSMenu()
        menu.delegate = self
        populate(menu)
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        accessibilityAuthorization.refresh()
        populate(menu)

        guard accessibilityAuthorization.isTrusted else {
            return
        }
        let previousEntries = scanner.cachedEntries
        scanner.refreshIfNeeded { [weak self, weak menu] in
            guard let self,
                  let menu,
                  self.isMenuOpen,
                  menu.highlightedItem == nil,
                  self.scanner.cachedEntries != previousEntries else {
                return
            }
            self.populate(menu)
        }
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()

        if accessibilityAuthorization.isTrusted {
            buildEntriesMenu(menu)
        } else {
            buildPermissionMenu(menu)
        }

        menu.addItem(.separator())

        let hint = disabledItem(
            "⌥ 点按打开图标菜单 · ⌘ 拖动可直接排序"
        )
        menu.addItem(hint)
        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "退出 iClipboard",
            action: #selector(quitApplication),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
    }

    private func buildEntriesMenu(_ menu: NSMenu) {
        let entries = scanner.cachedEntries

        guard !entries.isEmpty else {
            menu.addItem(
                disabledItem(
                    scanner.hasScanned
                        ? "未发现可管理的菜单栏图标"
                        : "正在扫描菜单栏图标…"
                )
            )
            return
        }

        menu.addItem(disabledItem("菜单栏图标"))

        for (index, entry) in entries.enumerated() {
            let item = NSMenuItem(
                title: MenuBarEntryPresenter.truncatedTitle(
                    entry.displayTitle
                ),
                action: #selector(entryClicked(_:)),
                keyEquivalent: index < 9 ? String(index + 1) : ""
            )
            item.target = self
            item.image = icon(for: entry.processIdentifier)
            item.representedObject = entry
            item.toolTip = "点按打开 · ⌥ 点按尝试打开该图标的右键菜单"
            if index < 9 {
                item.keyEquivalentModifierMask = []
            }
            menu.addItem(item)
        }
    }

    private func buildPermissionMenu(_ menu: NSMenu) {
        menu.addItem(
            disabledItem("需要辅助功能权限才能读取菜单栏图标")
        )

        let request = NSMenuItem(
            title: "授予辅助功能权限…",
            action: #selector(requestAccessibilityAccess),
            keyEquivalent: ""
        )
        request.target = self
        menu.addItem(request)
    }

    private func icon(for processIdentifier: pid_t) -> NSImage? {
        if let cached = iconCache[processIdentifier] {
            return cached
        }

        guard let source = NSRunningApplication(
            processIdentifier: processIdentifier
        )?.icon,
              let icon = source.copy() as? NSImage else {
            return nil
        }

        icon.size = NSSize(width: 18, height: 18)
        iconCache[processIdentifier] = icon
        return icon
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: nil,
            keyEquivalent: ""
        )
        item.isEnabled = false
        return item
    }

    @objc private func entryClicked(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? ManagedMenuBarEntry else {
            return
        }

        let action: MenuBarAction =
            NSApp.currentEvent?.modifierFlags.contains(.option) == true
                ? .showMenu
                : .press

        scanner.perform(action, on: entry) { succeeded in
            guard !succeeded else { return }

            self.scanner.refreshIfNeeded(force: true)

            if action == .press,
               let application = NSRunningApplication(
                processIdentifier: entry.processIdentifier
               ),
               application.activate(options: []) {
                return
            }

            menuBarScannerLogger.notice(
                "Menu bar action failed for pid \(entry.processIdentifier, privacy: .public)"
            )
            NSSound.beep()
        }
    }

    @objc private func requestAccessibilityAccess() {
        accessibilityAuthorization.requestAccess()
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }
}
