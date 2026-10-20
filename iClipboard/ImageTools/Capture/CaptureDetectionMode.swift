import Foundation

enum CaptureDetectionMode: String, CaseIterable, Identifiable, Sendable {
    case none
    case window
    case element

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "不检测"
        case .window: return "仅窗口"
        case .element: return "检测元素"
        }
    }
}
