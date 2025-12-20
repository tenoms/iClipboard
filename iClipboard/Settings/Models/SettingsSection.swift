import Foundation

enum SettingsSection: String, CaseIterable, Identifiable {
    case history
    case capture
    case keyboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .history: return "历史记录"
        case .capture: return "捕获类型"
        case .keyboard: return "快捷键"
        }
    }

    var icon: String {
        switch self {
        case .history: return "clock.arrow.circlepath"
        case .capture: return "slider.horizontal.3"
        case .keyboard: return "keyboard"
        }
    }
}
