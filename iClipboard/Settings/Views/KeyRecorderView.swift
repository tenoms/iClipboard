import SwiftUI

struct KeyRecorderView: View {
    @Environment(\.appPalette) private var palette
    @Binding var shortcut: KeyboardShortcut
    @ObservedObject var hotKeyManager = HotKeyManager.shared
    var isInteractive: Bool = true
    var body: some View {
        ShortcutRecorderRepresentable(shortcut: $shortcut, hotKeyManager: hotKeyManager,
                                      isInteractive: isInteractive, palette: palette)
            .fixedSize()
    }

    func keyCodeToString(_ keyCode: UInt16) -> String {
        SpecialKey(rawValue: Int(keyCode))?.description ?? "键码 \(keyCode)"
    }
}

// Standard macOS virtual key names, including ANSI punctuation and keypad keys.
enum SpecialKey: Int, CaseIterable {
    case kA = 0x00, kS = 0x01, kD = 0x02, kF = 0x03, kH = 0x04, kG = 0x05, kZ = 0x06, kX = 0x07
    case kC = 0x08, kV = 0x09, kISOSection = 0x0A, kB = 0x0B, kQ = 0x0C, kW = 0x0D, kE = 0x0E, kR = 0x0F
    case kY = 0x10, kT = 0x11, k1 = 0x12, k2 = 0x13, k3 = 0x14, k4 = 0x15, k6 = 0x16, k5 = 0x17
    case kEqual = 0x18, k9 = 0x19, k7 = 0x1A, kMinus = 0x1B, k8 = 0x1C, k0 = 0x1D
    case kRightBracket = 0x1E, kO = 0x1F, kU = 0x20, kLeftBracket = 0x21, kI = 0x22, kP = 0x23
    case kReturn = 0x24, kL = 0x25, kJ = 0x26, kQuote = 0x27, kK = 0x28, kSemicolon = 0x29, kBackslash = 0x2A
    case kComma = 0x2B, kSlash = 0x2C, kN = 0x2D, kM = 0x2E, kPeriod = 0x2F
    case kTab = 0x30, kSpace = 0x31, kGrave = 0x32, kDelete = 0x33, kEscape = 0x35
    case kF17 = 0x40, kKeypadDecimal = 0x41, kKeypadMultiply = 0x43, kKeypadPlus = 0x45
    case kKeypadClear = 0x47, kKeypadDivide = 0x4B, kKeypadEnter = 0x4C, kKeypadMinus = 0x4E
    case kF18 = 0x4F, kF19 = 0x50, kKeypadEquals = 0x51
    case kKeypad0 = 0x52, kKeypad1 = 0x53, kKeypad2 = 0x54, kKeypad3 = 0x55, kKeypad4 = 0x56
    case kKeypad5 = 0x57, kKeypad6 = 0x58, kKeypad7 = 0x59, kF20 = 0x5A, kKeypad8 = 0x5B, kKeypad9 = 0x5C
    case kJISYen = 0x5D, kJISUnderscore = 0x5E, kJISKeypadComma = 0x5F
    case kF5 = 0x60, kF6 = 0x61, kF7 = 0x62, kF3 = 0x63, kF8 = 0x64, kF9 = 0x65
    case kJISEisu = 0x66, kF11 = 0x67, kJISKana = 0x68, kF13 = 0x69, kF16 = 0x6A, kF14 = 0x6B
    case kF10 = 0x6D, kF12 = 0x6F, kF15 = 0x71, kHelp = 0x72, kHome = 0x73, kPageUp = 0x74
    case kForwardDelete = 0x75, kF4 = 0x76, kEnd = 0x77, kF2 = 0x78, kPageDown = 0x79, kF1 = 0x7A
    case kLeft = 0x7B, kRight = 0x7C, kDown = 0x7D, kUp = 0x7E

    var description: String {
        switch self {
        case .kA: return "A"; case .kS: return "S"; case .kD: return "D"; case .kF: return "F"; case .kH: return "H"; case .kG: return "G"; case .kZ: return "Z"; case .kX: return "X"
        case .kC: return "C"; case .kV: return "V"; case .kB: return "B"; case .kQ: return "Q"; case .kW: return "W"; case .kE: return "E"; case .kR: return "R"
        case .kY: return "Y"; case .kT: return "T"; case .k1: return "1"; case .k2: return "2"; case .k3: return "3"; case .k4: return "4"; case .k6: return "6"; case .k5: return "5"
        case .kEqual: return "="; case .k9: return "9"; case .k7: return "7"; case .kMinus: return "-"; case .k8: return "8"; case .k0: return "0"
        case .kRightBracket: return "]"; case .kO: return "O"; case .kU: return "U"; case .kLeftBracket: return "["; case .kI: return "I"; case .kP: return "P"
        case .kL: return "L"; case .kJ: return "J"; case .kQuote: return "'"; case .kK: return "K"; case .kSemicolon: return ";"; case .kBackslash: return "\\"
        case .kComma: return ","; case .kSlash: return "/"; case .kN: return "N"; case .kM: return "M"; case .kPeriod: return "."; case .kGrave: return "`"
        case .kReturn: return "↩"; case .kTab: return "⇥"; case .kSpace: return "Space"; case .kDelete: return "⌫"; case .kEscape: return "Esc"
        case .kLeft: return "←"; case .kRight: return "→"; case .kDown: return "↓"; case .kUp: return "↑"
        case .kHome: return "Home"; case .kEnd: return "End"; case .kPageUp: return "Page Up"; case .kPageDown: return "Page Down"
        case .kHelp: return "Help"; case .kForwardDelete: return "⌦"
        case .kF1: return "F1"; case .kF2: return "F2"; case .kF3: return "F3"; case .kF4: return "F4"; case .kF5: return "F5"
        case .kF6: return "F6"; case .kF7: return "F7"; case .kF8: return "F8"; case .kF9: return "F9"; case .kF10: return "F10"
        case .kF11: return "F11"; case .kF12: return "F12"; case .kF13: return "F13"; case .kF14: return "F14"; case .kF15: return "F15"
        case .kF16: return "F16"; case .kF17: return "F17"; case .kF18: return "F18"; case .kF19: return "F19"; case .kF20: return "F20"
        case .kKeypad0: return "小键盘 0"; case .kKeypad1: return "小键盘 1"; case .kKeypad2: return "小键盘 2"; case .kKeypad3: return "小键盘 3"; case .kKeypad4: return "小键盘 4"
        case .kKeypad5: return "小键盘 5"; case .kKeypad6: return "小键盘 6"; case .kKeypad7: return "小键盘 7"; case .kKeypad8: return "小键盘 8"; case .kKeypad9: return "小键盘 9"
        case .kKeypadDecimal: return "小键盘 ."; case .kKeypadMultiply: return "小键盘 ×"; case .kKeypadPlus: return "小键盘 +"; case .kKeypadDivide: return "小键盘 ÷"
        case .kKeypadMinus: return "小键盘 -"; case .kKeypadEquals: return "小键盘 ="; case .kKeypadEnter: return "小键盘 Enter"; case .kKeypadClear: return "Clear"
        case .kISOSection: return "§"; case .kJISYen: return "¥"; case .kJISUnderscore: return "_"; case .kJISKeypadComma: return "小键盘 ,"
        case .kJISEisu: return "英数"; case .kJISKana: return "かな"
        }
    }
}
