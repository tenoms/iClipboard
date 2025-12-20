import SwiftUI
import Carbon

struct KeyRecorderView: View {
    @Binding var shortcut: KeyboardShortcut
    @State private var isRecording = false
    @State private var monitor: Any?
    
    var body: some View {
        Button {
            isRecording = true
            startRecording()
        } label: {
            HStack(spacing: 4) {
                if isRecording {
                    Text("输入快捷键...")
                        .foregroundStyle(.secondary)
                } else if shortcut.isEmpty {
                    Text("点击录制")
                        .foregroundStyle(.secondary)
                } else {
                    Text(shortcutString(for: shortcut))
                        .fontWeight(.medium)
                    
                    Button {
                        shortcut = .empty
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isRecording ? Color.accentColor.opacity(0.1) : Color.gray.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isRecording ? Color.accentColor : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onDisappear {
            stopRecording()
        }
    }
    
    private func startRecording() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Ignore just modifier keys pressed alone
            if isModifierOnly(event) {
                return event
            }
            
            // Escape to cancel/clear
            if event.keyCode == kVK_Escape {
                stopRecording()
                return nil
            }
            
            // Validation: Shortcut must consist of at least 2 keys (Modifier + Key)
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            
            // If no modifiers are pressed, it's a single key (e.g. "A"). Reject it.
            if modifiers.isEmpty {
                NSSound.beep()
                return nil
            }
            
            let newShortcut = KeyboardShortcut(keyCode: Int(event.keyCode), modifiers: Int(event.modifierFlags.rawValue))
            shortcut = newShortcut
            stopRecording()
            return nil // Consume event
        }
    }
    
    private func stopRecording() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
    }
    
    private func isModifierOnly(_ event: NSEvent) -> Bool {
        let modifierKeyCodes: Set<Int> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        return modifierKeyCodes.contains(Int(event.keyCode))
    }
    
    private func shortcutString(for shortcut: KeyboardShortcut) -> String {
        var result = ""
        let flags = NSEvent.ModifierFlags(rawValue: UInt(shortcut.modifiers))
        
        if flags.contains(.control) { result += "⌃ " }
        if flags.contains(.option) { result += "⌥ " }
        if flags.contains(.shift) { result += "⇧ " }
        if flags.contains(.command) { result += "⌘ " }
        
        if let chars = keyString(for: shortcut.keyCode) {
            result += chars.uppercased()
        }
        
        return result
    }
    
    private func keyString(for keyCode: Int) -> String? {
        switch keyCode {
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "Esc"
        default:
            return formatKey(keyCode)
        }
    }
    
    private func formatKey(_ code: Int) -> String {
        return keyCodeToString(UInt16(code))
    }
    
    func keyCodeToString(_ keyCode: UInt16) -> String {
        return SpecialKey(rawValue: Int(keyCode))?.description ?? "KEY"
    }
}

// Minimal helper to display keys - INCOMPLETE BUT SUFFICIENT FOR MVP of Command+Shift+V
enum SpecialKey: Int {
    case kA = 0x00, kS = 0x01, kD = 0x02, kF = 0x03, kH = 0x04, kG = 0x05, kZ = 0x06, kX = 0x07
    case kC = 0x08, kV = 0x09, kB = 0x0B, kQ = 0x0C, kW = 0x0D, kE = 0x0E, kR = 0x0F
    case kY = 0x10, kT = 0x11, k1 = 0x12, k2 = 0x13, k3 = 0x14, k4 = 0x15, k6 = 0x16, k5 = 0x17
    case kEqual = 0x18, k9 = 0x19, k7 = 0x1A, kMinus = 0x1B, k8 = 0x1C, k0 = 0x1D
    case kRightBracket = 0x1E, kO = 0x1F, kU = 0x20, kLeftBracket = 0x21, kI = 0x22, kP = 0x23
    case kL = 0x25, kJ = 0x26, kQuote = 0x27, kK = 0x28, kSemicolon = 0x29, kBackslash = 0x2A
    case kComma = 0x2B, kSlash = 0x2C, kN = 0x2D, kM = 0x2E, kPeriod = 0x2F, kGrave = 0x32
    
    var description: String {
        switch self {
        case .kA: return "A"; case .kS: return "S"; case .kD: return "D"; case .kF: return "F"; case .kH: return "H"; case .kG: return "G"; case .kZ: return "Z"; case .kX: return "X"
        case .kC: return "C"; case .kV: return "V"; case .kB: return "B"; case .kQ: return "Q"; case .kW: return "W"; case .kE: return "E"; case .kR: return "R"
        case .kY: return "Y"; case .kT: return "T"; case .k1: return "1"; case .k2: return "2"; case .k3: return "3"; case .k4: return "4"; case .k6: return "6"; case .k5: return "5"
        case .kEqual: return "="; case .k9: return "9"; case .k7: return "7"; case .kMinus: return "-"; case .k8: return "8"; case .k0: return "0"
        case .kRightBracket: return "]"; case .kO: return "O"; case .kU: return "U"; case .kLeftBracket: return "["; case .kI: return "I"; case .kP: return "P"
        case .kL: return "L"; case .kJ: return "J"; case .kQuote: return "'"; case .kK: return "K"; case .kSemicolon: return ";"; case .kBackslash: return "\\"
        case .kComma: return ","; case .kSlash: return "/"; case .kN: return "N"; case .kM: return "M"; case .kPeriod: return "."; case .kGrave: return "`"
        }
    }
}
