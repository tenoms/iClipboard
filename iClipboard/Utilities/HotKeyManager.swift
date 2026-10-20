import Carbon
import SwiftUI
import Combine

struct KeyboardShortcut: Codable, Equatable {
    var keyCode: Int
    var modifiers: Int // NSEvent.ModifierFlags.rawValue, not Carbon modifier flags.

    static let supportedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    static let empty = KeyboardShortcut(keyCode: -1, modifiers: 0)

    var isEmpty: Bool { keyCode == -1 }

    var normalized: KeyboardShortcut {
        guard !isEmpty else { return .empty }
        let flags = NSEvent.ModifierFlags(rawValue: UInt(bitPattern: modifiers))
        return KeyboardShortcut(
            keyCode: keyCode,
            modifiers: Int(flags.intersection(Self.supportedModifiers).rawValue)
        )
    }

    var carbonModifiers: UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(normalized.modifiers))
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    var isValid: Bool {
        isEmpty || ((0...127).contains(keyCode)
            && !(54...63).contains(keyCode)
            && normalized.modifiers != 0)
    }
}

enum HotKeyAction: UInt32, CaseIterable, Identifiable {
    case history = 1
    case capture = 2
    case pinClipboard = 3
    case recognizeScreen = 4
    // ID 5 belonged to standalone color picking; never reuse retired bindings.
    case closePin = 6

    var id: UInt32 { rawValue }

    var isGlobal: Bool {
        switch self {
        case .history, .capture, .pinClipboard: return true
        case .recognizeScreen, .closePin: return false
        }
    }

    var title: String {
        switch self {
        case .history: return "显示/隐藏面板"
        case .capture: return "截取屏幕"
        case .pinClipboard: return "贴图"
        case .recognizeScreen: return "复制图像全文"
        case .closePin: return "关闭贴图"
        }
    }

    var helpText: String {
        switch self {
        case .history: return "快速呼出或隐藏 iClipboard 历史面板。"
        case .capture: return "选择屏幕区域并截图。"
        case .pinClipboard: return "截图中贴出当前选区并退出；其它时候贴出剪贴板图像。"
        case .recognizeScreen: return "仅在截图选区或获得键盘焦点的可见贴图中生效，不注册全局按键。截图中复制当前选区全文并退出，贴图复制后保留窗口；准备、未框选或文字输入中不操作，不会启动截图或识别剪贴板图像，也不拦截其它窗口输入。"
        case .closePin: return "仅关闭当前获得键盘焦点的可见贴图，不注册全局按键；不会关闭鼠标下或最近显示的其它贴图，不拦截其它窗口输入。"
        }
    }
}

// Carbon registration and published state belong to the main actor.
// @preconcurrency preserves synchronous Swift 5 callers such as WindowManager,
// which already run on the main thread but have not adopted actor annotations.
@preconcurrency @MainActor
final class HotKeyManager: ObservableObject {
    typealias RegisterHotKey = (UInt32, UInt32, EventHotKeyID, inout EventHotKeyRef?) -> OSStatus
    typealias UnregisterHotKey = (EventHotKeyRef) -> OSStatus
    typealias SystemConflictChecker = (KeyboardShortcut) -> SystemShortcutConflictResult

    static let shared = HotKeyManager()

    private static let defaultsKey = "globalShortcuts"
    private static let legacyDefaultsKey = "globalShortcut"

    private let defaults: UserDefaults
    private let registerHotKey: RegisterHotKey
    private let conflictChecker: SystemConflictChecker?
    private let registrations: HotKeyRegistrations
    nonisolated fileprivate let dispatchState = HotKeyDispatchState()
    private var handlers: [HotKeyAction: () -> Void] = [:]
    private var eventHandlerError: String?
    private var pendingShortcuts: [HotKeyAction: KeyboardShortcut] = [:]

