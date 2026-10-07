import Foundation

enum SettingsSection: String, CaseIterable, Identifiable {
    case history
    case capture
    case translation
    case keyboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .history: return "历史记录"
        case .capture: return "捕获类型"
        case .translation: return "划词翻译"
        case .keyboard: return "快捷键"
        }
    }

    var icon: String {
        switch self {
        case .history: return "clock.arrow.circlepath"
        case .capture: return "slider.horizontal.3"
        case .translation: return "character.bubble"
        case .keyboard: return "keyboard"
        }
    }
}
