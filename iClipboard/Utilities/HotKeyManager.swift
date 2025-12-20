import Carbon
import SwiftUI
import Combine

struct KeyboardShortcut: Codable, Equatable {
    var keyCode: Int
    var modifiers: Int // Using NSEvent.ModifierFlags.rawValue or Carbon modifier flags
    
    var isEmpty: Bool {
        return keyCode == -1
    }
    
    static let empty = KeyboardShortcut(keyCode: -1, modifiers: 0)
}

class HotKeyManager: ObservableObject {
    static let shared = HotKeyManager()
    
    private var hotKeyRef: EventHotKeyRef?
    private var handler: (() -> Void)?
    private var eventHandlerRef: EventHandlerRef?
    
    @Published var currentShortcut: KeyboardShortcut = .empty {
        didSet {
            register()
            saveToDefaults()
        }
    }
    
    private let defaultsKey = "globalShortcut"
    
    private init() {
        loadFromDefaults()
        installEventHandler()
    }
    
    func setShortcut(_ shortcut: KeyboardShortcut) {
        self.currentShortcut = shortcut
    }
    
    func setHandler(action: @escaping () -> Void) {
        self.handler = action
    }
    
    private func register() {
        // Unregister previous
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        
        guard !currentShortcut.isEmpty else { return }
        
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType("iClp".asResID) 
        hotKeyID.id = 1
        
        let carbonModifiers = convertToCarbonModifiers(param: currentShortcut.modifiers)
        
        let status = RegisterEventHotKey(
            UInt32(currentShortcut.keyCode),
            carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        
        if status != noErr {
            print("Failed to register hotkey: \(status)")
        }
    }
    
    func invokeHandler() {
        handler?()
    }
    
    private func installEventHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        
        // Pass the global function directly
        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &eventType, nil, &eventHandlerRef)
    }
    
    private func convertToCarbonModifiers(param: Int) -> UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(param))
        var carbonFlags: UInt32 = 0
        
        if flags.contains(.command) { carbonFlags |= UInt32(cmdKey) }
        if flags.contains(.option) { carbonFlags |= UInt32(optionKey) }
        if flags.contains(.control) { carbonFlags |= UInt32(controlKey) }
        if flags.contains(.shift) { carbonFlags |= UInt32(shiftKey) }
        
        return carbonFlags
    }
    
    // MARK: - Persistence
    
    private func saveToDefaults() {
        if let data = try? JSONEncoder().encode(currentShortcut) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
    
    private func loadFromDefaults() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) {
            self.currentShortcut = shortcut
        }
    }
}

// Global C-convention handler
private func hotKeyHandler(nextHandler: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    
    // 'iClp'
    let signature = "iClp".asResID
    if hotKeyID.signature == signature && hotKeyID.id == 1 {
        DispatchQueue.main.async {
            HotKeyManager.shared.invokeHandler()
        }
        return OSStatus(noErr)
    }
    
    return OSStatus(eventNotHandledErr)
}

extension String {
    // Helper to convert String to OSType (FourCharCode)
    var asResID: UInt32 {
        var result: UInt32 = 0
        if let data = self.data(using: .ascii) {
            for i in 0..<min(data.count, 4) {
                result = (result << 8) + UInt32(data[i])
            }
            // Pad if less than 4 chars
            for _ in data.count..<4 {
                 result = result << 8
            }
        }
        return result
    }
}