    @Published private var shortcuts: [HotKeyAction: KeyboardShortcut] = [:]
    @Published private var shortcutErrors: [HotKeyAction: String] = [:]
    @Published private var registrationErrors: [HotKeyAction: String] = [:]
    @Published private var suspensionDepth = 0
    @Published private var systemConflictResults: [HotKeyAction: SystemShortcutConflictResult] = [:]

    var isRegistrationSuspended: Bool { suspensionDepth > 0 }

    // Compatibility with the original history-only shortcut and SwiftUI bindings.
    var currentShortcut: KeyboardShortcut {
        get { shortcut(for: .history) }
        set { setShortcut(newValue, for: .history) }
    }

    init(
        defaults: UserDefaults = .standard,
        registerHotKey: @escaping RegisterHotKey = { keyCode, modifiers, id, ref in
            RegisterEventHotKey(
                keyCode, modifiers, id, GetApplicationEventTarget(),
                0, &ref
            )
        },
        unregisterHotKey: @escaping UnregisterHotKey = { UnregisterEventHotKey($0) },
        installEventHandler shouldInstallEventHandler: Bool = true,
        conflictChecker: SystemConflictChecker? = { SystemShortcutConflicts.check($0) }
    ) {
        self.defaults = defaults
        self.registerHotKey = registerHotKey
        self.conflictChecker = conflictChecker
        self.registrations = HotKeyRegistrations(unregister: unregisterHotKey)
        loadFromDefaults()
        if shouldInstallEventHandler {
            installEventHandler()
        }
        restoreRegistrations()
    }

    func setHandler(for action: HotKeyAction, action handler: @escaping () -> Void) {
        handlers[action] = handler
    }

    func setHandler(action: @escaping () -> Void) {
        setHandler(for: .history, action: action)
    }

    func shortcut(for action: HotKeyAction) -> KeyboardShortcut {
        shortcuts[action] ?? .empty
    }

    func setShortcut(_ shortcut: KeyboardShortcut) {
        setShortcut(shortcut, for: .history)
    }

    func setShortcut(_ shortcut: KeyboardShortcut, for action: HotKeyAction) {
        guard !action.isGlobal || eventHandlerError == nil else { return }
        systemConflictResults[action] = nil
        let candidate = shortcut.normalized
        guard candidate.isValid else {
            shortcutErrors[action] = "请使用 ⌘、⌥、⌃ 或 ⇧ 中至少一个修饰键和一个普通按键。"
            return
        }
        if !candidate.isEmpty, let conflict = HotKeyAction.allCases.first(where: {
            $0 != action && (self.shortcut(for: $0) == candidate || pendingShortcuts[$0] == candidate)
        }) {
            shortcutErrors[action] = "此快捷键已用于“\(conflict.title)”，请使用其他组合。"
            return
        }
        shortcutErrors[action] = nil
        guard !hasSystemConflict(candidate, for: action) else { return }

        // Defer changes made by clients during recording. Only commit after Carbon
        // accepts them, once the original registrations have been restored.
        if isRegistrationSuspended {
            pendingShortcuts[action] = candidate
            registrationErrors[action] = nil
            return
        }
        if candidate == self.shortcut(for: action), !action.isGlobal || candidate.isEmpty || registrations.refs[action] != nil {
            registrationErrors[action] = nil
            return
        }

        var replacementRef: EventHotKeyRef?
        if action.isGlobal, !candidate.isEmpty {
            guard let ref = makeRegistration(for: action, shortcut: candidate, checkSystemConflict: false) else { return }
            replacementRef = ref
        }

        // Register the replacement first: a Carbon failure must never discard the
        // working registration or overwrite its persisted shortcut.
        if let oldRef = registrations.refs[action] {
            let status = registrations.unregister(oldRef)
            guard status == noErr else {
                if let replacementRef { _ = registrations.unregister(replacementRef) }
                registrationErrors[action] = "无法替换原快捷键（错误 \(status)），已保留原设置。"
                return
            }
        }
        registrations.refs[action] = replacementRef
        dispatchState.invalidate()
        shortcuts[action] = candidate
        registrationErrors[action] = nil
        saveToDefaults()
    }

    func registrationError(for action: HotKeyAction) -> String? {
        (action.isGlobal ? eventHandlerError : nil) ?? shortcutErrors[action] ?? registrationErrors[action]
    }

    func hasConfirmedSystemConflict(for action: HotKeyAction) -> Bool {
        systemConflictResults[action] == .conflict
    }

    func systemConflictWarning(for action: HotKeyAction) -> String? {
        guard case let .unknown(status) = systemConflictResults[action] else { return nil }
        return "无法查询系统快捷键（错误 \(status)）；系统冲突状态未知，注册成功也不代表实体按键已验证。"
    }

    private func hasSystemConflict(_ shortcut: KeyboardShortcut, for action: HotKeyAction) -> Bool {
        guard action.isGlobal, !shortcut.isEmpty, let conflictChecker else {
            systemConflictResults[action] = nil
            return false
        }
        let result = conflictChecker(shortcut)
        systemConflictResults[action] = result
        guard result == .conflict else { return false }
        registrationErrors[action] = "此组合与已启用的系统快捷键冲突。请在“系统设置 → 键盘 → 键盘快捷键”中检查，或使用其他组合。原设置未更改。"
        return true
    }

    func suspendRegistration() {
        guard eventHandlerError == nil else { return }
        suspensionDepth += 1
        guard suspensionDepth == 1 else { return }
        dispatchState.invalidate()
        var failed = false
        for action in HotKeyAction.allCases {
            guard let ref = registrations.refs[action] else { continue }
            let status = registrations.unregister(ref)
            if status == noErr {
                registrations.refs[action] = nil
            } else {
                failed = true
                registrationErrors[action] = "无法暂停快捷键（错误 \(status)）。"
            }
        }
        if failed {
            suspensionDepth = 0
            restoreRegistrations()
        }
    }

    func resumeRegistration() {
        guard suspensionDepth > 0 else { return }
        suspensionDepth -= 1
        guard !isRegistrationSuspended else { return }
        dispatchState.invalidate()
        restoreRegistrations()
        let pending = pendingShortcuts
        pendingShortcuts.removeAll()
        for action in HotKeyAction.allCases {
            if let shortcut = pending[action] {
                setShortcut(shortcut, for: action)
            }
        }
    }

    func invokeHandler() {
        invokeHandler(for: .history)
    }

    func invokeHandler(for action: HotKeyAction) {
        guard !isRegistrationSuspended else { return }
        handlers[action]?()
    }

    func invokeHandler(forHotKeyID id: UInt32) {
        guard let action = HotKeyAction(rawValue: id), action.isGlobal else { return }
        invokeHandler(for: action)
    }

    /// Matching never registers a global key. The owning window supplies context
    /// and invokes the action synchronously, before the event can change focus.
    func contextualAction(for event: NSEvent) -> HotKeyAction? {
        guard event.type == .keyDown, !isRegistrationSuspended else { return nil }
        let candidate = KeyboardShortcut(keyCode: Int(event.keyCode),
                                         modifiers: Int(event.modifierFlags.rawValue)).normalized
        return HotKeyAction.allCases.first {
            !$0.isGlobal && !shortcut(for: $0).isEmpty && shortcut(for: $0) == candidate
        }
    }

    nonisolated func enqueueNativeInvocation(forHotKeyID id: UInt32) {
        let generation = dispatchState.snapshot()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.dispatchState.snapshot() == generation else { return }
            self.invokeHandler(forHotKeyID: id)
        }
    }

    private func makeRegistration(for action: HotKeyAction, shortcut: KeyboardShortcut,
                                  checkSystemConflict: Bool = true) -> EventHotKeyRef? {
        if checkSystemConflict, hasSystemConflict(shortcut, for: action) { return nil }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: hotKeySignature, id: action.rawValue)
        let status = registerHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers, id, &ref)
        guard status == noErr, let registeredRef = ref else {
            if let ref { _ = registrations.unregister(ref) }
            if status == OSStatus(eventHotKeyExistsErr) {
                registrationErrors[action] = "快捷键注册冲突（Carbon 错误 \(status)），可能被系统或其他应用占用。请使用其他组合。原设置未更改。"
            } else {
                registrationErrors[action] = "快捷键注册失败（错误 \(status == noErr ? OSStatus(paramErr) : status)），原设置未更改。"
            }
            return nil
        }
        registrationErrors[action] = nil
        return registeredRef
    }

    private func restoreRegistrations() {
        guard eventHandlerError == nil else { return }
        for action in HotKeyAction.allCases where action.isGlobal {
            let shortcut = shortcut(for: action)
            guard !shortcut.isEmpty, registrations.refs[action] == nil else { continue }
            registrations.refs[action] = makeRegistration(for: action, shortcut: shortcut)
        }
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(), hotKeyHandler, 1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(), &registrations.eventHandlerRef
        )
        if status != noErr {
            eventHandlerError = "无法安装全局快捷键监听（错误 \(status)）。"
        }
    }

    // MARK: - Persistence

    private func saveToDefaults() {
        let values = Dictionary(uniqueKeysWithValues: HotKeyAction.allCases.map {
            (String($0.rawValue), shortcut(for: $0))
        })
        if let data = try? JSONEncoder().encode(values) {
            defaults.set(data, forKey: Self.defaultsKey)
            defaults.removeObject(forKey: Self.legacyDefaultsKey)
        }
    }

    private func loadFromDefaults() {
        let values = defaults.data(forKey: Self.defaultsKey).flatMap {
            try? JSONDecoder().decode([String: KeyboardShortcut].self, from: $0)
        } ?? [:]
        let legacy = defaults.data(forKey: Self.legacyDefaultsKey).flatMap {
            try? JSONDecoder().decode(KeyboardShortcut.self, from: $0)
        }
        for action in HotKeyAction.allCases {
            let stored = values[String(action.rawValue)] ?? (action == .history ? legacy : nil) ?? .empty
            let shortcut = stored.normalized
            guard shortcut.isValid else {
                shortcutErrors[action] = "保存的快捷键无效，请重新录制。"
                continue
            }
            if !shortcut.isEmpty, shortcuts.values.contains(shortcut) {
                shortcutErrors[action] = "保存的快捷键与其他动作重复，请重新录制。"
                continue
            }
            shortcuts[action] = shortcut
        }
        if legacy != nil || values["5"] != nil {
            saveToDefaults()
        }
    }
}

// A native event may be queued before recording starts. Keep its generation
// outside the actor so the C callback can snapshot it without changing queues.
fileprivate final class HotKeyDispatchState: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func snapshot() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    func invalidate() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }
}

// Own the Carbon resources independently of the observable actor's deinit.
private final class HotKeyRegistrations {
    var refs: [HotKeyAction: EventHotKeyRef] = [:]
    var eventHandlerRef: EventHandlerRef?
    let unregister: HotKeyManager.UnregisterHotKey

    init(unregister: @escaping HotKeyManager.UnregisterHotKey) {
        self.unregister = unregister
    }

    deinit {
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
        for ref in refs.values { _ = unregister(ref) }
    }
}

private let hotKeySignature: OSType = 0x69436C70 // 'iClp'

// A plain C-compatible function, deliberately outside any actor-isolated type.
private func hotKeyHandler(nextHandler: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == hotKeySignature,
          HotKeyAction(rawValue: hotKeyID.id)?.isGlobal == true else {
        return OSStatus(eventNotHandledErr)
    }
    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    manager.enqueueNativeInvocation(forHotKeyID: hotKeyID.id)
    return OSStatus(noErr)
}
